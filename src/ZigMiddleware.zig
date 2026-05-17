//! Zig middleware for generated Zitron parser code.

mode: Mode,

const ZigMiddleware = @This();

const Mode = union(enum) {
    disabled,
    enabled: Middleware,
};

const Middleware = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    zls_child: std.process.Child,
    zls_transport: lsp.Transport.Stdio,
    zls_read_buffer: []u8,
    documents: std.StringHashMapUnmanaged(GeneratedDocument),
    zls_completion_triggers: []const []const u8,
    next_request_id: i64,

    const deinit = middlewareDeinit;
    const syncDocument = middlewareSyncDocument;
    const closeDocument = middlewareCloseDocument;
    const forwardHover = middlewareForwardHover;
    const forwardDefinition = middlewareForwardDefinition;
    const forwardReferences = middlewareForwardReferences;
    const forwardCompletion = middlewareForwardCompletion;
    const forwardDocumentSymbols = middlewareForwardDocumentSymbols;
    const forwardRename = middlewareForwardRename;
    const aliasCodeBlockRenameEdits = middlewareAliasCodeBlockRenameEdits;
    const initializeZls = middlewareInitializeZls;
    const shutdownZls = middlewareShutdownZls;
    const request = middlewareRequest;
    const readResponseForId = middlewareReadResponseForId;
    const nextRequestId = middlewareNextRequestId;
    const documentReady = middlewareDocumentReady;
};

pub const Error =
    OOM ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    std.process.RunError ||
    lsp.Transport.ReadError ||
    lsp.Transport.WriteError ||
    JsonParseError ||
    error{
        ChildProcessFailed,
        MissingGeneratedDocument,
        RequestFailed,
        UnexpectedResponse,
        UnsupportedUri,
    };

const GeneratedDocument = struct {
    source_uri: []u8,
    source_path: []u8,
    source_text: []const u8,
    generated_uri: []u8,
    generated_text: []u8,
    code_map: CodeMap,
    generation_error: ?[]u8,
    version: i32,
    opened: bool,

    fn deinit(doc: *GeneratedDocument, allocator: std.mem.Allocator) void {
        allocator.free(doc.source_uri);
        allocator.free(doc.source_path);
        allocator.free(doc.generated_uri);
        allocator.free(doc.generated_text);
        doc.code_map.deinit(allocator);
        if (doc.generation_error) |message| allocator.free(message);
    }
};

pub fn disabled() ZigMiddleware {
    return .{ .mode = .disabled };
}

pub fn init(io: std.Io, allocator: std.mem.Allocator) Error!ZigMiddleware {
    return initImpl(io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => disabled(),
    };
}

fn initImpl(io: std.Io, allocator: std.mem.Allocator) Error!ZigMiddleware {
    try checkZitron(allocator, io);

    const read_buffer = try allocator.alloc(u8, 4096);
    errdefer allocator.free(read_buffer);

    var child = try std.process.spawn(io, .{
        .argv = &.{"zls"},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    var mware: Middleware = .{
        .allocator = allocator,
        .io = io,
        .zls_child = child,
        .zls_transport = lsp.Transport.Stdio.init(read_buffer, child.stdout.?, child.stdin.?),
        .zls_read_buffer = read_buffer,
        .documents = .empty,
        .zls_completion_triggers = &.{},
        .next_request_id = 1,
    };
    errdefer mware.deinit();

    try mware.initializeZls();
    return .{ .mode = .{ .enabled = mware } };
}

pub fn deinit(middleware: *ZigMiddleware) void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |*mware| mware.deinit(),
    }
}

pub fn completionTriggerCharacters(middleware: *const ZigMiddleware) ?[]const []const u8 {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| mware.zls_completion_triggers,
    };
}

pub fn syncDocument(
    middleware: *ZigMiddleware,
    uri: []const u8,
    version: i32,
    source_text: []const u8,
    source_root: ts.Node,
) Error!void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |*mware| try mware.syncDocument(uri, version, source_text, source_root),
    }
}

pub fn closeDocument(middleware: *ZigMiddleware, uri: []const u8) void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |*mware| mware.closeDocument(uri),
    }
}

pub fn forwardHover(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.HoverParams,
) Error!?types.Hover {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| try mware.forwardHover(arena, source_uri, params),
    };
}

pub fn forwardDefinition(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.DefinitionParams,
) Error!lsp.ResultType("textDocument/definition") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| try mware.forwardDefinition(arena, source_uri, params),
    };
}

pub fn forwardReferences(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.ReferenceParams,
) Error!lsp.ResultType("textDocument/references") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| try mware.forwardReferences(arena, source_uri, params),
    };
}

pub fn forwardCompletion(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.CompletionParams,
) Error!lsp.ResultType("textDocument/completion") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| try mware.forwardCompletion(arena, source_uri, params),
    };
}

pub fn forwardDocumentSymbols(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
) Error!?[]const types.DocumentSymbol {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| try mware.forwardDocumentSymbols(arena, source_uri),
    };
}

pub fn forwardRename(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.RenameParams,
) Error!lsp.ResultType("textDocument/rename") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |*mware| try mware.forwardRename(arena, source_uri, params),
    };
}

pub fn aliasCodeBlockRenameEdits(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    source_ranges: []const ts.Range,
    offset_encoding: lsp.offsets.Encoding,
) Error!?[]const types.TextEdit {
    return switch (middleware.mode) {
        .disabled => &.{},
        .enabled => |*mware| try mware.aliasCodeBlockRenameEdits(
            arena,
            source_uri,
            alias_name,
            new_name,
            source_ranges,
            offset_encoding,
        ),
    };
}

fn middlewareDeinit(middleware: *Middleware) void {
    freeStringSlices(middleware.allocator, middleware.zls_completion_triggers);
    var it = middleware.documents.iterator();
    while (it.next()) |entry| {
        middleware.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(middleware.allocator);
    }
    middleware.documents.deinit(middleware.allocator);

    middleware.shutdownZls() catch {};
    middleware.zls_child.kill(middleware.io);
    middleware.allocator.free(middleware.zls_read_buffer);
}

fn middlewareSyncDocument(
    middleware: *Middleware,
    uri: []const u8,
    version: i32,
    source_text: []const u8,
    source_root: ts.Node,
) Error!void {
    const gop = try middleware.documents.getOrPut(middleware.allocator, uri);
    if (!gop.found_existing) {
        errdefer _ = middleware.documents.remove(uri);
        gop.key_ptr.* = try middleware.allocator.dupe(u8, uri);
        errdefer middleware.allocator.free(gop.key_ptr.*);

        const source_path = try filePathFromUri(middleware.allocator, uri);
        errdefer middleware.allocator.free(source_path);
        const generated_uri = try generatedUriForSourceUri(middleware.allocator, uri);
        errdefer middleware.allocator.free(generated_uri);

        gop.value_ptr.* = .{
            .source_uri = try middleware.allocator.dupe(u8, uri),
            .source_path = source_path,
            .source_text = source_text,
            .generated_uri = generated_uri,
            .generated_text = try middleware.allocator.alloc(u8, 0),
            .code_map = .{},
            .generation_error = null,
            .version = version,
            .opened = false,
        };
    }

    const doc = gop.value_ptr;
    doc.version = version;
    doc.source_text = source_text;
    if (doc.generation_error) |message| {
        middleware.allocator.free(message);
        doc.generation_error = null;
    }

    const generated = runZitron(middleware.allocator, middleware.io, doc.source_path, source_text) catch |err| {
        doc.generation_error = try middleware.allocator.dupe(u8, @errorName(err));
        return;
    };
    defer middleware.allocator.free(generated.stderr);
    const generated_success = switch (generated.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!generated_success) {
        middleware.allocator.free(generated.stdout);
        doc.generation_error = try middleware.allocator.dupe(u8, generated.stderr);
        return;
    }
    errdefer middleware.allocator.free(generated.stdout);

    try doc.code_map.update(middleware.allocator, source_root, generated.stdout, doc.source_path);

    if (doc.opened) {
        var text_changes = try diff.textChanges(middleware.allocator, doc.generated_text, generated.stdout, .@"utf-8");
        defer text_changes.deinit(middleware.allocator);

        if (text_changes.items.len != 0) {
            try middleware.zls_transport.transport.writeNotification(
                middleware.io,
                middleware.allocator,
                "textDocument/didChange",
                lsp.ParamsType("textDocument/didChange"),
                .{
                    .textDocument = .{ .uri = doc.generated_uri, .version = version },
                    .contentChanges = text_changes.items,
                },
                .{ .emit_null_optional_fields = false },
            );
        }
    } else {
        try middleware.zls_transport.transport.writeNotification(
            middleware.io,
            middleware.allocator,
            "textDocument/didOpen",
            lsp.ParamsType("textDocument/didOpen"),
            .{
                .textDocument = .{
                    .uri = doc.generated_uri,
                    .languageId = .{ .custom_value = "zig" },
                    .version = version,
                    .text = generated.stdout,
                },
            },
            .{ .emit_null_optional_fields = false },
        );
        doc.opened = true;
    }

    middleware.allocator.free(doc.generated_text);
    doc.generated_text = generated.stdout;
}

fn middlewareCloseDocument(middleware: *Middleware, uri: []const u8) void {
    const removed = middleware.documents.fetchRemove(uri) orelse return;
    middleware.allocator.free(removed.key);
    var doc = removed.value;
    if (doc.opened) {
        middleware.zls_transport.transport.writeNotification(
            middleware.io,
            middleware.allocator,
            "textDocument/didClose",
            lsp.ParamsType("textDocument/didClose"),
            .{ .textDocument = .{ .uri = doc.generated_uri } },
            .{ .emit_null_optional_fields = false },
        ) catch {};
    }
    doc.deinit(middleware.allocator);
}

fn middlewareForwardHover(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.HoverParams,
) Error!?types.Hover {
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_translator = try code_map.translatorForSourcePosition(
        middleware.allocator,
        doc.source_text,
        doc.generated_text,
        params.position,
    ) orelse return null;
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .active = span_translator,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = sharedPosition(translation_context.active.sourcePositionToGenerated(params.position)) orelse return null;

    var result = try middleware.request(arena, "textDocument/hover", mapped);
    if (result) |*hover_result| try translateHover(hover_result, &translation_context);
    return result;
}

