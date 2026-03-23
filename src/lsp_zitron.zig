//! Zitron Language Server
//!
//! Implementation of a language server for Zitron, an LALR(1) parser
//! generator based on a port of D. Richard Hipp's Lemon.

/// The language-server name reported during LSP initialization.
pub const server_name = "lsp_zitron";

const server_version = "0.0.1";

const ParseSummary = struct {
    root_kind: []const u8,
    has_error: bool,
};

const DocumentState = struct {
    source: []u8,
    version: i32,
    parsed: ParseSummary,
    tree: *ts.Tree,
};

const ParsedDocument = struct {
    summary: ParseSummary,
    tree: *ts.Tree,
};

const SemanticKind = enum {
    rule_definition,
    rule_reference,
    action_definition,
    action_implementation,
};

const SemanticSymbol = struct {
    kind: SemanticKind,
    capture_name: []const u8,
    symbol_name: []const u8,
    name_node: ts.Node,
    semantic_node: ts.Node,
    enclosing_kind: []const u8,
};

const Resolution = union(enum) {
    no_match,
    unsupported_zig_code,
    symbol: SemanticSymbol,
};

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

/// Errors that can occur while loading the configured fixture source.
pub const FixtureError = OOM || std.fs.File.OpenError || std.fs.File.ReadError || error{FileTooBig};

fn parseDocument(source: []const u8) Server.Error!ParsedDocument {
    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(zitronLanguage());

    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    const root = tree.rootNode();
    return .{
        .summary = .{
            .root_kind = root.kind(),
            .has_error = root.hasError(),
        },
        .tree = tree,
    };
}

fn serverCapabilities() types.ServerCapabilities {
    return .{
        .textDocumentSync = .{
            .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Full,
            },
        },
        .hoverProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = true },
    };
}

