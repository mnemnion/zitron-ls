//! Zitron Language Server
//!
//! Implementation of a language server for Zitron, an LALR(1) parser
//! generator based on a port of D. Richard Hipp's Lemon.

/// The language-server name reported during LSP initialization.
pub const server_name = "lsp_zitron";

const server_version = "0.0.1";
const zitron_completion_triggers = [_][]const u8{ "%", "(" };

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

/// Errors that can occur while loading the configured fixture source.
pub const FixtureError = std.Io.Dir.ReadFileAllocError;

fn positionEncodingKind(encoding: lsp.offsets.Encoding) types.PositionEncodingKind {
    return switch (encoding) {
        .@"utf-8" => .@"utf-8",
        .@"utf-16" => .@"utf-16",
        .@"utf-32" => .@"utf-32",
    };
}

fn serverCapabilities(
    allocator: std.mem.Allocator,
    offset_encoding: lsp.offsets.Encoding,
    zls_completion_triggers: ?[]const []const u8,
) types.ServerCapabilities {
    return .{
        .positionEncoding = positionEncodingKind(offset_encoding),
        .textDocumentSync = .{
            .text_document_sync_options = .{
                .openClose = true,
                .change = .Incremental,
            },
        },
        .completionProvider = .{
            .triggerCharacters = mergeCompletionTriggers(
                allocator,
                zls_completion_triggers,
            ) catch &zitron_completion_triggers,
        },
        .hoverProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = true },
        .referencesProvider = .{ .bool = true },
        .documentSymbolProvider = .{ .bool = true },
        .renameProvider = .{ .bool = true },
        .inlayHintProvider = .{ .inlay_hint_options = .{} },
    };
}