fn middlewareForwardDefinition(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.DefinitionParams,
) Error!lsp.ResultType("textDocument/definition") {
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_translator = try code_map.translatorForSourcePosition(
        middleware.allocator,
        doc.source_text,
        doc.generated_text,
        params.position,
    ) orelse return null;
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .active = span_translator,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = sharedPosition(translation_context.active.sourcePositionToGenerated(params.position)) orelse return null;

    const result = (try middleware.request(arena, "textDocument/definition", mapped)) orelse return null;
    return try translateDefinition(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
}

fn middlewareForwardReferences(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.ReferenceParams,
) Error!lsp.ResultType("textDocument/references") {
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_translator = try code_map.translatorForSourcePosition(
        middleware.allocator,
        doc.source_text,
        doc.generated_text,
        params.position,
    ) orelse return null;
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .active = span_translator,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = sharedPosition(translation_context.active.sourcePositionToGenerated(params.position)) orelse return null;

    const result = (try middleware.request(arena, "textDocument/references", mapped)) orelse return null;
    return try translateLocations(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
}

fn middlewareForwardCompletion(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.CompletionParams,
) Error!lsp.ResultType("textDocument/completion") {
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_translator = try code_map.translatorForSourcePosition(
        middleware.allocator,
        doc.source_text,
        doc.generated_text,
        params.position,
    ) orelse return null;
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .active = span_translator,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = sharedPosition(translation_context.active.sourcePositionToGenerated(params.position)) orelse return null;

    var result = try middleware.request(arena, "textDocument/completion", mapped);
    try translateCompletionResult(arena, &result, &translation_context);
    return result;
}

fn middlewareForwardDocumentSymbols(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
) Error!?[]const types.DocumentSymbol {
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const result = (try middleware.request(arena, "textDocument/documentSymbol", .{
        .textDocument = .{ .uri = doc.generated_uri },
    })) orelse return null;
    return try translateDocumentSymbols(arena, result, code_map);
}

fn middlewareForwardRename(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.RenameParams,
) Error!lsp.ResultType("textDocument/rename") {
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_translator = try code_map.translatorForSourcePosition(
        middleware.allocator,
        doc.source_text,
        doc.generated_text,
        params.position,
    ) orelse return null;
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .active = span_translator,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = sharedPosition(translation_context.active.sourcePositionToGenerated(params.position)) orelse return null;

    const result = (try middleware.request(arena, "textDocument/rename", mapped)) orelse return null;
    return try translateWorkspaceEdit(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
}

fn middlewareAliasCodeBlockRenameEdits(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    source_ranges: []const ts.Range,
    offset_encoding: lsp.offsets.Encoding,
) Error!?[]const types.TextEdit {
    const doc = try middleware.documentReady(source_uri);
    var edits: std.ArrayList(types.TextEdit) = .empty;
    errdefer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);

    for (source_ranges) |source_range| {
        const span_index = doc.code_map.indexForSourceRange(source_range) orelse return null;
        var translator = try SpanTranslator.init(
            middleware.allocator,
            doc.code_map.gen_span.items[span_index],
            doc.code_map.src_range.items[span_index],
            doc.source_text,
            doc.generated_text,
        );
        defer translator.deinit(middleware.allocator);

        try appendAliasRenameEditsFromDiff(
            arena,
            &edits,
            &seen_starts,
            doc.source_text,
            source_range,
            doc.generated_text,
            doc.code_map.gen_span.items[span_index].generated_range,
            translator.difference.edits.items,
            alias_name,
            new_name,
            offset_encoding,
        );
    }

    return try edits.toOwnedSlice(arena);
}

/// Mapping between original Zitron code blocks and generated Zig code.
pub const CodeMap = struct {
    /// Generated spans are stored in generated-line order, which is the order encountered
    /// while scanning the generated Zig file.
    gen_span: std.ArrayList(GenSpan) = .empty,
    /// Source ranges for the generated spans.  Indexes are kept in lockstep with
    /// `gen_span`, but the range retains exact tree-sitter byte and point data.
    src_range: std.ArrayList(ts.Range) = .empty,
    /// Indexes into `gen_span` and `src_range`, sorted by source-line order for source -> generated
    /// lookups. The buffer is retained across updates.
    src_order: std.ArrayList(usize) = .empty,

    /// Half-open byte range in either the source or generated text.
    pub const ByteRange = struct {
        start: usize,
        end: usize,
    };

    pub const Mutation = struct {
        source: types.Range,
        generated: types.Range,
    };

    pub const TranslatedPosition = union(enum) {
        shared: types.Position,
        mutant: Mutation,
    };

    /// One contiguous generated range. Source-line offsets keep the legacy LSP
    /// position mapping; `src_range` keeps the actual source code-block extent.
    const GenSpan = struct {
        /// First zero-based line in the original `.zy` document.
        source_line: u32,
        /// First zero-based line in the generated Zig document.
        generated_line: u32,
        /// Number of contiguous mapped lines shared by both coordinate systems.
        line_count: u32,
        /// Half-open byte range in the generated Zig document.
        generated_range: ByteRange,

        /// Exclusive source-line end.  Keeping this as a helper avoids repeating
        /// the half-open interval convention at every lookup site.
        fn sourceEnd(span: GenSpan) u32 {
            return span.source_line + span.line_count;
        }

        /// Exclusive generated-line end, matching `sourceEnd` in length.
        fn generatedEnd(span: GenSpan) u32 {
            return span.generated_line + span.line_count;
        }

        /// Compares a source line against this half-open span.
        fn orderSource(span: GenSpan, line: u32) std.math.Order {
            if (line < span.source_line) return .lt;
            if (line < span.sourceEnd()) return .eq;
            return .gt;
        }

        /// Compares a generated line against this half-open span.
        fn orderGenerated(span: GenSpan, line: u32) std.math.Order {
            if (line < span.generated_line) return .lt;
            if (line < span.generatedEnd()) return .eq;
            return .gt;
        }
    };

    const ActiveSpan = struct {
        gen_span: GenSpan,
        src_range: ts.Range,
    };

    /// Parses generated Zig into an initial map by delegating to `update`, so the
    /// initial build and incremental rebuild use the same span coalescing rules.
    pub fn parse(
        allocator: std.mem.Allocator,
        source_root: ts.Node,
        generated_text: []const u8,
        source_path: []const u8,
    ) OOM!CodeMap {
        var map: CodeMap = .{};
        errdefer map.deinit(allocator);
        try map.update(allocator, source_root, generated_text, source_path);
        return map;
    }

    /// Rebuilds this map from freshly generated Zig while retaining the backing
    /// allocations. The number of spans should usually stay stable, so this avoids
    /// churn without carrying incremental tree state.
    pub fn update(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        source_root: ts.Node,
        generated_text: []const u8,
        source_path: []const u8,
    ) OOM!void {
        map.gen_span.clearRetainingCapacity();
        map.src_range.clearRetainingCapacity();
        map.src_order.clearRetainingCapacity();

        try map.collectSpans(allocator, source_root, generated_text, source_path);
        try map.rebuildSourceOrder(allocator);
    }

    /// Frees the reusable span and index buffers.
    pub fn deinit(map: *CodeMap, allocator: std.mem.Allocator) void {
        map.gen_span.deinit(allocator);
        map.src_range.deinit(allocator);
        map.src_order.deinit(allocator);
        map.* = .{};
    }

    /// Translates a source position to generated coordinates by finding the
    /// earliest span that contains the source line and preserving the column.
    pub fn sourcePositionToGenerated(map: *const CodeMap, position: types.Position) ?types.Position {
        const span = map.findSource(position.line) orelse return null;
        return .{
            .line = span.generated_line + (position.line - span.source_line),
            .character = position.character,
        };
    }

    /// Translates a generated position back to source coordinates by finding the
    /// generated-order span containing the generated line and preserving column.
    pub fn generatedPositionToSource(map: *const CodeMap, position: types.Position) ?types.Position {
        const span = map.findGenerated(position.line) orelse return null;
        return .{
            .line = span.source_line + (position.line - span.generated_line),
            .character = position.character,
        };
    }

    fn translatorForSourcePosition(
        map: *const CodeMap,
        allocator: std.mem.Allocator,
        source_text: []const u8,
        generated_text: []const u8,
        position: types.Position,
    ) OOM!?SpanTranslator {
        const source_order_index = map.findSourceIndex(position.line) orelse return null;
        const span_index = map.src_order.items[source_order_index];
        return try SpanTranslator.init(
            allocator,
            map.gen_span.items[span_index],
            map.src_range.items[span_index],
            source_text,
            generated_text,
        );
    }

    /// Translates a generated range only when every generated line in the range is
    /// covered by adjacent mapped spans.  Gaps represent template/generated-only
    /// Zig and cannot be reported as a source range.
    pub fn generatedRangeToSource(map: *const CodeMap, range: types.Range) OOM!?types.Range {
        var index = map.findGeneratedIndex(range.start.line) orelse return null;
        while (map.gen_span.items[index].orderGenerated(range.end.line) != .eq) {
            const next_index = index + 1;
            if (next_index >= map.gen_span.items.len) return null;
            if (map.gen_span.items[next_index].generated_line != map.gen_span.items[index].generatedEnd()) return null;
            index = next_index;
        }

        return .{
            .start = map.generatedPositionToSource(range.start).?,
            .end = map.generatedPositionToSource(range.end).?,
        };
    }

    /// Scans generated text for `#line` comments and coalesces consecutive mapped
    /// lines into generated-order spans.
    fn collectSpans(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        source_root: ts.Node,
        generated_text: []const u8,
        source_path: []const u8,
    ) OOM!void {
        var generated_line: u32 = 0;
        var generated_offset: usize = 0;
        var active_span: ?ActiveSpan = null;
        var generated_lines = std.mem.splitScalar(u8, generated_text, '\n');
        while (generated_lines.next()) |line| : (generated_line += 1) {
            const line_end = generated_offset + line.len;
            const next_generated_offset = if (line_end < generated_text.len) line_end + 1 else line_end;

            if (parseLineDirective(line)) |directive| {
                try map.processActiveSpan(allocator, &active_span, generated_line, generated_offset);
                if (std.mem.eql(u8, directive.path, source_path)) {
                    if (zigCodeRangeForLine(source_root, directive.line)) |src_range| {
                        active_span = .{
                            .gen_span = .{
                                .source_line = directive.line,
                                .generated_line = generated_line + 1,
                                .line_count = 0,
                                .generated_range = .{
                                    .start = next_generated_offset,
                                    .end = next_generated_offset,
                                },
                            },
                            .src_range = src_range,
                        };
                    }
                }
            }

            generated_offset = next_generated_offset;
        }

        try map.processActiveSpan(allocator, &active_span, generated_line, generated_offset);
    }

    fn processActiveSpan(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        active_span: *?ActiveSpan,
        end_generated_line: u32,
        end_generated_offset: usize,
    ) OOM!void {
        var span = active_span.* orelse return;
        active_span.* = null;
        const line_count = end_generated_line - span.gen_span.generated_line;
        if (line_count == 0) return;
        span.gen_span.line_count = line_count;
        span.gen_span.generated_range.end = end_generated_offset;
        try map.gen_span.append(allocator, span.gen_span);
        errdefer _ = map.gen_span.pop();
        try map.src_range.append(allocator, span.src_range);
    }

    /// Rebuilds the source-order index over the current span buffer.
    fn rebuildSourceOrder(map: *CodeMap, allocator: std.mem.Allocator) OOM!void {
        try map.src_order.ensureTotalCapacity(allocator, map.gen_span.items.len);
        for (0..map.gen_span.items.len) |index| {
            try map.src_order.append(allocator, index);
        }
        std.mem.sort(usize, map.src_order.items, map.gen_span.items, sourceIndexLessThan);
    }

    /// Returns the number of spans in the map.  Tests use this to assert
    /// that multi-line ranges stay coalesced instead of becoming per-line nodes.
    fn len(map: *const CodeMap) usize {
        return map.gen_span.items.len;
    }

    fn indexForSourceRange(map: *const CodeMap, range: ts.Range) ?usize {
        for (map.src_range.items, 0..) |candidate, index| {
            if (candidate.start_byte == range.start_byte and candidate.end_byte == range.end_byte) {
                return index;
            }
        }
        return null;
    }

    /// Finds a generated-order span containing a generated line.
    fn findGenerated(map: *const CodeMap, line: u32) ?GenSpan {
        const index = map.findGeneratedIndex(line) orelse return null;
        return map.gen_span.items[index];
    }

    /// Finds the index of a generated-order span containing a generated line.
    fn findGeneratedIndex(map: *const CodeMap, line: u32) ?usize {
        var low: usize = 0;
        var high: usize = map.gen_span.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (map.gen_span.items[mid].orderGenerated(line)) {
                .lt => high = mid,
                .eq => return mid,
                .gt => low = mid + 1,
            }
        }

        return null;
    }

    /// Finds the earliest generated span containing a source line.
    fn findSource(map: *const CodeMap, line: u32) ?GenSpan {
        const index = map.findSourceIndex(line) orelse return null;
        return map.gen_span.items[map.src_order.items[index]];
    }

    fn spanInSourceOrder(map: *const CodeMap, index: usize) GenSpan {
        return map.gen_span.items[map.src_order.items[index]];
    }

    /// Finds the source-order index of the earliest generated span containing a
    /// source line.
    fn findSourceIndex(map: *const CodeMap, line: u32) ?usize {
        var low: usize = 0;
        var high: usize = map.src_order.items.len;
        var found: ?usize = null;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const span = map.spanInSourceOrder(mid);
            switch (span.orderSource(line)) {
                .lt => high = mid,
                .eq => {
                    found = mid;
                    high = mid;
                },
                .gt => low = mid + 1,
            }
        }
        return found;
    }

    /// Sorts source indexes by source start, then generated start.  The
    /// generated tie-breaker keeps defensive duplicate mappings deterministic.
    fn sourceIndexLessThan(spans: []const GenSpan, lhs_index: usize, rhs_index: usize) bool {
        const lhs = spans[lhs_index];
        const rhs = spans[rhs_index];
        if (lhs.source_line != rhs.source_line) return lhs.source_line < rhs.source_line;
        if (lhs.generated_line != rhs.generated_line) return lhs.generated_line < rhs.generated_line;
        return lhs_index < rhs_index;
    }
};