/// LSP server state and handlers for Zitron grammars.
pub const Server = struct {
    /// Errors produced while parsing or updating server-managed documents.
    pub const Error = OOM || ts.Query.Error || error{
        IncompatibleLanguage,
        InvalidParams,
        ParseFailed,
    };

    allocator: std.mem.Allocator,
    scratch_arena: std.heap.ArenaAllocator,
    documents: std.StringHashMapUnmanaged(DocumentState),
    tags_query: *ts.Query,

    /// Creates a server instance and compiles the grammar tag query.
    pub fn init(allocator: std.mem.Allocator) ts.Query.Error!Server {
        var query_error_offset: u32 = 0;
        const tags_query = try ts.Query.create(zitronLanguage(), tags_query_source, &query_error_offset);
        errdefer tags_query.destroy();

        return .{
            .allocator = allocator,
            .scratch_arena = std.heap.ArenaAllocator.init(allocator),
            .documents = .empty,
            .tags_query = tags_query,
        };
    }

    /// Releases all document state and query resources owned by the server.
    pub fn deinit(server: *Server) void {
        var it = server.documents.iterator();
        while (it.next()) |entry| {
            server.allocator.free(entry.key_ptr.*);
            server.allocator.free(entry.value_ptr.source);
            entry.value_ptr.tree.destroy();
        }
        server.documents.deinit(server.allocator);
        server.scratch_arena.deinit();
        server.tags_query.destroy();
    }

    fn scratchAllocator(server: *Server) std.mem.Allocator {
        _ = server.scratch_arena.reset(.retain_capacity);
        return server.scratch_arena.allocator();
    }

    fn putDocument(server: *Server, uri: []const u8, version: i32, text: []const u8) Error!void {
        const parsed = try parseDocument(text);
        const text_copy = try server.allocator.dupe(u8, text);
        errdefer server.allocator.free(text_copy);

        const gop = try server.documents.getOrPut(server.allocator, uri);
        if (gop.found_existing) {
            server.allocator.free(gop.value_ptr.source);
            gop.value_ptr.tree.destroy();
            gop.value_ptr.* = .{
                .source = text_copy,
                .version = version,
                .parsed = parsed.summary,
                .tree = parsed.tree,
            };
        } else {
            gop.key_ptr.* = try server.allocator.dupe(u8, uri);
            gop.value_ptr.* = .{
                .source = text_copy,
                .version = version,
                .parsed = parsed.summary,
                .tree = parsed.tree,
            };
        }
    }

    fn removeDocument(server: *Server, uri: []const u8) void {
        const removed = server.documents.fetchRemove(uri) orelse return;
        server.allocator.free(removed.key);
        server.allocator.free(removed.value.source);
        removed.value.tree.destroy();
    }

    fn getDocument(server: *Server, uri: []const u8) ?*DocumentState {
        return server.documents.getPtr(uri);
    }

    fn resolveAtPosition(
        server: *Server,
        doc: *const DocumentState,
        position: types.Position,
    ) Resolution {
        const source_index = lsp.offsets.positionToIndex(doc.source, position, offset_encoding);
        const point = tsPointFromIndex(doc.source, source_index);
        const root = doc.tree.rootNode();
        const raw_node = root.descendantForPointRange(point, point) orelse return .no_match;
        if (containsUnsupportedCode(raw_node)) {
            return .unsupported_zig_code;
        }
        const node = root.namedDescendantForPointRange(point, point) orelse return .no_match;
        if (containsUnsupportedCode(node)) {
            return .unsupported_zig_code;
        }

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(server.tags_query, root);

        var best: ?SemanticSymbol = null;
        while (cursor.nextMatch()) |match| {
            const candidate = semanticSymbolForMatch(server.tags_query, doc.source, source_index, match) orelse continue;
            if (best == null or isBetterMatch(candidate, best.?, source_index)) {
                best = candidate;
            }
        }

        return if (best) |symbol| .{ .symbol = symbol } else .no_match;
    }

    /// LSP `initialize` handler required by `lsp-kit`.
    pub fn initialize(
        _: *Server,
        _: std.mem.Allocator,
        _: types.InitializeParams,
    ) types.InitializeResult {
        return .{
            .capabilities = serverCapabilities(),
            .serverInfo = .{
                .name = server_name,
                .version = server_version,
            },
        };
    }

    /// LSP `initialized` handler required by `lsp-kit`.
    pub fn initialized(_: *Server, _: std.mem.Allocator, _: types.InitializedParams) void {}

    /// LSP `textDocument/didOpen` handler that stores the full document text.
    pub fn @"textDocument/didOpen"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidOpenTextDocumentParams,
    ) Error!void {
        _ = server.scratchAllocator();
        try server.putDocument(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
    }

    /// LSP `textDocument/didChange` handler that replaces stored document contents.
    pub fn @"textDocument/didChange"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidChangeTextDocumentParams,
    ) Error!void {
        _ = server.scratchAllocator();
        var latest_text: ?[]const u8 = null;
        for (params.contentChanges) |change| {
            switch (change) {
                .literal_1 => |whole| latest_text = whole.text,
                .literal_0 => return error.InvalidParams,
            }
        }

        const text = latest_text orelse return error.InvalidParams;
        try server.putDocument(params.textDocument.uri, params.textDocument.version, text);
    }

    /// LSP `textDocument/didClose` handler that drops cached document state.
    pub fn @"textDocument/didClose"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidCloseTextDocumentParams,
    ) void {
        _ = server.scratchAllocator();
        server.removeDocument(params.textDocument.uri);
    }

    /// LSP `textDocument/hover` handler for Zitron grammar symbols.
    pub fn @"textDocument/hover"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.HoverParams,
    ) OOM!?types.Hover {
        const scratch = server.scratchAllocator();
        const doc = server.getDocument(params.textDocument.uri) orelse return null;

        const value = switch (server.resolveAtPosition(doc, params.position)) {
            .no_match => return null,
            .unsupported_zig_code => return null,
            .symbol => |symbol| try hoverMarkdownForSymbol(scratch, symbol),
        };

        return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .markdown,
                    .value = value,
                },
            },
        };
    }

    /// LSP `textDocument/definition` handler for grammar symbol lookups.
    pub fn @"textDocument/definition"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DefinitionParams,
    ) lsp.ResultType("textDocument/definition") {
        _ = server.scratchAllocator();
        const doc = server.getDocument(params.textDocument.uri) orelse return null;

        return switch (server.resolveAtPosition(doc, params.position)) {
            .no_match => null,
            .unsupported_zig_code => null,
            .symbol => |symbol| switch (symbol.kind) {
                .rule_definition => .{
                    .Definition = .{
                        .Location = locationFromNode(params.textDocument.uri, symbol.name_node),
                    },
                },
                .rule_reference => blk: {
                    const definition = server.findRuleDefinition(doc, symbol.symbol_name) orelse break :blk null;
                    break :blk .{
                        .Definition = .{
                            .Location = locationFromNode(params.textDocument.uri, definition.name_node),
                        },
                    };
                },
                .action_definition, .action_implementation =>
                // TODO: Bridge named-action references through generated Zig and ZLS.
                null,
            },
        };
    }

    /// LSP `shutdown` handler required by `lsp-kit`.
    pub fn shutdown(_: *Server, _: std.mem.Allocator, _: void) ?void {
        return null;
    }

    /// LSP `exit` handler required by `lsp-kit`.
    pub fn exit(_: *Server, _: std.mem.Allocator, _: void) void {}

    /// LSP response hook; ignored because this server does not initiate requests yet.
    pub fn onResponse(_: *Server, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}

    fn findRuleDefinition(server: *Server, doc: *const DocumentState, symbol_name: []const u8) ?SemanticSymbol {
        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(server.tags_query, doc.tree.rootNode());

        while (cursor.nextMatch()) |match| {
            const candidate = semanticSymbolForMatch(server.tags_query, doc.source, null, match) orelse continue;
            if (candidate.kind != .rule_definition) continue;
            if (std.mem.eql(u8, candidate.symbol_name, symbol_name)) return candidate;
        }

        return null;
    }
};

