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
        MissingLineMap,
        RequestFailed,
        UnexpectedResponse,
        UnsupportedUri,
    };

const GeneratedDocument = struct {
    source_uri: []u8,
    source_path: []u8,
    generated_uri: []u8,
    generated_text: []u8,
    line_map: ?LineMap,
    generation_error: ?[]u8,
    version: i32,
    opened: bool,

    fn deinit(doc: *GeneratedDocument, allocator: std.mem.Allocator) void {
        allocator.free(doc.source_uri);
        allocator.free(doc.source_path);
        allocator.free(doc.generated_uri);
        allocator.free(doc.generated_text);
        if (doc.line_map) |*map| map.deinit(allocator);
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
) Error!void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |*mware| try mware.syncDocument(uri, version, source_text),
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
            .generated_uri = generated_uri,
            .generated_text = try middleware.allocator.alloc(u8, 0),
            .line_map = null,
            .generation_error = null,
            .version = version,
            .opened = false,
        };
    }

    const doc = gop.value_ptr;
    doc.version = version;
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

    if (doc.line_map) |*line_map| {
        try line_map.update(middleware.allocator, generated.stdout, doc.source_path);
    } else {
        doc.line_map = try LineMap.parse(middleware.allocator, generated.stdout, doc.source_path);
    }

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
    const line_map = &(doc.line_map.?);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = line_map.sourcePositionToGenerated(params.position) orelse return null;

    var result = try middleware.request(arena, "textDocument/hover", mapped);
    if (result) |*hover_result| translateHover(hover_result, line_map);
    return result;
}

fn middlewareForwardDefinition(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.DefinitionParams,
) Error!lsp.ResultType("textDocument/definition") {
    const doc = try middleware.documentReady(source_uri);
    const line_map = &(doc.line_map.?);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = line_map.sourcePositionToGenerated(params.position) orelse return null;

    const result = (try middleware.request(arena, "textDocument/definition", mapped)) orelse return null;
    return try translateDefinition(arena, result, line_map, doc.generated_uri, doc.source_uri);
}

fn middlewareForwardReferences(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.ReferenceParams,
) Error!lsp.ResultType("textDocument/references") {
    const doc = try middleware.documentReady(source_uri);
    const line_map = &(doc.line_map.?);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = line_map.sourcePositionToGenerated(params.position) orelse return null;

    const result = (try middleware.request(arena, "textDocument/references", mapped)) orelse return null;
    return try translateLocations(arena, result, line_map, doc.generated_uri, doc.source_uri);
}

fn middlewareForwardCompletion(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.CompletionParams,
) Error!lsp.ResultType("textDocument/completion") {
    const doc = try middleware.documentReady(source_uri);
    const line_map = &(doc.line_map.?);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = line_map.sourcePositionToGenerated(params.position) orelse return null;

    var result = try middleware.request(arena, "textDocument/completion", mapped);
    try translateCompletionResult(arena, &result, line_map);
    return result;
}

fn middlewareForwardDocumentSymbols(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
) Error!?[]const types.DocumentSymbol {
    const doc = try middleware.documentReady(source_uri);
    const line_map = &(doc.line_map.?);
    const result = (try middleware.request(arena, "textDocument/documentSymbol", .{
        .textDocument = .{ .uri = doc.generated_uri },
    })) orelse return null;
    return try translateDocumentSymbols(arena, result, line_map);
}