const SpanTranslator = struct {
    gen_span: CodeMap.GenSpan,
    src_range: ts.Range,
    source_text: []const u8,
    generated_text: []const u8,
    difference: Diff,

    const OffsetTranslation = union(enum) {
        shared: usize,
        mutant: CodeMap.Mutation,
    };

    fn init(
        allocator: std.mem.Allocator,
        gen_span: CodeMap.GenSpan,
        src_range: ts.Range,
        source_text: []const u8,
        generated_text: []const u8,
    ) OOM!SpanTranslator {
        const source_slice = source_text[src_range.start_byte..src_range.end_byte];
        const generated_slice = generated_text[gen_span.generated_range.start..gen_span.generated_range.end];

        var difference = Diff.init(.default);
        errdefer difference.deinit(allocator);
        _ = try difference.diff(allocator, source_slice, generated_slice);

        return .{
            .gen_span = gen_span,
            .src_range = src_range,
            .source_text = source_text,
            .generated_text = generated_text,
            .difference = difference,
        };
    }

    fn deinit(translator: *SpanTranslator, allocator: std.mem.Allocator) void {
        translator.difference.deinit(allocator);
        translator.* = undefined;
    }

    fn sourcePositionToGenerated(translator: *const SpanTranslator, position: types.Position) CodeMap.TranslatedPosition {
        const source_index = lsp.offsets.positionToIndex(translator.source_text, position, .@"utf-8");
        const source_start: usize = translator.src_range.start_byte;
        const rel = source_index - source_start;
        return switch (translator.sourceOffsetToGenerated(rel)) {
            .shared => |generated_rel| .{ .shared = lsp.offsets.indexToPosition(
                translator.generated_text,
                translator.gen_span.generated_range.start + generated_rel,
                .@"utf-8",
            ) },
            .mutant => |mutation| .{ .mutant = mutation },
        };
    }

    fn generatedPositionToSource(translator: *const SpanTranslator, position: types.Position) CodeMap.TranslatedPosition {
        const generated_index = lsp.offsets.positionToIndex(translator.generated_text, position, .@"utf-8");
        const rel = generated_index - translator.gen_span.generated_range.start;
        return switch (translator.generatedOffsetToSource(rel)) {
            .shared => |source_rel| .{ .shared = lsp.offsets.indexToPosition(
                translator.source_text,
                @as(usize, translator.src_range.start_byte) + source_rel,
                .@"utf-8",
            ) },
            .mutant => |mutation| .{ .mutant = mutation },
        };
    }

    fn generatedRangeToSource(translator: *const SpanTranslator, range: types.Range) ?types.Range {
        if (!translator.containsGeneratedPosition(range.start, false) or
            !translator.containsGeneratedPosition(range.end, true))
        {
            return null;
        }

        const generated_start = lsp.offsets.positionToIndex(translator.generated_text, range.start, .@"utf-8");
        const generated_end = lsp.offsets.positionToIndex(translator.generated_text, range.end, .@"utf-8");
        const rel_start = generated_start - translator.gen_span.generated_range.start;
        const rel_end = generated_end - translator.gen_span.generated_range.start;
        if (!translator.generatedIntervalShared(rel_start, rel_end)) return null;

        return .{
            .start = sharedPosition(translator.generatedPositionToSource(range.start)) orelse return null,
            .end = sharedPosition(translator.generatedPositionToSource(range.end)) orelse return null,
        };
    }

    fn containsGeneratedRange(translator: *const SpanTranslator, range: types.Range) bool {
        return translator.containsGeneratedPosition(range.start, false) and
            translator.containsGeneratedPosition(range.end, true);
    }

    fn containsGeneratedPosition(translator: *const SpanTranslator, position: types.Position, allow_end: bool) bool {
        if (position.line < translator.gen_span.generated_line) return false;
        if (position.line > translator.gen_span.generatedEnd()) return false;
        if (position.line == translator.gen_span.generatedEnd()) {
            return allow_end and position.character == 0;
        }
        return true;
    }

    fn sourceOffsetToGenerated(translator: *const SpanTranslator, rel: usize) OffsetTranslation {
        return sourceOffsetThroughDiff(translator, rel, translator.difference.edits.items);
    }

    fn generatedOffsetToSource(translator: *const SpanTranslator, rel: usize) OffsetTranslation {
        return generatedOffsetThroughDiff(translator, rel, translator.difference.edits.items);
    }

    fn generatedIntervalShared(translator: *const SpanTranslator, start: usize, end: usize) bool {
        if (start == end) return translator.generatedOffsetToSource(start) == .shared;
        return generatedDiffIntervalShared(start, end, translator.difference.edits.items);
    }

    fn sourceOffsetThroughDiff(translator: *const SpanTranslator, rel: usize, edits: []const Edit) OffsetTranslation {
        var source_cursor: usize = 0;
        var generated_cursor: usize = 0;
        var index: usize = 0;
        while (index < edits.len) {
            const edit = edits[index];
            switch (edit.operation) {
                .equal => {
                    const source_end = source_cursor + edit.text.len;
                    if (rel < source_end or (rel == source_end and source_end == translator.sourceLength())) {
                        return .{ .shared = generated_cursor + (rel - source_cursor) };
                    }
                    source_cursor = source_end;
                    generated_cursor += edit.text.len;
                    index += 1;
                },
                .delete, .insert => {
                    const mutation_start_source = source_cursor;
                    const mutation_start_generated = generated_cursor;
                    while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                        switch (edits[index].operation) {
                            .delete => source_cursor += edits[index].text.len,
                            .insert => generated_cursor += edits[index].text.len,
                            .equal => unreachable,
                        }
                    }
                    if (mutation_start_source <= rel and rel < source_cursor) {
                        return .{ .mutant = translator.sourceMutation(
                            mutation_start_source,
                            source_cursor,
                            mutation_start_generated,
                            generated_cursor,
                        ) };
                    }
                },
            }
        }
        return .{ .mutant = translator.sourceMutation(0, translator.sourceLength(), 0, translator.generatedLength()) };
    }

    fn generatedOffsetThroughDiff(translator: *const SpanTranslator, rel: usize, edits: []const Edit) OffsetTranslation {
        var source_cursor: usize = 0;
        var generated_cursor: usize = 0;
        var index: usize = 0;
        while (index < edits.len) {
            const edit = edits[index];
            switch (edit.operation) {
                .equal => {
                    const generated_end = generated_cursor + edit.text.len;
                    if (rel < generated_end or (rel == generated_end and generated_end == translator.generatedLength())) {
                        return .{ .shared = source_cursor + (rel - generated_cursor) };
                    }
                    source_cursor += edit.text.len;
                    generated_cursor = generated_end;
                    index += 1;
                },
                .delete, .insert => {
                    const mutation_start_source = source_cursor;
                    const mutation_start_generated = generated_cursor;
                    while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                        switch (edits[index].operation) {
                            .delete => source_cursor += edits[index].text.len,
                            .insert => generated_cursor += edits[index].text.len,
                            .equal => unreachable,
                        }
                    }
                    if (mutation_start_generated <= rel and rel < generated_cursor) {
                        return .{ .mutant = translator.sourceMutation(
                            mutation_start_source,
                            source_cursor,
                            mutation_start_generated,
                            generated_cursor,
                        ) };
                    }
                },
            }
        }
        return .{ .mutant = translator.sourceMutation(0, translator.sourceLength(), 0, translator.generatedLength()) };
    }

    fn sourceMutation(
        translator: *const SpanTranslator,
        source_start: usize,
        source_end: usize,
        generated_start: usize,
        generated_end: usize,
    ) CodeMap.Mutation {
        return .{
            .source = rangeFromByteRange(
                translator.source_text,
                @as(usize, translator.src_range.start_byte) + source_start,
                @as(usize, translator.src_range.start_byte) + source_end,
            ),
            .generated = rangeFromByteRange(
                translator.generated_text,
                translator.gen_span.generated_range.start + generated_start,
                translator.gen_span.generated_range.start + generated_end,
            ),
        };
    }

    fn sourceLength(translator: *const SpanTranslator) usize {
        return translator.src_range.end_byte - translator.src_range.start_byte;
    }

    fn generatedLength(translator: *const SpanTranslator) usize {
        return translator.gen_span.generated_range.end - translator.gen_span.generated_range.start;
    }
};

const RequestTranslationContext = struct {
    allocator: std.mem.Allocator,
    map: *const CodeMap,
    source_text: []const u8,
    generated_text: []const u8,
    active: SpanTranslator,
    generated_translators: std.ArrayList(GeneratedTranslator) = .empty,

    const GeneratedTranslator = struct {
        span_index: usize,
        translator: SpanTranslator,
    };

    fn deinit(context: *RequestTranslationContext) void {
        context.active.deinit(context.allocator);
        for (context.generated_translators.items) |*entry| {
            entry.translator.deinit(context.allocator);
        }
        context.generated_translators.deinit(context.allocator);
    }

    fn generatedRangeToSource(context: *RequestTranslationContext, range: types.Range) OOM!?types.Range {
        if (context.active.containsGeneratedRange(range)) {
            return context.active.generatedRangeToSource(range);
        }
        const translator = try context.translatorForGeneratedRange(range) orelse return null;
        return translator.generatedRangeToSource(range);
    }

    fn translatorForGeneratedRange(context: *RequestTranslationContext, range: types.Range) OOM!?*SpanTranslator {
        const span_index = context.map.findGeneratedIndex(range.start.line) orelse return null;
        const span = context.map.gen_span.items[span_index];
        if (span.orderGenerated(range.end.line) != .eq and !(range.end.line == span.generatedEnd() and range.end.character == 0)) {
            return null;
        }

        for (context.generated_translators.items) |*entry| {
            if (entry.span_index == span_index) return &entry.translator;
        }

        try context.generated_translators.append(context.allocator, .{
            .span_index = span_index,
            .translator = try SpanTranslator.init(
                context.allocator,
                span,
                context.map.src_range.items[span_index],
                context.source_text,
                context.generated_text,
            ),
        });
        return &context.generated_translators.items[context.generated_translators.items.len - 1].translator;
    }
};