fn semanticSymbolForMatch(
    query: *const ts.Query,
    source: []const u8,
    source_index: ?usize,
    match: ts.Query.Match,
) ?SemanticSymbol {
    var semantic_capture_name: ?[]const u8 = null;
    var semantic_node: ?ts.Node = null;
    var name_node: ?ts.Node = null;

    for (match.captures) |capture| {
        const capture_name = query.captureNameForId(capture.index) orelse continue;
        if (std.mem.eql(u8, capture_name, "name")) {
            name_node = capture.node;
            continue;
        }

        if (semanticKindForCaptureName(capture_name)) |_| {
            semantic_capture_name = capture_name;
            semantic_node = capture.node;
        }
    }

    const resolved_name_node = name_node orelse return null;
    const resolved_semantic_name = semantic_capture_name orelse return null;
    const resolved_semantic_node = semantic_node orelse return null;

    if (source_index) |index| {
        if (!nodeContainsIndex(resolved_name_node, index) and !nodeContainsIndex(resolved_semantic_node, index)) {
            return null;
        }
    }

    return .{
        .kind = semanticKindForCaptureName(resolved_semantic_name).?,
        .capture_name = resolved_semantic_name,
        .symbol_name = normalizeSymbolName(sliceForNode(source, resolved_name_node)),
        .name_node = resolved_name_node,
        .semantic_node = resolved_semantic_node,
        .enclosing_kind = resolved_semantic_node.kind(),
    };
}

fn semanticKindForCaptureName(capture_name: []const u8) ?SemanticKind {
    if (std.mem.eql(u8, capture_name, "definition.class")) return .rule_definition;
    if (std.mem.eql(u8, capture_name, "reference.class")) return .rule_reference;
    if (std.mem.eql(u8, capture_name, "definition.interface")) return .action_definition;
    if (std.mem.eql(u8, capture_name, "reference.implementation")) return .action_implementation;
    return null;
}

fn nodeContainsIndex(node: ts.Node, index: usize) bool {
    const start: usize = node.startByte();
    const end: usize = node.endByte();
    return start <= index and index < end;
}