/// Bidirectional line mapping derived from Zitron `// #line` comments.
pub const LineMap = struct {
    /// Spans are stored in generated-line order, which is the order encountered
    /// while scanning the generated Zig file.
    spans: std.ArrayList(Span) = .empty,
    /// Indexes into `spans`, sorted by source-line order for source -> generated
    /// lookups. The buffer is retained across updates.
    source_order: std.ArrayList(usize) = .empty,

    // TODO: this should also retain the offsets which begin and end each
    // translated code block (we don't care about the template code, only the
    // translated code). that won't be used immediately, but we need it, and
    // this is when we're traversing the generated text, so we get it now.

    /// One contiguous translated range.  The source and generated ranges have
    /// the same length, so one object records both coordinate systems.
    const Span = struct {
        /// First zero-based line in the original `.zy` document.
        source_line: u32,
        /// First zero-based line in the generated Zig document.
        generated_line: u32,
        /// Number of contiguous mapped lines shared by both coordinate systems.
        line_count: u32,

        /// Exclusive source-line end.  Keeping this as a helper avoids repeating
        /// the half-open interval convention at every lookup site.
        fn sourceEnd(span: Span) u32 {
            return span.source_line + span.line_count;
        }

        /// Exclusive generated-line end, matching `sourceEnd` in length.
        fn generatedEnd(span: Span) u32 {
            return span.generated_line + span.line_count;
        }

        /// Compares a source line against this half-open span.
        fn orderSource(span: Span, line: u32) std.math.Order {
            if (line < span.source_line) return .lt;
            if (line < span.sourceEnd()) return .eq;
            return .gt;
        }

        /// Compares a generated line against this half-open span.
        fn orderGenerated(span: Span, line: u32) std.math.Order {
            if (line < span.generated_line) return .lt;
            if (line < span.generatedEnd()) return .eq;
            return .gt;
        }
    };

    /// Parses generated Zig into an initial map by delegating to `update`, so the
    /// initial build and incremental rebuild use the same span coalescing rules.
    pub fn parse(allocator: std.mem.Allocator, generated_text: []const u8, source_path: []const u8) OOM!LineMap {
        var map: LineMap = .{};
        errdefer map.deinit(allocator);
        try map.update(allocator, generated_text, source_path);
        return map;
    }

    /// Rebuilds this map from freshly generated Zig while retaining the backing
    /// allocations. The number of spans should usually stay stable, so this avoids
    /// churn without carrying incremental tree state.
    pub fn update(map: *LineMap, allocator: std.mem.Allocator, generated_text: []const u8, source_path: []const u8) OOM!void {
        map.spans.clearRetainingCapacity();
        map.source_order.clearRetainingCapacity();

        try map.collectSpans(allocator, generated_text, source_path);
        try map.rebuildSourceOrder(allocator);
    }

    /// Frees the reusable span and index buffers.
    pub fn deinit(map: *LineMap, allocator: std.mem.Allocator) void {
        map.spans.deinit(allocator);
        map.source_order.deinit(allocator);
        map.* = .{};
    }

    /// Translates a source position to generated coordinates by finding the
    /// earliest span that contains the source line and preserving the column.
    pub fn sourcePositionToGenerated(map: *const LineMap, position: types.Position) ?types.Position {
        const span = map.findSource(position.line) orelse return null;
        return .{
            .line = span.generated_line + (position.line - span.source_line),
            .character = position.character,
        };
    }

    /// Translates a generated position back to source coordinates by finding the
    /// generated-order span containing the generated line and preserving column.
    pub fn generatedPositionToSource(map: *const LineMap, position: types.Position) ?types.Position {
        const span = map.findGenerated(position.line) orelse return null;
        return .{
            .line = span.source_line + (position.line - span.generated_line),
            .character = position.character,
        };
    }

    /// Translates a generated range only when every generated line in the range is
    /// covered by adjacent mapped spans.  Gaps represent template/generated-only
    /// Zig and cannot be reported as a source range.
    pub fn generatedRangeToSource(map: *const LineMap, range: types.Range) ?types.Range {
        var index = map.findGeneratedIndex(range.start.line) orelse return null;
        while (map.spans.items[index].orderGenerated(range.end.line) != .eq) {
            const next_index = index + 1;
            if (next_index >= map.spans.items.len) return null;
            if (map.spans.items[next_index].generated_line != map.spans.items[index].generatedEnd()) return null;
            index = next_index;
        }

        return .{
            .start = map.generatedPositionToSource(range.start).?,
            .end = map.generatedPositionToSource(range.end).?,
        };
    }

    /// Scans generated text for `#line` comments and coalesces consecutive mapped
    /// lines into generated-order spans.
    fn collectSpans(map: *LineMap, allocator: std.mem.Allocator, generated_text: []const u8, source_path: []const u8) OOM!void {
        var generated_line: u32 = 0;
        var active_source_line: ?u32 = null;
        var active_span: ?Span = null;
        var lines = std.mem.splitScalar(u8, generated_text, '\n');
        while (lines.next()) |line| : (generated_line += 1) {
            if (parseLineDirective(line)) |directive| {
                if (active_span) |span| try map.spans.append(allocator, span);
                active_span = null;
                active_source_line = if (std.mem.eql(u8, directive.path, source_path))
                    directive.line
                else
                    null;
                continue;
            }

            const source_line = active_source_line orelse {
                if (active_span) |span| try map.spans.append(allocator, span);
                active_span = null;
                continue;
            };

            if (active_span) |*span| {
                if (span.sourceEnd() == source_line and span.generatedEnd() == generated_line) {
                    span.line_count += 1;
                } else {
                    try map.spans.append(allocator, span.*);
                    active_span = .{
                        .source_line = source_line,
                        .generated_line = generated_line,
                        .line_count = 1,
                    };
                }
            } else {
                active_span = .{
                    .source_line = source_line,
                    .generated_line = generated_line,
                    .line_count = 1,
                };
            }
            active_source_line = source_line + 1;
        }

        if (active_span) |span| try map.spans.append(allocator, span);
    }

    /// Rebuilds the source-order index over the current span buffer.
    fn rebuildSourceOrder(map: *LineMap, allocator: std.mem.Allocator) OOM!void {
        try map.source_order.ensureTotalCapacity(allocator, map.spans.items.len);
        for (0..map.spans.items.len) |index| {
            try map.source_order.append(allocator, index);
        }
        std.mem.sort(usize, map.source_order.items, map.spans.items, sourceIndexLessThan);
    }

    /// Returns the number of spans in the map.  Tests use this to assert
    /// that multi-line ranges stay coalesced instead of becoming per-line nodes.
    fn len(map: *const LineMap) usize {
        return map.spans.items.len;
    }

    /// Finds a generated-order span containing a generated line.
    fn findGenerated(map: *const LineMap, line: u32) ?Span {
        const index = map.findGeneratedIndex(line) orelse return null;
        return map.spans.items[index];
    }

    /// Finds the index of a generated-order span containing a generated line.
    fn findGeneratedIndex(map: *const LineMap, line: u32) ?usize {
        var low: usize = 0;
        var high: usize = map.spans.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (map.spans.items[mid].orderGenerated(line)) {
                .lt => high = mid,
                .eq => return mid,
                .gt => low = mid + 1,
            }
        }

        return null;
    }

    /// Finds the earliest generated span containing a source line.
    fn findSource(map: *const LineMap, line: u32) ?Span {
        const index = map.findSourceIndex(line) orelse return null;
        return map.spans.items[map.source_order.items[index]];
    }

    fn spanInSourceOrder(map: *const LineMap, index: usize) Span {
        return map.spans.items[map.source_order.items[index]];
    }

    /// Finds the source-order index of the earliest generated span containing a
    /// source line.
    fn findSourceIndex(map: *const LineMap, line: u32) ?usize {
        var low: usize = 0;
        var high: usize = map.source_order.items.len;
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
    /// generated tie-breaker makes duplicate source lines choose the earliest
    /// generated mapping.
    fn sourceIndexLessThan(spans: []const Span, lhs_index: usize, rhs_index: usize) bool {
        const lhs = spans[lhs_index];
        const rhs = spans[rhs_index];
        if (lhs.source_line != rhs.source_line) return lhs.source_line < rhs.source_line;
        if (lhs.generated_line != rhs.generated_line) return lhs.generated_line < rhs.generated_line;
        return lhs_index < rhs_index;
    }
};