fn sharedPosition(translated: CodeMap.TranslatedPosition) ?types.Position {
    return switch (translated) {
        .shared => |position| position,
        .mutant => null,
    };
}

fn generatedDiffIntervalShared(start: usize, end: usize, edits: []const Edit) bool {
    var index: usize = 0;
    var generated_cursor: usize = 0;
    while (index < edits.len) {
        switch (edits[index].operation) {
            .equal => {
                generated_cursor += edits[index].text.len;
                index += 1;
            },
            .delete, .insert => {
                const mutation_start = generated_cursor;
                while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                    if (edits[index].operation == .insert) generated_cursor += edits[index].text.len;
                }
                if (rangesOverlap(start, end, mutation_start, generated_cursor)) return false;
                if (mutation_start == generated_cursor and start < mutation_start and mutation_start < end) return false;
            },
        }
    }
    return true;
}

fn rangesOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) bool {
    return a_start < b_end and b_start < a_end;
}

fn rangeFromByteRange(text: []const u8, start: usize, end: usize) types.Range {
    return .{
        .start = lsp.offsets.indexToPosition(text, start, .@"utf-8"),
        .end = lsp.offsets.indexToPosition(text, end, .@"utf-8"),
    };
}

fn appendAliasRenameEditsFromDiff(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    source_text: []const u8,
    source_range: ts.Range,
    generated_text: []const u8,
    generated_range: CodeMap.ByteRange,
    diff_edits: []const Edit,
    alias_name: []const u8,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    var source_cursor: usize = 0;
    var generated_cursor: usize = 0;
    for (diff_edits) |edit| {
        switch (edit.operation) {
            .equal => {
                try appendAliasRenameEditsFromEqual(
                    arena,
                    edits,
                    seen_starts,
                    source_text,
                    @as(usize, source_range.start_byte) + source_cursor,
                    generated_text,
                    generated_range.start + generated_cursor,
                    edit.text,
                    alias_name,
                    new_name,
                    offset_encoding,
                );
                source_cursor += edit.text.len;
                generated_cursor += edit.text.len;
            },
            .insert => generated_cursor += edit.text.len,
            .delete => {
                try appendAliasRenameEditsFromDelete(
                    arena,
                    edits,
                    seen_starts,
                    source_text,
                    @as(usize, source_range.start_byte) + source_cursor,
                    edit.text,
                    alias_name,
                    new_name,
                    offset_encoding,
                );
                source_cursor += edit.text.len;
            },
        }
    }
}

fn appendAliasRenameEditsFromEqual(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    source_text: []const u8,
    source_start: usize,
    generated_text: []const u8,
    generated_start: usize,
    equal_text: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    // TODO: Drop this when alias rename uses token-based diffing instead of string diffing.
    var index: usize = 0;
    while (index < equal_text.len) : (index += 1) {
        const source_absolute = source_start + index;
        const generated_absolute = generated_start + index;
        if (equal_text[index] == '@' and
            std.mem.startsWith(u8, equal_text[index + 1 ..], alias_name) and
            isAliasBoundary(source_text, source_absolute + 1, alias_name.len) and
            !isAliasBoundary(generated_text, generated_absolute + 1, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                source_text,
                source_absolute,
                source_absolute + 1 + alias_name.len,
                try std.fmt.allocPrint(arena, "@{s}", .{new_name}),
                offset_encoding,
            );
            index += alias_name.len;
            continue;
        }

        if (std.mem.startsWith(u8, equal_text[index..], alias_name) and
            isAliasBoundary(source_text, source_absolute, alias_name.len) and
            !isAliasBoundary(generated_text, generated_absolute, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                source_text,
                source_absolute,
                source_absolute + alias_name.len,
                new_name,
                offset_encoding,
            );
            index += alias_name.len - 1;
        }
    }
}

fn appendAliasRenameEditsFromDelete(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    source_text: []const u8,
    delete_start: usize,
    deleted_text: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    var index: usize = 0;
    while (index < deleted_text.len) : (index += 1) {
        const absolute = delete_start + index;
        if (deleted_text[index] == '@' and
            std.mem.startsWith(u8, deleted_text[index + 1 ..], alias_name) and
            isAliasBoundary(source_text, absolute + 1, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                source_text,
                absolute,
                absolute + 1 + alias_name.len,
                try std.fmt.allocPrint(arena, "@{s}", .{new_name}),
                offset_encoding,
            );
            index += alias_name.len;
            continue;
        }

        if (std.mem.startsWith(u8, deleted_text[index..], alias_name) and
            isAliasBoundary(source_text, absolute, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                source_text,
                absolute,
                absolute + alias_name.len,
                new_name,
                offset_encoding,
            );
            index += alias_name.len - 1;
        }
    }
}

fn appendAliasCodeEdit(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    source_text: []const u8,
    start: usize,
    end: usize,
    new_text: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    const gop = try seen_starts.getOrPut(arena, start);
    if (gop.found_existing) return;

    try edits.append(arena, .{
        .range = lsp.offsets.locToRange(source_text, .{
            .start = start,
            .end = end,
        }, offset_encoding),
        .newText = new_text,
    });
}

fn isAliasBoundary(source_text: []const u8, start: usize, len: usize) bool {
    if (start > 0 and isAliasByte(source_text[start - 1])) return false;
    const end = start + len;
    return end >= source_text.len or !isAliasByte(source_text[end]);
}

fn isAliasByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn zigCodeRangeForLine(source_root: ts.Node, line: u32) ?ts.Range {
    const line_start: ts.Point = .{ .row = line, .column = 0 };
    var node = source_root.descendantForPointRange(line_start, lineEndPoint(source_root, line)) orelse return null;
    if (std.mem.eql(u8, node.kind(), "zig_code")) return node.range();

    while (true) {
        const zig_code = descendantOfKindOnLine(node, "zig_code", line) orelse {
            node = node.parent() orelse return null;
            continue;
        };
        return zig_code.range();
    }
}

fn lineEndPoint(source_root: ts.Node, line: u32) ts.Point {
    const source_end = source_root.endPoint();
    if (source_end.row == line) return source_end;
    return .{ .row = line, .column = std.math.maxInt(u32) };
}

fn descendantOfKindOnLine(node: ts.Node, kind: []const u8, line: u32) ?ts.Node {
    var cursor = node.walk();
    defer cursor.destroy();

    while (true) {
        const current = cursor.node();
        if (nodeContainsLine(current, line)) {
            if (std.mem.eql(u8, current.kind(), kind)) return current;
            if (cursor.gotoFirstChild()) continue;
        }

        while (!cursor.gotoNextSibling()) {
            if (!cursor.gotoParent()) return null;
        }
    }
}

fn nodeContainsLine(node: ts.Node, line: u32) bool {
    return node.startPoint().row <= line and line <= node.endPoint().row;
}

/// Parsed form of a generated `// #line N path` marker. Zitron emits these
/// markers to connect generated Zig lines back to original Zitron source lines.
const LineDirective = struct {
    /// One-based line from the directive, normalized to zero-based LSP lines.
    line: u32,
    /// Path payload from the directive; only spans for the source `.zy` path are
    /// mapped back to the client document.
    path: []const u8,
};

/// Recognizes the exact generated-line marker format used by Zitron.
fn parseLineDirective(line: []const u8) ?LineDirective {
    const trimmed = trimLeft(line, " \t");
    const prefix = "// #line ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    var rest = trimmed[prefix.len..];
    const line_end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    const line_number = std.fmt.parseInt(u32, rest[0..line_end], 10) catch return null;
    rest = trimLeft(rest[line_end..], " \t");
    if (rest.len == 0) return null;

    return .{
        .line = line_number -| 1,
        .path = rest,
    };
}

/// Removes a small set of leading bytes without allocating.  Directive parsing
/// uses this so indentation before comments does not break mapping.
fn trimLeft(slice: []const u8, values_to_strip: []const u8) []const u8 {
    var index: usize = 0;
    while (index < slice.len and std.mem.indexOfScalar(u8, values_to_strip, slice[index]) != null) {
        index += 1;
    }
    return slice[index..];
}

pub fn translateHover(hover_result: *types.Hover, map: *RequestTranslationContext) OOM!void {
    if (hover_result.range) |range| {
        hover_result.range = try map.generatedRangeToSource(range);
    }
}