fn isBetterMatch(candidate: SemanticSymbol, current: SemanticSymbol, source_index: usize) bool {
    const candidate_hits_name = nodeContainsIndex(candidate.name_node, source_index);
    const current_hits_name = nodeContainsIndex(current.name_node, source_index);
    if (candidate_hits_name != current_hits_name) return candidate_hits_name;

    const candidate_len = candidate.name_node.endByte() - candidate.name_node.startByte();
    const current_len = current.name_node.endByte() - current.name_node.startByte();
    if (candidate_len != current_len) return candidate_len < current_len;

    const candidate_span = candidate.semantic_node.endByte() - candidate.semantic_node.startByte();
    const current_span = current.semantic_node.endByte() - current.semantic_node.startByte();
    return candidate_span < current_span;
}

fn containsUnsupportedCode(node: ts.Node) bool {
    var cursor = node;
    while (true) {
        const kind = cursor.kind();
        if (std.mem.eql(u8, kind, "zig_code") or std.mem.eql(u8, kind, "code_block")) {
            // TODO: Once Zitron-to-Zig source maps exist, hand these spans off to Zig/ZLS.
            return true;
        }
        cursor = cursor.parent() orelse return false;
    }
}

fn sliceForNode(source: []const u8, node: ts.Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn normalizeSymbolName(symbol_name: []const u8) []const u8 {
    const open_paren = std.mem.indexOfScalar(u8, symbol_name, '(') orelse return symbol_name;
    return std.mem.trimRight(u8, symbol_name[0..open_paren], " \t");
}

fn tsPointFromIndex(source: []const u8, index: usize) ts.Point {
    const position = lsp.offsets.indexToPosition(source, index, .@"utf-8");
    return .{
        .row = position.line,
        .column = position.character,
    };
}

fn positionFromPoint(point: ts.Point) types.Position {
    return .{
        .line = point.row,
        .character = point.column,
    };
}

fn rangeFromNode(node: ts.Node) types.Range {
    return .{
        .start = positionFromPoint(node.startPoint()),
        .end = positionFromPoint(node.endPoint()),
    };
}

fn locationFromNode(uri: []const u8, node: ts.Node) types.Location {
    return .{
        .uri = uri,
        .range = rangeFromNode(node),
    };
}

fn hoverMarkdownForSymbol(arena: std.mem.Allocator, symbol: SemanticSymbol) OOM![]const u8 {
    return switch (symbol.kind) {
        .rule_definition => std.fmt.allocPrint(
            arena,
            "rule definition `{s}`\n\ncapture `{s}` on `{s}`",
            .{ symbol.symbol_name, symbol.capture_name, symbol.enclosing_kind },
        ),
        .rule_reference => std.fmt.allocPrint(
            arena,
            "rule reference `{s}`\n\ncapture `{s}` on `{s}`",
            .{ symbol.symbol_name, symbol.capture_name, symbol.enclosing_kind },
        ),
        .action_definition => std.fmt.allocPrint(
            arena,
            "named action definition `{s}`\n\ncapture `{s}` on `{s}`",
            .{ symbol.symbol_name, symbol.capture_name, symbol.enclosing_kind },
        ),
        .action_implementation => std.fmt.allocPrint(
            arena,
            "named action implementation `{s}`\n\ncapture `{s}` on `{s}`",
            .{ symbol.symbol_name, symbol.capture_name, symbol.enclosing_kind },
        ),
    };
}

// Tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

fn parseSource(source: []const u8) Server.Error!ParseSummary {
    const parsed = try parseDocument(source);
    defer parsed.tree.destroy();
    return parsed.summary;
}

fn byteIndexOf(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!usize {
    return std.mem.indexOf(u8, haystack, needle) orelse error.NeedleNotFound;
}

fn byteIndexOfAfter(haystack: []const u8, start_index: usize, needle: []const u8) error{NeedleNotFound}!usize {
    const relative = std.mem.indexOf(u8, haystack[start_index..], needle) orelse return error.NeedleNotFound;
    return start_index + relative;
}

fn positionOfText(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!types.Position {
    const index = try byteIndexOf(haystack, needle);
    return lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}

fn positionOfTextAfter(haystack: []const u8, start_index: usize, needle: []const u8) error{NeedleNotFound}!types.Position {
    const index = try byteIndexOfAfter(haystack, start_index, needle);
    return lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}

//| Tests

/// Loads the configured fixture source into memory for smoke tests and helpers.
pub fn loadFixtureAlloc(allocator: std.mem.Allocator) FixtureError![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, build_options.fixture_path, 64 * 1024);
}

test "server capabilities match the implemented handlers" {
    lsp.basic_server.validateServerCapabilities(Server, serverCapabilities());
}

test "embedded tags query compiles for the zitron grammar" {
    var error_offset: u32 = 0;
    const query = try ts.Query.create(zitronLanguage(), tags_query_source, &error_offset);
    defer query.destroy();

    try expectEqual(@as(u32, 6), query.patternCount());
    try expect(query.captureCount() >= 3);
}

test "tree-sitter zitron parses the configured fixture" {
    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    const parsed = try parseSource(sample);

    try expectEqualStrings("source_file", parsed.root_kind);
    try expect(!parsed.has_error);
}

test "server tracks open documents" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .languageId = "zitron",
            .version = 1,
            .text = sample,
        },
    });

    const doc = server.getDocument("file:///samples/calc.zy").?;
    try expectEqual(@as(i32, 1), doc.version);
    try expectEqualStrings("source_file", doc.parsed.root_kind);
    try expect(!doc.parsed.has_error);
}

