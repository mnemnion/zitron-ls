//! Live document state and document-local operations for Zitron sources.

source: []u8,
version: i32,
parsed: ParseSummary,
tree: *ts.Tree,

const Document = @This();

/// Summary information derived from the current tree-sitter parse.
pub const ParseSummary = struct {
    root_kind: []const u8,
    has_error: bool,
};

/// Semantic categories resolved from the Zitron tags query.
pub const SemanticKind = enum {
    rule_definition,
    rule_reference,
    action_definition,
    action_implementation,
};

/// Semantic information for a resolved grammar or named-action symbol.
pub const SemanticSymbol = struct {
    kind: SemanticKind,
    capture_name: []const u8,
    symbol_name: []const u8,
    name_node: ts.Node,
    semantic_node: ts.Node,
    enclosing_kind: []const u8,
};

/// Result of resolving a symbol lookup at a document position.
pub const Resolution = union(enum) {
    no_match,
    unsupported_zig_code,
    symbol: SemanticSymbol,
};

/// Errors that can occur while parsing or updating a document.
pub const Error = OOM || ts.Query.Error || error{
    IncompatibleLanguage,
    InvalidParams,
    ParseFailed,
};

/// Creates a live document from source text and parses it immediately.
pub fn init(allocator: std.mem.Allocator, version: i32, text: []const u8) Error!Document {
    const parsed = try parseDocument(text);
    errdefer parsed.tree.destroy();

    const text_copy = try allocator.dupe(u8, text);
    errdefer allocator.free(text_copy);

    return .{
        .source = text_copy,
        .version = version,
        .parsed = parsed.summary,
        .tree = parsed.tree,
    };
}

/// Releases the source buffer and parse tree owned by the document.
pub fn deinit(document: *Document, allocator: std.mem.Allocator) void {
    allocator.free(document.source);
    document.tree.destroy();
}

/// Replaces the document contents with a fresh parse of the given text.
pub fn replace(document: *Document, allocator: std.mem.Allocator, version: i32, text: []const u8) Error!void {
    var replacement = try init(allocator, version, text);
    errdefer replacement.deinit(allocator);

    document.deinit(allocator);
    document.* = replacement;
}

/// Applies incremental content changes and reparses against the edited tree.
pub fn updateIncremental(
    document: *Document,
    allocator: std.mem.Allocator,
    version: i32,
    content_changes: []const types.TextDocumentContentChangeEvent,
    offset_encoding: lsp.offsets.Encoding,
) Error!void {
    var applied_change = try diff.applyContentChangesWithEdits(
        allocator,
        document.source,
        content_changes,
        offset_encoding,
    );
    defer applied_change.deinit(allocator);

    const edited_old_tree = document.tree.dupe();
    defer edited_old_tree.destroy();
    for (applied_change.input_edits.items) |input_edit| {
        edited_old_tree.edit(input_edit);
    }

    const parsed = try parseDocumentIncremental(applied_change.text, edited_old_tree);
    errdefer parsed.tree.destroy();

    const text_copy = try allocator.dupe(u8, applied_change.text);
    errdefer allocator.free(text_copy);

    allocator.free(document.source);
    document.tree.destroy();
    document.* = .{
        .source = text_copy,
        .version = version,
        .parsed = parsed.summary,
        .tree = parsed.tree,
    };
}

/// Resolves the best semantic symbol match at the requested position.
pub fn resolveAtPosition(
    document: Document,
    tags_query: *const ts.Query,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) Resolution {
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
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
    cursor.exec(tags_query, root);

    var best: ?SemanticSymbol = null;
    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, source_index, match) orelse continue;
        if (best == null or isBetterMatch(candidate, best.?, source_index)) {
            best = candidate;
        }
    }

    return if (best) |symbol| .{ .symbol = symbol } else .no_match;
}

