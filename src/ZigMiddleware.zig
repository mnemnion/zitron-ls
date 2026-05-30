//! Zig middleware for generated Zitron parser code.

mode: Mode,

const ZigMiddleware = @This();

const Mode = union(enum) {
    disabled,
    enabled: *Middleware,
};

const DiagnosticsPublisher = *const fn (context: *anyopaque, source_uri: []const u8, version: i32) void;

const Middleware = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    zls_child: std.process.Child,
    zls_transport: lsp.Transport.Stdio,
    zls_read_buffer: []u8,
    reader_thread: ?std.Thread,
    response_mutex: std.Io.Mutex,
    response_cond: std.Io.Condition,
    pending_responses: std.AutoHashMapUnmanaged(i64, PendingResponse),
    reader_failed: bool,
    diagnostics_context: ?*anyopaque,
    diagnostics_publisher: ?DiagnosticsPublisher,
    documents_mutex: std.Io.Mutex,
    documents: std.StringHashMapUnmanaged(DocumentState),
    zls_completion_triggers: []const []const u8,
    next_generation_id: usize,
    next_request_id: i64,

    const deinit = middlewareDeinit;
    const syncDocument = middlewareSyncDocument;
    const closeDocument = middlewareCloseDocument;
    const publishGeneration = middlewarePublishGeneration;
    const forwardHover = middlewareForwardHover;
    const forwardDefinition = middlewareForwardDefinition;
    const forwardReferences = middlewareForwardReferences;
    const forwardCompletion = middlewareForwardCompletion;
    const forwardInlayHint = middlewareForwardInlayHint;
    const forwardDocumentSymbols = middlewareForwardDocumentSymbols;
    const forwardRename = middlewareForwardRename;
    const aliasCodeBlockRenameEdits = middlewareAliasCodeBlockRenameEdits;
    const initializeZls = middlewareInitializeZls;
    const shutdownZls = middlewareShutdownZls;
    const request = middlewareRequest;
    const waitResponseForId = middlewareWaitResponseForId;
    const nextRequestId = middlewareNextRequestId;
    const documentReady = middlewareDocumentReady;
    const documentForGeneratedUri = middlewareDocumentForGeneratedUri;
    const handleZlsDiagnostics = middlewareHandleZlsDiagnostics;
    const readerMain = middlewareReaderMain;
    const handleZlsMessage = middlewareHandleZlsMessage;
};

const PendingResponse = struct {
    response: ?[]u8 = null,
};

const PublishedDiagnostics = struct {
    source_uri: []u8,
    version: i32,
};

pub const Error =
    OOM ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    std.process.RunError ||
    std.Thread.SpawnError ||
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
    generation_id: usize = 0,
    source_uri: []u8,
    source_path: []u8,
    source_text: []const u8,
    generated_uri: []u8,
    generated_text: []u8,
    code_map: CodeMap,
    generation_error: ?[]u8,
    grammar_diagnostics: []types.Diagnostic,
    zls_diagnostics: []types.Diagnostic,
    zls_diagnostics_version: ?i32,
    version: i32,
    opened: bool,

    fn deinit(doc: *GeneratedDocument, allocator: std.mem.Allocator) void {
        allocator.free(doc.source_uri);
        allocator.free(doc.source_path);
        allocator.free(doc.source_text);
        allocator.free(doc.generated_uri);
        allocator.free(doc.generated_text);
        doc.code_map.deinit(allocator);
        if (doc.generation_error) |message| allocator.free(message);
        freeStoredDiagnostics(allocator, doc.grammar_diagnostics);
        freeStoredDiagnostics(allocator, doc.zls_diagnostics);
    }
};

const DocumentState = struct {
    current: ?GeneratedDocument,
    latest_requested_version: i32,
    in_flight_version: ?i32,
    opened: bool,
    zls_sync_count: usize,

    fn currentGeneration(state: *DocumentState) ?*GeneratedDocument {
        return &(state.current orelse return null);
    }

    fn currentForVersion(state: *DocumentState, version: ?i32) ?*GeneratedDocument {
        const current = state.currentGeneration() orelse return null;
        if (version) |value| {
            if (current.version != value) return null;
        } else {
            if (state.in_flight_version != null) return null;
            if (state.zls_sync_count != 1) return null;
        }
        return current;
    }

    fn publishIfCurrent(
        state: *DocumentState,
        allocator: std.mem.Allocator,
        generation: GeneratedDocument,
    ) bool {
        if (generation.version != state.latest_requested_version) {
            var stale = generation;
            stale.deinit(allocator);
            return false;
        }
        if (state.current) |*old| old.deinit(allocator);
        state.current = generation;
        state.in_flight_version = null;
        return true;
    }

    fn deinit(state: *DocumentState, allocator: std.mem.Allocator) void {
        if (state.current) |*current| current.deinit(allocator);
    }
};

pub fn disabled() ZigMiddleware {
    return .{ .mode = .disabled };
}

pub fn init(io: std.Io, allocator: std.mem.Allocator) Error!ZigMiddleware {
    return initImpl(io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn("Zig middleware disabled: {}", .{err});
            return disabled();
        },
    };
}

fn initImpl(io: std.Io, allocator: std.mem.Allocator) Error!ZigMiddleware {
    log.info("Starting ZLS middleware", .{});
    try checkZitron(allocator, io);

    const read_buffer = try allocator.alloc(u8, 4096);
    errdefer allocator.free(read_buffer);

    var child = try std.process.spawn(io, .{
        .argv = &.{"zls"},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const mware = allocator.create(Middleware) catch |err| {
        child.kill(io);
        return err;
    };
    errdefer allocator.destroy(mware);
    mware.* = .{
        .allocator = allocator,
        .io = io,
        .zls_child = child,
        .zls_transport = lsp.Transport.Stdio.init(read_buffer, child.stdout.?, child.stdin.?),
        .zls_read_buffer = read_buffer,
        .reader_thread = null,
        .response_mutex = .init,
        .response_cond = .init,
        .pending_responses = .empty,
        .reader_failed = false,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
        .next_request_id = 1,
    };
    errdefer mware.deinit();

    mware.reader_thread = try std.Thread.spawn(.{}, Middleware.readerMain, .{mware});
    try mware.initializeZls();
    log.info("ZLS middleware enabled", .{});
    return .{ .mode = .{ .enabled = mware } };
}

pub fn deinit(middleware: *ZigMiddleware) void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |mware| {
            mware.deinit();
            mware.allocator.destroy(mware);
        },
    }
}

pub fn completionTriggerCharacters(middleware: *const ZigMiddleware) ?[]const []const u8 {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.zls_completion_triggers,
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
        .enabled => |mware| try mware.syncDocument(uri, version, source_text, source_root),
    }
}

pub fn closeDocument(middleware: *ZigMiddleware, uri: []const u8) void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |mware| mware.closeDocument(uri),
    }
}

pub fn appendDiagnostics(
    middleware: *ZigMiddleware,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(types.Diagnostic),
    uri: []const u8,
) OOM!void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |mware| {
            mware.documents_mutex.lockUncancelable(mware.io);
            defer mware.documents_mutex.unlock(mware.io);
            const state = mware.documents.getPtr(uri) orelse return;
            const generation = state.current orelse return;
            try diagnostics.appendSlice(allocator, generation.grammar_diagnostics);
            if (generation.zls_diagnostics_version == generation.version) {
                try diagnostics.appendSlice(allocator, generation.zls_diagnostics);
            }
        },
    }
}

pub fn setDiagnosticsPublisher(
    middleware: *ZigMiddleware,
    context: *anyopaque,
    publisher: DiagnosticsPublisher,
) void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |mware| {
            mware.diagnostics_context = context;
            mware.diagnostics_publisher = publisher;
        },
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
        .enabled => |mware| mware.forwardHover(arena, source_uri, params) catch |err| {
            try suppressForwardRequestFailure("hover", source_uri, err);
            return null;
        },
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
        .enabled => |mware| mware.forwardDefinition(arena, source_uri, params) catch |err| {
            try suppressForwardRequestFailure("definition", source_uri, err);
            return null;
        },
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
        .enabled => |mware| mware.forwardReferences(arena, source_uri, params) catch |err| {
            try suppressForwardRequestFailure("references", source_uri, err);
            return null;
        },
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
        .enabled => |mware| mware.forwardCompletion(arena, source_uri, params) catch |err| {
            try suppressForwardRequestFailure("completion", source_uri, err);
            return null;
        },
    };
}

pub fn forwardInlayHint(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.InlayHintParams,
) Error!lsp.ResultType("textDocument/inlayHint") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardInlayHint(arena, source_uri, params) catch |err| {
            try suppressForwardRequestFailure("inlayHint", source_uri, err);
            return null;
        },
    };
}

pub fn forwardDocumentSymbols(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
) Error!?[]const types.DocumentSymbol {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardDocumentSymbols(arena, source_uri) catch |err| {
            try suppressForwardRequestFailure("documentSymbol", source_uri, err);
            return null;
        },
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
        .enabled => |mware| mware.forwardRename(arena, source_uri, params) catch |err| {
            try suppressForwardRequestFailure("rename", source_uri, err);
            return null;
        },
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
        .enabled => |mware| mware.aliasCodeBlockRenameEdits(
            arena,
            source_uri,
            alias_name,
            new_name,
            source_ranges,
            offset_encoding,
        ) catch |err| {
            try suppressForwardRequestFailure("aliasRename", source_uri, err);
            return null;
        },
    };
}

fn suppressForwardRequestFailure(comptime operation: []const u8, source_uri: []const u8, err: Error) Error!void {
    switch (err) {
        error.RequestFailed => log.debug("Zig forward {s} -> uri={s} result=null reason=request_failed", .{
            operation,
            source_uri,
        }),
        else => return err,
    }
}

fn middlewareDeinit(middleware: *Middleware) void {
    freeStringSlices(middleware.allocator, middleware.zls_completion_triggers);
    middleware.shutdownZls() catch |err| {
        log.warn("ZLS shutdown failed: {}", .{err});
        middleware.zls_child.kill(middleware.io);
    };
    if (middleware.reader_thread) |thread| {
        thread.join();
        middleware.reader_thread = null;
    }

    middleware.documents_mutex.lockUncancelable(middleware.io);
    defer middleware.documents_mutex.unlock(middleware.io);
    var it = middleware.documents.iterator();
    while (it.next()) |entry| {
        middleware.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(middleware.allocator);
    }
    middleware.documents.deinit(middleware.allocator);

    var pending_it = middleware.pending_responses.iterator();
    while (pending_it.next()) |entry| {
        if (entry.value_ptr.response) |response| middleware.allocator.free(response);
    }
    middleware.pending_responses.deinit(middleware.allocator);
    middleware.allocator.free(middleware.zls_read_buffer);
}