test "query resolution finds rule definitions and references in calc" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const calc_resolution = server.resolveAtPosition(doc, try positionOfText(sample, "calc ::= expr"));
    switch (calc_resolution) {
        .symbol => |symbol| {
            try expectEqual(SemanticKind.rule_definition, symbol.kind);
            try expectEqualStrings("calc", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }

    const calc_rule_index = try byteIndexOf(sample, "calc ::= expr");
    const expr_reference_resolution = server.resolveAtPosition(doc, try positionOfTextAfter(sample, calc_rule_index + 1, "expr"));
    switch (expr_reference_resolution) {
        .symbol => |symbol| {
            try expectEqual(SemanticKind.rule_reference, symbol.kind);
            try expectEqualStrings("expr", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }
}

test "query resolution returns no match on punctuation" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const resolution = server.resolveAtPosition(doc, try positionOfText(sample, "%token_type"));
    try expectEqual(Resolution.no_match, resolution);
}

test "query resolution returns unsupported inside zig code" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const resolution = server.resolveAtPosition(doc, try positionOfText(sample, "answer = A"));
    try expectEqual(Resolution.unsupported_zig_code, resolution);
}

test "hover and definition operate on stored live document state" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .languageId = "zitron",
            .version = 1,
            .text = sample,
        },
    });

    const hover = (try server.@"textDocument/hover"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfText(sample, "calc ::= expr"),
    })).?;
    switch (hover.contents) {
        .MarkupContent => |content| {
            try expect(std.mem.indexOf(u8, content.value, "rule definition `calc`") != null);
        },
        else => return error.UnexpectedHoverContents,
    }

    const calc_rule_index = try byteIndexOf(sample, "calc ::= expr");
    const definition = (server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, calc_rule_index + 1, "expr"),
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .Definition => |target| switch (target) {
            .Location => |location| {
                try expectEqualStrings("file:///samples/calc.zy", location.uri);
                try expectEqual(@as(u32, 48), location.range.start.line);
                try expectEqual(@as(u32, 0), location.range.start.character);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }
}

const std = @import("std");
const OOM = std.mem.Allocator.Error;
/// Re-exported `lsp-kit` API used by companion executables in this package.
pub const lsp = @import("lsp");
/// Re-exported LSP protocol types used by companion executables in this package.
pub const types = lsp.types;
const build_options = @import("build_options");
const ts = @import("tree-sitter");
const tags_query_source = @embedFile("zitron-tags-query");
const zitron_grammar = @import("tree_sitter_zitron");
const offset_encoding: lsp.offsets.Encoding = .@"utf-8";
