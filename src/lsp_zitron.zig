//! Zitron Language Server
//!
//! Implementation of a language server for Zitron, an LALR(1) parser
//! generator based on a port of D. Richard Hipp's Lemon.

/// The language-server name reported during LSP initialization.
pub const server_name = "lsp_zitron";

const server_version = "0.0.1";

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

/// Errors that can occur while loading the configured fixture source.
pub const FixtureError = OOM || std.fs.File.OpenError || std.fs.File.ReadError || error{FileTooBig};

fn positionEncodingKind(encoding: lsp.offsets.Encoding) types.PositionEncodingKind {
    return switch (encoding) {
        .@"utf-8" => .@"utf-8",
        .@"utf-16" => .@"utf-16",
        .@"utf-32" => .@"utf-32",
    };
}

fn serverCapabilities(offset_encoding: lsp.offsets.Encoding) types.ServerCapabilities {
    return .{
        .positionEncoding = positionEncodingKind(offset_encoding),
        .textDocumentSync = .{
            .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Incremental,
            },
        },
        .completionProvider = .{
            .triggerCharacters = &.{"%"},
        },
        .hoverProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = true },
        .referencesProvider = .{ .bool = true },
    };
}

/// LSP server state and handlers for Zitron grammars.
pub const Server = struct {
    /// Errors produced while parsing or updating server-managed documents.
    pub const Error = Document.Error;

    allocator: std.mem.Allocator,
    scratch_arena: std.heap.ArenaAllocator,
    documents: std.StringHashMapUnmanaged(Document),
    tags_query: *ts.Query,
    offset_encoding: lsp.offsets.Encoding,

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
            .offset_encoding = .@"utf-16",
        };
    }

    /// Releases all document state and query resources owned by the server.
    pub fn deinit(server: *Server) void {
        var it = server.documents.iterator();
        while (it.next()) |entry| {
            server.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(server.allocator);
        }
        server.documents.deinit(server.allocator);
        server.scratch_arena.deinit();
        server.tags_query.destroy();
    }

    /// LSP `initialize` handler required by `lsp-kit`.
    pub fn initialize(
        server: *Server,
        _: std.mem.Allocator,
        params: types.InitializeParams,
    ) types.InitializeResult {
        if (params.capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                server.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }

        return .{
            .capabilities = serverCapabilities(server.offset_encoding),
            .serverInfo = .{
                .name = server_name,
                .version = server_version,
            },
        };
    }

    /// LSP `initialized` handler required by `lsp-kit`.
    pub fn initialized(_: *Server, _: std.mem.Allocator, _: types.InitializedParams) void {}

    //| Handlers
    //|
    //| `lsp-kit` passes in a per-message arena on requests.  Sometimes we use it,
    //| sometimes we don't.

    /// LSP `textDocument/didOpen` handler that stores the full document text.
    pub fn @"textDocument/didOpen"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidOpenTextDocumentParams,
    ) Error!void {
        try server.putDocument(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
    }

    /// LSP `textDocument/didChange` handler that applies incremental document changes.
    pub fn @"textDocument/didChange"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidChangeTextDocumentParams,
    ) Error!void {
        const doc = server.getDocument(params.textDocument.uri) orelse return error.InvalidParams;
        try doc.updateIncremental(
            server.allocator,
            params.textDocument.version,
            params.contentChanges,
            server.offset_encoding,
        );
    }

    /// LSP `textDocument/didClose` handler that drops cached document state.
    pub fn @"textDocument/didClose"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidCloseTextDocumentParams,
    ) void {
        server.removeDocument(params.textDocument.uri);
    }

    /// LSP `textDocument/completion` handler for directive completions.
    pub fn @"textDocument/completion"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.CompletionParams,
    ) OOM!lsp.ResultType("textDocument/completion") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        const items = try completion.completeDirectives(
            arena,
            doc.source,
            params.position,
            server.offset_encoding,
        ) orelse return null;

        return .{ .array_of_CompletionItem = items };
    }

    /// LSP `textDocument/hover` handler for Zitron grammar symbols.
    pub fn @"textDocument/hover"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.HoverParams,
    ) OOM!?types.Hover {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;

        const value = switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => return null,
            .unsupported_zig_code => return null,
            .symbol => |symbol| try hoverMarkdownForSymbol(arena, symbol),
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
        const doc = server.getDocument(params.textDocument.uri) orelse return null;

        return switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => null,
            .unsupported_zig_code => null,
            .symbol => |symbol| switch (symbol.kind) {
                .rule_definition, .action_definition => .{
                    .Definition = .{
                        .Location = doc.locationForNode(
                            params.textDocument.uri,
                            symbol.name_node,
                            server.offset_encoding,
                        ),
                    },
                },
                .rule_reference => if (doc.findRuleDefinition(
                    server.tags_query,
                    symbol.symbol_name,
                )) |definition| .{
                    .Definition = .{
                        .Location = doc.locationForNode(
                            params.textDocument.uri,
                            definition.name_node,
                            server.offset_encoding,
                        ),
                    },
                } else null,
                .action_implementation => if (doc.findActionDefinition(server.tags_query, symbol.symbol_name)) |definition| .{
                    .Definition = .{
                        .Location = doc.locationForNode(
                            params.textDocument.uri,
                            definition.name_node,
                            server.offset_encoding,
                        ),
                    },
                } else null,
            },
        };
    }

    /// LSP `textDocument/references` handler for same-document grammar symbol lookups.
    pub fn @"textDocument/references"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.ReferenceParams,
    ) OOM!lsp.ResultType("textDocument/references") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;

        return switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => null,
            .unsupported_zig_code => null,
            .symbol => |symbol| try doc.findReferences(
                server.tags_query,
                arena,
                params.textDocument.uri,
                symbol,
                params.context.includeDeclaration,
                server.offset_encoding,
            ),
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

    //| Internal

    fn putDocument(server: *Server, uri: []const u8, version: i32, text: []const u8) Error!void {
        var document = try Document.init(server.allocator, version, text);
        errdefer document.deinit(server.allocator);

        const gop = try server.documents.getOrPut(server.allocator, uri);
        if (gop.found_existing) {
            gop.value_ptr.deinit(server.allocator);
            gop.value_ptr.* = document;
        } else {
            errdefer server.documents.removeByPtr(gop.key_ptr);
            gop.key_ptr.* = try server.allocator.dupe(u8, uri);
            gop.value_ptr.* = document;
        }
    }

    fn removeDocument(server: *Server, uri: []const u8) void {
        const removed = server.documents.fetchRemove(uri) orelse return;
        server.allocator.free(removed.key);
        var document = removed.value;
        document.deinit(server.allocator);
    }

    fn getDocument(server: *Server, uri: []const u8) ?*Document {
        return server.documents.getPtr(uri);
    }

    fn hasLocationAt(locations: []const types.Location, uri: []const u8, position: types.Position) bool {
        for (locations) |location| {
            if (!std.mem.eql(u8, location.uri, uri)) continue;
            if (std.meta.eql(location.range.start, position)) return true;
        }

        return false;
    }

    fn hoverMarkdownForSymbol(arena: std.mem.Allocator, symbol: Document.SemanticSymbol) OOM![]const u8 {
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
};

//| Tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

fn parseSource(source: []const u8) Server.Error!Document.ParseSummary {
    var document = try Document.init(testing_allocator, 1, source);
    defer document.deinit(testing_allocator);
    return document.parsed;
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
    return lsp.offsets.indexToPosition(haystack, index, test_offset_encoding);
}

fn positionOfTextAfter(haystack: []const u8, start_index: usize, needle: []const u8) error{NeedleNotFound}!types.Position {
    const index = try byteIndexOfAfter(haystack, start_index, needle);
    return lsp.offsets.indexToPosition(haystack, index, test_offset_encoding);
}

/// Loads the configured fixture source into memory for smoke tests and helpers.
pub fn loadFixtureAlloc(allocator: std.mem.Allocator) FixtureError![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, build_options.fixture_path, 64 * 1024);
}

fn completionItemsContainLabel(items: []const types.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

test "server capabilities match the implemented handlers" {
    lsp.basic_server.validateServerCapabilities(Server, serverCapabilities(.@"utf-16"));
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

test "server applies incremental didChange updates" {
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

    const end_position = lsp.offsets.indexToPosition(sample, sample.len, .@"utf-8");
    try server.@"textDocument/didChange"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .version = 2,
        },
        .contentChanges = &.{
            .{ .literal_0 = .{
                .range = .{
                    .start = end_position,
                    .end = end_position,
                },
                .rangeLength = 0,
                .text = "\n",
            } },
        },
    });

    const doc = server.getDocument("file:///samples/calc.zy").?;
    try expectEqual(@as(i32, 2), doc.version);
    try expectEqualStrings("\n", doc.source[doc.source.len - 1 ..]);
    try expectEqualStrings("source_file", doc.parsed.root_kind);
    try expect(!doc.parsed.has_error);
}