pub fn translateDefinition(
    arena: std.mem.Allocator,
    definition_result: lsp.types.Definition.Result,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?lsp.types.Definition.Result {
    return switch (definition_result) {
        .definition => |definition_value| if (try translateDefinitionValue(arena, definition_value, map, generated_uri, source_uri)) |translated|
            .{ .definition = translated }
        else
            null,
        .definition_links => |links| blk: {
            var translated: std.ArrayList(types.DefinitionLink) = .empty;
            for (links) |link| {
                if (try translateDefinitionLink(link, map, generated_uri, source_uri)) |mapped| {
                    try translated.append(arena, mapped);
                }
            }
            break :blk if (translated.items.len == 0) null else .{
                .definition_links = try translated.toOwnedSlice(arena),
            };
        },
    };
}

pub fn translateDefinitionValue(
    arena: std.mem.Allocator,
    definition_result: types.Definition,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?types.Definition {
    return switch (definition_result) {
        .location => |location| if (try translateLocation(location, map, generated_uri, source_uri)) |translated|
            .{ .location = translated }
        else
            null,
        .locations => |locations| blk: {
            var translated: std.ArrayList(types.Location) = .empty;
            for (locations) |location| {
                if (try translateLocation(location, map, generated_uri, source_uri)) |mapped| {
                    try translated.append(arena, mapped);
                }
            }
            break :blk if (translated.items.len == 0) null else .{
                .locations = try translated.toOwnedSlice(arena),
            };
        },
    };
}

fn translateDefinitionLink(
    link: types.DefinitionLink,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?types.DefinitionLink {
    if (!std.mem.eql(u8, link.targetUri, generated_uri)) return link;
    return .{
        .originSelectionRange = if (link.originSelectionRange) |range| try map.generatedRangeToSource(range) else null,
        .targetUri = source_uri,
        .targetRange = (try map.generatedRangeToSource(link.targetRange)) orelse return null,
        .targetSelectionRange = (try map.generatedRangeToSource(link.targetSelectionRange)) orelse return null,
    };
}

pub fn translateLocations(
    arena: std.mem.Allocator,
    locations: []const types.Location,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?[]const types.Location {
    var translated: std.ArrayList(types.Location) = .empty;
    for (locations) |location| {
        if (try translateLocation(location, map, generated_uri, source_uri)) |mapped| {
            try translated.append(arena, mapped);
        }
    }

    return if (translated.items.len == 0) null else try translated.toOwnedSlice(arena);
}

pub fn translateCompletionResult(
    arena: std.mem.Allocator,
    result: *lsp.ResultType("textDocument/completion"),
    map: *RequestTranslationContext,
) OOM!void {
    const completion_result = result.* orelse return;
    switch (completion_result) {
        .completion_items => |items| {
            result.* = .{ .completion_items = try translateCompletionItems(arena, items, map) };
        },
        .completion_list => |list| {
            var translated_list = list;
            translated_list.items = try translateCompletionItems(arena, list.items, map);
            if (translated_list.itemDefaults) |*defaults| {
                if (defaults.editRange) |*edit_range| {
                    edit_range.* = (try translateCompletionDefaultEditRange(edit_range.*, map)) orelse return;
                }
            }
            result.* = .{ .completion_list = translated_list };
        },
    }
}

pub fn translateDocumentSymbols(
    arena: std.mem.Allocator,
    result: lsp.types.DocumentSymbol.Result,
    map: *const CodeMap,
) OOM!?[]const types.DocumentSymbol {
    return switch (result) {
        .document_symbols => |symbols| translateDocumentSymbolSlice(arena, symbols, map),
        .symbol_informations => null,
    };
}

pub fn translateWorkspaceEdit(
    arena: std.mem.Allocator,
    workspace_edit: types.WorkspaceEdit,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?types.WorkspaceEdit {
    var translated = workspace_edit;
    var has_changes = false;

    if (workspace_edit.changes) |changes| {
        var translated_changes = std.json.ArrayHashMap([]const types.TextEdit){};
        var it = changes.map.iterator();
        while (it.next()) |entry| {
            const uri = entry.key_ptr.*;
            const edits = entry.value_ptr.*;
            const translated_edits = if (std.mem.eql(u8, uri, generated_uri))
                try translateTextEdits(arena, edits, map)
            else
                edits;
            if (translated_edits.len == 0) continue;

            const translated_uri = if (std.mem.eql(u8, uri, generated_uri)) source_uri else uri;
            try translated_changes.map.put(arena, translated_uri, translated_edits);
        }

        if (translated_changes.map.count() != 0) {
            translated.changes = translated_changes;
            has_changes = true;
        } else {
            translated.changes = null;
        }
    }

    if (workspace_edit.documentChanges) |document_changes| {
        var translated_document_changes: std.ArrayList(@TypeOf(document_changes[0])) = .empty;
        for (document_changes) |change| {
            switch (change) {
                .text_document_edit => |edit| {
                    if (try translateTextDocumentEdit(arena, edit, map, generated_uri, source_uri)) |translated_edit| {
                        try translated_document_changes.append(arena, .{ .text_document_edit = translated_edit });
                    }
                },
                else => try translated_document_changes.append(arena, change),
            }
        }

        if (translated_document_changes.items.len != 0) {
            translated.documentChanges = try translated_document_changes.toOwnedSlice(arena);
            has_changes = true;
        } else {
            translated.documentChanges = null;
        }
    }

    return if (has_changes) translated else null;
}

fn translateLocation(location: types.Location, map: *RequestTranslationContext, generated_uri: []const u8, source_uri: []const u8) OOM!?types.Location {
    if (!std.mem.eql(u8, location.uri, generated_uri)) return location;
    return .{
        .uri = source_uri,
        .range = (try map.generatedRangeToSource(location.range)) orelse return null,
    };
}

fn translateDocumentSymbolSlice(
    arena: std.mem.Allocator,
    symbols: []const types.DocumentSymbol,
    map: *const CodeMap,
) OOM!?[]const types.DocumentSymbol {
    var translated: std.ArrayList(types.DocumentSymbol) = .empty;
    for (symbols) |symbol| {
        if (startsWithYy(symbol.name)) {
            if (symbol.children) |children| {
                if (try translateDocumentSymbolSlice(arena, children, map)) |mapped_children| {
                    try translated.appendSlice(arena, mapped_children);
                }
            }
            continue;
        }
        if (try translateDocumentSymbol(arena, symbol, map)) |mapped| {
            try translated.append(arena, mapped);
        }
    }

    return if (translated.items.len == 0) null else try translated.toOwnedSlice(arena);
}

fn translateDocumentSymbol(
    arena: std.mem.Allocator,
    symbol: types.DocumentSymbol,
    map: *const CodeMap,
) OOM!?types.DocumentSymbol {
    return .{
        .name = symbol.name,
        .detail = symbol.detail,
        .kind = symbol.kind,
        .tags = symbol.tags,
        .deprecated = symbol.deprecated,
        .range = (try map.generatedRangeToSource(symbol.range)) orelse return null,
        .selectionRange = (try map.generatedRangeToSource(symbol.selectionRange)) orelse return null,
        .children = if (symbol.children) |children| try translateDocumentSymbolSlice(arena, children, map) else null,
    };
}

fn startsWithYy(name: []const u8) bool {
    return name.len >= 2 and
        std.ascii.toLower(name[0]) == 'y' and
        std.ascii.toLower(name[1]) == 'y';
}

fn translateCompletionItems(
    arena: std.mem.Allocator,
    items_const: []const types.CompletionItem,
    map: *RequestTranslationContext,
) OOM![]const types.CompletionItem {
    const items = try arena.dupe(types.CompletionItem, items_const);
    for (items) |*item| {
        if (item.textEdit) |text_edit| {
            item.textEdit = (try translateCompletionTextEdit(text_edit, map)) orelse {
                item.textEdit = null;
                continue;
            };
        }

        if (item.additionalTextEdits) |edits| {
            var translated_edits: std.ArrayList(types.TextEdit) = .empty;
            for (edits) |edit| {
                if (try translateTextEdit(edit, map)) |translated_edit| {
                    try translated_edits.append(arena, translated_edit);
                }
            }
            item.additionalTextEdits = try translated_edits.toOwnedSlice(arena);
        }
    }

    return items;
}

fn translateCompletionTextEdit(text_edit: types.CompletionItem.TextEdit, map: *RequestTranslationContext) OOM!?types.CompletionItem.TextEdit {
    return switch (text_edit) {
        .text_edit => |edit| .{ .text_edit = (try translateTextEdit(edit, map)) orelse return null },
        .insert_replace_edit => |edit| .{ .insert_replace_edit = .{
            .newText = edit.newText,
            .insert = (try map.generatedRangeToSource(edit.insert)) orelse return null,
            .replace = (try map.generatedRangeToSource(edit.replace)) orelse return null,
        } },
    };
}

fn translateCompletionDefaultEditRange(
    edit_range: lsp.types.ClientCapabilities.TextDocument.Completion.EditRange,
    map: *RequestTranslationContext,
) OOM!?lsp.types.ClientCapabilities.TextDocument.Completion.EditRange {
    return switch (edit_range) {
        .range => |range| .{ .range = (try map.generatedRangeToSource(range)) orelse return null },
        .edit_range_with_insert_replace => |ranges| .{ .edit_range_with_insert_replace = .{
            .insert = (try map.generatedRangeToSource(ranges.insert)) orelse return null,
            .replace = (try map.generatedRangeToSource(ranges.replace)) orelse return null,
        } },
    };
}

fn translateTextEdit(edit: types.TextEdit, map: *RequestTranslationContext) OOM!?types.TextEdit {
    return .{
        .range = (try map.generatedRangeToSource(edit.range)) orelse return null,
        .newText = edit.newText,
    };
}

fn translateTextEdits(
    arena: std.mem.Allocator,
    edits: []const types.TextEdit,
    map: *RequestTranslationContext,
) OOM![]const types.TextEdit {
    var translated: std.ArrayList(types.TextEdit) = .empty;
    for (edits) |edit| {
        if (try translateTextEdit(edit, map)) |mapped| {
            try translated.append(arena, mapped);
        }
    }
    return try translated.toOwnedSlice(arena);
}

fn translateTextDocumentEdit(
    arena: std.mem.Allocator,
    edit: types.TextDocumentEdit,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?types.TextDocumentEdit {
    if (!std.mem.eql(u8, edit.textDocument.uri, generated_uri)) return edit;

    var translated_edits: std.ArrayList(@TypeOf(edit.edits[0])) = .empty;
    for (edit.edits) |document_edit| {
        switch (document_edit) {
            .text_edit => |text_edit| {
                if (try translateTextEdit(text_edit, map)) |translated| {
                    try translated_edits.append(arena, .{ .text_edit = translated });
                }
            },
            .annotated_text_edit => |annotated| {
                if (try translateAnnotatedTextEdit(annotated, map)) |translated| {
                    try translated_edits.append(arena, .{ .annotated_text_edit = translated });
                }
            },
            .snippet_text_edit => |snippet| {
                if (try translateSnippetTextEdit(snippet, map)) |translated| {
                    try translated_edits.append(arena, .{ .snippet_text_edit = translated });
                }
            },
        }
    }
    if (translated_edits.items.len == 0) return null;

    return .{
        .textDocument = .{
            .uri = source_uri,
            .version = null,
        },
        .edits = try translated_edits.toOwnedSlice(arena),
    };
}

fn translateAnnotatedTextEdit(edit: types.TextEdit.Annotated, map: *RequestTranslationContext) OOM!?types.TextEdit.Annotated {
    return .{
        .annotationId = edit.annotationId,
        .range = (try map.generatedRangeToSource(edit.range)) orelse return null,
        .newText = edit.newText,
    };
}

fn translateSnippetTextEdit(edit: types.TextDocumentEdit.Snippet, map: *RequestTranslationContext) OOM!?types.TextDocumentEdit.Snippet {
    return .{
        .range = (try map.generatedRangeToSource(edit.range)) orelse return null,
        .snippet = edit.snippet,
        .annotationId = edit.annotationId,
    };
}

fn checkZitron(allocator: std.mem.Allocator, io: std.Io) Error!void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zitron", "--version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

fn middlewareInitializeZls(middleware: *Middleware) Error!void {
    const id = middleware.nextRequestId();
    try middleware.zls_transport.transport.writeRequest(
        middleware.io,
        middleware.allocator,
        id,
        "initialize",
        lsp.ParamsType("initialize"),
        .{
            .processId = null,
            .clientInfo = .{ .name = "lsp_zitron" },
            .capabilities = .{
                .general = .{
                    .positionEncodings = &.{.@"utf-8"},
                },
                .textDocument = .{
                    .hover = .{
                        .contentFormat = &.{ .markdown, .plaintext },
                    },
                    .documentSymbol = .{
                        .hierarchicalDocumentSymbolSupport = true,
                    },
                },
            },
        },
        .{ .emit_null_optional_fields = false },
    );
    const initialize_response = try middleware.readResponseForId(middleware.allocator, id);
    defer middleware.allocator.free(initialize_response);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, middleware.allocator, initialize_response, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const result_value = switch (parsed.value) {
        .response => |response| switch (response.result_or_error) {
            .result => |maybe_result| maybe_result,
            .@"error" => return error.RequestFailed,
        },
        else => return error.UnexpectedResponse,
    };
    if (result_value == null or result_value.? == .null) return error.UnexpectedResponse;

    const initialize_result = try std.json.parseFromValue(types.InitializeResult, middleware.allocator, result_value.?, .{
        .ignore_unknown_fields = true,
    });
    defer initialize_result.deinit();

    if (initialize_result.value.capabilities.completionProvider) |completion_options| {
        if (completion_options.triggerCharacters) |trigger_characters| {
            freeStringSlices(middleware.allocator, middleware.zls_completion_triggers);
            middleware.zls_completion_triggers = try dupeStringSlices(middleware.allocator, trigger_characters);
        }
    }

    try middleware.zls_transport.transport.writeNotification(
        middleware.io,
        middleware.allocator,
        "initialized",
        lsp.ParamsType("initialized"),
        .{},
        .{ .emit_null_optional_fields = false },
    );
}

fn dupeStringSlices(allocator: std.mem.Allocator, slices: []const []const u8) OOM![]const []const u8 {
    if (slices.len == 0) return &.{};

    const owned = try allocator.alloc([]const u8, slices.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |owned_slice| allocator.free(owned_slice);
        allocator.free(owned);
    }
    for (slices, owned) |slice, *dest| {
        dest.* = try allocator.dupe(u8, slice);
        initialized += 1;
    }
    return owned;
}

fn freeStringSlices(allocator: std.mem.Allocator, slices: []const []const u8) void {
    if (slices.len == 0) return;
    for (slices) |slice| allocator.free(slice);
    allocator.free(slices);
}

fn middlewareShutdownZls(middleware: *Middleware) Error!void {
    const id = middleware.nextRequestId();
    try middleware.zls_transport.transport.writeRequest(
        middleware.io,
        middleware.allocator,
        id,
        "shutdown",
        lsp.ParamsType("shutdown"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    const json_message = try middleware.readResponseForId(middleware.allocator, id);
    middleware.allocator.free(json_message);
    try middleware.zls_transport.transport.writeNotification(
        middleware.io,
        middleware.allocator,
        "exit",
        lsp.ParamsType("exit"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    middleware.zls_child.stdin.?.close(middleware.io);
    middleware.zls_child.stdin = null;
    _ = try middleware.zls_child.wait(middleware.io);
}

fn middlewareRequest(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) Error!lsp.ResultType(method) {
    const id = middleware.nextRequestId();
    try middleware.zls_transport.transport.writeRequest(
        middleware.io,
        middleware.allocator,
        id,
        method,
        lsp.ParamsType(method),
        params,
        .{ .emit_null_optional_fields = false },
    );

    const json_message = try middleware.readResponseForId(arena, id);
    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, arena, json_message, .{
        .ignore_unknown_fields = true,
    });

    const result_value = switch (parsed.value) {
        .response => |response| switch (response.result_or_error) {
            .result => |maybe_result| maybe_result,
            .@"error" => return error.RequestFailed,
        },
        else => return error.UnexpectedResponse,
    };
    if (result_value == null or result_value.? == .null) return null;

    const typed = try std.json.parseFromValue(lsp.ResultType(method), arena, result_value.?, .{
        .ignore_unknown_fields = true,
    });
    return typed.value;
}

fn middlewareReadResponseForId(middleware: *Middleware, allocator: std.mem.Allocator, id: lsp.JsonRPCMessage.ID) Error![]u8 {
    while (true) {
        const json_message = try middleware.zls_transport.transport.readJsonMessage(middleware.io, allocator);
        errdefer allocator.free(json_message);
        const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        switch (parsed.value) {
            .response => |response| {
                if (response.id != null and response.id.?.eql(id)) return json_message;
            },
            else => {},
        }

        allocator.free(json_message);
    }
}

fn middlewareNextRequestId(middleware: *Middleware) lsp.JsonRPCMessage.ID {
    const id = middleware.next_request_id;
    middleware.next_request_id += 1;
    return .{ .number = id };
}

fn middlewareDocumentReady(middleware: *Middleware, source_uri: []const u8) Error!*GeneratedDocument {
    const doc = middleware.documents.getPtr(source_uri) orelse return error.MissingGeneratedDocument;
    if (doc.generation_error != null) return error.RequestFailed;
    return doc;
}

const ZitronResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runZitron(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    source_text: []const u8,
) Error!ZitronResult {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zitron", "-Fl", source_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    try std.Io.File.writeStreamingAll(child.stdin.?, io, source_text);
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer comptime unreachable;

    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn filePathFromUri(allocator: std.mem.Allocator, uri: []const u8) Error![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedUri;
    return try allocator.dupe(u8, uri[prefix.len..]);
}

fn generatedUriForSourceUri(allocator: std.mem.Allocator, uri: []const u8) Error![]u8 {
    const suffix = ".zy";
    if (std.mem.endsWith(u8, uri, suffix)) {
        return try std.fmt.allocPrint(allocator, "{s}.zitron.zig", .{uri[0 .. uri.len - suffix.len]});
    }
    return try std.fmt.allocPrint(allocator, "{s}.zitron.zig", .{uri});
}

fn parseCodeMapForTest(source_text: []const u8, generated_text: []const u8, source_path: []const u8) !CodeMap {
    var allocated_source: ?[]u8 = null;
    defer if (allocated_source) |source| testing_allocator.free(source);
    const effective_source = if (std.mem.indexOf(u8, source_text, "// #line") == null) source_text else source: {
        allocated_source = try genericZigCodeSourceForGeneratedTest(generated_text);
        break :source allocated_source.?;
    };

    const tree = try parseZitronTreeForTest(effective_source);
    defer tree.destroy();
    return try CodeMap.parse(testing_allocator, tree.rootNode(), generated_text, source_path);
}

fn updateCodeMapForTest(map: *CodeMap, source_text: []const u8, generated_text: []const u8, source_path: []const u8) !void {
    var allocated_source: ?[]u8 = null;
    defer if (allocated_source) |source| testing_allocator.free(source);
    const effective_source = if (std.mem.indexOf(u8, source_text, "// #line") == null) source_text else source: {
        allocated_source = try genericZigCodeSourceForGeneratedTest(generated_text);
        break :source allocated_source.?;
    };

    const tree = try parseZitronTreeForTest(effective_source);
    defer tree.destroy();
    try map.update(testing_allocator, tree.rootNode(), generated_text, source_path);
}

fn requestTranslationContextForTest(
    map: *const CodeMap,
    source_text: []const u8,
    generated_text: []const u8,
    position: types.Position,
) !RequestTranslationContext {
    const active = try map.translatorForSourcePosition(
        testing_allocator,
        source_text,
        generated_text,
        position,
    ) orelse return error.UnexpectedCodeMap;

    return .{
        .allocator = testing_allocator,
        .map = map,
        .source_text = source_text,
        .generated_text = generated_text,
        .active = active,
    };
}

fn genericZigCodeSourceForGeneratedTest(generated_text: []const u8) OOM![]u8 {
    var max_source_line: u32 = 0;
    var generated_line_count: u32 = 0;
    var generated_lines = std.mem.splitScalar(u8, generated_text, '\n');
    while (generated_lines.next()) |line| {
        if (parseLineDirective(line)) |directive| {
            max_source_line = @max(max_source_line, directive.line);
        }
        generated_line_count += 1;
    }

    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(testing_allocator);
    try source.appendSlice(testing_allocator, "%code {\n");
    for (0..max_source_line + generated_line_count + 1) |_| {
        try source.append(testing_allocator, '\n');
    }
    try source.appendSlice(testing_allocator, "}\n");
    return try source.toOwnedSlice(testing_allocator);
}

fn parseZitronTreeForTest(source_text: []const u8) !*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(zitronLanguage());
    return parser.parseString(source_text, null) orelse error.ParseFailed;
}

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

test "code map translates source and generated positions" {
    const generated =
        \\const std = @import("std");
        \\// #line 10 samples/calc.zy
        \\ answer = A;
        \\// #line 50 samples/calc.zig
        \\const generated_only = true;
        \\// #line 11 samples/calc.zy
        \\ next = answer;
    ;

    var map = try parseCodeMapForTest(generated, generated, "samples/calc.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Position{ .line = 2, .character = 5 }, map.sourcePositionToGenerated(.{
        .line = 9,
        .character = 5,
    }).?);
    try expectEqual(types.Position{ .line = 10, .character = 8 }, map.generatedPositionToSource(.{
        .line = 6,
        .character = 8,
    }).?);
    try expectEqual(@as(?types.Position, null), map.generatedPositionToSource(.{
        .line = 4,
        .character = 0,
    }));
}

test "code map translates only fully mapped generated ranges" {
    const generated =
        \\// #line 20 source.zy
        \\const a = 1;
        \\const b = 2;
        \\// #line 40 source.zig
        \\const generated_only = true;
    ;

    var map = try parseCodeMapForTest(generated, generated, "source.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Range{
        .start = .{ .line = 19, .character = 2 },
        .end = .{ .line = 20, .character = 7 },
    }, (try map.generatedRangeToSource(.{
        .start = .{ .line = 1, .character = 2 },
        .end = .{ .line = 2, .character = 7 },
    })).?);

    try expectEqual(@as(?types.Range, null), try map.generatedRangeToSource(.{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    }));
}

test "code map stores one span for a multi-line mapped range" {
    const generated =
        \\// #line 20 source.zy
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ;

    var map = try parseCodeMapForTest(generated, generated, "source.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(@as(u32, 3), map.gen_span.items[0].line_count);
    try expectEqual(types.Position{ .line = 21, .character = 9 }, map.generatedPositionToSource(.{
        .line = 3,
        .character = 9,
    }).?);
}

test "code map update reuses allocation and applies changed spans" {
    const original =
        \\// #line 10 source.zy
        \\const a = 1;
        \\const b = 2;
        \\// #line 20 source.zy
        \\const c = 3;
        \\// #line 30 source.zy
        \\const d = 4;
    ;

    var map = try parseCodeMapForTest(original, original, "source.zy");
    defer map.deinit(testing_allocator);

    const gen_span_capacity = map.gen_span.capacity;
    const src_range_capacity = map.src_range.capacity;
    const src_order_capacity = map.src_order.capacity;

    try updateCodeMapForTest(&map, original, original, "source.zy");
    try expectEqual(gen_span_capacity, map.gen_span.capacity);
    try expectEqual(src_range_capacity, map.src_range.capacity);
    try expectEqual(src_order_capacity, map.src_order.capacity);

    const shifted =
        \\// #line 10 source.zy
        \\const a = 1;
        \\const b = 2;
        \\// #line 80 source.zig
        \\const generated_only = true;
        \\// #line 21 source.zy
        \\const c = 3;
        \\// #line 90 source.zig
        \\// #line 33 source.zy
        \\const d = 4;
    ;
    try updateCodeMapForTest(&map, shifted, shifted, "source.zy");

    try expectEqual(gen_span_capacity, map.gen_span.capacity);
    try expectEqual(src_range_capacity, map.src_range.capacity);
    try expectEqual(src_order_capacity, map.src_order.capacity);
    try expectEqual(types.Position{ .line = 20, .character = 4 }, map.generatedPositionToSource(.{
        .line = 6,
        .character = 4,
    }).?);
    try expectEqual(types.Position{ .line = 32, .character = 4 }, map.generatedPositionToSource(.{
        .line = 9,
        .character = 4,
    }).?);
    try expectEqual(types.Position{ .line = 9, .character = 4 }, map.sourcePositionToGenerated(.{
        .line = 32,
        .character = 4,
    }).?);
}

test "code map update retains capacity after growing and shrinking" {
    const one_span =
        \\// #line 10 source.zy
        \\const a = 1;
    ;
    const two_spans =
        \\// #line 10 source.zy
        \\const a = 1;
        \\// #line 20 source.zy
        \\const b = 2;
    ;

    var map = try parseCodeMapForTest(one_span, one_span, "source.zy");
    defer map.deinit(testing_allocator);

    try updateCodeMapForTest(&map, two_spans, two_spans, "source.zy");
    try expectEqual(@as(usize, 2), map.len());
    const grown_gen_span_capacity = map.gen_span.capacity;
    const grown_src_range_capacity = map.src_range.capacity;
    const grown_src_order_capacity = map.src_order.capacity;

    try updateCodeMapForTest(&map, one_span, one_span, "source.zy");
    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(grown_gen_span_capacity, map.gen_span.capacity);
    try expectEqual(grown_src_range_capacity, map.src_range.capacity);
    try expectEqual(grown_src_order_capacity, map.src_order.capacity);
}

test "code map handles duplicate line directives deterministically" {
    const generated =
        \\// #line 5 source.zy
        \\const first = 1;
        \\// #line 5 source.zy
        \\const second = 2;
    ;

    var map = try parseCodeMapForTest(generated, generated, "source.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Position{ .line = 1, .character = 6 }, map.sourcePositionToGenerated(.{
        .line = 4,
        .character = 6,
    }).?);
    try expectEqual(types.Position{ .line = 4, .character = 6 }, map.generatedPositionToSource(.{
        .line = 3,
        .character = 6,
    }).?);
}

test "code map stores source and generated byte ranges" {
    const source =
        \\%code {
        \\const answer = 42;
        \\}
        \\rule ::= TOKEN. { result = token; }
    ;
    const generated =
        \\// #line 1 source.zy
        \\
        \\const answer = 42;
        \\// #line 4 source.zy
        \\ result = token; // #line 99 source.zig
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 2), map.len());

    const code_gen_span = map.gen_span.items[0];
    const code_src_range = map.src_range.items[0];
    try expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "{\n").? + 1)), code_src_range.start_byte);
    try expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "}\n").?)), code_src_range.end_byte);
    try expectEqual(std.mem.indexOf(u8, generated, "\n\n").? + 1, code_gen_span.generated_range.start);
    try expectEqual(std.mem.indexOf(u8, generated, "// #line 4").?, code_gen_span.generated_range.end);

    const action_gen_span = map.gen_span.items[1];
    const action_src_range = map.src_range.items[1];
    try expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "{ result").? + 1)), action_src_range.start_byte);
    try expectEqual(@as(u32, @intCast(std.mem.lastIndexOfScalar(u8, source, '}').?)), action_src_range.end_byte);
    try expectEqual(std.mem.indexOf(u8, generated, " result").?, action_gen_span.generated_range.start);
    try expectEqual(generated.len, action_gen_span.generated_range.end);
}