fn middlewareSyncDocument(
    middleware: *Middleware,
    uri: []const u8,
    version: i32,
    source_text: []const u8,
    source_root: ts.Node,
) Error!void {
    const start = logStart(middleware.io);
    log.debug("Zig sync <- uri={s} version={} source_bytes={}", .{ uri, version, source_text.len });

    const generation_id = blk: {
        middleware.documents_mutex.lockUncancelable(middleware.io);
        defer middleware.documents_mutex.unlock(middleware.io);

        const gop = try middleware.documents.getOrPut(middleware.allocator, uri);
        if (!gop.found_existing) {
            errdefer _ = middleware.documents.remove(uri);
            gop.key_ptr.* = try middleware.allocator.dupe(u8, uri);
            errdefer middleware.allocator.free(gop.key_ptr.*);
            gop.value_ptr.* = .{
                .current = null,
                .latest_requested_version = version,
                .in_flight_version = version,
                .opened = false,
                .zls_sync_count = 0,
            };
            log.debug("Zig sync doc-created uri={s}", .{uri});
        } else {
            gop.value_ptr.latest_requested_version = version;
            gop.value_ptr.in_flight_version = version;
        }

        const id = middleware.next_generation_id;
        middleware.next_generation_id += 1;
        break :blk id;
    };

    var source_path = try filePathFromUri(middleware.allocator, uri);
    errdefer if (source_path.len != 0) middleware.allocator.free(source_path);
    var generated_uri = try generatedUriForSourceUri(middleware.allocator, uri);
    errdefer if (generated_uri.len != 0) middleware.allocator.free(generated_uri);
    var owned_source_text = try middleware.allocator.dupe(u8, source_text);
    errdefer if (owned_source_text.len != 0) middleware.allocator.free(owned_source_text);

    const generation_start = logStart(middleware.io);
    const generated = runZitron(middleware.allocator, middleware.io, source_path, source_text) catch |err| {
        log.warn("Zitron generation failed for '{s}': {}", .{ source_path, err });
        const generation_error = try middleware.allocator.dupe(u8, @errorName(err));
        errdefer middleware.allocator.free(generation_error);
        const empty_generated = try middleware.allocator.alloc(u8, 0);
        errdefer middleware.allocator.free(empty_generated);
        var generation = GeneratedDocument{
            .generation_id = generation_id,
            .source_uri = try middleware.allocator.dupe(u8, uri),
            .source_path = source_path,
            .source_text = owned_source_text,
            .generated_uri = generated_uri,
            .generated_text = empty_generated,
            .code_map = .{},
            .generation_error = generation_error,
            .grammar_diagnostics = &.{},
            .zls_diagnostics = &.{},
            .zls_diagnostics_version = null,
            .version = version,
            .opened = false,
        };
        source_path = &.{};
        generated_uri = &.{};
        owned_source_text = &.{};
        errdefer generation.deinit(middleware.allocator);
        try middleware.publishGeneration(uri, &generation, start);
        return;
    };
    defer middleware.allocator.free(generated.stderr);

    var grammar_diagnostics = try parseZitronDiagnostics(middleware.allocator, generated.stderr);
    errdefer if (grammar_diagnostics.len != 0) freeStoredDiagnostics(middleware.allocator, grammar_diagnostics);

    var generation_error: ?[]u8 = null;
    errdefer if (generation_error) |message| middleware.allocator.free(message);
    var generated_text: []u8 = undefined;
    var generated_text_needs_free = false;
    errdefer if (generated_text_needs_free) middleware.allocator.free(generated_text);
    var code_map: CodeMap = .{};
    var code_map_needs_deinit = true;
    errdefer if (code_map_needs_deinit) code_map.deinit(middleware.allocator);

    if (zitronOutputFailedWithoutStdout(generated.term, generated.stdout.len)) {
        log.warn("Zitron generation exited unsuccessfully for '{s}': {s}", .{ source_path, generated.stderr });
        middleware.allocator.free(generated.stdout);
        generated_text = try middleware.allocator.alloc(u8, 0);
        generation_error = try middleware.allocator.dupe(u8, generated.stderr);
    } else {
        generated_text = generated.stdout;
        generated_text_needs_free = true;
        if (zitronTermFailed(generated.term)) {
            log.debug("Zitron generation exited with errors for '{s}' but produced stdout; publishing generated text: {s}", .{
                source_path,
                generated.stderr,
            });
        }
        log.debug("Zig sync generated uri={s} generated_bytes={} stderr_bytes={} elapsed_ns={}", .{
            uri,
            generated_text.len,
            generated.stderr.len,
            elapsedNs(middleware.io, generation_start),
        });
        try code_map.update(middleware.allocator, source_root, generated_text, source_path);
        log.debug("Zig sync code-map uri={s} spans={}", .{ uri, code_map.len() });
    }

    var generation = GeneratedDocument{
        .generation_id = generation_id,
        .source_uri = try middleware.allocator.dupe(u8, uri),
        .source_path = source_path,
        .source_text = owned_source_text,
        .generated_uri = generated_uri,
        .generated_text = generated_text,
        .code_map = code_map,
        .generation_error = generation_error,
        .grammar_diagnostics = grammar_diagnostics,
        .zls_diagnostics = &.{},
        .zls_diagnostics_version = null,
        .version = version,
        .opened = false,
    };
    source_path = &.{};
    generated_uri = &.{};
    owned_source_text = &.{};
    grammar_diagnostics = &.{};
    generation_error = null;
    generated_text_needs_free = false;
    code_map_needs_deinit = false;
    errdefer generation.deinit(middleware.allocator);
    try middleware.publishGeneration(uri, &generation, start);
}

fn middlewarePublishGeneration(
    middleware: *Middleware,
    uri: []const u8,
    generation: *GeneratedDocument,
    start: std.Io.Timestamp,
) Error!void {
    var text_changes: ?diff.TextChanges = null;
    defer if (text_changes) |*changes| changes.deinit(middleware.allocator);
    var notify_kind: enum { none, open, change } = .none;
    var notify_uri: []const u8 = &.{};
    var notify_version: i32 = 0;
    var notify_text: []const u8 = &.{};
    var notify_generated_bytes: usize = 0;
    var log_version: i32 = 0;
    var log_opened = false;
    var log_generated_bytes: usize = 0;
    var log_span_count: usize = 0;

    {
        middleware.documents_mutex.lockUncancelable(middleware.io);
        defer middleware.documents_mutex.unlock(middleware.io);

        const state = middleware.documents.getPtr(uri) orelse {
            log.debug("Zig sync stale generation dropped uri={s} version={} reason=closed", .{ uri, generation.version });
            generation.deinit(middleware.allocator);
            generation.* = undefined;
            return;
        };
        if (generation.version != state.latest_requested_version) {
            log.debug("Zig sync stale generation dropped uri={s} version={} latest={}", .{
                uri,
                generation.version,
                state.latest_requested_version,
            });
            generation.deinit(middleware.allocator);
            generation.* = undefined;
            return;
        }

        const send_to_zls = generation.generation_error == null;
        if (send_to_zls and state.opened) {
            const current = state.current orelse return error.MissingGeneratedDocument;
            text_changes = try diff.textChanges(middleware.allocator, current.generated_text, generation.generated_text, .@"utf-8");
        }

        if (send_to_zls) {
            notify_uri = generation.generated_uri;
            notify_version = generation.version;
            notify_generated_bytes = generation.generated_text.len;
            if (state.opened) {
                const changes = text_changes orelse return error.MissingGeneratedDocument;
                if (changes.items.len != 0) {
                    notify_kind = .change;
                    state.zls_sync_count += 1;
                } else {
                    log.debug("ZLS skip textDocument/didChange uri={s} version={} changes=0", .{
                        generation.generated_uri,
                        generation.version,
                    });
                }
            } else {
                notify_kind = .open;
                notify_text = generation.generated_text;
                state.opened = true;
                state.zls_sync_count += 1;
            }
        }

        if (state.current) |*old| old.deinit(middleware.allocator);
        state.current = generation.*;
        state.in_flight_version = null;
        generation.* = undefined;
        const doc = state.currentForVersion(state.latest_requested_version) orelse return error.MissingGeneratedDocument;
        log_version = doc.version;
        log_opened = state.opened;
        log_generated_bytes = doc.generated_text.len;
        log_span_count = doc.code_map.len();
    }

    switch (notify_kind) {
        .none => {},
        .change => {
            const changes = text_changes orelse return error.MissingGeneratedDocument;
            log.debug("ZLS <- textDocument/didChange uri={s} version={} changes={} generated_bytes={}", .{
                notify_uri,
                notify_version,
                changes.items.len,
                notify_generated_bytes,
            });
            try middleware.zls_transport.transport.writeNotification(
                middleware.io,
                middleware.allocator,
                "textDocument/didChange",
                lsp.ParamsType("textDocument/didChange"),
                .{
                    .textDocument = .{ .uri = notify_uri, .version = notify_version },
                    .contentChanges = changes.items,
                },
                .{ .emit_null_optional_fields = false },
            );
        },
        .open => {
            log.debug("ZLS <- textDocument/didOpen uri={s} version={} generated_bytes={}", .{
                notify_uri,
                notify_version,
                notify_generated_bytes,
            });
            try middleware.zls_transport.transport.writeNotification(
                middleware.io,
                middleware.allocator,
                "textDocument/didOpen",
                lsp.ParamsType("textDocument/didOpen"),
                .{
                    .textDocument = .{
                        .uri = notify_uri,
                        .languageId = .{ .custom_value = "zig" },
                        .version = notify_version,
                        .text = notify_text,
                    },
                },
                .{ .emit_null_optional_fields = false },
            );
        },
    }

    log.debug("Zig sync -> uri={s} version={} opened={} generated_bytes={} spans={} elapsed_ns={}", .{
        uri,
        log_version,
        log_opened,
        log_generated_bytes,
        log_span_count,
        elapsedNs(middleware.io, start),
    });
}

fn zitronOutputFailedWithoutStdout(term: std.process.Child.Term, stdout_len: usize) bool {
    return zitronTermFailed(term) and stdout_len == 0;
}

fn zitronTermFailed(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code != 0,
        else => true,
    };
}

fn parseZitronDiagnostics(allocator: std.mem.Allocator, stderr: []const u8) OOM![]types.Diagnostic {
    var diagnostics: std.ArrayList(types.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| freeStoredDiagnostic(allocator, diagnostic);
        diagnostics.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const diagnostic = try parseZitronDiagnosticLine(allocator, line) orelse continue;
        diagnostics.append(allocator, diagnostic) catch |err| {
            freeStoredDiagnostic(allocator, diagnostic);
            return err;
        };
    }

    return diagnostics.toOwnedSlice(allocator);
}

fn parseZitronDiagnosticLine(allocator: std.mem.Allocator, line: []const u8) OOM!?types.Diagnostic {
    const path_end = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const line_start = path_end + 1;
    const line_end = std.mem.indexOfScalarPos(u8, line, line_start, ':') orelse return null;
    if (line_start == line_end) return null;

    const one_based_line = std.fmt.parseUnsigned(u32, line[line_start..line_end], 10) catch return null;
    const zero_based_line = if (one_based_line == 0) 0 else one_based_line - 1;
    var message = line[line_end + 1 ..];
    if (std.mem.startsWith(u8, message, " ")) message = message[1..];
    if (message.len == 0) return null;

    const source = try allocator.dupe(u8, "zitron");
    errdefer allocator.free(source);
    return .{
        .range = .{
            .start = .{ .line = zero_based_line, .character = 0 },
            .end = .{ .line = zero_based_line, .character = 0 },
        },
        .severity = .Error,
        .source = source,
        .message = try allocator.dupe(u8, message),
    };
}

fn freeStoredDiagnostics(allocator: std.mem.Allocator, diagnostics: []const types.Diagnostic) void {
    if (diagnostics.len == 0) return;
    for (diagnostics) |diagnostic| freeStoredDiagnostic(allocator, diagnostic);
    allocator.free(diagnostics);
}

fn freeStoredDiagnostic(allocator: std.mem.Allocator, diagnostic: types.Diagnostic) void {
    allocator.free(diagnostic.message);
    if (diagnostic.source) |source| allocator.free(source);
    if (diagnostic.code) |code| switch (code) {
        .number => {},
        .string => |string| allocator.free(string),
    };
    if (diagnostic.codeDescription) |description| allocator.free(description.href);
    if (diagnostic.tags) |tags| allocator.free(tags);
}