fn mergeCompletionTriggers(
    allocator: std.mem.Allocator,
    zls_completion_triggers: ?[]const []const u8,
) OOM![]const []const u8 {
    const zls_triggers = zls_completion_triggers orelse return &zitron_completion_triggers;

    var merged: std.ArrayList([]const u8) = .empty;
    errdefer merged.deinit(allocator);
    try merged.appendSlice(allocator, &zitron_completion_triggers);
    for (zls_triggers) |trigger| {
        if (!containsString(merged.items, trigger)) {
            try merged.append(allocator, trigger);
        }
    }

    return try merged.toOwnedSlice(allocator);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// LSP server state and handlers for Zitron grammars.
pub const Server = struct {
    /// Errors produced while parsing or updating server-managed documents.
    pub const Error = Document.Error || ZigMiddleware.Error;

    allocator: std.mem.Allocator,
    scratch_arena: std.heap.ArenaAllocator,
    documents: std.StringHashMapUnmanaged(Document),
    tags_query: *ts.Query,
    rename_query: *ts.Query,
    offset_encoding: lsp.offsets.Encoding,
    zig_middleware: ZigMiddleware,

    /// Creates a server instance and compiles the grammar tag query.
    pub fn init(allocator: std.mem.Allocator) ts.Query.Error!Server {
        var query_error_offset: u32 = 0;
        const tags_query = try ts.Query.create(zitronLanguage(), tags_query_source, &query_error_offset);
        errdefer tags_query.destroy();
        const rename_query = try ts.Query.create(zitronLanguage(), rename_query_source, &query_error_offset);
        errdefer rename_query.destroy();

        return .{
            .allocator = allocator,
            .scratch_arena = std.heap.ArenaAllocator.init(allocator),
            .documents = .empty,
            .tags_query = tags_query,
            .rename_query = rename_query,
            .offset_encoding = .@"utf-16",
            .zig_middleware = ZigMiddleware.disabled(),
        };
    }

    /// Creates a server instance with the production Zig middleware enabled.
    pub fn initProduction(io: std.Io, allocator: std.mem.Allocator) Error!Server {
        var server = try init(allocator);
        errdefer server.deinit();
        server.zig_middleware = try ZigMiddleware.init(io, allocator);
        return server;
    }

    /// Releases all document state and query resources owned by the server.
    pub fn deinit(server: *Server) void {
        server.zig_middleware.deinit();
        var it = server.documents.iterator();
        while (it.next()) |entry| {
            server.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(server.allocator);
        }
        server.documents.deinit(server.allocator);
        server.scratch_arena.deinit();
        server.rename_query.destroy();
        server.tags_query.destroy();
    }

    /// LSP `initialize` handler required by `lsp-kit`.
    pub fn initialize(
        server: *Server,
        allocator: std.mem.Allocator,
        params: types.InitializeParams,
    ) types.InitializeResult {
        if (params.clientInfo) |client_info| {
            log.info("Client: {s} {s}", .{ client_info.name, client_info.version orelse "" });
        }
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
            .capabilities = serverCapabilities(
                allocator,
                server.offset_encoding,
                server.zig_middleware.completionTriggerCharacters(),
            ),
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
        log.debug("Opened document: {s}", .{params.textDocument.uri});
        const doc = server.getDocument(params.textDocument.uri) orelse return error.InvalidParams;
        try server.zig_middleware.syncDocument(
            params.textDocument.uri,
            params.textDocument.version,
            doc.source,
            doc.tree.rootNode(),
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
        log.debug("Changed document: {s}", .{params.textDocument.uri});
        try server.zig_middleware.syncDocument(
            params.textDocument.uri,
            params.textDocument.version,
            doc.source,
            doc.tree.rootNode(),
        );
    }

    /// LSP `textDocument/didClose` handler that drops cached document state.
    pub fn @"textDocument/didClose"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidCloseTextDocumentParams,
    ) void {
        server.zig_middleware.closeDocument(params.textDocument.uri);
        server.removeDocument(params.textDocument.uri);
    }

    /// LSP `textDocument/completion` handler for directive completions.
    pub fn @"textDocument/completion"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.CompletionParams,
    ) Error!lsp.ResultType("textDocument/completion") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        if (doc.containsZigCodeAtPosition(server.offset_encoding, params.position)) {
            return try server.zig_middleware.forwardCompletion(arena, params.textDocument.uri, params);
        }

        const root = doc.tree.rootNode();
        const items = try completion.completeImplAliases(
            arena,
            doc.source,
            root,
            params.position,
            server.offset_encoding,
        ) orelse try completion.completeRuleActionAliases(
            arena,
            doc.source,
            root,
            params.position,
            server.offset_encoding,
        ) orelse try completion.completeDirectives(
            arena,
            doc.source,
            root,
            params.position,
            server.offset_encoding,
        ) orelse try completion.completeGrammarParticles(
            arena,
            doc.source,
            root,
            params.position,
            server.offset_encoding,
        ) orelse return null;

        return .{ .completion_items = items };
    }

    /// LSP `textDocument/hover` handler for Zitron grammar symbols.
    pub fn @"textDocument/hover"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.HoverParams,
    ) Error!?types.Hover {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        const value = switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => return null,
            .unsupported_zig_code => return try server.zig_middleware.forwardHover(arena, params.textDocument.uri, params),
            .symbol => |symbol| try hoverMarkdownForSymbol(arena, symbol),
        };

        return .{
            .contents = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = value,
                },
            },
        };
    }

    /// LSP `textDocument/definition` handler for grammar symbol lookups.
    pub fn @"textDocument/definition"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DefinitionParams,
    ) Error!lsp.ResultType("textDocument/definition") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        return switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => null,
            .unsupported_zig_code => try server.zig_middleware.forwardDefinition(arena, params.textDocument.uri, params),
            .symbol => |symbol| switch (symbol.kind) {
                .rule_definition, .action_definition => .{
                    .definition = .{
                        .location = doc.locationForNode(
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
                    .definition = .{
                        .location = doc.locationForNode(
                            params.textDocument.uri,
                            definition.name_node,
                            server.offset_encoding,
                        ),
                    },
                } else null,
                .terminal_reference => null,
                .action_implementation => if (doc.findActionDefinition(server.tags_query, symbol.symbol_name)) |definition| .{
                    .definition = .{
                        .location = doc.locationForNode(
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
    ) Error!lsp.ResultType("textDocument/references") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        return switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => null,
            .unsupported_zig_code => try server.zig_middleware.forwardReferences(arena, params.textDocument.uri, params),
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

    /// LSP `textDocument/inlayHint` handler for embedded Zig inlay hints.
    pub fn @"textDocument/inlayHint"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.InlayHintParams,
    ) Error!lsp.ResultType("textDocument/inlayHint") {
        _ = server.getDocument(params.textDocument.uri) orelse return null;
        return try server.zig_middleware.forwardInlayHint(arena, params.textDocument.uri, params);
    }

    /// LSP `textDocument/documentSymbol` handler for document-local grammar symbols.
    pub fn @"textDocument/documentSymbol"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DocumentSymbolParams,
    ) Error!lsp.ResultType("textDocument/documentSymbol") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        const local_symbols = try doc.documentSymbols(
            server.tags_query,
            arena,
            server.offset_encoding,
        );
        var symbols: std.ArrayList(types.DocumentSymbol) = .empty;
        try symbols.appendSlice(arena, local_symbols);
        if (try server.zig_middleware.forwardDocumentSymbols(arena, params.textDocument.uri)) |zig_symbols| {
            try symbols.appendSlice(arena, zig_symbols);
        }
        return .{
            .document_symbols = try symbols.toOwnedSlice(arena),
        };
    }

    /// LSP `textDocument/rename` handler for document-local grammar symbols.
    pub fn @"textDocument/rename"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.RenameParams,
    ) Error!lsp.ResultType("textDocument/rename") {
        const doc = server.getDocument(params.textDocument.uri) orelse return null;
        if (doc.containsZigCodeAtPosition(server.offset_encoding, params.position)) {
            return try server.zig_middleware.forwardRename(arena, params.textDocument.uri, params);
        }

        const symbol = doc.renameSymbolAtPosition(
            server.rename_query,
            server.offset_encoding,
            params.position,
        ) orelse return null;
        const edits = try doc.renameEdits(
            server.rename_query,
            arena,
            symbol,
            params.newName,
            server.offset_encoding,
        );
        var all_edits: std.ArrayList(types.TextEdit) = .empty;
        try all_edits.appendSlice(arena, edits);
        if (symbol.kind == .alias) {
            const code_ranges = try doc.aliasCodeBlockRangesForRename(arena, symbol);
            const code_edits = (try server.zig_middleware.aliasCodeBlockRenameEdits(
                arena,
                params.textDocument.uri,
                symbol.symbol_name,
                params.newName,
                code_ranges,
                server.offset_encoding,
            )) orelse return null;
            const magic_comment_edits = try doc.aliasMagicCommentEditsForRename(
                arena,
                symbol,
                params.newName,
                server.offset_encoding,
            );
            try all_edits.appendSlice(arena, magic_comment_edits);
            try all_edits.appendSlice(arena, code_edits);
        }
        if (all_edits.items.len == 0) return null;

        var changes = std.json.ArrayHashMap([]const types.TextEdit){};
        try changes.map.put(arena, params.textDocument.uri, try all_edits.toOwnedSlice(arena));
        return .{ .changes = changes };
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
            .terminal_reference => std.fmt.allocPrint(
                arena,
                "terminal reference `{s}`\n\ncapture `{s}` on `{s}`",
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
pub fn loadFixtureAlloc(io: std.Io, allocator: std.mem.Allocator) FixtureError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, build_options.fixture_path, allocator, .limited(64 * 1024));
}

fn completionItemsContainLabel(items: []const types.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

fn completionItemWithLabel(items: []const types.CompletionItem, label: []const u8) ?types.CompletionItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return item;
    }
    return null;
}