/// Parsed form of a generated `// #line N path` marker.  Zitron emits these
/// markers as the only bridge between generated Zig and original Zitron source.
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

pub fn translateHover(hover_result: *types.Hover, map: *const LineMap) void {
    if (hover_result.range) |range| {
        hover_result.range = map.generatedRangeToSource(range);
    }
}

pub fn translateDefinition(
    arena: std.mem.Allocator,
    definition_result: lsp.types.Definition.Result,
    map: *const LineMap,
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
                if (translateDefinitionLink(link, map, generated_uri, source_uri)) |mapped| {
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
    map: *const LineMap,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?types.Definition {
    return switch (definition_result) {
        .location => |location| if (translateLocation(location, map, generated_uri, source_uri)) |translated|
            .{ .location = translated }
        else
            null,
        .locations => |locations| blk: {
            var translated: std.ArrayList(types.Location) = .empty;
            for (locations) |location| {
                if (translateLocation(location, map, generated_uri, source_uri)) |mapped| {
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
    map: *const LineMap,
    generated_uri: []const u8,
    source_uri: []const u8,
) ?types.DefinitionLink {
    if (!std.mem.eql(u8, link.targetUri, generated_uri)) return link;
    return .{
        .originSelectionRange = if (link.originSelectionRange) |range| map.generatedRangeToSource(range) else null,
        .targetUri = source_uri,
        .targetRange = map.generatedRangeToSource(link.targetRange) orelse return null,
        .targetSelectionRange = map.generatedRangeToSource(link.targetSelectionRange) orelse return null,
    };
}

pub fn translateLocations(
    arena: std.mem.Allocator,
    locations: []const types.Location,
    map: *const LineMap,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?[]const types.Location {
    var translated: std.ArrayList(types.Location) = .empty;
    for (locations) |location| {
        if (translateLocation(location, map, generated_uri, source_uri)) |mapped| {
            try translated.append(arena, mapped);
        }
    }

    return if (translated.items.len == 0) null else try translated.toOwnedSlice(arena);
}

pub fn translateCompletionResult(
    arena: std.mem.Allocator,
    result: *lsp.ResultType("textDocument/completion"),
    map: *const LineMap,
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
                    edit_range.* = translateCompletionDefaultEditRange(edit_range.*, map) orelse return;
                }
            }
            result.* = .{ .completion_list = translated_list };
        },
    }
}

pub fn translateDocumentSymbols(
    arena: std.mem.Allocator,
    result: lsp.types.DocumentSymbol.Result,
    map: *const LineMap,
) OOM!?[]const types.DocumentSymbol {
    return switch (result) {
        .document_symbols => |symbols| translateDocumentSymbolSlice(arena, symbols, map),
        .symbol_informations => null,
    };
}

fn translateLocation(location: types.Location, map: *const LineMap, generated_uri: []const u8, source_uri: []const u8) ?types.Location {
    if (!std.mem.eql(u8, location.uri, generated_uri)) return location;
    return .{
        .uri = source_uri,
        .range = map.generatedRangeToSource(location.range) orelse return null,
    };
}

fn translateDocumentSymbolSlice(
    arena: std.mem.Allocator,
    symbols: []const types.DocumentSymbol,
    map: *const LineMap,
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
    map: *const LineMap,
) OOM!?types.DocumentSymbol {
    return .{
        .name = symbol.name,
        .detail = symbol.detail,
        .kind = symbol.kind,
        .tags = symbol.tags,
        .deprecated = symbol.deprecated,
        .range = map.generatedRangeToSource(symbol.range) orelse return null,
        .selectionRange = map.generatedRangeToSource(symbol.selectionRange) orelse return null,
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
    map: *const LineMap,
) OOM![]const types.CompletionItem {
    const items = try arena.dupe(types.CompletionItem, items_const);
    for (items) |*item| {
        if (item.textEdit) |text_edit| {
            item.textEdit = translateCompletionTextEdit(text_edit, map) orelse {
                item.textEdit = null;
                continue;
            };
        }

        if (item.additionalTextEdits) |edits| {
            var translated_edits: std.ArrayList(types.TextEdit) = .empty;
            for (edits) |edit| {
                if (translateTextEdit(edit, map)) |translated_edit| {
                    try translated_edits.append(arena, translated_edit);
                }
            }
            item.additionalTextEdits = try translated_edits.toOwnedSlice(arena);
        }
    }

    return items;
}

fn translateCompletionTextEdit(text_edit: types.CompletionItem.TextEdit, map: *const LineMap) ?types.CompletionItem.TextEdit {
    return switch (text_edit) {
        .text_edit => |edit| .{ .text_edit = translateTextEdit(edit, map) orelse return null },
        .insert_replace_edit => |edit| .{ .insert_replace_edit = .{
            .newText = edit.newText,
            .insert = map.generatedRangeToSource(edit.insert) orelse return null,
            .replace = map.generatedRangeToSource(edit.replace) orelse return null,
        } },
    };
}

fn translateCompletionDefaultEditRange(
    edit_range: lsp.types.ClientCapabilities.TextDocument.Completion.EditRange,
    map: *const LineMap,
) ?lsp.types.ClientCapabilities.TextDocument.Completion.EditRange {
    return switch (edit_range) {
        .range => |range| .{ .range = map.generatedRangeToSource(range) orelse return null },
        .edit_range_with_insert_replace => |ranges| .{ .edit_range_with_insert_replace = .{
            .insert = map.generatedRangeToSource(ranges.insert) orelse return null,
            .replace = map.generatedRangeToSource(ranges.replace) orelse return null,
        } },
    };
}

fn translateTextEdit(edit: types.TextEdit, map: *const LineMap) ?types.TextEdit {
    return .{
        .range = map.generatedRangeToSource(edit.range) orelse return null,
        .newText = edit.newText,
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
    if (doc.line_map == null) return error.MissingLineMap;
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

test "line map translates source and generated positions" {
    const generated =
        \\const std = @import("std");
        \\// #line 10 samples/calc.zy
        \\ answer = A;
        \\// #line 50 samples/calc.zig
        \\const generated_only = true;
        \\// #line 11 samples/calc.zy
        \\ next = answer;
    ;

    var map = try LineMap.parse(testing_allocator, generated, "samples/calc.zy");
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

test "line map translates only fully mapped generated ranges" {
    const generated =
        \\// #line 20 source.zy
        \\const a = 1;
        \\const b = 2;
        \\// #line 40 source.zig
        \\const generated_only = true;
    ;

    var map = try LineMap.parse(testing_allocator, generated, "source.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Range{
        .start = .{ .line = 19, .character = 2 },
        .end = .{ .line = 20, .character = 7 },
    }, map.generatedRangeToSource(.{
        .start = .{ .line = 1, .character = 2 },
        .end = .{ .line = 2, .character = 7 },
    }).?);

    try expectEqual(@as(?types.Range, null), map.generatedRangeToSource(.{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    }));
}

test "line map stores one span for a multi-line mapped range" {
    const generated =
        \\// #line 20 source.zy
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ;

    var map = try LineMap.parse(testing_allocator, generated, "source.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(@as(u32, 3), map.spans.items[0].line_count);
    try expectEqual(types.Position{ .line = 21, .character = 9 }, map.generatedPositionToSource(.{
        .line = 3,
        .character = 9,
    }).?);
}

test "line map update reuses allocation and applies changed spans" {
    const original =
        \\// #line 10 source.zy
        \\const a = 1;
        \\const b = 2;
        \\// #line 20 source.zy
        \\const c = 3;
        \\// #line 30 source.zy
        \\const d = 4;
    ;

    var map = try LineMap.parse(testing_allocator, original, "source.zy");
    defer map.deinit(testing_allocator);

    const spans_capacity = map.spans.capacity;
    const source_order_capacity = map.source_order.capacity;

    try map.update(testing_allocator, original, "source.zy");
    try expectEqual(spans_capacity, map.spans.capacity);
    try expectEqual(source_order_capacity, map.source_order.capacity);

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
    try map.update(testing_allocator, shifted, "source.zy");

    try expectEqual(spans_capacity, map.spans.capacity);
    try expectEqual(source_order_capacity, map.source_order.capacity);
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

test "line map update retains capacity after growing and shrinking" {
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

    var map = try LineMap.parse(testing_allocator, one_span, "source.zy");
    defer map.deinit(testing_allocator);

    try map.update(testing_allocator, two_spans, "source.zy");
    try expectEqual(@as(usize, 2), map.len());
    const grown_spans_capacity = map.spans.capacity;
    const grown_source_order_capacity = map.source_order.capacity;

    try map.update(testing_allocator, one_span, "source.zy");
    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(grown_spans_capacity, map.spans.capacity);
    try expectEqual(grown_source_order_capacity, map.source_order.capacity);
}

test "line map source lookup chooses the earliest generated duplicate" {
    const generated =
        \\// #line 5 source.zy
        \\const first = 1;
        \\// #line 5 source.zy
        \\const second = 2;
    ;

    var map = try LineMap.parse(testing_allocator, generated, "source.zy");
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

test "translates hover and definition results back to source ranges" {
    const generated =
        \\// #line 5 source.zy
        \\const answer = 42;
    ;
    var map = try LineMap.parse(testing_allocator, generated, "source.zy");
    defer map.deinit(testing_allocator);

    var hover_result = types.Hover{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = "answer" } },
        .range = .{
            .start = .{ .line = 1, .character = 6 },
            .end = .{ .line = 1, .character = 12 },
        },
    };
    translateHover(&hover_result, &map);
    try expectEqual(types.Range{
        .start = .{ .line = 4, .character = 6 },
        .end = .{ .line = 4, .character = 12 },
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
        &map,
        "file:///source.zitron.zig",
        "file:///source.zy",
    );
    switch (translated.?) {
        .definition => |translated_definition| switch (translated_definition) {
            .location => |location| {
                try expectEqualStrings("file:///source.zy", location.uri);
                try expectEqual(@as(u32, 4), location.range.start.line);
                try expectEqual(@as(u32, 6), location.range.start.character);
            },
            else => return error.UnexpectedDefinition,
        },
        else => return error.UnexpectedDefinition,
    }
}

test "translates completion edits back to source ranges" {
    const generated =
        \\// #line 5 source.zy
        \\const answer = 42;
    ;
    var map = try LineMap.parse(testing_allocator, generated, "source.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(@as(u32, 4), map.generatedPositionToSource(.{
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

    try translateCompletionResult(arena_state.allocator(), &result, &map);
    switch (result.?) {
        .completion_items => |translated| switch (translated[0].textEdit.?) {
            .text_edit => |edit| {
                try expectEqual(@as(u32, 4), edit.range.start.line);
                try expectEqual(@as(u32, 6), edit.range.start.character);
            },
            else => return error.UnexpectedCompletionEdit,
        },
        else => return error.UnexpectedCompletion,
    }
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
    var map = try LineMap.parse(testing_allocator, generated, "source.zy");
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
const lsp = @import("lsp");
const types = lsp.types.flat;
const JsonParseError = std.json.ParseFromValueError || error{
    BufferUnderrun,
    SyntaxError,
    UnexpectedEndOfInput,
    ValueTooLong,
};
const OOM = std.mem.Allocator.Error;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