test "server returns directive completions from stored live document state" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/directive_completion.zy",
            .languageId = "zitron",
            .version = 1,
            .text =
            \\%t
            \\rule ::= TOKEN.
            ,
        },
    });

    const result = (try server.@"textDocument/completion"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/directive_completion.zy" },
        .position = .{ .line = 0, .character = 2 },
    })) orelse return error.UnexpectedCompletionResult;
    switch (result) {
        .array_of_CompletionItem => |items| {
            try expect(items.len >= 2);
            try expect(completionItemsContainLabel(items, "%type"));
            try expect(completionItemsContainLabel(items, "%token_type"));
        },
        else => return error.UnexpectedCompletionResult,
    }
}

test "incremental tree-sitter reparse matches fresh parse" {
    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    var incremental = try Document.init(testing_allocator, 1, sample);
    defer incremental.deinit(testing_allocator);

    try incremental.updateIncremental(testing_allocator, 2, &.{
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 4 },
            },
            .rangeLength = 4,
            .text = "start",
        } },
    }, .@"utf-8");

    var fresh = try Document.init(testing_allocator, 2, incremental.source);
    defer fresh.deinit(testing_allocator);

    try expectEqualStrings(fresh.parsed.root_kind, incremental.parsed.root_kind);
    try expectEqual(fresh.parsed.has_error, incremental.parsed.has_error);
}

test "query resolution finds rule definitions and references in calc" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const calc_resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfText(sample, "calc ::= expr"));
    switch (calc_resolution) {
        .symbol => |symbol| {
            try expectEqual(Document.SemanticKind.rule_definition, symbol.kind);
            try expectEqualStrings("calc", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }

    const calc_rule_index = try byteIndexOf(sample, "calc ::= expr");
    const expr_reference_resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfTextAfter(sample, calc_rule_index + 1, "expr"));
    switch (expr_reference_resolution) {
        .symbol => |symbol| {
            try expectEqual(Document.SemanticKind.rule_reference, symbol.kind);
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

    const resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfText(sample, "%token_type"));
    try expectEqual(Document.Resolution.no_match, resolution);
}

test "query resolution returns unsupported inside zig code" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfText(sample, "answer = A"));
    try expectEqual(Document.Resolution.unsupported_zig_code, resolution);
}

test "hover definition and references operate on stored live document state" {
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

    const references = (try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, calc_rule_index + 1, "expr"),
        .context = .{ .includeDeclaration = false },
    })) orelse return error.UnexpectedDefinitionTarget;
    try expectEqual(@as(usize, 4), references.len);
    try expect(Server.hasLocationAt(references, "file:///samples/calc.zy", try positionOfTextAfter(sample, calc_rule_index + 1, "expr")));

    const first_expr_rhs_rule_index = try byteIndexOf(sample, "expr(A) ::= expr(B) PLUS|FOO(O) term(C).");
    try expect(Server.hasLocationAt(references, "file:///samples/calc.zy", try positionOfTextAfter(sample, first_expr_rhs_rule_index + 1, "expr")));

    const second_expr_rhs_rule_index = try byteIndexOf(sample, "expr(A) ::= expr(B) MINUS term(C).");
    try expect(Server.hasLocationAt(references, "file:///samples/calc.zy", try positionOfTextAfter(sample, second_expr_rhs_rule_index + 1, "expr")));

    const factor_rule_index = try byteIndexOf(sample, "factor(A) ::= LPAREN expr(E) RPAREN.");
    try expect(Server.hasLocationAt(references, "file:///samples/calc.zy", try positionOfTextAfter(sample, factor_rule_index + 1, "expr")));

    const references_with_declaration = (try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, calc_rule_index + 1, "expr"),
        .context = .{ .includeDeclaration = true },
    })) orelse return error.UnexpectedDefinitionTarget;
    try expectEqual(@as(usize, 7), references_with_declaration.len);
    try expect(Server.hasLocationAt(references_with_declaration, "file:///samples/calc.zy", try positionOfTextAfter(sample, calc_rule_index, "expr(A)")));
    try expect(Server.hasLocationAt(references_with_declaration, "file:///samples/calc.zy", try positionOfTextAfter(sample, first_expr_rhs_rule_index, "expr(A)")));

    const third_expr_rule_index = try byteIndexOf(sample, "expr(A) ::= term(A).");
    try expect(Server.hasLocationAt(references_with_declaration, "file:///samples/calc.zy", try positionOfTextAfter(sample, third_expr_rule_index, "expr(A)")));
}