fn expectActionAliasCompletion(
    server: *Server,
    arena: std.mem.Allocator,
    sample: []const u8,
    marker: []const u8,
    expected: []const u8,
) !void {
    const position = lsp.offsets.indexToPosition(sample, (try byteIndexOf(sample, marker)) + marker.len, test_offset_encoding);
    const result = (try server.@"textDocument/completion"(arena, .{
        .textDocument = .{ .uri = "file:///samples/action_alias_completion.zy" },
        .position = position,
        .context = .{
            .triggerKind = .TriggerCharacter,
            .triggerCharacter = "(",
        },
    })) orelse return error.UnexpectedCompletionResult;

    const items = switch (result) {
        .completion_items => |completion_items| completion_items,
        else => return error.UnexpectedCompletionResult,
    };
    const item = completionItemWithLabel(items, expected) orelse return error.UnexpectedCompletionResult;
    try expectEqualStrings("@action aliases", item.detail.?);
    switch (item.textEdit.?) {
        .text_edit => |edit| try expectEqualStrings(expected, edit.newText),
        else => return error.UnexpectedCompletionResult,
    }
}

test "server capabilities match the implemented handlers" {
    lsp.basic_server.validateServerCapabilities(
        Server,
        serverCapabilities(testing_allocator, .@"utf-16", null),
    );
}

test "server capabilities merge zls completion triggers" {
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const capabilities = serverCapabilities(
        arena_state.allocator(),
        .@"utf-8",
        &.{ ".", ":", "(" },
    );
    const triggers = capabilities.completionProvider.?.triggerCharacters.?;

    try expectEqual(@as(usize, 4), triggers.len);
    try expectEqualStrings("%", triggers[0]);
    try expectEqualStrings("(", triggers[1]);
    try expectEqualStrings(".", triggers[2]);
    try expectEqualStrings(":", triggers[3]);
}

test "embedded tags query compiles for the zitron grammar" {
    var error_offset: u32 = 0;
    const query = try ts.Query.create(zitronLanguage(), tags_query_source, &error_offset);
    defer query.destroy();

    try expectEqual(@as(u32, 13), query.patternCount());
    try expect(query.captureCount() >= 3);
}

test "tree-sitter zitron parses the configured fixture" {
    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    const parsed = try parseSource(sample);

    try expectEqualStrings("source_file", parsed.root_kind);
    try expect(!parsed.has_error);
}