test "code map reports optimized-away code blocks as unmapped" {
    const source =
        \\%impl @first(A) {
        \\    A = B;
        \\}
        \\%impl @second(B) {
        \\    B = C;
        \\}
    ;
    const generated =
        \\// #line 1 source.zy
        \\    yygotominor.yy0 = yymsp[0].minor.yy42;
    ;

    const tree = try parseZitronTreeForTest(source);
    defer tree.destroy();
    var map = try CodeMap.parse(testing_allocator, tree.rootNode(), generated, "source.zy");
    defer map.deinit(testing_allocator);

    const mapped_range = zigCodeRangeForLine(tree.rootNode(), 1) orelse return error.UnexpectedCodeMap;
    const unmapped_range = zigCodeRangeForLine(tree.rootNode(), 4) orelse return error.UnexpectedCodeMap;
    try std.testing.expect(map.indexForSourceRange(mapped_range) != null);
    try expectEqual(@as(?usize, null), map.indexForSourceRange(unmapped_range));
}

test "alias code block rename refuses unmapped source blocks" {
    const source =
        \\%impl @first(A) {
        \\    A = B;
        \\}
        \\%impl @second(B) {
        \\    B = C;
        \\}
    ;
    const generated =
        \\// #line 1 source.zy
        \\    yygotominor.yy0 = yymsp[0].minor.yy42;
    ;
    const uri = "file:///source.zy";

    const tree = try parseZitronTreeForTest(source);
    defer tree.destroy();
    const mapped_range = zigCodeRangeForLine(tree.rootNode(), 1) orelse return error.UnexpectedCodeMap;
    const unmapped_range = zigCodeRangeForLine(tree.rootNode(), 4) orelse return error.UnexpectedCodeMap;
    var map = try CodeMap.parse(testing_allocator, tree.rootNode(), generated, "source.zy");
    errdefer map.deinit(testing_allocator);

    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = undefined,
        .zls_child = undefined,
        .zls_transport = undefined,
        .zls_read_buffer = undefined,
        .documents = .empty,
        .zls_completion_triggers = &.{},
        .next_request_id = 1,
    };
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, .{
        .source_uri = try testing_allocator.dupe(u8, uri),
        .source_path = try testing_allocator.dupe(u8, "source.zy"),
        .source_text = source,
        .generated_uri = try generatedUriForSourceUri(testing_allocator, uri),
        .generated_text = try testing_allocator.dupe(u8, generated),
        .code_map = map,
        .generation_error = null,
        .version = 1,
        .opened = false,
    });
    errdefer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var doc = removed.value;
        doc.deinit(testing_allocator);
        middleware.documents.deinit(testing_allocator);
    }

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const edits = try middleware.aliasCodeBlockRenameEdits(
        arena_state.allocator(),
        uri,
        "A",
        "Alias",
        &.{ mapped_range, unmapped_range },
        .@"utf-8",
    );
    try expectEqual(@as(?[]const types.TextEdit, null), edits);

    const removed = middleware.documents.fetchRemove(uri).?;
    testing_allocator.free(removed.key);
    var doc = removed.value;
    doc.deinit(testing_allocator);
    middleware.documents.deinit(testing_allocator);
}