fn middlewareHandleZlsDiagnostics(
    middleware: *Middleware,
    params_value: ?std.json.Value,
) Error!?PublishedDiagnostics {
    const value = params_value orelse return null;
    const parsed = try std.json.parseFromValue(types.PublishDiagnosticsParams, middleware.allocator, value, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const params = parsed.value;
    middleware.documents_mutex.lockUncancelable(middleware.io);
    defer middleware.documents_mutex.unlock(middleware.io);

    const state = middleware.documentForGeneratedUri(params.uri) orelse {
        log.debug("ZLS diagnostics ignored uri={s} reason=unknown_generated_uri count={}", .{
            params.uri,
            params.diagnostics.len,
        });
        return null;
    };
    const doc = state.currentForVersion(params.version) orelse {
        const current_version = if (state.current) |current| current.version else null;
        log.debug("ZLS diagnostics ignored uri={s} reason=stale_or_ambiguous_version zls_version={?} current_version={?} count={}", .{
            params.uri,
            params.version,
            current_version,
            params.diagnostics.len,
        });
        return null;
    };

    if (params.version == null and state.in_flight_version != null) {
        log.debug("ZLS diagnostics ignored uri={s} reason=null_version_in_flight current_version={} count={}", .{
            params.uri,
            doc.version,
            params.diagnostics.len,
        });
        return null;
    }

    freeStoredDiagnostics(middleware.allocator, doc.zls_diagnostics);
    doc.zls_diagnostics = try translateZlsDiagnostics(middleware.allocator, doc, params.diagnostics);
    doc.zls_diagnostics_version = params.version orelse doc.version;
    log.debug("ZLS diagnostics stored source_uri={s} generated_uri={s} zls_version={?} current_version={} zls_count={} translated_count={}", .{
        doc.source_uri,
        doc.generated_uri,
        params.version,
        doc.version,
        params.diagnostics.len,
        doc.zls_diagnostics.len,
    });
    for (doc.zls_diagnostics, 0..) |diagnostic, index| {
        if (index >= 3) break;
        log.debug("ZLS diagnostic detail source_uri={s} index={} range={any} severity={?} message={s}", .{
            doc.source_uri,
            index,
            diagnostic.range,
            diagnostic.severity,
            diagnostic.message,
        });
    }
    return .{
        .source_uri = try middleware.allocator.dupe(u8, doc.source_uri),
        .version = doc.version,
    };
}

fn translateZlsDiagnostics(
    allocator: std.mem.Allocator,
    doc: *GeneratedDocument,
    diagnostics: []const types.Diagnostic,
) OOM![]types.Diagnostic {
    var translated: std.ArrayList(types.Diagnostic) = .empty;
    errdefer {
        for (translated.items) |diagnostic| freeStoredDiagnostic(allocator, diagnostic);
        translated.deinit(allocator);
    }

    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(allocator);
    var context = RequestTranslationContext{
        .allocator = allocator,
        .map = &doc.code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = null,
    };
    defer context.deinit();

    for (diagnostics) |diagnostic| {
        const source_range = (try context.generatedRangeToSource(diagnostic.range)) orelse continue;
        const stored = try cloneStoredDiagnostic(allocator, diagnostic, source_range, "zls");
        translated.append(allocator, stored) catch |err| {
            freeStoredDiagnostic(allocator, stored);
            return err;
        };
    }

    return translated.toOwnedSlice(allocator);
}

fn cloneStoredDiagnostic(
    allocator: std.mem.Allocator,
    diagnostic: types.Diagnostic,
    range: types.Range,
    fallback_source: []const u8,
) OOM!types.Diagnostic {
    var stored: types.Diagnostic = .{
        .range = range,
        .severity = diagnostic.severity,
        .message = try allocator.dupe(u8, diagnostic.message),
        .source = null,
    };
    errdefer freeStoredDiagnostic(allocator, stored);

    stored.source = try allocator.dupe(u8, diagnostic.source orelse fallback_source);
    stored.code = try cloneDiagnosticCode(allocator, diagnostic.code);
    if (diagnostic.codeDescription) |description| {
        stored.codeDescription = .{ .href = try allocator.dupe(u8, description.href) };
    }
    if (diagnostic.tags) |tags| {
        stored.tags = try allocator.dupe(types.Diagnostic.Tag, tags);
    }
    return stored;
}

fn cloneDiagnosticCode(allocator: std.mem.Allocator, code: ?types.ID) OOM!?types.ID {
    const value = code orelse return null;
    return switch (value) {
        .number => |number| .{ .number = number },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
    };
}

fn middlewareCloseDocument(middleware: *Middleware, uri: []const u8) void {
    const start = logStart(middleware.io);
    log.debug("Zig close <- uri={s}", .{uri});

    const removed = blk: {
        middleware.documents_mutex.lockUncancelable(middleware.io);
        defer middleware.documents_mutex.unlock(middleware.io);
        break :blk middleware.documents.fetchRemove(uri) orelse return;
    };

    middleware.allocator.free(removed.key);
    var state = removed.value;
    if (state.opened) {
        if (state.currentGeneration()) |generation| {
            log.debug("ZLS <- textDocument/didClose uri={s}", .{generation.generated_uri});
            middleware.zls_transport.transport.writeNotification(
                middleware.io,
                middleware.allocator,
                "textDocument/didClose",
                lsp.ParamsType("textDocument/didClose"),
                .{ .textDocument = .{ .uri = generation.generated_uri } },
                .{ .emit_null_optional_fields = false },
            ) catch {};
        }
    }
    state.deinit(middleware.allocator);
    log.debug("Zig close -> uri={s} elapsed_ns={}", .{ uri, elapsedNs(middleware.io, start) });
}

fn middlewareForwardHover(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.HoverParams,
) Error!?types.Hover {
    const start = logStart(middleware.io);
    log.debug("Zig forward hover <- uri={s} source_position={any}", .{ source_uri, params.position });
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_index = code_map.sourceSpanIndexForPosition(params.position) orelse {
        log.debug("Zig forward hover -> uri={s} result=null reason=unmapped_source elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = span_index,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = (try translation_context.sourcePositionToGenerated(params.position)) orelse {
        log.debug("Zig forward hover -> uri={s} result=null reason=mutated_source span={} elapsed_ns={}", .{
            source_uri,
            span_index,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    log.debug("Zig forward hover mapped uri={s} generated_uri={s} span={} generated_position={any}", .{
        source_uri,
        doc.generated_uri,
        span_index,
        mapped.position,
    });

    var result = try middleware.request(arena, "textDocument/hover", mapped);
    if (result) |*hover_result| try translateHover(hover_result, &translation_context);
    log.debug("Zig forward hover -> uri={s} null={} elapsed_ns={}", .{
        source_uri,
        result == null,
        elapsedNs(middleware.io, start),
    });
    return result;
}

fn middlewareForwardDefinition(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.DefinitionParams,
) Error!lsp.ResultType("textDocument/definition") {
    const start = logStart(middleware.io);
    log.debug("Zig forward definition <- uri={s} source_position={any}", .{ source_uri, params.position });
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_index = code_map.sourceSpanIndexForPosition(params.position) orelse {
        log.debug("Zig forward definition -> uri={s} result=null reason=unmapped_source elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = span_index,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = (try translation_context.sourcePositionToGenerated(params.position)) orelse {
        log.debug("Zig forward definition -> uri={s} result=null reason=mutated_source span={} elapsed_ns={}", .{
            source_uri,
            span_index,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    log.debug("Zig forward definition mapped uri={s} generated_uri={s} span={} generated_position={any}", .{
        source_uri,
        doc.generated_uri,
        span_index,
        mapped.position,
    });

    const result = (try middleware.request(arena, "textDocument/definition", mapped)) orelse {
        log.debug("Zig forward definition -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    const translated = try translateDefinition(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
    log.debug("Zig forward definition -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
        source_uri,
        definitionResultCount(result),
        definitionResultCount(translated),
        translated == null,
        elapsedNs(middleware.io, start),
    });
    return translated;
}

fn middlewareForwardReferences(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.ReferenceParams,
) Error!lsp.ResultType("textDocument/references") {
    const start = logStart(middleware.io);
    log.debug("Zig forward references <- uri={s} source_position={any} include_declaration={}", .{
        source_uri,
        params.position,
        params.context.includeDeclaration,
    });
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_index = code_map.sourceSpanIndexForPosition(params.position) orelse {
        log.debug("Zig forward references -> uri={s} result=null reason=unmapped_source elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = span_index,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = (try translation_context.sourcePositionToGenerated(params.position)) orelse {
        log.debug("Zig forward references -> uri={s} result=null reason=mutated_source span={} elapsed_ns={}", .{
            source_uri,
            span_index,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    log.debug("Zig forward references mapped uri={s} generated_uri={s} span={} generated_position={any}", .{
        source_uri,
        doc.generated_uri,
        span_index,
        mapped.position,
    });

    const result = (try middleware.request(arena, "textDocument/references", mapped)) orelse {
        log.debug("Zig forward references -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    const translated = try translateLocations(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
    log.debug("Zig forward references -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
        source_uri,
        result.len,
        if (translated) |locations| locations.len else 0,
        translated == null,
        elapsedNs(middleware.io, start),
    });
    return translated;
}

fn middlewareForwardCompletion(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.CompletionParams,
) Error!lsp.ResultType("textDocument/completion") {
    const start = logStart(middleware.io);
    log.debug("Zig forward completion <- uri={s} source_position={any}", .{ source_uri, params.position });
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_index = code_map.sourceSpanIndexForPosition(params.position) orelse {
        log.debug("Zig forward completion -> uri={s} result=null reason=unmapped_source elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = span_index,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = (try translation_context.sourcePositionToGenerated(params.position)) orelse {
        log.debug("Zig forward completion -> uri={s} result=null reason=mutated_source span={} elapsed_ns={}", .{
            source_uri,
            span_index,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    log.debug("Zig forward completion mapped uri={s} generated_uri={s} span={} generated_position={any}", .{
        source_uri,
        doc.generated_uri,
        span_index,
        mapped.position,
    });

    var result = try middleware.request(arena, "textDocument/completion", mapped);
    const zls_count = completionResultCount(result);
    try translateCompletionResult(arena, &result, &translation_context);
    log.debug("Zig forward completion -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
        source_uri,
        zls_count,
        completionResultCount(result),
        result == null,
        elapsedNs(middleware.io, start),
    });
    return result;
}

fn middlewareForwardInlayHint(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.InlayHintParams,
) Error!lsp.ResultType("textDocument/inlayHint") {
    const start = logStart(middleware.io);
    log.debug("Zig forward inlayHint <- uri={s} source_range={any}", .{ source_uri, params.range });
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    var mapped_range: ?types.Range = null;
    var active_span_index: ?usize = null;
    var spans_scanned: usize = 0;
    var spans_intersected: usize = 0;

    var source_order_index = code_map.firstSourceIndexPossiblyIntersecting(params.range);
    while (source_order_index < code_map.src_order.items.len) : (source_order_index += 1) {
        spans_scanned += 1;
        const span_index = code_map.src_order.items[source_order_index];
        const source_range = sourceRangeFromTsRange(code_map.src_range.items[span_index]);
        if (!positionLessThan(source_range.start, params.range.end)) break;

        const request_range = rangeIntersection(params.range, source_range) orelse continue;
        spans_intersected += 1;
        const span = code_map.gen_span.items[span_index];
        const mapped_start = span.sourcePositionToGenerated(request_range.start);
        const mapped_end = span.sourcePositionToGenerated(request_range.end);
        mapped_range = rangeUnion(mapped_range, .{
            .start = mapped_start,
            .end = mapped_end,
        });
        active_span_index = active_span_index orelse span_index;
    }

    const resolved_range = mapped_range orelse {
        log.debug("Zig forward inlayHint -> uri={s} result=null reason=unmapped_range spans_scanned={} spans_intersected={} elapsed_ns={}", .{
            source_uri,
            spans_scanned,
            spans_intersected,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    const resolved_active_span_index = active_span_index orelse {
        log.debug("Zig forward inlayHint -> uri={s} result=null reason=no_active_span spans_scanned={} spans_intersected={} elapsed_ns={}", .{
            source_uri,
            spans_scanned,
            spans_intersected,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.range = resolved_range;
    log.debug("Zig forward inlayHint mapped uri={s} generated_uri={s} source_range={any} generated_range={any} spans_scanned={} spans_intersected={} active_span={}", .{
        source_uri,
        doc.generated_uri,
        params.range,
        resolved_range,
        spans_scanned,
        spans_intersected,
        resolved_active_span_index,
    });

    const result = (try middleware.request(arena, "textDocument/inlayHint", mapped)) orelse {
        log.debug("Zig forward inlayHint -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    if (result.len == 0) {
        log.debug("Zig forward inlayHint -> uri={s} result=null reason=zls_empty elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    }

    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = resolved_active_span_index,
    };
    defer translation_context.deinit();

    const translated = try translateInlayHints(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
    log.debug("Zig forward inlayHint -> uri={s} zls_count={} translated_count={} dropped_count={} elapsed_ns={}", .{
        source_uri,
        result.len,
        translated.len,
        result.len - translated.len,
        elapsedNs(middleware.io, start),
    });
    return if (translated.len == 0) null else translated;
}

fn middlewareForwardDocumentSymbols(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
) Error!?[]const types.DocumentSymbol {
    const start = logStart(middleware.io);
    log.debug("Zig forward documentSymbol <- uri={s}", .{source_uri});
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const request_result = try middleware.request(arena, "textDocument/documentSymbol", .{
        .textDocument = .{ .uri = doc.generated_uri },
    });
    const result = request_result orelse {
        log.debug("Zig forward documentSymbol -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = null,
    };
    defer translation_context.deinit();
    const translated = try translateDocumentSymbols(arena, result, &translation_context);
    log.debug("Zig forward documentSymbol -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
        source_uri,
        documentSymbolResultCount(request_result),
        if (translated) |symbols| symbols.len else 0,
        translated == null,
        elapsedNs(middleware.io, start),
    });
    return translated;
}

fn middlewareForwardRename(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.RenameParams,
) Error!lsp.ResultType("textDocument/rename") {
    const start = logStart(middleware.io);
    log.debug("Zig forward rename <- uri={s} source_position={any} new_name_len={}", .{
        source_uri,
        params.position,
        params.newName.len,
    });
    const doc = try middleware.documentReady(source_uri);
    const code_map = &doc.code_map;
    const span_index = code_map.sourceSpanIndexForPosition(params.position) orelse {
        log.debug("Zig forward rename -> uri={s} result=null reason=unmapped_source elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);
    var translation_context = RequestTranslationContext{
        .allocator = middleware.allocator,
        .map = code_map,
        .source_text = doc.source_text,
        .generated_text = doc.generated_text,
        .cache = &translation_cache,
        .active_span_index = span_index,
    };
    defer translation_context.deinit();

    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = (try translation_context.sourcePositionToGenerated(params.position)) orelse {
        log.debug("Zig forward rename -> uri={s} result=null reason=mutated_source span={} elapsed_ns={}", .{
            source_uri,
            span_index,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    log.debug("Zig forward rename mapped uri={s} generated_uri={s} span={} generated_position={any}", .{
        source_uri,
        doc.generated_uri,
        span_index,
        mapped.position,
    });

    const result = (try middleware.request(arena, "textDocument/rename", mapped)) orelse {
        log.debug("Zig forward rename -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
            source_uri,
            elapsedNs(middleware.io, start),
        });
        return null;
    };
    const translated = try translateWorkspaceEdit(arena, result, &translation_context, doc.generated_uri, doc.source_uri);
    log.debug("Zig forward rename -> uri={s} zls_edit_count={} translated_edit_count={} null={} elapsed_ns={}", .{
        source_uri,
        workspaceEditCount(result),
        if (translated) |edit| workspaceEditCount(edit) else 0,
        translated == null,
        elapsedNs(middleware.io, start),
    });
    return translated;
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
    const start = logStart(middleware.io);
    log.debug("Zig alias rename <- uri={s} ranges={} alias_len={} new_name_len={}", .{
        source_uri,
        source_ranges.len,
        alias_name.len,
        new_name.len,
    });
    const doc = try middleware.documentReady(source_uri);
    var edits: std.ArrayList(types.TextEdit) = .empty;
    errdefer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);
    var translation_cache: SpanTranslatorCache = .{};
    defer translation_cache.deinit(middleware.allocator);

    for (source_ranges) |source_range| {
        const span_index = doc.code_map.indexForSourceRange(source_range) orelse {
            log.debug("Zig alias rename -> uri={s} result=null reason=unmapped_source_range elapsed_ns={}", .{
                source_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const translator = try translation_cache.get(
            middleware.allocator,
            &doc.code_map,
            doc.source_text,
            doc.generated_text,
            span_index,
        );

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

    const result = try edits.toOwnedSlice(arena);
    log.debug("Zig alias rename -> uri={s} edit_count={} elapsed_ns={}", .{
        source_uri,
        result.len,
        elapsedNs(middleware.io, start),
    });
    return result;
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

        fn sourcePositionToGenerated(span: GenSpan, position: types.Position) types.Position {
            return .{
                .line = span.generated_line + (position.line - span.source_line),
                .character = position.character,
            };
        }

        fn generatedPositionToSource(span: GenSpan, position: types.Position) types.Position {
            return .{
                .line = span.source_line + (position.line - span.generated_line),
                .character = position.character,
            };
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
        return span.sourcePositionToGenerated(position);
    }

    /// Translates a generated position back to source coordinates by finding the
    /// generated-order span containing the generated line and preserving column.
    pub fn generatedPositionToSource(map: *const CodeMap, position: types.Position) ?types.Position {
        const span = map.findGenerated(position.line) orelse return null;
        return span.generatedPositionToSource(position);
    }

    fn sourceSpanIndexForPosition(map: *const CodeMap, position: types.Position) ?usize {
        const source_order_index = map.findSourceIndex(position.line) orelse return null;
        return map.src_order.items[source_order_index];
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

    fn firstSourceIndexPossiblyIntersecting(map: *const CodeMap, range: types.Range) usize {
        var low: usize = 0;
        var high: usize = map.src_order.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const span = map.spanInSourceOrder(mid);
            if (span.sourceEnd() <= range.start.line) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
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
                    if (rel == mutation_start_source) {
                        return .{ .shared = if (source_cursor == mutation_start_source)
                            generated_cursor
                        else
                            mutation_start_generated };
                    }
                    if (mutation_start_source < rel and rel < source_cursor) {
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
        if (rel == source_cursor) return .{ .shared = generated_cursor };
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
                    if (rel == mutation_start_generated) {
                        return .{ .shared = if (generated_cursor == mutation_start_generated)
                            source_cursor
                        else
                            mutation_start_source };
                    }
                    if (mutation_start_generated < rel and rel < generated_cursor) {
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
        if (rel == generated_cursor) return .{ .shared = source_cursor };
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

const SpanTranslatorCache = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        span_index: usize,
        translator: SpanTranslator,
    };

    fn get(
        cache: *SpanTranslatorCache,
        allocator: std.mem.Allocator,
        map: *const CodeMap,
        source_text: []const u8,
        generated_text: []const u8,
        span_index: usize,
    ) OOM!*SpanTranslator {
        const entry_index = try cache.getEntryIndex(allocator, map, source_text, generated_text, span_index);
        return &cache.entries.items[entry_index].translator;
    }

    fn getEntryIndex(
        cache: *SpanTranslatorCache,
        allocator: std.mem.Allocator,
        map: *const CodeMap,
        source_text: []const u8,
        generated_text: []const u8,
        span_index: usize,
    ) OOM!usize {
        for (cache.entries.items, 0..) |*entry, entry_index| {
            if (entry.span_index == span_index) return entry_index;
        }

        var translator = try SpanTranslator.init(
            allocator,
            map.gen_span.items[span_index],
            map.src_range.items[span_index],
            source_text,
            generated_text,
        );
        errdefer translator.deinit(allocator);
        try cache.entries.append(allocator, .{
            .span_index = span_index,
            .translator = translator,
        });
        return cache.entries.items.len - 1;
    }

    fn at(cache: *SpanTranslatorCache, entry_index: usize) *SpanTranslator {
        return &cache.entries.items[entry_index].translator;
    }

    fn reset(cache: *SpanTranslatorCache, allocator: std.mem.Allocator) void {
        for (cache.entries.items) |*entry| {
            entry.translator.deinit(allocator);
        }
        cache.entries.clearRetainingCapacity();
    }

    fn deinit(cache: *SpanTranslatorCache, allocator: std.mem.Allocator) void {
        cache.reset(allocator);
        cache.entries.deinit(allocator);
        cache.* = .{};
    }

    fn len(cache: *const SpanTranslatorCache) usize {
        return cache.entries.items.len;
    }
};

const RequestTranslationContext = struct {
    allocator: std.mem.Allocator,
    map: *const CodeMap,
    source_text: []const u8,
    generated_text: []const u8,
    cache: *SpanTranslatorCache,
    active_span_index: ?usize,

    fn deinit(context: *RequestTranslationContext) void {
        _ = context;
    }

    fn sourcePositionToGenerated(context: *RequestTranslationContext, position: types.Position) OOM!?types.Position {
        const span_index = context.active_span_index orelse context.map.sourceSpanIndexForPosition(position) orelse return null;
        const translator = try context.translatorForSpanIndex(span_index);
        return sharedPosition(translator.sourcePositionToGenerated(position));
    }

    fn generatedRangeToSource(context: *RequestTranslationContext, range: types.Range) OOM!?types.Range {
        const translator = try context.translatorForGeneratedRange(range) orelse return null;
        return translator.generatedRangeToSource(range);
    }

    fn generatedPositionToSource(context: *RequestTranslationContext, position: types.Position) OOM!?types.Position {
        const translator = try context.translatorForGeneratedPosition(position) orelse return null;
        return sharedPosition(translator.generatedPositionToSource(position));
    }

    fn translatorForGeneratedRange(context: *RequestTranslationContext, range: types.Range) OOM!?*SpanTranslator {
        const span_index = context.map.findGeneratedIndex(range.start.line) orelse return null;
        const span = context.map.gen_span.items[span_index];
        if (span.orderGenerated(range.end.line) != .eq and !(range.end.line == span.generatedEnd() and range.end.character == 0)) {
            return null;
        }

        return try context.translatorForSpanIndex(span_index);
    }

    fn translatorForGeneratedPosition(context: *RequestTranslationContext, position: types.Position) OOM!?*SpanTranslator {
        const span_index = context.map.findGeneratedIndex(position.line) orelse return null;
        const span = context.map.gen_span.items[span_index];
        if (position.line == span.generatedEnd() and position.character != 0) return null;
        return try context.translatorForSpanIndex(span_index);
    }

    fn translatorForSpanIndex(context: *RequestTranslationContext, span_index: usize) OOM!*SpanTranslator {
        return try context.cache.get(
            context.allocator,
            context.map,
            context.source_text,
            context.generated_text,
            span_index,
        );
    }

    fn translatorEntryIndexForSpanIndex(context: *RequestTranslationContext, span_index: usize) OOM!usize {
        return try context.cache.getEntryIndex(
            context.allocator,
            context.map,
            context.source_text,
            context.generated_text,
            span_index,
        );
    }
};

const GeneratedPositionCursor = struct {
    context: *RequestTranslationContext,
    span_index: ?usize = null,
    cache_entry_index: usize = 0,
    generated_line: u32 = 0,
    generated_line_start: usize = 0,
    source_line: u32 = 0,
    source_line_start: usize = 0,
    diff: DiffCursor = .{},

    const DiffCursor = struct {
        edit_index: usize = 0,
        source_cursor: usize = 0,
        generated_cursor: usize = 0,
    };

    fn generatedPositionToSource(cursor: *GeneratedPositionCursor, position: types.Position) OOM!?types.Position {
        const translator = try cursor.translatorForPosition(position) orelse return null;
        const generated_index = cursor.generatedIndexForPosition(translator, position) orelse return null;
        const rel = generated_index - translator.gen_span.generated_range.start;
        const translated = cursor.generatedOffsetToSource(translator, rel);
        const source_rel = switch (translated) {
            .shared => |source_rel| source_rel,
            .mutant => return null,
        };
        return cursor.sourcePositionForRel(translator, source_rel);
    }

    fn translatorForPosition(cursor: *GeneratedPositionCursor, position: types.Position) OOM!?*SpanTranslator {
        if (cursor.span_index) |span_index| {
            const span = cursor.context.map.gen_span.items[span_index];
            if (spanContainsGeneratedPosition(span, position)) {
                return cursor.context.cache.at(cursor.cache_entry_index);
            }

            if (position.line >= span.generatedEnd()) {
                var next_index = span_index + 1;
                while (next_index < cursor.context.map.gen_span.items.len) : (next_index += 1) {
                    const next_span = cursor.context.map.gen_span.items[next_index];
                    if (position.line < next_span.generated_line) break;
                    if (spanContainsGeneratedPosition(next_span, position)) {
                        try cursor.resetToSpan(next_index);
                        return cursor.context.cache.at(cursor.cache_entry_index);
                    }
                }
            }
        }

        const span_index = cursor.context.map.findGeneratedIndex(position.line) orelse return null;
        const span = cursor.context.map.gen_span.items[span_index];
        if (!spanContainsGeneratedPosition(span, position)) return null;
        try cursor.resetToSpan(span_index);
        return cursor.context.cache.at(cursor.cache_entry_index);
    }

    fn resetToSpan(cursor: *GeneratedPositionCursor, span_index: usize) OOM!void {
        const cache_entry_index = try cursor.context.translatorEntryIndexForSpanIndex(span_index);
        const translator = cursor.context.cache.at(cache_entry_index);
        cursor.span_index = span_index;
        cursor.cache_entry_index = cache_entry_index;
        cursor.generated_line = translator.gen_span.generated_line;
        cursor.generated_line_start = translator.gen_span.generated_range.start;
        cursor.source_line = translator.src_range.start_point.row;
        cursor.source_line_start = sourceLineStart(translator);
        cursor.diff = .{};
    }

    fn generatedIndexForPosition(
        cursor: *GeneratedPositionCursor,
        translator: *const SpanTranslator,
        position: types.Position,
    ) ?usize {
        if (position.line < cursor.generated_line) {
            cursor.generated_line = translator.gen_span.generated_line;
            cursor.generated_line_start = translator.gen_span.generated_range.start;
        }
        while (cursor.generated_line < position.line) : (cursor.generated_line += 1) {
            const line_tail = translator.generated_text[cursor.generated_line_start..translator.gen_span.generated_range.end];
            const newline = std.mem.indexOfScalar(u8, line_tail, '\n') orelse return null;
            cursor.generated_line_start += newline + 1;
        }
        const index = cursor.generated_line_start + position.character;
        return if (index <= translator.gen_span.generated_range.end) index else null;
    }

    fn sourcePositionForRel(
        cursor: *GeneratedPositionCursor,
        translator: *const SpanTranslator,
        source_rel: usize,
    ) types.Position {
        const source_index = @as(usize, translator.src_range.start_byte) + source_rel;
        if (source_index < cursor.source_line_start) {
            cursor.source_line = translator.src_range.start_point.row;
            cursor.source_line_start = sourceLineStart(translator);
        }
        while (cursor.source_line_start < source_index) {
            const line_tail = translator.source_text[cursor.source_line_start..@as(usize, translator.src_range.end_byte)];
            const newline = std.mem.indexOfScalar(u8, line_tail, '\n') orelse break;
            const next_line_start = cursor.source_line_start + newline + 1;
            if (next_line_start > source_index) break;
            cursor.source_line_start = next_line_start;
            cursor.source_line += 1;
        }
        return .{
            .line = cursor.source_line,
            .character = @intCast(source_index - cursor.source_line_start),
        };
    }

    fn generatedOffsetToSource(cursor: *GeneratedPositionCursor, translator: *const SpanTranslator, rel: usize) SpanTranslator.OffsetTranslation {
        if (rel < cursor.diff.generated_cursor) {
            cursor.diff = .{};
        }

        const edits = translator.difference.edits.items;
        var source_cursor = cursor.diff.source_cursor;
        var generated_cursor = cursor.diff.generated_cursor;
        var index = cursor.diff.edit_index;
        while (index < edits.len) {
            const edit = edits[index];
            switch (edit.operation) {
                .equal => {
                    const generated_end = generated_cursor + edit.text.len;
                    cursor.diff = .{
                        .edit_index = index,
                        .source_cursor = source_cursor,
                        .generated_cursor = generated_cursor,
                    };
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
                    const mutation_start_index = index;
                    while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                        switch (edits[index].operation) {
                            .delete => source_cursor += edits[index].text.len,
                            .insert => generated_cursor += edits[index].text.len,
                            .equal => unreachable,
                        }
                    }
                    cursor.diff = .{
                        .edit_index = mutation_start_index,
                        .source_cursor = mutation_start_source,
                        .generated_cursor = mutation_start_generated,
                    };
                    if (rel == mutation_start_generated) {
                        return .{ .shared = if (generated_cursor == mutation_start_generated)
                            source_cursor
                        else
                            mutation_start_source };
                    }
                    if (mutation_start_generated < rel and rel < generated_cursor) {
                        return .{ .mutant = translator.sourceMutation(
                            mutation_start_source,
                            source_cursor,
                            mutation_start_generated,
                            generated_cursor,
                        ) };
                    }
                    cursor.diff = .{
                        .edit_index = index,
                        .source_cursor = source_cursor,
                        .generated_cursor = generated_cursor,
                    };
                },
            }
        }
        if (rel == generated_cursor) return .{ .shared = source_cursor };
        return .{ .mutant = translator.sourceMutation(0, translator.sourceLength(), 0, translator.generatedLength()) };
    }

    fn spanContainsGeneratedPosition(span: CodeMap.GenSpan, position: types.Position) bool {
        if (position.line < span.generated_line) return false;
        if (position.line > span.generatedEnd()) return false;
        if (position.line == span.generatedEnd()) return position.character == 0;
        return true;
    }

    fn sourceLineStart(translator: *const SpanTranslator) usize {
        return translator.src_range.start_byte - @as(usize, translator.src_range.start_point.column);
    }
};

fn sharedPosition(translated: CodeMap.TranslatedPosition) ?types.Position {
    return switch (translated) {
        .shared => |position| position,
        .mutant => null,
    };
}

fn logStart(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) i96 {
    return start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
}

fn completionResultCount(result: lsp.ResultType("textDocument/completion")) usize {
    const value = result orelse return 0;
    return switch (value) {
        .completion_items => |items| items.len,
        .completion_list => |list| list.items.len,
    };
}

fn definitionResultCount(result: lsp.ResultType("textDocument/definition")) usize {
    const value = result orelse return 0;
    return switch (value) {
        .definition => |definition| switch (definition) {
            .location => 1,
            .locations => |locations| locations.len,
        },
        .definition_links => |links| links.len,
    };
}

fn documentSymbolResultCount(result: lsp.ResultType("textDocument/documentSymbol")) usize {
    const value = result orelse return 0;
    return switch (value) {
        .document_symbols => |symbols| symbols.len,
        .symbol_informations => |symbols| symbols.len,
    };
}

fn workspaceEditCount(edit: types.WorkspaceEdit) usize {
    var count: usize = 0;
    if (edit.changes) |changes| {
        var it = changes.map.iterator();
        while (it.next()) |entry| {
            count += entry.value_ptr.*.len;
        }
    }
    if (edit.documentChanges) |document_changes| {
        for (document_changes) |change| {
            switch (change) {
                .text_document_edit => |document_edit| count += document_edit.edits.len,
                else => {},
            }
        }
    }
    return count;
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

fn positionLessThan(lhs: types.Position, rhs: types.Position) bool {
    return lhs.line < rhs.line or (lhs.line == rhs.line and lhs.character < rhs.character);
}

fn positionMax(lhs: types.Position, rhs: types.Position) types.Position {
    return if (positionLessThan(lhs, rhs)) rhs else lhs;
}

fn positionMin(lhs: types.Position, rhs: types.Position) types.Position {
    return if (positionLessThan(lhs, rhs)) lhs else rhs;
}

fn rangeIntersection(lhs: types.Range, rhs: types.Range) ?types.Range {
    const start = positionMax(lhs.start, rhs.start);
    const end = positionMin(lhs.end, rhs.end);
    return if (positionLessThan(start, end)) .{
        .start = start,
        .end = end,
    } else null;
}

fn rangeUnion(maybe_lhs: ?types.Range, rhs: types.Range) types.Range {
    const lhs = maybe_lhs orelse return rhs;
    return .{
        .start = positionMin(lhs.start, rhs.start),
        .end = positionMax(lhs.end, rhs.end),
    };
}

fn sourceRangeFromTsRange(range: ts.Range) types.Range {
    return .{
        .start = .{
            .line = range.start_point.row,
            .character = range.start_point.column,
        },
        .end = .{
            .line = range.end_point.row,
            .character = range.end_point.column,
        },
    };
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

pub fn translateInlayHints(
    arena: std.mem.Allocator,
    hints: []const types.InlayHint,
    map: *RequestTranslationContext,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM![]const types.InlayHint {
    var translated: std.ArrayList(types.InlayHint) = .empty;
    var position_cursor = GeneratedPositionCursor{ .context = map };
    for (hints) |hint| {
        if (try translateInlayHint(arena, hint, map, &position_cursor, generated_uri, source_uri)) |mapped| {
            try translated.append(arena, mapped);
        }
    }
    return try translated.toOwnedSlice(arena);
}

fn translateInlayHint(
    arena: std.mem.Allocator,
    hint: types.InlayHint,
    map: *RequestTranslationContext,
    position_cursor: *GeneratedPositionCursor,
    generated_uri: []const u8,
    source_uri: []const u8,
) OOM!?types.InlayHint {
    var translated = hint;
    translated.position = (try position_cursor.generatedPositionToSource(hint.position)) orelse return null;
    translated.label = switch (hint.label) {
        .string => hint.label,
        .inlay_hint_label_parts => |parts| blk: {
            const translated_parts = try arena.alloc(types.InlayHintLabelPart, parts.len);
            for (parts, translated_parts) |part, *translated_part| {
                translated_part.* = part;
                if (part.location) |location| {
                    translated_part.location = try translateLocation(location, map, generated_uri, source_uri);
                }
            }
            break :blk .{ .inlay_hint_label_parts = translated_parts };
        },
    };
    if (hint.textEdits) |edits| {
        const translated_edits = try translateTextEdits(arena, edits, map);
        translated.textEdits = if (translated_edits.len == edits.len) translated_edits else null;
    }
    return translated;
}

pub fn translateDocumentSymbols(
    arena: std.mem.Allocator,
    result: lsp.types.DocumentSymbol.Result,
    map: *RequestTranslationContext,
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
    map: *RequestTranslationContext,
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
    map: *RequestTranslationContext,
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
    const start = logStart(middleware.io);
    const id = middleware.nextRequestId();
    log.debug("ZLS <- initialize id={any}", .{id});
    const number_id = switch (id) {
        .number => |number| number,
        .string => unreachable,
    };
    middleware.response_mutex.lockUncancelable(middleware.io);
    errdefer middleware.response_mutex.unlock(middleware.io);
    try middleware.pending_responses.put(middleware.allocator, number_id, .{});
    middleware.response_mutex.unlock(middleware.io);
    errdefer {
        middleware.response_mutex.lockUncancelable(middleware.io);
        _ = middleware.pending_responses.remove(number_id);
        middleware.response_mutex.unlock(middleware.io);
    }

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
                    .publishDiagnostics = .{
                        .relatedInformation = true,
                        .tagSupport = .{ .valueSet = &.{ .Unnecessary, .Deprecated } },
                        .versionSupport = true,
                        .codeDescriptionSupport = true,
                        .dataSupport = true,
                    },
                    .inlayHint = .{},
                },
            },
        },
        .{ .emit_null_optional_fields = false },
    );
    const wait_start = logStart(middleware.io);
    const initialize_response = try middleware.waitResponseForId(id);
    defer middleware.allocator.free(initialize_response);
    log.debug("ZLS -> initialize id={any} response_bytes={} wait_ns={}", .{
        id,
        initialize_response.len,
        elapsedNs(middleware.io, wait_start),
    });

    const parse_start = logStart(middleware.io);
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
    log.debug("ZLS initialize parsed id={any} parse_ns={}", .{
        id,
        elapsedNs(middleware.io, parse_start),
    });

    if (initialize_result.value.capabilities.completionProvider) |completion_options| {
        if (completion_options.triggerCharacters) |trigger_characters| {
            freeStringSlices(middleware.allocator, middleware.zls_completion_triggers);
            middleware.zls_completion_triggers = try dupeStringSlices(middleware.allocator, trigger_characters);
        }
    }

    log.debug("ZLS <- initialized", .{});
    try middleware.zls_transport.transport.writeNotification(
        middleware.io,
        middleware.allocator,
        "initialized",
        lsp.ParamsType("initialized"),
        .{},
        .{ .emit_null_optional_fields = false },
    );
    log.debug("ZLS initialize complete id={any} triggers={} elapsed_ns={}", .{
        id,
        middleware.zls_completion_triggers.len,
        elapsedNs(middleware.io, start),
    });
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
    log.info("Stopping ZLS middleware", .{});
    const start = logStart(middleware.io);
    const id = middleware.nextRequestId();
    log.debug("ZLS <- shutdown id={any}", .{id});
    const number_id = switch (id) {
        .number => |number| number,
        .string => unreachable,
    };
    middleware.response_mutex.lockUncancelable(middleware.io);
    errdefer middleware.response_mutex.unlock(middleware.io);
    try middleware.pending_responses.put(middleware.allocator, number_id, .{});
    middleware.response_mutex.unlock(middleware.io);
    errdefer {
        middleware.response_mutex.lockUncancelable(middleware.io);
        _ = middleware.pending_responses.remove(number_id);
        middleware.response_mutex.unlock(middleware.io);
    }

    try middleware.zls_transport.transport.writeRequest(
        middleware.io,
        middleware.allocator,
        id,
        "shutdown",
        lsp.ParamsType("shutdown"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    const wait_start = logStart(middleware.io);
    const json_message = try middleware.waitResponseForId(id);
    log.debug("ZLS -> shutdown id={any} response_bytes={} wait_ns={}", .{
        id,
        json_message.len,
        elapsedNs(middleware.io, wait_start),
    });
    middleware.allocator.free(json_message);
    log.debug("ZLS <- exit", .{});
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
    log.debug("ZLS shutdown complete id={any} elapsed_ns={}", .{ id, elapsedNs(middleware.io, start) });
}

fn middlewareRequest(
    middleware: *Middleware,
    arena: std.mem.Allocator,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) Error!lsp.ResultType(method) {
    const start = logStart(middleware.io);
    const id = middleware.nextRequestId();
    log.debug("ZLS <- {s} id={any}", .{ method, id });
    const number_id = switch (id) {
        .number => |number| number,
        .string => unreachable,
    };
    middleware.response_mutex.lockUncancelable(middleware.io);
    errdefer middleware.response_mutex.unlock(middleware.io);
    try middleware.pending_responses.put(middleware.allocator, number_id, .{});
    middleware.response_mutex.unlock(middleware.io);
    errdefer {
        middleware.response_mutex.lockUncancelable(middleware.io);
        _ = middleware.pending_responses.remove(number_id);
        middleware.response_mutex.unlock(middleware.io);
    }

    try middleware.zls_transport.transport.writeRequest(
        middleware.io,
        middleware.allocator,
        id,
        method,
        lsp.ParamsType(method),
        params,
        .{ .emit_null_optional_fields = false },
    );

    const wait_start = logStart(middleware.io);
    const json_message = try middleware.waitResponseForId(id);
    const wait_ns = elapsedNs(middleware.io, wait_start);
    log.debug("ZLS -> {s} id={any} response_bytes={} wait_ns={}", .{
        method,
        id,
        json_message.len,
        wait_ns,
    });
    const parse_start = logStart(middleware.io);
    defer middleware.allocator.free(json_message);
    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, arena, json_message, .{
        .ignore_unknown_fields = true,
    });
    const parse_ns = elapsedNs(middleware.io, parse_start);

    const result_value = switch (parsed.value) {
        .response => |response| switch (response.result_or_error) {
            .result => |maybe_result| maybe_result,
            .@"error" => {
                log.warn("ZLS '{s}' request failed id={any}", .{ method, id });
                return error.RequestFailed;
            },
        },
        else => return error.UnexpectedResponse,
    };
    if (result_value == null or result_value.? == .null) {
        log.debug("ZLS parsed {s} id={any} result=null parse_ns={} elapsed_ns={}", .{
            method,
            id,
            parse_ns,
            elapsedNs(middleware.io, start),
        });
        return null;
    }

    const typed_parse_start = logStart(middleware.io);
    const typed = try std.json.parseFromValue(lsp.ResultType(method), arena, result_value.?, .{
        .ignore_unknown_fields = true,
    });
    log.debug("ZLS parsed {s} id={any} result=success parse_ns={} typed_parse_ns={} elapsed_ns={}", .{
        method,
        id,
        parse_ns,
        elapsedNs(middleware.io, typed_parse_start),
        elapsedNs(middleware.io, start),
    });
    return typed.value;
}

fn middlewareWaitResponseForId(middleware: *Middleware, id: lsp.JsonRPCMessage.ID) Error![]u8 {
    const number_id = switch (id) {
        .number => |number| number,
        .string => return error.UnexpectedResponse,
    };

    middleware.response_mutex.lockUncancelable(middleware.io);
    defer middleware.response_mutex.unlock(middleware.io);

    while (true) {
        if (middleware.pending_responses.getPtr(number_id)) |pending| {
            if (pending.response) |response| {
                _ = middleware.pending_responses.remove(number_id);
                return response;
            }
        } else {
            return error.UnexpectedResponse;
        }
        if (middleware.reader_failed) return error.UnexpectedResponse;
        middleware.response_cond.waitUncancelable(middleware.io, &middleware.response_mutex);
    }
}

fn middlewareReaderMain(middleware: *Middleware) void {
    while (true) {
        const json_message = middleware.zls_transport.transport.readJsonMessage(
            middleware.io,
            middleware.allocator,
        ) catch |err| {
            log.debug("ZLS reader stopped: {}", .{err});
            middleware.response_mutex.lockUncancelable(middleware.io);
            middleware.reader_failed = true;
            middleware.response_cond.broadcast(middleware.io);
            middleware.response_mutex.unlock(middleware.io);
            return;
        };

        const consumed = middleware.handleZlsMessage(json_message) catch |err| blk: {
            log.warn("ZLS message ignored: {}", .{err});
            break :blk false;
        };
        if (!consumed) middleware.allocator.free(json_message);
    }
}

fn middlewareHandleZlsMessage(middleware: *Middleware, json_message: []u8) Error!bool {
    log.debug("ZLS read message bytes={}", .{json_message.len});
    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, middleware.allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    switch (parsed.value) {
        .response => |response| {
            const id = response.id orelse {
                log.debug("ZLS ignored response response_has_id=false", .{});
                return false;
            };
            const number_id = switch (id) {
                .number => |number| number,
                .string => {
                    log.debug("ZLS ignored response id={any} reason=string_id", .{id});
                    return false;
                },
            };

            middleware.response_mutex.lockUncancelable(middleware.io);
            defer middleware.response_mutex.unlock(middleware.io);
            if (middleware.pending_responses.getPtr(number_id)) |pending| {
                pending.response = json_message;
                middleware.response_cond.broadcast(middleware.io);
                return true;
            }
            log.debug("ZLS ignored response id={any} reason=unknown_id", .{id});
            return false;
        },
        .request => |request| {
            log.debug("ZLS ignored request method={s}", .{request.method});
            return false;
        },
        .notification => |notification| {
            if (std.mem.eql(u8, notification.method, "textDocument/publishDiagnostics")) {
                if (try middleware.handleZlsDiagnostics(notification.params)) |published| {
                    if (middleware.diagnostics_context) |context| {
                        if (middleware.diagnostics_publisher) |publisher| {
                            publisher(context, published.source_uri, published.version);
                        }
                    }
                    middleware.allocator.free(published.source_uri);
                }
            } else {
                log.debug("ZLS ignored notification method={s}", .{notification.method});
            }
            return false;
        },
    }
}

fn middlewareNextRequestId(middleware: *Middleware) lsp.JsonRPCMessage.ID {
    const id = middleware.next_request_id;
    middleware.next_request_id += 1;
    return .{ .number = id };
}

fn middlewareDocumentReady(middleware: *Middleware, source_uri: []const u8) Error!*GeneratedDocument {
    const state = middleware.documents.getPtr(source_uri) orelse return error.MissingGeneratedDocument;
    const doc = state.currentGeneration() orelse return error.MissingGeneratedDocument;
    if (doc.generation_error != null) return error.RequestFailed;
    return doc;
}

fn middlewareDocumentForGeneratedUri(middleware: *Middleware, generated_uri: []const u8) ?*DocumentState {
    var it = middleware.documents.iterator();
    while (it.next()) |entry| {
        const current = entry.value_ptr.current orelse continue;
        if (std.mem.eql(u8, current.generated_uri, generated_uri)) return entry.value_ptr;
    }
    return null;
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
        .argv = &.{ "zitron", "-Ful", source_path },
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

fn makeTestGeneratedDocument(
    allocator: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    source_text: []const u8,
    generated_text: []const u8,
) !GeneratedDocument {
    var map = try parseCodeMapForTest(source_text, generated_text, "source.zy");
    errdefer map.deinit(allocator);

    return .{
        .generation_id = @intCast(version),
        .source_uri = try allocator.dupe(u8, uri),
        .source_path = try allocator.dupe(u8, "source.zy"),
        .source_text = try allocator.dupe(u8, source_text),
        .generated_uri = try generatedUriForSourceUri(allocator, uri),
        .generated_text = try allocator.dupe(u8, generated_text),
        .code_map = map,
        .generation_error = null,
        .grammar_diagnostics = &.{},
        .zls_diagnostics = &.{},
        .zls_diagnostics_version = null,
        .version = version,
        .opened = false,
    };
}

fn makeTestDocumentState(
    allocator: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    source_text: []const u8,
    generated_text: []const u8,
) !DocumentState {
    return .{
        .current = try makeTestGeneratedDocument(allocator, uri, version, source_text, generated_text),
        .latest_requested_version = version,
        .in_flight_version = null,
        .opened = false,
        .zls_sync_count = 0,
    };
}

fn requestTranslationContextForTest(
    cache: *SpanTranslatorCache,
    map: *const CodeMap,
    source_text: []const u8,
    generated_text: []const u8,
    position: types.Position,
) !RequestTranslationContext {
    return .{
        .allocator = testing_allocator,
        .map = map,
        .source_text = source_text,
        .generated_text = generated_text,
        .cache = cache,
        .active_span_index = map.sourceSpanIndexForPosition(position) orelse return error.UnexpectedCodeMap,
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
        .io = std.Options.debug_io,
        .zls_child = undefined,
        .zls_transport = undefined,
        .zls_read_buffer = undefined,
        .reader_thread = null,
        .response_mutex = .init,
        .response_cond = .init,
        .pending_responses = .empty,
        .reader_failed = false,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
        .next_request_id = 1,
    };
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, .{
        .current = .{
            .source_uri = try testing_allocator.dupe(u8, uri),
            .source_path = try testing_allocator.dupe(u8, "source.zy"),
            .source_text = try testing_allocator.dupe(u8, source),
            .generated_uri = try generatedUriForSourceUri(testing_allocator, uri),
            .generated_text = try testing_allocator.dupe(u8, generated),
            .code_map = map,
            .generation_error = null,
            .grammar_diagnostics = &.{},
            .zls_diagnostics = &.{},
            .zls_diagnostics_version = null,
            .version = 1,
            .opened = false,
        },
        .latest_requested_version = 1,
        .in_flight_version = null,
        .opened = false,
        .zls_sync_count = 0,
    });
    errdefer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var state = removed.value;
        state.deinit(testing_allocator);
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

test "forward requests return null while generation has errors" {
    const uri = "file:///source.zy";
    const source = "%code { broken }";
    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .zls_child = undefined,
        .zls_transport = undefined,
        .zls_read_buffer = undefined,
        .reader_thread = null,
        .response_mutex = .init,
        .response_cond = .init,
        .pending_responses = .empty,
        .reader_failed = false,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
        .next_request_id = 1,
    };
    var zig_middleware: ZigMiddleware = .{ .mode = .{ .enabled = &middleware } };

    switch (zig_middleware.mode) {
        .disabled => unreachable,
        .enabled => |mware| {
            const key = try testing_allocator.dupe(u8, uri);
            errdefer testing_allocator.free(key);
            try mware.documents.put(testing_allocator, key, .{
                .current = .{
                    .source_uri = try testing_allocator.dupe(u8, uri),
                    .source_path = try testing_allocator.dupe(u8, "source.zy"),
                    .source_text = try testing_allocator.dupe(u8, source),
                    .generated_uri = try generatedUriForSourceUri(testing_allocator, uri),
                    .generated_text = try testing_allocator.dupe(u8, ""),
                    .code_map = .{},
                    .generation_error = try testing_allocator.dupe(u8, "generation failed"),
                    .grammar_diagnostics = &.{},
                    .zls_diagnostics = &.{},
                    .zls_diagnostics_version = null,
                    .version = 1,
                    .opened = false,
                },
                .latest_requested_version = 1,
                .in_flight_version = null,
                .opened = false,
                .zls_sync_count = 0,
            });
        },
    }
    defer switch (zig_middleware.mode) {
        .disabled => unreachable,
        .enabled => |mware| {
            const removed = mware.documents.fetchRemove(uri).?;
            testing_allocator.free(removed.key);
            var state = removed.value;
            state.deinit(testing_allocator);
            mware.documents.deinit(testing_allocator);
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const completion_result = try zig_middleware.forwardCompletion(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 0 },
    });
    try std.testing.expect(completion_result == null);

    const inlay_result = try zig_middleware.forwardInlayHint(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 16 },
        },
    });
    try std.testing.expect(inlay_result == null);
}

test "nonzero Zitron exit can continue with stdout" {
    try std.testing.expect(!zitronOutputFailedWithoutStdout(.{ .exited = 0 }, 0));
    try std.testing.expect(zitronOutputFailedWithoutStdout(.{ .exited = 1 }, 0));
    try std.testing.expect(!zitronOutputFailedWithoutStdout(.{ .exited = 1 }, 1));
    try std.testing.expect(!zitronOutputFailedWithoutStdout(.{ .signal = .KILL }, 1));
}

test "Zitron stderr diagnostics become line-start LSP diagnostics" {
    const stderr =
        \\src/edn/edn.zy:349: Rule RHS alias "Mcdr" does not match rule impl's "P".
        \\src/edn/edn.zy:349: There is no prior rule upon which to attach the code fragment which begins on this line
        \\not a diagnostic
        \\src/edn/edn.zy:172: Alias P for "pair(P)" is never used.
        \\
    ;

    const diagnostics = try parseZitronDiagnostics(testing_allocator, stderr);
    defer freeStoredDiagnostics(testing_allocator, diagnostics);

    try expectEqual(@as(usize, 3), diagnostics.len);
    try expectEqual(@as(u32, 348), diagnostics[0].range.start.line);
    try expectEqual(@as(u32, 0), diagnostics[0].range.start.character);
    try expectEqual(diagnostics[0].range.start, diagnostics[0].range.end);
    try expectEqual(types.Diagnostic.Severity.Error, diagnostics[0].severity.?);
    try expectEqualStrings("zitron", diagnostics[0].source.?);
    try expectEqualStrings("Rule RHS alias \"Mcdr\" does not match rule impl's \"P\".", diagnostics[0].message);

    try expectEqual(@as(u32, 348), diagnostics[1].range.start.line);
    try expectEqualStrings("There is no prior rule upon which to attach the code fragment which begins on this line", diagnostics[1].message);

    try expectEqual(@as(u32, 171), diagnostics[2].range.start.line);
    try expectEqualStrings("Alias P for \"pair(P)\" is never used.", diagnostics[2].message);
}

test "ZLS diagnostics translate to source ranges and default source" {
    const source =
        \\rule ::= value. {
        \\    const result: MissingType = value;
        \\}
    ;
    const generated =
        \\// #line 1 source.zy
        \\    const result: MissingType = value;
    ;
    const missing_start = std.mem.indexOf(u8, generated, "MissingType") orelse return error.NeedleNotFound;
    const missing_end = missing_start + "MissingType".len;
    const tags = [_]types.Diagnostic.Tag{.Unnecessary};
    const zls_diagnostics = [_]types.Diagnostic{
        .{
            .range = .{
                .start = lsp.offsets.indexToPosition(generated, missing_start, .@"utf-8"),
                .end = lsp.offsets.indexToPosition(generated, missing_end, .@"utf-8"),
            },
            .severity = .Warning,
            .source = null,
            .code = .{ .string = "zls-code" },
            .message = "use of undeclared identifier 'MissingType'",
            .tags = &tags,
        },
        .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 4 },
            },
            .severity = .Error,
            .source = "zls",
            .message = "generated-only diagnostic",
        },
    };

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    errdefer map.deinit(testing_allocator);
    var doc: GeneratedDocument = .{
        .source_uri = try testing_allocator.dupe(u8, "file:///source.zy"),
        .source_path = try testing_allocator.dupe(u8, "source.zy"),
        .source_text = try testing_allocator.dupe(u8, source),
        .generated_uri = try testing_allocator.dupe(u8, "file:///source.zitron.zig"),
        .generated_text = try testing_allocator.dupe(u8, generated),
        .code_map = map,
        .generation_error = null,
        .grammar_diagnostics = &.{},
        .zls_diagnostics = &.{},
        .zls_diagnostics_version = null,
        .version = 1,
        .opened = false,
    };
    defer doc.deinit(testing_allocator);

    const translated = try translateZlsDiagnostics(testing_allocator, &doc, &zls_diagnostics);
    defer freeStoredDiagnostics(testing_allocator, translated);

    try expectEqual(@as(usize, 1), translated.len);
    try expectEqual(@as(u32, 1), translated[0].range.start.line);
    try expectEqual(types.Diagnostic.Severity.Warning, translated[0].severity.?);
    try expectEqualStrings("zls", translated[0].source.?);
    try expectEqualStrings("use of undeclared identifier 'MissingType'", translated[0].message);
    try expectEqualStrings("zls-code", translated[0].code.?.string);
    try expectEqual(@as(usize, 1), translated[0].tags.?.len);
    try expectEqual(types.Diagnostic.Tag.Unnecessary, translated[0].tags.?[0]);
}

test "document state resolves current generation by version" {
    var state = try makeTestDocumentState(testing_allocator, "file:///source.zy", 1, "source", "generated");
    defer state.deinit(testing_allocator);

    try std.testing.expect(state.currentForVersion(1) != null);
    try std.testing.expect(state.currentForVersion(2) == null);
}

test "document state rejects version-null diagnostics while generation is in flight" {
    var state = try makeTestDocumentState(testing_allocator, "file:///source.zy", 1, "source", "generated");
    defer state.deinit(testing_allocator);

    state.zls_sync_count = 1;
    state.in_flight_version = 2;
    try std.testing.expect(state.currentForVersion(null) == null);
}

test "document state accepts version-null diagnostics only before a second ZLS sync" {
    var state = try makeTestDocumentState(testing_allocator, "file:///source.zy", 1, "source", "generated");
    defer state.deinit(testing_allocator);

    state.zls_sync_count = 1;
    try std.testing.expect(state.currentForVersion(null) != null);
    state.zls_sync_count = 2;
    try std.testing.expect(state.currentForVersion(null) == null);
}

test "document state does not publish stale generation" {
    var state = DocumentState{
        .current = null,
        .latest_requested_version = 2,
        .in_flight_version = 1,
        .opened = false,
        .zls_sync_count = 0,
    };
    defer state.deinit(testing_allocator);

    const stale = try makeTestGeneratedDocument(testing_allocator, "file:///source.zy", 1, "old", "old generated");
    const published = state.publishIfCurrent(testing_allocator, stale);

    try std.testing.expect(!published);
    try std.testing.expect(state.current == null);
}

test "ZLS diagnostics for stale generation do not replace current diagnostics" {
    const uri = "file:///source.zy";
    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .zls_child = undefined,
        .zls_transport = undefined,
        .zls_read_buffer = undefined,
        .reader_thread = null,
        .response_mutex = .init,
        .response_cond = .init,
        .pending_responses = .empty,
        .reader_failed = false,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
        .next_request_id = 1,
    };
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, try makeTestDocumentState(
        testing_allocator,
        uri,
        2,
        "rule ::= TOKEN. { result = token; }",
        "// #line 1 source.zy\n result = token;",
    ));
    defer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var state = removed.value;
        state.deinit(testing_allocator);
        middleware.documents.deinit(testing_allocator);
    }

    const params_json =
        \\{
        \\  "uri": "file:///source.zitron.zig",
        \\  "version": 1,
        \\  "diagnostics": []
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing_allocator, params_json, .{});
    defer parsed.deinit();

    const published = try middleware.handleZlsDiagnostics(parsed.value);
    try std.testing.expect(published == null);
    const state = middleware.documents.getPtr(uri).?;
    const current = state.currentForVersion(2).?;
    try expectEqual(@as(usize, 0), current.zls_diagnostics.len);
    try std.testing.expect(current.zls_diagnostics_version == null);
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

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    const source_position = lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "result").?, .@"utf-8");
    const translator = try cache.get(
        testing_allocator,
        &map,
        source,
        generated,
        map.sourceSpanIndexForPosition(source_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(types.Position{
        .line = 1,
        .character = @intCast(std.mem.indexOf(u8, " result = token;", "result").?),
    }, sharedPosition(translator.sourcePositionToGenerated(source_position)) orelse return error.UnexpectedCodeMap);
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

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    const source_position = lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "pik_elist_append").?, .@"utf-8");
    const translator = try cache.get(
        testing_allocator,
        &map,
        source,
        generated,
        map.sourceSpanIndexForPosition(source_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(types.Position{
        .line = 1,
        .character = @intCast(std.mem.indexOf(u8, generated, "pik_elist_append").? - std.mem.lastIndexOfScalar(u8, generated[0..std.mem.indexOf(u8, generated, "pik_elist_append").?], '\n').? - 1),
    }, sharedPosition(translator.sourcePositionToGenerated(source_position)) orelse return error.UnexpectedCodeMap);

    try expectEqual(
        lsp.offsets.indexToPosition(generated, std.mem.indexOf(u8, generated, "yygotominor").?, .@"utf-8"),
        sharedPosition(translator.sourcePositionToGenerated(lsp.offsets.indexToPosition(
            source,
            std.mem.indexOf(u8, source, "A =").?,
            .@"utf-8",
        ))) orelse return error.UnexpectedCodeMap,
    );

    try std.testing.expect(translator.generatedRangeToSource(.{
        .start = lsp.offsets.indexToPosition(generated, std.mem.indexOf(u8, generated, "yygotominor").?, .@"utf-8"),
        .end = lsp.offsets.indexToPosition(generated, std.mem.indexOf(u8, generated, " =").?, .@"utf-8"),
    }) == null);
}

test "request span translator maps generated alias boundary points" {
    const source =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const generated =
        \\// #line 1 source.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);

    const source_call = std.mem.indexOf(u8, source, "pik_elist_append").?;
    const source_alias = source_call + std.mem.indexOf(u8, source[source_call..], "X").?;
    const generated_call = std.mem.indexOf(u8, generated, "pik_elist_append").?;
    const generated_alias = generated_call + std.mem.indexOf(u8, generated[generated_call..], "yymsp").?;
    const source_position = lsp.offsets.indexToPosition(source, source_alias, .@"utf-8");
    const generated_position = lsp.offsets.indexToPosition(generated, generated_alias, .@"utf-8");

    const translator = try cache.get(
        testing_allocator,
        &map,
        source,
        generated,
        map.sourceSpanIndexForPosition(source_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(
        source_position,
        sharedPosition(translator.generatedPositionToSource(generated_position)) orelse return error.UnexpectedCodeMap,
    );
    try std.testing.expect(sharedPosition(translator.generatedPositionToSource(lsp.offsets.indexToPosition(
        generated,
        generated_alias + 1,
        .@"utf-8",
    ))) == null);
    try std.testing.expect(translator.generatedRangeToSource(.{
        .start = generated_position,
        .end = lsp.offsets.indexToPosition(generated, generated_alias + "yymsp".len, .@"utf-8"),
    }) == null);

    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .source_text = source,
        .generated_text = generated,
        .cache = &cache,
        .active_span_index = map.sourceSpanIndexForPosition(source_position) orelse return error.UnexpectedCodeMap,
    };
    defer context.deinit();

    const hints = [_]types.InlayHint{.{
        .position = generated_position,
        .label = .{ .string = "obj:" },
        .kind = .Parameter,
    }};

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateInlayHints(
        arena_state.allocator(),
        &hints,
        &context,
        "file:///source.zitron.zig",
        "file:///source.zy",
    );

    try expectEqual(@as(usize, 1), translated.len);
    try expectEqual(source_position, translated[0].position);
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

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    const source_position = lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "pik_elist_append").?, .@"utf-8");
    const translator = try cache.get(
        testing_allocator,
        &map,
        source,
        generated,
        map.sourceSpanIndexForPosition(source_position) orelse return error.UnexpectedCodeMap,
    );

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

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    const active_position = lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "pik_render").?, .@"utf-8");
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .source_text = source,
        .generated_text = generated,
        .cache = &cache,
        .active_span_index = map.sourceSpanIndexForPosition(active_position) orelse return error.UnexpectedCodeMap,
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
    var map: CodeMap = .{};
    defer map.deinit(testing_allocator);
    try map.gen_span.append(testing_allocator, .{
        .source_line = 0,
        .generated_line = 0,
        .line_count = 1,
        .generated_range = .{ .start = 0, .end = generated.len },
    });
    try map.src_range.append(testing_allocator, .{
        .start_byte = 0,
        .end_byte = @intCast(source.len),
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = 1, .column = @intCast("const answer = 42;".len) },
    });

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    const translator = try cache.get(testing_allocator, &map, source, generated, 0);

    try expectEqual(types.Position{ .line = 0, .character = 6 }, sharedPosition(translator.sourcePositionToGenerated(.{
        .line = 1,
        .character = 6,
    })) orelse return error.UnexpectedCodeMap);
    try expectEqual(types.Position{ .line = 0, .character = 0 }, sharedPosition(translator.sourcePositionToGenerated(.{
        .line = 0,
        .character = 0,
    })) orelse return error.UnexpectedCodeMap);
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
    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &cache,
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
    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &cache,
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

test "translates inlay hints back to source positions" {
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
    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &cache,
        &map,
        source,
        generated,
        lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "answer").?, .@"utf-8"),
    );
    defer context.deinit();

    var label_parts = [_]types.InlayHintLabelPart{.{
        .value = ": i32",
        .location = .{
            .uri = "file:///generated.zig",
            .range = .{
                .start = .{ .line = 1, .character = 6 },
                .end = .{ .line = 1, .character = 12 },
            },
        },
    }};
    const hints = [_]types.InlayHint{.{
        .position = .{ .line = 1, .character = 12 },
        .label = .{ .inlay_hint_label_parts = &label_parts },
        .kind = .Type,
        .textEdits = &.{.{
            .range = .{
                .start = .{ .line = 1, .character = 12 },
                .end = .{ .line = 1, .character = 12 },
            },
            .newText = ": i32",
        }},
    }};
    const other_hints = [_]types.InlayHint{
        hints[0],
        .{
            .position = .{ .line = 1, .character = 17 },
            .label = .{ .string = ": comptime_int" },
            .kind = .Type,
            .textEdits = &.{.{
                .range = .{
                    .start = .{ .line = 1, .character = 17 },
                    .end = .{ .line = 1, .character = 17 },
                },
                .newText = ": comptime_int",
            }},
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    try expectEqual(@as(usize, 0), cache.len());
    const translated = try translateInlayHints(
        arena_state.allocator(),
        &other_hints,
        &context,
        "file:///generated.zig",
        "file:///source.zy",
    );

    try expectEqual(@as(usize, 1), cache.len());
    try expectEqual(@as(usize, 2), translated.len);
    try expectEqual(@as(u32, 1), translated[0].position.line);
    try expectEqual(@as(u32, 12), translated[0].position.character);
    try expectEqual(@as(u32, 1), translated[0].textEdits.?[0].range.start.line);
    switch (translated[0].label) {
        .inlay_hint_label_parts => |parts| {
            try expectEqualStrings("file:///source.zy", parts[0].location.?.uri);
            try expectEqual(@as(u32, 1), parts[0].location.?.range.start.line);
            try expectEqual(@as(u32, 6), parts[0].location.?.range.start.character);
        },
        else => return error.UnexpectedInlayHint,
    }
}

test "translates inlay hints on first block line with source column skew" {
    const prefix = "prefix ";
    const source = prefix ++ "const answer = 42;";
    const generated = "const answer = 42;";

    var map: CodeMap = .{};
    defer map.deinit(testing_allocator);
    try map.gen_span.append(testing_allocator, .{
        .source_line = 0,
        .generated_line = 0,
        .line_count = 1,
        .generated_range = .{ .start = 0, .end = generated.len },
    });
    try map.src_range.append(testing_allocator, .{
        .start_byte = prefix.len,
        .end_byte = @intCast(source.len),
        .start_point = .{ .row = 0, .column = prefix.len },
        .end_point = .{ .row = 0, .column = @intCast(source.len) },
    });
    try map.rebuildSourceOrder(testing_allocator);

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .source_text = source,
        .generated_text = generated,
        .cache = &cache,
        .active_span_index = null,
    };
    defer context.deinit();

    const hints = [_]types.InlayHint{.{
        .position = .{ .line = 0, .character = 12 },
        .label = .{ .string = ": i32" },
        .kind = .Type,
    }};

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateInlayHints(
        arena_state.allocator(),
        &hints,
        &context,
        "file:///generated.zig",
        "file:///source.zy",
    );

    try expectEqual(@as(usize, 1), translated.len);
    try expectEqual(types.Position{ .line = 0, .character = prefix.len + 12 }, translated[0].position);
}

test "translates inlay hints with one cached diff per touched block" {
    const source =
        \\%code {
        \\const answer = 42;
        \\}
        \\%code {
        \\const other = answer;
        \\}
    ;
    const generated =
        \\// #line 2 source.zy
        \\const answer = 42;
        \\// #line 5 source.zy
        \\const other = answer;
    ;
    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(@as(usize, 2), map.len());

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .source_text = source,
        .generated_text = generated,
        .cache = &cache,
        .active_span_index = null,
    };
    defer context.deinit();

    const hints = [_]types.InlayHint{
        .{
            .position = .{ .line = 1, .character = 12 },
            .label = .{ .string = ": i32" },
            .kind = .Type,
        },
        .{
            .position = .{ .line = 3, .character = 11 },
            .label = .{ .string = ": i32" },
            .kind = .Type,
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    try expectEqual(@as(usize, 0), cache.len());
    const translated = try translateInlayHints(
        arena_state.allocator(),
        &hints,
        &context,
        "file:///generated.zig",
        "file:///source.zy",
    );

    try expectEqual(@as(usize, 2), translated.len);
    try expectEqual(@as(usize, 2), cache.len());
    try expectEqual(@as(u32, 1), translated[0].position.line);
    try expectEqual(@as(u32, 4), translated[1].position.line);
}

test "span translator cache is lazy and resets across regeneration" {
    const source =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const generated =
        \\// #line 2 source.zy
        \\const answer = 42;
    ;
    const updated_generated =
        \\// #line 2 source.zy
        \\const answer = 43;
    ;

    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);

    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);

    try expectEqual(@as(usize, 0), cache.len());
    _ = try cache.get(testing_allocator, &map, source, generated, 0);
    try expectEqual(@as(usize, 1), cache.len());

    cache.reset(testing_allocator);
    try updateCodeMapForTest(&map, source, updated_generated, "source.zy");
    try expectEqual(@as(usize, 0), cache.len());

    _ = try cache.get(testing_allocator, &map, source, updated_generated, 0);
    try expectEqual(@as(usize, 1), cache.len());
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
    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &cache,
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
    const source =
        \\%code {
        \\
        \\
        \\
        \\pub const Token = struct {
        \\    pub fn lit() void {}
        \\};
        \\}
        \\%code {
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\const yyFallback = 1;
        \\}
    ;
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
    var map = try parseCodeMapForTest(source, generated, "source.zy");
    defer map.deinit(testing_allocator);
    var cache: SpanTranslatorCache = .{};
    defer cache.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .source_text = source,
        .generated_text = generated,
        .cache = &cache,
        .active_span_index = null,
    };
    defer context.deinit();

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
        &context,
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
const log = std.log.scoped(.zig_middleware);