test "server tracks open documents" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .languageId = .{ .custom_value = "zitron" },
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

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .languageId = .{ .custom_value = "zitron" },
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
            .{ .text_document_content_change_partial = .{
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
            .languageId = .{ .custom_value = "zitron" },
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
        .completion_items => |items| {
            try expect(items.len >= 2);
            try expect(completionItemsContainLabel(items, "%type"));
            try expect(completionItemsContainLabel(items, "%token_type"));
        },
        else => return error.UnexpectedCompletionResult,
    }
}

test "server returns impl alias list completion from action definition" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample =
        \\pair(P) ::= m_form(K) discard m_form(V). @on_pair2(P; K, V)
        \\%impl @on_pair2(
    ;

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/impl_completion.zy",
            .languageId = .{ .custom_value = "zitron" },
            .version = 1,
            .text = sample,
        },
    });

    const result = (try server.@"textDocument/completion"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/impl_completion.zy" },
        .position = lsp.offsets.indexToPosition(sample, sample.len, test_offset_encoding),
        .context = .{
            .triggerKind = .TriggerCharacter,
            .triggerCharacter = "(",
        },
    })) orelse return error.UnexpectedCompletionResult;

    const items = switch (result) {
        .completion_items => |completion_items| completion_items,
        else => return error.UnexpectedCompletionResult,
    };
    const item = completionItemWithLabel(items, "P; K, V") orelse return error.UnexpectedCompletionResult;
    try expectEqual(types.CompletionItemKind.Variable, item.kind.?);
    switch (item.textEdit.?) {
        .text_edit => |edit| {
            try expectEqualStrings("P; K, V", edit.newText);
            try expectEqual(@as(u32, 1), edit.range.start.line);
            try expectEqual(@as(u32, 16), edit.range.start.character);
        },
        else => return error.UnexpectedCompletionResult,
    }
}

test "server returns rule action alias completions in house style" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const cases = [_]struct {
        sample: []const u8,
        marker: []const u8,
        expected: []const u8,
    }{
        .{ .sample = "one_lhs(A) ::= . @one_lhs(", .marker = "@one_lhs(", .expected = "A" },
        .{ .sample = "one_rhs ::= TOKEN(B). @one_rhs(", .marker = "@one_rhs(", .expected = ";B" },
        .{ .sample = "one_each(A) ::= TOKEN(B). @one_each(", .marker = "@one_each(", .expected = "A;B" },
        .{ .sample = "several_rhs ::= ONE(B) TWO(C). @several_rhs(", .marker = "@several_rhs(", .expected = " ; B, C" },
        .{ .sample = "buncha(A) ::= ONE(B) TWO(C) THREE(D). @buncha(", .marker = "@buncha(", .expected = "A; B, C, D" },
    };

    for (cases, 1..) |case, version| {
        try server.@"textDocument/didOpen"(testing_allocator, .{
            .textDocument = .{
                .uri = "file:///samples/action_alias_completion.zy",
                .languageId = .{ .custom_value = "zitron" },
                .version = @intCast(version),
                .text = case.sample,
            },
        });
        try expectActionAliasCompletion(&server, arena_state.allocator(), case.sample, case.marker, case.expected);
    }
}

test "server completes grammar particles including multiterminals" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample =
        \\foo ::= FOO|BAR|BAZ.
        \\bar ::= FOO.
        \\calc ::= F
    ;

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/particle_completion.zy",
            .languageId = .{ .custom_value = "zitron" },
            .version = 1,
            .text = sample,
        },
    });

    const result = (try server.@"textDocument/completion"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/particle_completion.zy" },
        .position = lsp.offsets.indexToPosition(sample, sample.len, test_offset_encoding),
    })) orelse return error.UnexpectedCompletionResult;

    const items = switch (result) {
        .completion_items => |completion_items| completion_items,
        else => return error.UnexpectedCompletionResult,
    };
    const terminal = completionItemWithLabel(items, "FOO") orelse return error.UnexpectedCompletionResult;
    try expectEqualStrings("terminal", terminal.detail.?);
    try expectEqual(types.CompletionItemKind.EnumMember, terminal.kind.?);

    const multiterminal = completionItemWithLabel(items, "FOO|BAR|BAZ") orelse return error.UnexpectedCompletionResult;
    try expectEqualStrings("multiterminal", multiterminal.detail.?);
    try expectEqual(types.CompletionItemKind.Constant, multiterminal.kind.?);
    try expectEqualStrings("FOO|BAR|BAZ", multiterminal.filterText.?);
}