test "request span translator applies source column offset" {
    const source =
        \\rule ::= TOKEN.   { result = token; }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ result = token;
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);

    var translator = try map.translatorForSourcePosition(
        testing_allocator,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "result").?, .@"utf-8"),
    ) orelse return error.UnexpectedCodeMap;
    defer translator.deinit(testing_allocator);

    try expectEqual(types.Position{
        .line = 1,
        .character = @intCast(std.mem.indexOf(u8, " result = token;", "result").?),
    }, sharedPosition(translator.sourcePositionToGenerated(lsp.offsets.indexToPosition(
        source,
        std.mem.indexOf(u8, source, "result").?,
        .@"utf-8",
    ))) orelse return error.UnexpectedCodeMap);
}

test "request span translator nulls mutated generated aliases" {
    const source =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);

    var translator = try map.translatorForSourcePosition(
        testing_allocator,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "pik_elist_append").?, .@"utf-8"),
    ) orelse return error.UnexpectedCodeMap;
    defer translator.deinit(testing_allocator);

    try expectEqual(types.Position{
        .line = 1,
        .character = @intCast(std.mem.indexOf(u8, generated, "pik_elist_append").? - std.mem.lastIndexOfScalar(u8, generated[0..std.mem.indexOf(u8, generated, "pik_elist_append").?], '\n').? - 1),
    }, sharedPosition(translator.sourcePositionToGenerated(lsp.offsets.indexToPosition(
        source,
        std.mem.indexOf(u8, source, "pik_elist_append").?,
        .@"utf-8",
    ))) orelse return error.UnexpectedCodeMap);

    try std.testing.expect(sharedPosition(translator.sourcePositionToGenerated(lsp.offsets.indexToPosition(
        source,
        std.mem.indexOf(u8, source, "A =").?,
        .@"utf-8",
    ))) == null);

    try std.testing.expect(translator.generatedRangeToSource(.{
        .start = lsp.offsets.indexToPosition(generated, std.mem.indexOf(u8, generated, "yygotominor").?, .@"utf-8"),
        .end = lsp.offsets.indexToPosition(generated, std.mem.indexOf(u8, generated, " =").?, .@"utf-8"),
    }) == null);
}

test "alias code block rename edits come from source-side deletes" {
    const source =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, @X, local_X); }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ yygotominor.yy0 = pik_elist_append(p, yymsp[0].minor.yy42, local_X);
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source_range = map.src_range.items[0];
    const generated_range = map.gen_span.items[0].generated_range;
    var difference = Diff.init(.default);
    defer difference.deinit(testing_allocator);
    _ = try difference.diff(
        testing_allocator,
        source[source_range.start_byte..source_range.end_byte],
        generated[generated_range.start..generated_range.end],
    );

    var edits: std.ArrayList(types.TextEdit) = .empty;
    defer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);
    try appendAliasRenameEditsFromDiff(
        arena,
        &edits,
        &seen_starts,
        source,
        source_range,
        generated,
        generated_range,
        difference.edits.items,
        "X",
        "Item",
        .@"utf-8",
    );

    try expectEqual(@as(usize, 1), edits.items.len);
    try expectEqualStrings("@X", lsp.offsets.rangeToSlice(source, edits.items[0].range, .@"utf-8"));
    try expectEqualStrings("@Item", edits.items[0].newText);
}

test "alias code block rename catches lhs aliases matched inside generated types" {
    const source =
        \\form(F) ::= list(L).   { F = L; // F-overwrites-L }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ (yymsp - 1)[1].minor.@"?Form" = (yymsp - 1)[1].minor.@"Form"; // F-overwrites-L
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source_range = map.src_range.items[0];
    const generated_range = map.gen_span.items[0].generated_range;
    var difference = Diff.init(.default);
    defer difference.deinit(testing_allocator);
    _ = try difference.diff(
        testing_allocator,
        source[source_range.start_byte..source_range.end_byte],
        generated[generated_range.start..generated_range.end],
    );

    var edits: std.ArrayList(types.TextEdit) = .empty;
    defer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);
    try appendAliasRenameEditsFromDiff(
        arena,
        &edits,
        &seen_starts,
        source,
        source_range,
        generated,
        generated_range,
        difference.edits.items,
        "F",
        "FormValue",
        .@"utf-8",
    );

    try expectEqual(@as(usize, 1), edits.items.len);
    try expectEqualStrings("F", lsp.offsets.rangeToSlice(source, edits.items[0].range, .@"utf-8"));
    try expectEqualStrings("FormValue", edits.items[0].newText);
    try expectEqual(
        std.mem.indexOf(u8, source, "F =").?,
        lsp.offsets.positionToIndex(source, edits.items[0].range.start, .@"utf-8"),
    );
}

test "request span translator handles generated line directive after action" {
    const source =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
        \\// #line 200 source.zig
        \\generated_only();
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(std.mem.indexOf(u8, generated, "// #line 200").?, map.gen_span.items[0].generated_range.end);

    var translator = try map.translatorForSourcePosition(
        testing_allocator,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "pik_elist_append").?, .@"utf-8"),
    ) orelse return error.UnexpectedCodeMap;
    defer translator.deinit(testing_allocator);

    try expectEqual(lsp.offsets.indexToPosition(
        generated,
        std.mem.indexOf(u8, generated, "pik_elist_append").?,
        .@"utf-8",
    ), sharedPosition(translator.sourcePositionToGenerated(lsp.offsets.indexToPosition(
        source,
        std.mem.indexOf(u8, source, "pik_elist_append").?,
        .@"utf-8",
    ))) orelse return error.UnexpectedCodeMap);
}