test "named action definitions resolve in the same document" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample =
        \\vector(F) ::= SQL v_forms(V) SQR. @vector_form(F;V)
        \\%impl @vector_form(F;V) { _ = .{F, V}; }
        \\%impl @vector_form(F;V) { _ = .{V, F}; }
    ;

    try server.putDocument("file:///samples/named_actions.zy", 1, sample);

    const definition_target = try positionOfText(sample, "@vector_form(F;V)");
    const definition_position = try positionOfText(sample, "vector_form(F;V)");
    const definition = (server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/named_actions.zy" },
        .position = definition_position,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .Definition => |target| switch (target) {
            .Location => |location| {
                try expectEqualStrings("file:///samples/named_actions.zy", location.uri);
                try expectEqual(definition_target, location.range.start);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const implementation_anchor = try byteIndexOf(sample, "%impl @vector_form(F;V)");
    const implementation_position = try positionOfTextAfter(sample, implementation_anchor + 1, "vector_form(F;V)");
    const implementation_definition = (server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/named_actions.zy" },
        .position = implementation_position,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (implementation_definition) {
        .Definition => |target| switch (target) {
            .Location => |location| {
                try expectEqualStrings("file:///samples/named_actions.zy", location.uri);
                try expectEqual(definition_target, location.range.start);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const missing_definition_sample =
        \\rule ::= TOKEN. @missing_action()
        \\%impl @other_action() { _ = .{}; }
    ;
    try server.putDocument("file:///samples/missing_named_action.zy", 1, missing_definition_sample);
    const missing_anchor = try byteIndexOf(missing_definition_sample, "%impl @other_action()");
    const missing_position = try positionOfTextAfter(missing_definition_sample, missing_anchor + 1, "other_action()");
    const missing_result = server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/missing_named_action.zy" },
        .position = missing_position,
    });
    try expect(missing_result == null);
}

test "definition on discard resolves that rule instead of a neighbor" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample =
        \\pair(P) ::= m_form(K) discard m_form(V).  @on_pair2(P; K, V)
        \\m_form(A) ::= FORM(A).
        \\discard ::= .
    ;

    try server.putDocument("file:///samples/discard.zy", 1, sample);

    const definition_anchor = try byteIndexOf(sample, "\ndiscard");
    const definition_target = try positionOfTextAfter(sample, definition_anchor + 1, "discard");
    const reference_anchor = try byteIndexOf(sample, "m_form(K) discard");
    const reference_position = try positionOfTextAfter(sample, reference_anchor + 1, "discard");

    const doc = server.getDocument("file:///samples/discard.zy").?;
    switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, reference_position)) {
        .symbol => |symbol| try expectEqualStrings("discard", symbol.symbol_name),
        else => return error.UnexpectedResolution,
    }

    const definition = (server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/discard.zy" },
        .position = reference_position,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .Definition => |target| switch (target) {
            .Location => |location| {
                try expectEqualStrings("file:///samples/discard.zy", location.uri);
                try expectEqual(definition_target, location.range.start);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }
}

test "initialize negotiates position encoding" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const result = server.initialize(testing_allocator, .{
        .capabilities = .{
            .general = .{
                .positionEncodings = &.{ .@"utf-8", .@"utf-16" },
            },
        },
    });

    try expectEqual(lsp.offsets.Encoding.@"utf-8", server.offset_encoding);
    try expectEqual(types.PositionEncodingKind.@"utf-8", result.capabilities.positionEncoding.?);
}

const std = @import("std");
const OOM = std.mem.Allocator.Error;
const Document = @import("Document.zig");
const completion = @import("completion.zig");
const lsp = @import("lsp");
const types = lsp.types;
const build_options = @import("build_options");
const ts = @import("tree-sitter");
const tags_query_source = @embedFile("zitron-tags-query");
const zitron_grammar = @import("tree_sitter_zitron");
const test_offset_encoding: lsp.offsets.Encoding = .@"utf-8";