test "server completes multiterminals from matching member terminals" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample =
        \\foo ::= FOO|BAR|BAZ.
        \\calc ::= BA
    ;

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/multiterminal_member_completion.zy",
            .languageId = .{ .custom_value = "zitron" },
            .version = 1,
            .text = sample,
        },
    });

    const result = (try server.@"textDocument/completion"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/multiterminal_member_completion.zy" },
        .position = lsp.offsets.indexToPosition(sample, sample.len, test_offset_encoding),
    })) orelse return error.UnexpectedCompletionResult;

    const items = switch (result) {
        .completion_items => |completion_items| completion_items,
        else => return error.UnexpectedCompletionResult,
    };

    const multiterminal = completionItemWithLabel(items, "FOO|BAR|BAZ") orelse return error.UnexpectedCompletionResult;
    try expectEqualStrings("BAR", multiterminal.filterText.?);
    switch (multiterminal.textEdit.?) {
        .text_edit => |edit| {
            try expectEqualStrings("FOO|BAR|BAZ", edit.newText);
            try expectEqual(@as(u32, 1), edit.range.start.line);
            try expectEqual(@as(u32, 9), edit.range.start.character);
        },
        else => return error.UnexpectedCompletionResult,
    }
}

test "incremental tree-sitter reparse matches fresh parse" {
    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    var incremental = try Document.init(testing_allocator, 1, sample);
    defer incremental.deinit(testing_allocator);

    try incremental.updateIncremental(testing_allocator, 2, &.{
        .{ .text_document_content_change_partial = .{
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

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
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

test "query resolution finds directive grammar symbols" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const expr_type_index = try byteIndexOf(sample, "%type expr f64");
    const expr_resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfTextAfter(sample, expr_type_index, "expr"));
    switch (expr_resolution) {
        .symbol => |symbol| {
            try expectEqual(Document.SemanticKind.rule_reference, symbol.kind);
            try expectEqualStrings("expr", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }

    const number_type_index = try byteIndexOf(sample, "%type NUMBER {f64}");
    const number_resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfTextAfter(sample, number_type_index, "NUMBER"));
    switch (number_resolution) {
        .symbol => |symbol| {
            try expectEqual(Document.SemanticKind.terminal_reference, symbol.kind);
            try expectEqualStrings("NUMBER", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }
}

test "query resolution returns no match on punctuation" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfText(sample, "%token_type"));
    try expectEqual(Document.Resolution.no_match, resolution);
}

test "query resolution returns unsupported inside zig code" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.putDocument("file:///samples/calc.zy", 1, sample);
    const doc = server.getDocument("file:///samples/calc.zy").?;

    const resolution = doc.resolveAtPosition(server.tags_query, server.offset_encoding, try positionOfText(sample, "answer = A"));
    try expectEqual(Document.Resolution.unsupported_zig_code, resolution);
}

test "disabled Zig middleware returns null for Zig-code requests" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .languageId = .{ .custom_value = "zitron" },
            .version = 1,
            .text = sample,
        },
    });

    const position = try positionOfText(sample, "answer = A");
    const hover = try server.@"textDocument/hover"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = position,
    });
    try expect(hover == null);

    const definition = try server.@"textDocument/definition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = position,
    });
    try expect(definition == null);

    const references = try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = position,
        .context = .{ .includeDeclaration = false },
    });
    try expect(references == null);

    const completion_result = try server.@"textDocument/completion"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = position,
    });
    try expect(completion_result == null);

    const inlay_hints = try server.@"textDocument/inlayHint"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 100, .character = 0 },
        },
    });
    try expect(inlay_hints == null);
}