/// Returns whether the requested position is within embedded Zig source.
pub fn containsZigCodeAtPosition(
    document: Document,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) bool {
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
    const raw_node = root.descendantForPointRange(point, point) orelse return false;
    if (containsUnsupportedCode(raw_node)) return true;
    const node = root.namedDescendantForPointRange(point, point) orelse return false;
    return containsUnsupportedCode(node);
}

/// Finds the definition symbol for a named rule in this document.
pub fn findRuleDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .rule_definition);
}

/// Finds the definition symbol for a named action in this document.
pub fn findActionDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .action_definition);
}

/// Collects same-document references for the resolved semantic symbol.
pub fn findReferences(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    uri: []const u8,
    symbol: SemanticSymbol,
    include_declaration: bool,
    offset_encoding: lsp.offsets.Encoding,
) OOM!lsp.ResultType("textDocument/references") {
    var references: std.ArrayList(types.Location) = .empty;

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, null, match) orelse continue;
        if (!std.mem.eql(u8, candidate.symbol_name, symbol.symbol_name)) continue;

        switch (symbol.kind) {
            .rule_definition, .rule_reference => {
                if (candidate.kind == .rule_reference) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                    continue;
                }

                if (include_declaration and candidate.kind == .rule_definition) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                }
            },
            .action_definition, .action_implementation => {
                if (candidate.kind == .action_definition or candidate.kind == .action_implementation) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                }
            },
        }
    }

    return if (references.items.len == 0) null else try references.toOwnedSlice(arena);
}

/// Builds an LSP location for the given syntax node in this document.
pub fn locationForNode(
    document: Document,
    uri: []const u8,
    node: ts.Node,
    offset_encoding: lsp.offsets.Encoding,
) types.Location {
    return .{
        .uri = uri,
        .range = rangeFromNode(document.source, node, offset_encoding),
    };
}

fn findDefinition(
    document: Document,
    tags_query: *const ts.Query,
    symbol_name: []const u8,
    kind: SemanticKind,
) ?SemanticSymbol {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, null, match) orelse continue;
        if (candidate.kind != kind) continue;
        if (std.mem.eql(u8, candidate.symbol_name, symbol_name)) return candidate;
    }

    return null;
}

fn parseDocument(source: []const u8) Error!ParsedDocument {
    return parseDocumentIncremental(source, null);
}

fn parseDocumentIncremental(source: []const u8, old_tree: ?*const ts.Tree) Error!ParsedDocument {
    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(zitronLanguage());

    const tree = parser.parseString(source, old_tree) orelse return error.ParseFailed;
    const root = tree.rootNode();
    return .{
        .summary = .{
            .root_kind = root.kind(),
            .has_error = root.hasError(),
        },
        .tree = tree,
    };
}

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
            if (source_index) |index| {
                if (nodeContainsIndex(capture.node, index)) {
                    name_node = capture.node;
                }
            } else if (name_node == null) {
                name_node = capture.node;
            }
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
    return std.mem.trimEnd(u8, symbol_name[0..open_paren], " \t");
}

fn tsPointFromIndex(source: []const u8, index: usize) ts.Point {
    const position = lsp.offsets.indexToPosition(source, index, .@"utf-8");
    return .{
        .row = position.line,
        .column = position.character,
    };
}

fn rangeFromNode(source: []const u8, node: ts.Node, offset_encoding: lsp.offsets.Encoding) types.Range {
    return lsp.offsets.locToRange(source, .{
        .start = node.startByte(),
        .end = node.endByte(),
    }, offset_encoding);
}

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

const ParsedDocument = struct {
    summary: ParseSummary,
    tree: *ts.Tree,
};

//| Tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