test "request translation context maps reference ranges in other spans" {
    const source =
        \\document ::= statement_list(X).  { pik_render(p, X); }
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ pik_render(p, yymsp[0].minor.yy0);
        \\// #line 2 source.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
        \\// #line 200 source.zig
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);

    const active = try map.translatorForSourcePosition(
        testing_allocator,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "pik_render").?, .@"utf-8"),
    ) orelse return error.UnexpectedCodeMap;

    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .source_text = source,
        .generated_text = generated,
        .active = active,
    };
    defer context.deinit();

    const generated_call = std.mem.indexOf(u8, generated, "pik_elist_append").?;
    const locations = [_]types.Location{.{
        .uri = "file:///source.zitron.zig",
        .range = .{
            .start = lsp.offsets.indexToPosition(generated, generated_call, .@"utf-8"),
            .end = lsp.offsets.indexToPosition(generated, generated_call + "pik_elist_append".len, .@"utf-8"),
        },
    }};

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = (try translateLocations(
        arena_state.allocator(),
        &locations,
        &context,
        "file:///source.zitron.zig",
        "file:///source.zy",
    )) orelse return error.UnexpectedCodeMap;

    const source_call = std.mem.indexOf(u8, source, "pik_elist_append").?;
    try expectEqual(lsp.offsets.indexToPosition(source, source_call, .@"utf-8"), translated[0].range.start);
    try expectEqual(lsp.offsets.indexToPosition(source, source_call + "pik_elist_append".len, .@"utf-8"), translated[0].range.end);
}

test "request span translator handles one leading newline edit" {
    const source = "\nconst answer = 42;";
    const generated = "const answer = 42;";
    var translator = try SpanTranslator.init(
        testing_allocator,
        .{
            .source_line = 0,
            .generated_line = 0,
            .line_count = 1,
            .generated_range = .{ .start = 0, .end = generated.len },
        },
        .{
            .start_byte = 0,
            .end_byte = @intCast(source.len),
            .start_point = .{ .row = 0, .column = 0 },
            .end_point = .{ .row = 1, .column = @intCast("const answer = 42;".len) },
        },
        source,
        generated,
    );
    defer translator.deinit(testing_allocator);

    try expectEqual(types.Position{ .line = 0, .character = 6 }, sharedPosition(translator.sourcePositionToGenerated(.{
        .line = 1,
        .character = 6,
    })) orelse return error.UnexpectedCodeMap);
    try std.testing.expect(sharedPosition(translator.sourcePositionToGenerated(.{
        .line = 0,
        .character = 0,
    })) == null);
}

test "translates hover and definition results back to source ranges" {
    const source =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const generated =
        \\// #line 2 source.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "answer").?, .@"utf-8"),
    );
    defer context.deinit();

    var hover_result = types.Hover{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = "answer" } },
        .range = .{
            .start = .{ .line = 1, .character = 6 },
            .end = .{ .line = 1, .character = 12 },
        },
    };
    try translateHover(&hover_result, &context);
    try expectEqual(types.Range{
        .start = .{ .line = 1, .character = 6 },
        .end = .{ .line = 1, .character = 12 },
    }, hover_result.range.?);

    const definition = types.Definition{ .location = .{
        .uri = "file:///source.zitron.zig",
        .range = .{
            .start = .{ .line = 1, .character = 6 },
            .end = .{ .line = 1, .character = 12 },
        },
    } };
    const translated = try translateDefinition(
        testing_allocator,
        .{ .definition = definition },
        &context,
        "file:///source.zitron.zig",
        "file:///source.zy",
    );
    switch (translated.?) {
        .definition => |translated_definition| switch (translated_definition) {
            .location => |location| {
                try expectEqualStrings("file:///source.zy", location.uri);
                try expectEqual(@as(u32, 1), location.range.start.line);
                try expectEqual(@as(u32, 6), location.range.start.character);
            },
            else => return error.UnexpectedDefinition,
        },
        else => return error.UnexpectedDefinition,
    }
}

test "translates completion edits back to source ranges" {
    const source =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const generated =
        \\// #line 2 source.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "answer").?, .@"utf-8"),
    );
    defer context.deinit();
    try expectEqual(@as(u32, 1), map.generatedPositionToSource(.{
        .line = 1,
        .character = 0,
    }).?.line);

    var items = [_]types.CompletionItem{.{
        .label = "answer",
        .textEdit = .{ .text_edit = .{
            .range = .{
                .start = .{ .line = 1, .character = 6 },
                .end = .{ .line = 1, .character = 12 },
            },
            .newText = "answer",
        } },
    }};
    var result: lsp.ResultType("textDocument/completion") = lsp.types.completion.Result{ .completion_items = &items };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    try translateCompletionResult(arena_state.allocator(), &result, &context);
    switch (result.?) {
        .completion_items => |translated| switch (translated[0].textEdit.?) {
            .text_edit => |edit| {
                try expectEqual(@as(u32, 1), edit.range.start.line);
                try expectEqual(@as(u32, 6), edit.range.start.character);
            },
            else => return error.UnexpectedCompletionEdit,
        },
        else => return error.UnexpectedCompletion,
    }
}

test "translates workspace edit changes back to source ranges" {
    const source =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const generated =
        \\// #line 2 source.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "answer").?, .@"utf-8"),
    );
    defer context.deinit();

    const generated_edits = [_]types.TextEdit{
        .{
            .range = .{
                .start = .{ .line = 1, .character = 6 },
                .end = .{ .line = 1, .character = 12 },
            },
            .newText = "solution",
        },
        .{
            .range = .{
                .start = .{ .line = 20, .character = 0 },
                .end = .{ .line = 20, .character = 6 },
            },
            .newText = "dropped",
        },
    };
    const other_edits = [_]types.TextEdit{.{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 5 },
        },
        .newText = "other",
    }};

    var changes = std.json.ArrayHashMap([]const types.TextEdit){};
    defer changes.deinit(testing_allocator);
    try changes.map.put(testing_allocator, "file:///source.zitron.zig", &generated_edits);
    try changes.map.put(testing_allocator, "file:///other.zig", &other_edits);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = (try translateWorkspaceEdit(
        arena_state.allocator(),
        .{ .changes = changes },
        &context,
        "file:///source.zitron.zig",
        "file:///source.zy",
    )) orelse return error.UnexpectedWorkspaceEdit;

    const translated_changes = translated.changes orelse return error.UnexpectedWorkspaceEdit;
    const source_edits = translated_changes.map.get("file:///source.zy") orelse return error.UnexpectedWorkspaceEdit;
    try expectEqual(@as(usize, 1), source_edits.len);
    try expectEqual(types.Range{
        .start = .{ .line = 1, .character = 6 },
        .end = .{ .line = 1, .character = 12 },
    }, source_edits[0].range);
    try expectEqualStrings("solution", source_edits[0].newText);

    const preserved_edits = translated_changes.map.get("file:///other.zig") orelse return error.UnexpectedWorkspaceEdit;
    try expectEqual(@as(usize, 1), preserved_edits.len);
    try expectEqualStrings("other", preserved_edits[0].newText);
}

test "translates document symbols and drops generated yy symbols" {
    const generated =
        \\// #line 5 source.zy
        \\pub const Token = struct {
        \\    pub fn lit() void {}
        \\};
        \\// #line 80 source.zig
        \\const generated_only = true;
        \\// #line 20 source.zy
        \\const yyFallback = 1;
    ;
    var map = try parseCodeMapForTest(generated, generated, "source.zy");
    defer map.deinit(testing_allocator);

    const children = [_]types.DocumentSymbol{
        .{
            .name = "lit",
            .kind = .Function,
            .range = .{
                .start = .{ .line = 2, .character = 4 },
                .end = .{ .line = 2, .character = 25 },
            },
            .selectionRange = .{
                .start = .{ .line = 2, .character = 11 },
                .end = .{ .line = 2, .character = 14 },
            },
        },
        .{
            .name = "YYDropMe",
            .kind = .Function,
            .range = .{
                .start = .{ .line = 7, .character = 0 },
                .end = .{ .line = 7, .character = 21 },
            },
            .selectionRange = .{
                .start = .{ .line = 7, .character = 6 },
                .end = .{ .line = 7, .character = 14 },
            },
        },
    };
    const symbols = [_]types.DocumentSymbol{
        .{
            .name = "Token",
            .kind = .Constant,
            .range = .{
                .start = .{ .line = 1, .character = 0 },
                .end = .{ .line = 3, .character = 1 },
            },
            .selectionRange = .{
                .start = .{ .line = 1, .character = 10 },
                .end = .{ .line = 1, .character = 15 },
            },
            .children = &children,
        },
        .{
            .name = "yyContainer",
            .kind = .Function,
            .range = .{
                .start = .{ .line = 1, .character = 0 },
                .end = .{ .line = 3, .character = 1 },
            },
            .selectionRange = .{
                .start = .{ .line = 1, .character = 10 },
                .end = .{ .line = 1, .character = 21 },
            },
            .children = &.{
                .{
                    .name = "keptChild",
                    .kind = .Function,
                    .range = .{
                        .start = .{ .line = 2, .character = 4 },
                        .end = .{ .line = 2, .character = 25 },
                    },
                    .selectionRange = .{
                        .start = .{ .line = 2, .character = 11 },
                        .end = .{ .line = 2, .character = 20 },
                    },
                },
            },
        },
        .{
            .name = "generated_only",
            .kind = .Constant,
            .range = .{
                .start = .{ .line = 5, .character = 0 },
                .end = .{ .line = 5, .character = 28 },
            },
            .selectionRange = .{
                .start = .{ .line = 5, .character = 6 },
                .end = .{ .line = 5, .character = 20 },
            },
        },
        .{
            .name = "yyFallback",
            .kind = .Constant,
            .range = .{
                .start = .{ .line = 7, .character = 0 },
                .end = .{ .line = 7, .character = 21 },
            },
            .selectionRange = .{
                .start = .{ .line = 7, .character = 6 },
                .end = .{ .line = 7, .character = 16 },
            },
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = (try translateDocumentSymbols(
        arena_state.allocator(),
        .{ .document_symbols = &symbols },
        &map,
    )) orelse return error.UnexpectedDocumentSymbols;
    try expectEqual(@as(usize, 2), translated.len);
    try expectEqualStrings("Token", translated[0].name);
    try expectEqual(@as(u32, 4), translated[0].range.start.line);
    try expectEqual(@as(u32, 10), translated[0].selectionRange.start.character);

    const translated_children = translated[0].children orelse return error.UnexpectedDocumentSymbols;
    try expectEqual(@as(usize, 1), translated_children.len);
    try expectEqualStrings("lit", translated_children[0].name);
    try expectEqual(@as(u32, 5), translated_children[0].range.start.line);

    try expectEqualStrings("keptChild", translated[1].name);
    try expectEqual(@as(u32, 5), translated[1].range.start.line);
}

const std = @import("std");
const diff = @import("diff.zig");
const dmp = @import("dmp");
const lsp = @import("lsp");
const types = lsp.types.flat;
const ts = @import("tree-sitter");
const zitron_grammar = @import("tree_sitter_zitron");
const Diff = dmp.Diff;
const Edit = dmp.Edit;
const JsonParseError = std.json.ParseFromValueError || error{
    BufferUnderrun,
    SyntaxError,
    UnexpectedEndOfInput,
    ValueTooLong,
};
const OOM = std.mem.Allocator.Error || error{TooManySegments};
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