test "hover definition and references operate on stored live document state" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
    defer testing_allocator.free(sample);

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/calc.zy",
            .languageId = .{ .custom_value = "zitron" },
            .version = 1,
            .text = sample,
        },
    });

    const hover = (try server.@"textDocument/hover"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfText(sample, "calc ::= expr"),
    })).?;
    switch (hover.contents) {
        .markup_content => |content| {
            try expect(std.mem.indexOf(u8, content.value, "rule definition `calc`") != null);
        },
        else => return error.UnexpectedHoverContents,
    }

    const calc_rule_index = try byteIndexOf(sample, "calc ::= expr");
    const definition = (try server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, calc_rule_index + 1, "expr"),
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .definition => |target| switch (target) {
            .location => |location| {
                try expectEqualStrings("file:///samples/calc.zy", location.uri);
                try expectEqual(@as(u32, 48), location.range.start.line);
                try expectEqual(@as(u32, 0), location.range.start.character);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const expr_type_index = try byteIndexOf(sample, "%type expr f64");
    const directive_definition = (try server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, expr_type_index, "expr"),
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (directive_definition) {
        .definition => |target| switch (target) {
            .location => |location| {
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
    try expectEqual(@as(usize, 5), references.len);
    try expect(Server.hasLocationAt(references, "file:///samples/calc.zy", try positionOfTextAfter(sample, calc_rule_index + 1, "expr")));
    try expect(Server.hasLocationAt(references, "file:///samples/calc.zy", try positionOfTextAfter(sample, expr_type_index, "expr")));

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
    try expectEqual(@as(usize, 8), references_with_declaration.len);
    try expect(Server.hasLocationAt(references_with_declaration, "file:///samples/calc.zy", try positionOfTextAfter(sample, calc_rule_index, "expr(A)")));
    try expect(Server.hasLocationAt(references_with_declaration, "file:///samples/calc.zy", try positionOfTextAfter(sample, first_expr_rhs_rule_index, "expr(A)")));

    const third_expr_rule_index = try byteIndexOf(sample, "expr(A) ::= term(A).");
    try expect(Server.hasLocationAt(references_with_declaration, "file:///samples/calc.zy", try positionOfTextAfter(sample, third_expr_rule_index, "expr(A)")));

    const number_type_index = try byteIndexOf(sample, "%type NUMBER {f64}");
    const number_references = (try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, number_type_index, "NUMBER"),
        .context = .{ .includeDeclaration = false },
    })) orelse return error.UnexpectedDefinitionTarget;
    try expectEqual(@as(usize, 2), number_references.len);
    try expect(Server.hasLocationAt(number_references, "file:///samples/calc.zy", try positionOfTextAfter(sample, number_type_index, "NUMBER")));

    const number_rhs_index = try byteIndexOf(sample, "factor(A) ::= NUMBER(N).");
    try expect(Server.hasLocationAt(number_references, "file:///samples/calc.zy", try positionOfTextAfter(sample, number_rhs_index, "NUMBER")));
}

test "document symbols operate on stored live document state" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample =
        \\calc ::= expr(A). @on_calc(A)
        \\expr(A) ::= NUMBER(A).
        \\%impl @on_calc(A) { _ = A; }
    ;

    try server.@"textDocument/didOpen"(testing_allocator, .{
        .textDocument = .{
            .uri = "file:///samples/symbols.zy",
            .languageId = .{ .custom_value = "zitron" },
            .version = 1,
            .text = sample,
        },
    });

    const result = (try server.@"textDocument/documentSymbol"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/symbols.zy" },
    })) orelse return error.UnexpectedDocumentSymbols;

    switch (result) {
        .document_symbols => |symbols| {
            try expectEqual(@as(usize, 4), symbols.len);
            try expectEqualStrings("calc", symbols[0].name);
            try expectEqual(types.SymbolKind.Class, symbols[0].kind);
            try expectEqualStrings("@on_calc", symbols[1].name);
            try expectEqual(types.SymbolKind.Interface, symbols[1].kind);
            try expectEqualStrings("expr", symbols[2].name);
            try expectEqual(types.SymbolKind.Class, symbols[2].kind);
            try expectEqualStrings("@on_calc", symbols[3].name);
            try expectEqual(types.SymbolKind.Function, symbols[3].kind);
        },
        else => return error.UnexpectedDocumentSymbols,
    }
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
    const definition = (try server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/named_actions.zy" },
        .position = definition_position,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .definition => |target| switch (target) {
            .location => |location| {
                try expectEqualStrings("file:///samples/named_actions.zy", location.uri);
                try expectEqual(definition_target, location.range.start);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const implementation_anchor = try byteIndexOf(sample, "%impl @vector_form(F;V)");
    const implementation_position = try positionOfTextAfter(sample, implementation_anchor + 1, "vector_form(F;V)");
    const implementation_definition = (try server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/named_actions.zy" },
        .position = implementation_position,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (implementation_definition) {
        .definition => |target| switch (target) {
            .location => |location| {
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
    const missing_result = try server.@"textDocument/definition"(testing_allocator, .{
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

    const definition = (try server.@"textDocument/definition"(testing_allocator, .{
        .textDocument = .{ .uri = "file:///samples/discard.zy" },
        .position = reference_position,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .definition => |target| switch (target) {
            .location => |location| {
                try expectEqualStrings("file:///samples/discard.zy", location.uri);
                try expectEqual(definition_target, location.range.start);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }
}

test "rename returns grammar-side edits without including aliases" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/rename.zy";
    const sample =
        \\%type expr f64
        \\%type NUMBER {f64}
        \\start ::= expr(A).
        \\expr(A) ::= term(A) PLUS|MINUS NUMBER(N). @on_expr(A; N)
        \\term(A) ::= NUMBER(A).
        \\%impl @on_expr(A; N) { _ = .{A,N}; }
    ;
    try server.putDocument(uri, 1, sample);

    const nonterminal_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "expr(A)"),
        .newName = "expression",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, nonterminal_edit, uri, "expr", "expression", 3);
    try expectRenamePreservesAliasText(sample, nonterminal_edit, "(A)");

    const terminal_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "PLUS|MINUS"),
        .newName = "ADD",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, terminal_edit, uri, "PLUS", "ADD", 1);
    try expectRenamePreservesAliasText(sample, terminal_edit, "|MINUS");

    const action_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "on_expr(A; N)"),
        .newName = "@on_expression",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, action_edit, uri, "@on_expr", "@on_expression", 2);
    try expectRenamePreservesAliasText(sample, action_edit, "(A; N)");
}

test "rename returns scoped alias grammar edits" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/alias_rename.zy";
    const sample =
        \\expr(A) ::= term(A) NUMBER(N). @on_expr(A; N)
        \\sum(A) ::= term(A) NUMBER(N). @on_expr(A; N)
        \\%impl @on_expr(A; N) { _ = .{ A, N }; }
        \\%impl @on_expr(A; N) { _ = .{ N, A }; }
        \\term(A) ::= NUMBER(A).
    ;
    try server.putDocument(uri, 1, sample);

    const first_alias = try byteIndexOf(sample, "expr(A)");
    const rule_alias_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, first_alias + "expr(".len, "A"),
        .newName = "Value",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, rule_alias_edit, uri, "A", "Value", 8);
    try expectRenameDoesNotTouchText(sample, rule_alias_edit, "term(A) ::= NUMBER(A)");

    _ = arena_state.reset(.retain_capacity);

    const impl_alias = try byteIndexOf(sample, "%impl @on_expr(A; N)");
    const impl_alias_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, impl_alias + "%impl @on_expr(".len, "A"),
        .newName = "Value",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, impl_alias_edit, uri, "A", "Value", 8);
    try expectRenameDoesNotTouchText(sample, impl_alias_edit, "term(A) ::= NUMBER(A)");
}