fn byteIndexOf(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!usize {
    return std.mem.indexOf(u8, haystack, needle) orelse error.NeedleNotFound;
}

fn positionOfText(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!types.Position {
    const index = try byteIndexOf(haystack, needle);
    return lsp.offsets.indexToPosition(haystack, index, .@"utf-8");
}

fn compileTagsQuery() ts.Query.Error!*ts.Query {
    var error_offset: u32 = 0;
    return ts.Query.create(zitronLanguage(), tags_query_source, &error_offset);
}

test "init builds expected parse summary" {
    var document = try Document.init(testing_allocator, 1, "rule ::= TOKEN.");
    defer document.deinit(testing_allocator);

    try expectEqual(@as(i32, 1), document.version);
    try expectEqualStrings("source_file", document.parsed.root_kind);
    try expect(!document.parsed.has_error);
}

test "updateIncremental preserves parse correctness" {
    var document = try Document.init(testing_allocator, 1, "rule ::= TOKEN.");
    defer document.deinit(testing_allocator);

    const end_position = lsp.offsets.indexToPosition(document.source, document.source.len, .@"utf-8");
    try document.updateIncremental(
        testing_allocator,
        2,
        &.{
            .{ .text_document_content_change_partial = .{
                .range = .{
                    .start = end_position,
                    .end = end_position,
                },
                .rangeLength = 0,
                .text = "\n",
            } },
        },
        .@"utf-8",
    );

    try expectEqual(@as(i32, 2), document.version);
    try expectEqualStrings("\n", document.source[document.source.len - 1 ..]);
    try expectEqualStrings("source_file", document.parsed.root_kind);
    try expect(!document.parsed.has_error);
}

test "resolution and references work without server" {
    const sample =
        \\calc ::= expr.
        \\expr(A) ::= expr(B) PLUS term(C).
        \\expr(A) ::= term(A).
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    const resolution = document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "calc ::= expr"));
    switch (resolution) {
        .symbol => |symbol| try expectEqual(SemanticKind.rule_definition, symbol.kind),
        else => return error.UnexpectedResolution,
    }

    const symbol = switch (document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "expr(B)"))) {
        .symbol => |resolved| resolved,
        else => return error.UnexpectedResolution,
    };

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const references = (try document.findReferences(
        query,
        arena.allocator(),
        "file:///samples/doc.zy",
        symbol,
        true,
        .@"utf-8",
    )) orelse return error.UnexpectedReferences;
    try expect(references.len >= 2);
}

test "classifies zig code positions for middleware routing" {
    const sample =
        \\calc ::= expr(A). { answer = A; }
        \\%code {
        \\const parser_name = "calc";
        \\}
    ;

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    try expect(document.containsZigCodeAtPosition(.@"utf-8", try positionOfText(sample, "answer")));
    try expect(document.containsZigCodeAtPosition(.@"utf-8", try positionOfText(sample, "parser_name")));
    try expect(!document.containsZigCodeAtPosition(.@"utf-8", try positionOfText(sample, "calc ::= expr")));
}

test "resolution chooses discard rule reference instead of leftmost rule" {
    const sample =
        \\pair(P) ::= m_form(K) discard m_form(V).  @on_pair2(P; K, V)
        \\m_form(A) ::= FORM(A).
        \\discard ::= .
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    const resolution = document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "discard"));
    switch (resolution) {
        .symbol => |symbol| {
            try expectEqual(SemanticKind.rule_reference, symbol.kind);
            try expectEqualStrings("discard", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }
}

test "resolution chooses discard after terminal instead of neighbors" {
    const sample =
        \\tagged(F) ::= TAGGED(T) discard t_form(E).  @tagged_form2(F; T, E)
        \\t_form(A) ::= FORM(A).
        \\discard ::= .
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    const resolution = document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "discard"));
    switch (resolution) {
        .symbol => |symbol| {
            try expectEqual(SemanticKind.rule_reference, symbol.kind);
            try expectEqualStrings("discard", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }
}

const std = @import("std");
const OOM = std.mem.Allocator.Error;
const diff = @import("diff.zig");
const lsp = @import("lsp");
const types = lsp.types.flat;
const ts = @import("tree-sitter");
const tags_query_source = @embedFile("zitron-tags-query");
const zitron_grammar = @import("tree_sitter_zitron");