test "rename rewrites magic overwrite comments for special aliases" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/magic_comment_rename.zy";
    const sample =
        \\form(F) ::= list(L). @f_list(F; L)
        \\%impl @f_list(F; L) {
        \\    F = L; // F-overwrites-L
        \\}
        \\pair(P) ::= ONE(A) TWO(B). @pair(P; A, B)
        \\%impl @pair(P; A, B) {
        \\    // P-overwrites-A
        \\}
    ;
    try server.putDocument(uri, 1, sample);

    const lhs_alias = try byteIndexOf(sample, "form(F)");
    const lhs_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, lhs_alias + "form(".len, "F"),
        .newName = "Value",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEditCount(lhs_edit, uri, 4);
    try expectRenameHasEdit(sample, lhs_edit, "// F-overwrites-L\n", "// Value-overwrites-L\n");

    _ = arena_state.reset(.retain_capacity);

    const impl_rhs_alias = try byteIndexOf(sample, "%impl @f_list(F; L)");
    const rhs_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, impl_rhs_alias + "%impl @f_list(F; ".len, "L"),
        .newName = "List",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEditCount(rhs_edit, uri, 4);
    try expectRenameHasEdit(sample, rhs_edit, "// F-overwrites-L\n", "// F-overwrites-List\n");

    _ = arena_state.reset(.retain_capacity);

    const second_rhs_alias = try byteIndexOf(sample, "B). @pair");
    const second_rhs_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, second_rhs_alias, "B"),
        .newName = "Bee",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEditCount(second_rhs_edit, uri, 3);
    try expectRenameDoesNotTouchText(sample, second_rhs_edit, "// P-overwrites-A\n");
}

test "rename follows ditto aliases from master and named actions" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/ditto_alias_rename.zy";
    const sample =
        \\form(F) ::= list(L). @f_list(F; L)
        \\%type ignored void
        \\  `` map(M). @f_map(F; M)
        \\next(N) ::= atom(A). @next(N; A)
        \\  `` other(O). @other(N; O)
        \\%impl @f_list(F; L) {
        \\    F = L; // F-overwrites-L
        \\}
        \\%impl @f_map(F; M) {
        \\    F = M; // F-overwrites-M
        \\}
        \\%impl @other(N; O) {
        \\    N = O; // N-overwrites-O
        \\}
    ;
    try server.putDocument(uri, 1, sample);

    const lhs_alias = try byteIndexOf(sample, "form(F)");
    const lhs_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, lhs_alias + "form(".len, "F"),
        .newName = "Value",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEditCount(lhs_edit, uri, 7);
    try expectRenameHasEdit(sample, lhs_edit, "// F-overwrites-L\n", "// Value-overwrites-L\n");
    try expectRenameHasEdit(sample, lhs_edit, "// F-overwrites-M\n", "// Value-overwrites-M\n");
    try expectRenameDoesNotTouchText(sample, lhs_edit, "// N-overwrites-O\n");

    _ = arena_state.reset(.retain_capacity);

    const impl_ditto_lhs = try byteIndexOf(sample, "%impl @f_map(F; M)");
    const impl_lhs_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, impl_ditto_lhs + "%impl @f_map(".len, "F"),
        .newName = "Value",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEditCount(impl_lhs_edit, uri, 7);
    try expectRenameHasEdit(sample, impl_lhs_edit, "// F-overwrites-L\n", "// Value-overwrites-L\n");
    try expectRenameHasEdit(sample, impl_lhs_edit, "// F-overwrites-M\n", "// Value-overwrites-M\n");
    try expectRenameDoesNotTouchText(sample, impl_lhs_edit, "// N-overwrites-O\n");

    _ = arena_state.reset(.retain_capacity);

    const ditto_rhs = try byteIndexOf(sample, "map(M)");
    const rhs_edit = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfTextAfter(sample, ditto_rhs + "map(".len, "M"),
        .newName = "MapValue",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEditCount(rhs_edit, uri, 4);
    try expectRenameHasEdit(sample, rhs_edit, "// F-overwrites-M\n", "// F-overwrites-MapValue\n");
    try expectRenameDoesNotTouchText(sample, rhs_edit, "// F-overwrites-L\n");
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

fn expectRenameEdits(
    source: []const u8,
    workspace_edit: types.WorkspaceEdit,
    uri: []const u8,
    old_name: []const u8,
    new_name: []const u8,
    expected_count: usize,
) !void {
    const changes = workspace_edit.changes orelse return error.UnexpectedRenameResult;
    const edits = changes.map.get(uri) orelse return error.UnexpectedRenameResult;
    try expectEqual(expected_count, edits.len);
    for (edits) |edit| {
        try expectEqualStrings(old_name, lsp.offsets.rangeToSlice(source, edit.range, test_offset_encoding));
        try expectEqualStrings(new_name, edit.newText);
    }
}

fn expectRenamePreservesAliasText(
    source: []const u8,
    workspace_edit: types.WorkspaceEdit,
    preserved_text: []const u8,
) !void {
    const changes = workspace_edit.changes orelse return error.UnexpectedRenameResult;
    var it = changes.map.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.*) |edit| {
            const end = lsp.offsets.positionToIndex(source, edit.range.end, test_offset_encoding);
            if (std.mem.startsWith(u8, source[end..], preserved_text)) return;
        }
    }
    return error.UnexpectedRenameResult;
}

fn expectRenameEditCount(
    workspace_edit: types.WorkspaceEdit,
    uri: []const u8,
    expected_count: usize,
) !void {
    const changes = workspace_edit.changes orelse return error.UnexpectedRenameResult;
    const edits = changes.map.get(uri) orelse return error.UnexpectedRenameResult;
    try expectEqual(expected_count, edits.len);
}

fn expectRenameHasEdit(
    source: []const u8,
    workspace_edit: types.WorkspaceEdit,
    old_text: []const u8,
    new_text: []const u8,
) !void {
    const changes = workspace_edit.changes orelse return error.UnexpectedRenameResult;
    var it = changes.map.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.*) |edit| {
            if (std.mem.eql(u8, old_text, lsp.offsets.rangeToSlice(source, edit.range, test_offset_encoding)) and
                std.mem.eql(u8, new_text, edit.newText))
            {
                return;
            }
        }
    }
    return error.UnexpectedRenameResult;
}

fn expectRenameDoesNotTouchText(
    source: []const u8,
    workspace_edit: types.WorkspaceEdit,
    preserved_text: []const u8,
) !void {
    const preserved_start = try byteIndexOf(source, preserved_text);
    const preserved_end = preserved_start + preserved_text.len;
    const changes = workspace_edit.changes orelse return error.UnexpectedRenameResult;
    var it = changes.map.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.*) |edit| {
            const start = lsp.offsets.positionToIndex(source, edit.range.start, test_offset_encoding);
            const end = lsp.offsets.positionToIndex(source, edit.range.end, test_offset_encoding);
            try expect(end <= preserved_start or preserved_end <= start);
        }
    }
}

const std = @import("std");
const OOM = std.mem.Allocator.Error;
const Document = @import("Document.zig");
const ZigMiddleware = @import("ZigMiddleware.zig");
const completion = @import("completion.zig");
const lsp = @import("lsp");
const types = lsp.types.flat;
const build_options = @import("build_options");
const ts = @import("tree-sitter");
const tags_query_source = @embedFile("zitron-tags-query");
const rename_query_source = @embedFile("zitron-rename-query");
const zitron_grammar = @import("tree_sitter_zitron");
const test_offset_encoding: lsp.offsets.Encoding = .@"utf-8";
const log = std.log.scoped(.lsp_zitron);

comptime {
    std.testing.refAllDecls(Document);
    std.testing.refAllDecls(ZigMiddleware);
}
