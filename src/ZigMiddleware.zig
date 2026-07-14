//! Zig middleware for Zitron-produced Zig parser code.

mode: Mode,

const ZigMiddleware = @This();

const Mode = union(enum) {
    disabled,
    enabled: *Middleware,
};

const DiagnosticsPublisher = *const fn (context: *anyopaque, zy_uri: []const u8, version: i32) void;

const SemanticDirtyRange = struct {
    previous: types.Range,
    current: types.Range,
};

const max_semantic_token_snapshots = 8;

const Middleware = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    diagnostics_context: ?*anyopaque,
    diagnostics_publisher: ?DiagnosticsPublisher,
    documents_mutex: std.Io.Mutex,
    documents: std.StringHashMapUnmanaged(DocumentState),
    zls_mutex: std.Io.Mutex,
    zls_update_buffer: [max_pending_zls_updates]ZlsChangeUpdate = undefined,
    zls_updates: std.Io.Queue(ZlsChangeUpdate) = undefined,
    zls_update_worker: ?ZlsUpdateWorkerFuture = null,
    zls_updates_mutex: std.Io.Mutex = .init,
    zls_updates_changed: std.Io.Condition = .init,
    zls_updates_submitted: usize = 0,
    zls_updates_completed: usize = 0,
    zls_update_error: ?Error = null,
    zls_library: ZlsAdapter,
    zls_completion_triggers: []const []const u8,
    next_generation_id: usize,

    fn deinit(middleware: *Middleware) void {
        middleware.drainPendingZlsUpdates() catch |err| {
            log.warn("ZLS update drain failed during deinit: {}", .{err});
        };
        if (middleware.zls_update_worker) |*worker| {
            middleware.zls_updates.close(middleware.io);
            worker.await(middleware.io);
            middleware.zls_update_worker = null;
        }
        freeStringSlices(middleware.allocator, middleware.zls_completion_triggers);
        middleware.zls_library.deinit();

        middleware.documents_mutex.lockUncancelable(middleware.io);
        defer middleware.documents_mutex.unlock(middleware.io);
        var it = middleware.documents.iterator();
        while (it.next()) |entry| {
            middleware.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(middleware.allocator);
        }
        middleware.documents.deinit(middleware.allocator);
    }

    fn syncDocument(
        middleware: *Middleware,
        uri: []const u8,
        version: i32,
        zy_text: []const u8,
        zy_root: ts.Node,
    ) Error!void {
        const start = logStart(middleware.io);
        log.debug("Zig sync <- uri={s} version={} zy_bytes={}", .{ uri, version, zy_text.len });

        const generation_id = blk: {
            middleware.documents_mutex.lockUncancelable(middleware.io);
            defer middleware.documents_mutex.unlock(middleware.io);

            const gop = try middleware.documents.getOrPut(middleware.allocator, uri);
            if (!gop.found_existing) {
                errdefer _ = middleware.documents.remove(uri);
                gop.key_ptr.* = try middleware.allocator.dupe(u8, uri);
                errdefer comptime unreachable;
                gop.value_ptr.* = .{
                    .current = null,
                    .latest_requested_version = version,
                    .in_flight_version = version,
                    .opened = false,
                    .zls_synced_generation_id = null,
                    .semantic_tokens_current = null,
                    .semantic_tokens = .empty,
                    .next_semantic_tokens_result_id = 1,
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

        var zy_path = try filePathFromUri(middleware.allocator, uri);
        errdefer if (zy_path.len != 0) middleware.allocator.free(zy_path);
        var zig_uri = try zigUriForZyUri(middleware.allocator, uri);
        errdefer if (zig_uri.len != 0) middleware.allocator.free(zig_uri);
        var owned_zy_text = try middleware.allocator.dupe(u8, zy_text);
        errdefer if (owned_zy_text.len != 0) middleware.allocator.free(owned_zy_text);

        const generation_start = logStart(middleware.io);
        var generation_ns: i96 = 0;
        var diagnostics_ns: i96 = 0;
        var code_map_ns: i96 = 0;
        var publish_ns: i96 = 0;
        const z_out = runZitron(middleware.allocator, middleware.io, zy_path, zy_text) catch |err| {
            generation_ns = elapsedNs(middleware.io, generation_start);
            log.warn("Zitron generation failed for '{s}': {}", .{ zy_path, err });
            const generation_error = try middleware.allocator.dupe(u8, @errorName(err));
            errdefer middleware.allocator.free(generation_error);
            const empty_zig = try middleware.allocator.alloc(u8, 0);
            errdefer middleware.allocator.free(empty_zig);
            var generation = ZigDocument{
                .generation_id = generation_id,
                .zy_uri = try middleware.allocator.dupe(u8, uri),
                .zy_path = zy_path,
                .zy_text = owned_zy_text,
                .zig_uri = zig_uri,
                .zig_text = empty_zig,
                .code_map = .empty,
                .generation_error = generation_error,
                .grammar_diagnostics = &.{},
                .zls_diagnostics = &.{},
                .zls_diagnostics_version = null,
                .version = version,
            };
            zy_path = &.{};
            zig_uri = &.{};
            owned_zy_text = &.{};
            errdefer generation.deinit(middleware.allocator);
            const publish_start = logStart(middleware.io);
            try middleware.publishGeneration(uri, &generation, start);
            publish_ns = elapsedNs(middleware.io, publish_start);
            log.debug("Zig sync phases uri={s} version={} generation_ns={} diagnostics_ns={} code_map_ns={} publish_ns={} elapsed_ns={}", .{
                uri,
                version,
                generation_ns,
                diagnostics_ns,
                code_map_ns,
                publish_ns,
                elapsedNs(middleware.io, start),
            });
            return;
        };
        generation_ns = elapsedNs(middleware.io, generation_start);
        defer middleware.allocator.free(z_out.stderr);

        const diagnostics_start = logStart(middleware.io);
        var grammar_diagnostics = try parseZitronDiagnostics(middleware.allocator, z_out.stderr);
        diagnostics_ns = elapsedNs(middleware.io, diagnostics_start);
        errdefer if (grammar_diagnostics.len != 0) freeStoredDiagnostics(middleware.allocator, grammar_diagnostics);

        var generation_error: ?[]u8 = null;
        errdefer if (generation_error) |message| middleware.allocator.free(message);
        var zig_text: []u8 = undefined;
        var zig_text_needs_free = false;
        errdefer if (zig_text_needs_free) middleware.allocator.free(zig_text);
        var code_map: CodeMap = .empty;
        var code_map_needs_deinit = true;
        errdefer if (code_map_needs_deinit) code_map.deinit(middleware.allocator);

        if (zitronOutputFailedWithoutStdout(z_out.term, z_out.stdout.len)) {
            log.warn("Zitron generation exited unsuccessfully for '{s}': {s}", .{ zy_path, z_out.stderr });
            middleware.allocator.free(z_out.stdout);
            zig_text = try middleware.allocator.alloc(u8, 0);
            generation_error = try middleware.allocator.dupe(u8, z_out.stderr);
        } else {
            zig_text = z_out.stdout;
            zig_text_needs_free = true;
            if (zitronTermFailed(z_out.term)) {
                log.debug("Zitron generation exited with errors for '{s}' but produced stdout; publishing zig text: {s}", .{
                    zy_path,
                    z_out.stderr,
                });
            }
            log.debug("Zig sync zig uri={s} zig_bytes={} stderr_bytes={} elapsed_ns={}", .{
                uri,
                zig_text.len,
                z_out.stderr.len,
                elapsedNs(middleware.io, generation_start),
            });
            const code_map_start = logStart(middleware.io);
            try code_map.update(middleware.allocator, zy_root, zy_text, zig_text, zy_path);
            code_map_ns = elapsedNs(middleware.io, code_map_start);
            log.debug("Zig sync code-map uri={s} spans={}", .{ uri, code_map.len() });
        }

        var generation = ZigDocument{
            .generation_id = generation_id,
            .zy_uri = try middleware.allocator.dupe(u8, uri),
            .zy_path = zy_path,
            .zy_text = owned_zy_text,
            .zig_uri = zig_uri,
            .zig_text = zig_text,
            .code_map = code_map,
            .generation_error = generation_error,
            .grammar_diagnostics = grammar_diagnostics,
            .zls_diagnostics = &.{},
            .zls_diagnostics_version = null,
            .version = version,
        };
        zy_path = &.{};
        zig_uri = &.{};
        owned_zy_text = &.{};
        grammar_diagnostics = &.{};
        generation_error = null;
        zig_text_needs_free = false;
        code_map_needs_deinit = false;
        errdefer generation.deinit(middleware.allocator);
        const publish_start = logStart(middleware.io);
        try middleware.publishGeneration(uri, &generation, start);
        publish_ns = elapsedNs(middleware.io, publish_start);
        log.debug("Zig sync phases uri={s} version={} generation_ns={} diagnostics_ns={} code_map_ns={} publish_ns={} elapsed_ns={}", .{
            uri,
            version,
            generation_ns,
            diagnostics_ns,
            code_map_ns,
            publish_ns,
            elapsedNs(middleware.io, start),
        });
    }

    fn closeDocument(middleware: *Middleware, uri: []const u8) void {
        const start = logStart(middleware.io);
        log.debug("Zig close <- uri={s}", .{uri});

        middleware.drainPendingZlsUpdates() catch |err| {
            log.warn("ZLS update drain failed before close uri={s}: {}", .{ uri, err });
        };

        const removed = blk: {
            middleware.documents_mutex.lockUncancelable(middleware.io);
            defer middleware.documents_mutex.unlock(middleware.io);
            break :blk middleware.documents.fetchRemove(uri) orelse return;
        };

        middleware.allocator.free(removed.key);
        var state = removed.value;
        if (state.opened) {
            if (state.currentGeneration()) |generation| {
                middleware.syncLibraryCloseLocked(generation.zig_uri) catch |err| {
                    log.warn("ZLS library didClose failed uri={s}: {}", .{ generation.zig_uri, err });
                };
            }
        }
        state.deinit(middleware.allocator);
        log.debug("Zig close -> uri={s} elapsed_ns={}", .{ uri, elapsedNs(middleware.io, start) });
    }

    fn publishGeneration(
        middleware: *Middleware,
        uri: []const u8,
        generation: *ZigDocument,
        start: std.Io.Timestamp,
    ) Error!void {
        var notify_kind: enum { none, open, change } = .none;
        var notify_uri: []const u8 = &.{};
        var notify_version: i32 = 0;
        var notify_generation_id: usize = 0;
        var notify_text: []const u8 = &.{};
        var log_version: i32 = 0;
        var log_opened = false;
        var log_zig_bytes: usize = 0;
        var log_span_count: usize = 0;
        var log_notified = false;

        const state_start = logStart(middleware.io);
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
            if (send_to_zls) {
                if (state.opened) {
                    notify_kind = .change;
                    log_notified = true;
                } else {
                    notify_kind = .open;
                    state.opened = true;
                    log_notified = true;
                    state.zls_synced_generation_id = generation.generation_id;
                }
            }

            if (state.current) |*old| old.deinit(middleware.allocator);
            state.current = generation.*;
            state.in_flight_version = null;
            generation.* = undefined;
            const doc = state.currentForVersion(state.latest_requested_version) orelse return error.MissingZigDocument;
            log_version = doc.version;
            log_opened = state.opened;
            log_zig_bytes = doc.zig_text.len;
            log_span_count = doc.code_map.len();
            if (send_to_zls) {
                notify_uri = doc.zig_uri;
                notify_version = doc.version;
                notify_generation_id = doc.generation_id;
                notify_text = doc.zig_text;
            }
        }
        const state_ns = elapsedNs(middleware.io, state_start);

        const notify_start = logStart(middleware.io);
        switch (notify_kind) {
            .none => {},
            .change => {
                try middleware.launchZlsChangeUpdate(notify_uri, notify_version, notify_generation_id, notify_text);
            },
            .open => {
                try middleware.syncLibraryOpen(notify_uri, notify_version, notify_text);
            },
        }
        const notify_ns = elapsedNs(middleware.io, notify_start);

        log.debug("Zig sync -> uri={s} version={} opened={} zig_bytes={} spans={} elapsed_ns={}", .{
            uri,
            log_version,
            log_opened,
            log_zig_bytes,
            log_span_count,
            elapsedNs(middleware.io, start),
        });
        log.debug("Zig sync publish-phases uri={s} version={} kind={t} notified={} state_ns={} notify_ns={} elapsed_ns={}", .{
            uri,
            log_version,
            notify_kind,
            log_notified,
            state_ns,
            notify_ns,
            elapsedNs(middleware.io, start),
        });
    }

    fn forwardHover(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.HoverParams,
    ) Error!?types.Hover {
        const start = logStart(middleware.io);
        log.debug("Zig forward hover <- uri={s} zy_position={any}", .{ zy_uri, params.position });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(params.position) orelse {
            log.debug("Zig forward hover -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(params.position)) orelse {
            log.debug("Zig forward hover -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward hover mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        log.debug("Zig forward hover backend=library uri={s} zig_uri={s}", .{ zy_uri, doc.zig_uri });
        var result = try middleware.request(arena, "textDocument/hover", mapped);
        if (result) |*hover_result| try translateHover(hover_result, &translation_context);
        log.debug("Zig forward hover -> uri={s} null={} elapsed_ns={}", .{
            zy_uri,
            result == null,
            elapsedNs(middleware.io, start),
        });
        return result;
    }

    fn syncLibraryOpen(
        middleware: *Middleware,
        zig_uri: []const u8,
        version: i32,
        zig_text: []const u8,
    ) Error!void {
        try middleware.drainPendingZlsUpdates();
        try middleware.syncLibraryOpenLocked(zig_uri, version, zig_text);
    }

    fn syncLibraryOpenLocked(
        middleware: *Middleware,
        zig_uri: []const u8,
        version: i32,
        zig_text: []const u8,
    ) Error!void {
        middleware.zls_mutex.lockUncancelable(middleware.io);
        defer middleware.zls_mutex.unlock(middleware.io);

        log.debug("ZLS library <- textDocument/didOpen uri={s} version={} zig_bytes={}", .{
            zig_uri,
            version,
            zig_text.len,
        });
        try middleware.zls_library.openDocument(middleware.allocator, zig_uri, version, zig_text);
        try middleware.processCapturedZlsMessages();
    }

    fn syncLibraryChange(
        middleware: *Middleware,
        zig_uri: []const u8,
        version: i32,
        zig_text: []const u8,
    ) Error!void {
        try middleware.drainPendingZlsUpdates();
        try middleware.syncLibraryChangeLocked(zig_uri, version, zig_text);
    }

    fn syncLibraryChangeLocked(
        middleware: *Middleware,
        zig_uri: []const u8,
        version: i32,
        zig_text: []const u8,
    ) Error!void {
        middleware.zls_mutex.lockUncancelable(middleware.io);
        defer middleware.zls_mutex.unlock(middleware.io);

        log.debug("ZLS library <- textDocument/didChange uri={s} version={} zig_bytes={}", .{
            zig_uri,
            version,
            zig_text.len,
        });
        try middleware.zls_library.replaceDocument(middleware.allocator, zig_uri, version, zig_text);
        try middleware.processCapturedZlsMessages();
    }

    fn syncLibraryCloseLocked(
        middleware: *Middleware,
        zig_uri: []const u8,
    ) Error!void {
        middleware.zls_mutex.lockUncancelable(middleware.io);
        defer middleware.zls_mutex.unlock(middleware.io);

        log.debug("ZLS library <- textDocument/didClose uri={s}", .{zig_uri});
        try middleware.zls_library.closeDocument(middleware.allocator, zig_uri);
        try middleware.processCapturedZlsMessages();
    }

    fn launchZlsChangeUpdate(
        middleware: *Middleware,
        zig_uri: []const u8,
        version: i32,
        generation_id: usize,
        zig_text: []const u8,
    ) Error!void {
        if (middleware.zls_update_worker == null) {
            middleware.markZlsUpdateStarted(zig_uri, generation_id);
            try middleware.runZlsChangeUpdate(zig_uri, version, zig_text);
            return;
        }

        var update = ZlsChangeUpdate{
            .zig_uri = try middleware.allocator.dupe(u8, zig_uri),
            .version = version,
            .generation_id = generation_id,
            .zig_text = &.{},
            .sequence = 0,
        };
        errdefer update.deinit(middleware.allocator);
        update.zig_text = try middleware.allocator.dupe(u8, zig_text);

        middleware.zls_updates_mutex.lockUncancelable(middleware.io);
        middleware.zls_updates_submitted += 1;
        update.sequence = middleware.zls_updates_submitted;
        middleware.zls_updates_mutex.unlock(middleware.io);

        middleware.zls_updates.putOneUncancelable(middleware.io, update) catch unreachable;
        log.debug("ZLS update queued uri={s} version={} sequence={}", .{ zig_uri, version, update.sequence });
    }

    fn runZlsUpdateWorker(middleware: *Middleware) void {
        var batch: [max_pending_zls_updates]ZlsChangeUpdate = undefined;
        while (true) {
            batch[0] = middleware.zls_updates.getOneUncancelable(middleware.io) catch return;
            const extra_count = middleware.zls_updates.getUncancelable(middleware.io, batch[1..], 0) catch 0;
            const batch_count = extra_count + 1;

            var index: usize = 0;
            while (index < batch_count) {
                var update = batch[index];
                index += 1;
                while (index < batch_count and std.mem.eql(u8, update.zig_uri, batch[index].zig_uri)) : (index += 1) {
                    const superseded = update.version;
                    update.deinit(middleware.allocator);
                    update = batch[index];
                    log.debug("ZLS update coalesced uri={s} superseded_version={} selected_version={}", .{
                        update.zig_uri,
                        superseded,
                        update.version,
                    });
                }

                middleware.markZlsUpdateStarted(update.zig_uri, update.generation_id);
                var update_error: ?Error = null;
                middleware.runZlsChangeUpdate(update.zig_uri, update.version, update.zig_text) catch |err| {
                    update_error = err;
                };
                middleware.finishZlsUpdate(update.sequence, update_error);
                update.deinit(middleware.allocator);
            }
        }
    }

    fn markZlsUpdateStarted(middleware: *Middleware, zig_uri: []const u8, generation_id: usize) void {
        middleware.documents_mutex.lockUncancelable(middleware.io);
        defer middleware.documents_mutex.unlock(middleware.io);
        const state = middleware.documentForZigUri(zig_uri) orelse return;
        state.zls_synced_generation_id = generation_id;
    }

    fn finishZlsUpdate(middleware: *Middleware, sequence: usize, maybe_error: ?Error) void {
        middleware.zls_updates_mutex.lockUncancelable(middleware.io);
        defer middleware.zls_updates_mutex.unlock(middleware.io);
        middleware.zls_updates_completed = sequence;
        if (maybe_error) |err| {
            if (middleware.zls_update_error == null) middleware.zls_update_error = err;
        }
        middleware.zls_updates_changed.broadcast(middleware.io);
    }

    fn runZlsChangeUpdate(
        middleware: *Middleware,
        zig_uri: []const u8,
        version: i32,
        zig_text: []const u8,
    ) Error!void {
        const start = logStart(middleware.io);
        try middleware.syncLibraryChangeLocked(zig_uri, version, zig_text);
        log.debug("ZLS update async -> textDocument/didChange uri={s} version={} elapsed_ns={}", .{
            zig_uri,
            version,
            elapsedNs(middleware.io, start),
        });
    }

    fn drainPendingZlsUpdates(middleware: *Middleware) Error!void {
        if (middleware.zls_update_worker == null) return;
        const start = logStart(middleware.io);
        middleware.zls_updates_mutex.lockUncancelable(middleware.io);
        defer middleware.zls_updates_mutex.unlock(middleware.io);
        const target = middleware.zls_updates_submitted;
        var waited = false;
        while (middleware.zls_updates_completed < target) {
            waited = true;
            middleware.zls_updates_changed.waitUncancelable(middleware.io, &middleware.zls_updates_mutex);
        }
        const maybe_error = middleware.zls_update_error;
        middleware.zls_update_error = null;
        if (waited or maybe_error != null) {
            log.debug("ZLS update barrier target={} completed={} elapsed_ns={}", .{
                target,
                middleware.zls_updates_completed,
                elapsedNs(middleware.io, start),
            });
        }
        if (maybe_error) |err| return err;
    }

    fn forwardDeclaration(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.DeclarationParams,
    ) Error!lsp.ResultType("textDocument/declaration") {
        return try forwardDefinitionLike(
            "textDocument/declaration",
            "declaration",
            middleware,
            arena,
            zy_uri,
            params.textDocument,
            params.position,
            params.workDoneToken,
            params.partialResultToken,
        );
    }

    fn forwardDefinition(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.DefinitionParams,
    ) Error!lsp.ResultType("textDocument/definition") {
        return try forwardDefinitionLike(
            "textDocument/definition",
            "definition",
            middleware,
            arena,
            zy_uri,
            params.textDocument,
            params.position,
            params.workDoneToken,
            params.partialResultToken,
        );
    }

    fn forwardDefinitionLike(
        comptime method: []const u8,
        comptime label: []const u8,
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        text_document: types.TextDocumentIdentifier,
        position: types.Position,
        work_done_token: ?types.ProgressToken,
        partial_result_token: ?types.ProgressToken,
    ) Error!lsp.ResultType(method) {
        const start = logStart(middleware.io);
        log.debug("Zig forward {s} <- uri={s} zy_position={any}", .{ label, zy_uri, position });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(position) orelse {
            log.debug("Zig forward {s} -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                label,
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped: lsp.ParamsType(method) = .{
            .textDocument = text_document,
            .position = position,
            .workDoneToken = work_done_token,
            .partialResultToken = partial_result_token,
        };
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(position)) orelse {
            log.debug("Zig forward {s} -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                label,
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward {s} mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            label,
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        const result = (try middleware.request(arena, method, mapped)) orelse {
            log.debug("Zig forward {s} -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
                label,
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const translated = try translateDefinition(arena, result, &translation_context, doc.zig_uri, doc.zy_uri);
        log.debug("Zig forward {s} -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
            label,
            zy_uri,
            definitionResultCount(result),
            definitionResultCount(translated),
            translated == null,
            elapsedNs(middleware.io, start),
        });
        return translated;
    }

    fn forwardReferences(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.ReferenceParams,
    ) Error!lsp.ResultType("textDocument/references") {
        const start = logStart(middleware.io);
        log.debug("Zig forward references <- uri={s} zy_position={any} include_declaration={}", .{
            zy_uri,
            params.position,
            params.context.includeDeclaration,
        });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(params.position) orelse {
            log.debug("Zig forward references -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(params.position)) orelse {
            log.debug("Zig forward references -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward references mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        const result = (try middleware.request(arena, "textDocument/references", mapped)) orelse {
            log.debug("Zig forward references -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const translated = try translateLocations(arena, result, &translation_context, doc.zig_uri, doc.zy_uri);
        log.debug("Zig forward references -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
            zy_uri,
            result.len,
            if (translated) |locations| locations.len else 0,
            translated == null,
            elapsedNs(middleware.io, start),
        });
        return translated;
    }

    fn forwardDocumentHighlight(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.DocumentHighlightParams,
    ) Error!lsp.ResultType("textDocument/documentHighlight") {
        const start = logStart(middleware.io);
        log.debug("Zig forward documentHighlight <- uri={s} zy_position={any}", .{ zy_uri, params.position });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(params.position) orelse {
            log.debug("Zig forward documentHighlight -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(params.position)) orelse {
            log.debug("Zig forward documentHighlight -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward documentHighlight mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        const result = (try middleware.request(arena, "textDocument/documentHighlight", mapped)) orelse {
            log.debug("Zig forward documentHighlight -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const translated = try translateDocumentHighlights(arena, result, &translation_context);
        log.debug("Zig forward documentHighlight -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
            zy_uri,
            result.len,
            if (translated) |highlights| highlights.len else 0,
            translated == null,
            elapsedNs(middleware.io, start),
        });
        return translated;
    }

    fn forwardCompletion(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.CompletionParams,
    ) Error!lsp.ResultType("textDocument/completion") {
        const start = logStart(middleware.io);
        log.debug("Zig forward completion <- uri={s} zy_position={any}", .{ zy_uri, params.position });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(params.position) orelse {
            log.debug("Zig forward completion -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(params.position)) orelse {
            log.debug("Zig forward completion -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward completion mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        var result = try middleware.request(arena, "textDocument/completion", mapped);
        const zls_count = completionResultCount(result);
        try translateCompletionResult(arena, &result, &translation_context);
        log.debug("Zig forward completion -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
            zy_uri,
            zls_count,
            completionResultCount(result),
            result == null,
            elapsedNs(middleware.io, start),
        });
        return result;
    }

    fn forwardSignatureHelp(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.SignatureHelpParams,
    ) Error!lsp.ResultType("textDocument/signatureHelp") {
        const start = logStart(middleware.io);
        log.debug("Zig forward signatureHelp <- uri={s} zy_position={any}", .{ zy_uri, params.position });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(params.position) orelse {
            log.debug("Zig forward signatureHelp -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(params.position)) orelse {
            log.debug("Zig forward signatureHelp -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward signatureHelp mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        const result = try middleware.request(arena, "textDocument/signatureHelp", mapped);
        log.debug("Zig forward signatureHelp -> uri={s} result_count={} null={} elapsed_ns={}", .{
            zy_uri,
            if (result) |help| help.signatures.len else 0,
            result == null,
            elapsedNs(middleware.io, start),
        });
        return result;
    }

    fn forwardInlayHint(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.InlayHintParams,
    ) Error!lsp.ResultType("textDocument/inlayHint") {
        const start = logStart(middleware.io);
        log.debug("Zig forward inlayHint <- uri={s} zy_range={any}", .{ zy_uri, params.range });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        var mapped_range: ?types.Range = null;
        var active_span_index: ?usize = null;
        var spans_scanned: usize = 0;
        var spans_intersected: usize = 0;

        var zy_order_index = code_map.firstZyIndexPossiblyIntersecting(params.range);
        while (zy_order_index < code_map.zy_order.items.len) : (zy_order_index += 1) {
            spans_scanned += 1;
            const span_index = code_map.zy_order.items[zy_order_index];
            const zy_range = zyRangeFromTsRange(code_map.zy_range.items[span_index]);
            if (!positionLessThan(zy_range.start, params.range.end)) break;

            const request_range = rangeIntersection(params.range, zy_range) orelse continue;
            spans_intersected += 1;
            const mapped_start = code_map.zyPositionToZigInSpanFromText(span_index, doc.zy_text, request_range.start);
            const mapped_end = code_map.zyPositionToZigInSpanFromText(span_index, doc.zy_text, request_range.end);
            mapped_range = rangeUnion(mapped_range, .{
                .start = mapped_start,
                .end = mapped_end,
            });
            active_span_index = active_span_index orelse span_index;
        }

        const resolved_range = mapped_range orelse {
            log.debug("Zig forward inlayHint -> uri={s} result=null reason=unmapped_range spans_scanned={} spans_intersected={} elapsed_ns={}", .{
                zy_uri,
                spans_scanned,
                spans_intersected,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const resolved_active_span_index = active_span_index orelse {
            log.debug("Zig forward inlayHint -> uri={s} result=null reason=no_active_span spans_scanned={} spans_intersected={} elapsed_ns={}", .{
                zy_uri,
                spans_scanned,
                spans_intersected,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.range = resolved_range;
        log.debug("Zig forward inlayHint mapped uri={s} zig_uri={s} zy_range={any} zig_range={any} spans_scanned={} spans_intersected={} active_span={}", .{
            zy_uri,
            doc.zig_uri,
            params.range,
            resolved_range,
            spans_scanned,
            spans_intersected,
            resolved_active_span_index,
        });

        const result = (try middleware.request(arena, "textDocument/inlayHint", mapped)) orelse {
            log.debug("Zig forward inlayHint -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        if (result.len == 0) {
            log.debug("Zig forward inlayHint -> uri={s} result=null reason=zls_empty elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        }
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = resolved_active_span_index,
        };
        defer translation_context.deinit();

        const translated = try translateInlayHints(arena, result, &translation_context, doc.zig_uri, doc.zy_uri);
        log.debug("Zig forward inlayHint -> uri={s} zls_count={} translated_count={} dropped_count={} elapsed_ns={}", .{
            zy_uri,
            result.len,
            translated.len,
            result.len - translated.len,
            elapsedNs(middleware.io, start),
        });
        return if (translated.len == 0) null else translated;
    }

    fn forwardDocumentSymbols(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
    ) Error!?[]const types.DocumentSymbol {
        const start = logStart(middleware.io);
        log.debug("Zig forward documentSymbol <- uri={s}", .{zy_uri});
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const request_result = try middleware.request(arena, "textDocument/documentSymbol", .{
            .textDocument = .{ .uri = doc.zig_uri },
        });
        const result = request_result orelse {
            log.debug("Zig forward documentSymbol -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = null,
        };
        defer translation_context.deinit();
        const translated = try translateDocumentSymbols(arena, result, &translation_context);
        log.debug("Zig forward documentSymbol -> uri={s} zls_count={} translated_count={} null={} elapsed_ns={}", .{
            zy_uri,
            documentSymbolResultCount(request_result),
            if (translated) |symbols| symbols.len else 0,
            translated == null,
            elapsedNs(middleware.io, start),
        });
        return translated;
    }

    fn forwardSemanticTokensFull(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.SemanticTokensParams,
    ) Error!lsp.ResultType("textDocument/semanticTokens/full") {
        const start = logStart(middleware.io);
        log.debug("Zig forward semanticTokens/full <- uri={s}", .{zy_uri});
        const current = (try middleware.ensureSemanticTokensCurrent(arena, zy_uri, .{
            .textDocument = params.textDocument,
            .workDoneToken = params.workDoneToken,
            .partialResultToken = params.partialResultToken,
        })) orelse return null;
        const zy_result_id = try middleware.storeSemanticTokensSnapshotFromCurrent(zy_uri, current);

        log.debug("Zig forward semanticTokens/full -> uri={s} route=current token_count={} elapsed_ns={}", .{
            zy_uri,
            current.zy_data.len / 5,
            elapsedNs(middleware.io, start),
        });
        return .{
            .resultId = zy_result_id,
            .data = current.zy_data,
        };
    }

    fn forwardSemanticTokensFullDelta(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.SemanticTokensDeltaParams,
    ) Error!lsp.ResultType("textDocument/semanticTokens/full/delta") {
        const start = logStart(middleware.io);
        log.debug("Zig forward semanticTokens/full/delta <- uri={s} previous={s}", .{ zy_uri, params.previousResultId });
        const current = (try middleware.ensureSemanticTokensCurrent(arena, zy_uri, .{
            .textDocument = params.textDocument,
            .workDoneToken = params.workDoneToken,
            .partialResultToken = params.partialResultToken,
        })) orelse return null;
        const snapshot = middleware.semanticTokensSnapshot(zy_uri, params.previousResultId) orelse {
            const zy_result_id = try middleware.storeSemanticTokensSnapshotFromCurrent(zy_uri, current);
            log.debug("Zig forward semanticTokens/full/delta -> uri={s} route=current_full reason=unknown_previous token_count={} elapsed_ns={}", .{
                zy_uri,
                current.zy_data.len / 5,
                elapsedNs(middleware.io, start),
            });
            return .{ .semantic_tokens = .{
                .resultId = zy_result_id,
                .data = current.zy_data,
            } };
        };

        const zy_edits = try semanticTokenDeltaEdits(arena, snapshot.zy_data, current.zy_data);
        const zy_result_id = try middleware.storeSemanticTokensSnapshotFromCurrent(zy_uri, current);
        log.debug("Zig forward semanticTokens/full/delta -> uri={s} route=current_delta zy_edits={} elapsed_ns={}", .{
            zy_uri,
            zy_edits.len,
            elapsedNs(middleware.io, start),
        });
        return .{ .semantic_tokens_delta = .{
            .resultId = zy_result_id,
            .edits = zy_edits,
        } };
    }

    fn forwardSemanticTokensRange(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.SemanticTokensRangeParams,
    ) Error!lsp.ResultType("textDocument/semanticTokens/range") {
        const start = logStart(middleware.io);
        log.debug("Zig forward semanticTokens/range <- uri={s} zy_range={any}", .{ zy_uri, params.range });
        const current = (try middleware.ensureSemanticTokensCurrent(arena, zy_uri, .{
            .textDocument = params.textDocument,
            .workDoneToken = params.workDoneToken,
            .partialResultToken = params.partialResultToken,
        })) orelse return null;
        const range_data = try semanticTokenDataForRange(arena, current.zy_index, params.range);

        log.debug("Zig forward semanticTokens/range -> uri={s} route=current token_count={} elapsed_ns={}", .{
            zy_uri,
            range_data.len / 5,
            elapsedNs(middleware.io, start),
        });
        return .{
            .resultId = null,
            .data = range_data,
        };
    }

    fn forwardRename(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.RenameParams,
    ) Error!lsp.ResultType("textDocument/rename") {
        const start = logStart(middleware.io);
        log.debug("Zig forward rename <- uri={s} zy_position={any} new_name_len={}", .{
            zy_uri,
            params.position,
            params.newName.len,
        });
        const doc = try middleware.documentReady(zy_uri);
        const code_map = &doc.code_map;
        const span_index = code_map.zySpanIndexForPosition(params.position) orelse {
            log.debug("Zig forward rename -> uri={s} result=null reason=unmapped_zy elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = span_index,
        };
        defer translation_context.deinit();

        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        mapped.position = (try translation_context.zyPositionToZig(params.position)) orelse {
            log.debug("Zig forward rename -> uri={s} result=null reason=mutated_zy span={} elapsed_ns={}", .{
                zy_uri,
                span_index,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        log.debug("Zig forward rename mapped uri={s} zig_uri={s} span={} zig_position={any}", .{
            zy_uri,
            doc.zig_uri,
            span_index,
            mapped.position,
        });

        const result = (try middleware.request(arena, "textDocument/rename", mapped)) orelse {
            log.debug("Zig forward rename -> uri={s} result=null reason=zls_null elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const translated = try translateWorkspaceEdit(arena, result, &translation_context, doc.zig_uri, doc.zy_uri);
        log.debug("Zig forward rename -> uri={s} zls_edit_count={} translated_edit_count={} null={} elapsed_ns={}", .{
            zy_uri,
            workspaceEditCount(result),
            if (translated) |edit| workspaceEditCount(edit) else 0,
            translated == null,
            elapsedNs(middleware.io, start),
        });
        return translated;
    }

    fn semanticTokensSnapshot(
        middleware: *Middleware,
        zy_uri: []const u8,
        zy_result_id: []const u8,
    ) ?*SemanticTokensSnapshot {
        const state = middleware.documents.getPtr(zy_uri) orelse return null;
        for (state.semantic_tokens.items, 0..) |*snapshot, index| {
            if (std.mem.eql(u8, snapshot.zy_result_id, zy_result_id)) {
                if (index != state.semantic_tokens.items.len - 1) {
                    const touched = state.semantic_tokens.orderedRemove(index);
                    state.semantic_tokens.appendAssumeCapacity(touched);
                }
                return &state.semantic_tokens.items[state.semantic_tokens.items.len - 1];
            }
        }
        return null;
    }

    fn storeSemanticTokensSnapshotOwned(
        middleware: *Middleware,
        zy_uri: []const u8,
        owned_zy_data: []u32,
    ) OOM![]const u8 {
        const state = middleware.documents.getPtr(zy_uri) orelse unreachable;
        errdefer middleware.allocator.free(owned_zy_data);

        const zy_result_id = try std.fmt.allocPrint(
            middleware.allocator,
            "lsp-zitron-semantic-{d}",
            .{state.next_semantic_tokens_result_id},
        );
        errdefer middleware.allocator.free(zy_result_id);
        state.next_semantic_tokens_result_id += 1;

        const snapshot = SemanticTokensSnapshot{
            .zy_result_id = zy_result_id,
            .zy_data = owned_zy_data,
        };
        try state.semantic_tokens.append(middleware.allocator, snapshot);
        while (state.semantic_tokens.items.len > max_semantic_token_snapshots) {
            var old = state.semantic_tokens.orderedRemove(0);
            old.deinit(middleware.allocator);
        }
        return zy_result_id;
    }

    fn translateSemanticTokensForDocument(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        doc: *ZigDocument,
        data: []u32,
    ) Error![]const u32 {
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = &doc.code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = null,
        };
        defer translation_context.deinit();
        return try translateSemanticTokenData(arena, data, &translation_context);
    }

    fn translateSemanticTokenRangeForDocument(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        doc: *ZigDocument,
        data: []u32,
    ) Error![]const u32 {
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = &doc.code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = null,
        };
        defer translation_context.deinit();
        return try translateSemanticTokenRangeData(arena, data, &translation_context);
    }

    fn translateSemanticTokenRangeForDocumentFiltered(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        doc: *ZigDocument,
        data: []const u32,
        requested_zig_range: types.Range,
        replacement_zy_range: types.Range,
    ) Error!FilteredSemanticTokens {
        var translation_context = RequestTranslationContext{
            .allocator = middleware.allocator,
            .map = &doc.code_map,
            .document_version = doc.version,
            .zy_text = doc.zy_text,
            .zig_text = doc.zig_text,
            .active_span_index = null,
        };
        defer translation_context.deinit();
        return try translateSemanticTokenRangeDataFiltered(
            arena,
            data,
            &translation_context,
            requested_zig_range,
            replacement_zy_range,
        );
    }

    fn ensureSemanticTokensCurrent(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        params: types.SemanticTokensParams,
    ) Error!?*const SemanticTokenCollection {
        const doc = try middleware.documentReady(zy_uri);
        const state = middleware.documents.getPtr(zy_uri) orelse return error.MissingZigDocument;
        if (state.semantic_tokens_current) |*current| {
            if (current.version == doc.version) return current;
            try middleware.updateSemanticTokensCurrent(arena, zy_uri, doc, current, null);
            return &(middleware.documents.getPtr(zy_uri).?.semantic_tokens_current.?);
        }
        return try middleware.initSemanticTokensCurrent(arena, zy_uri, doc, params);
    }

    fn initSemanticTokensCurrent(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        doc: *ZigDocument,
        params: types.SemanticTokensParams,
    ) Error!?*const SemanticTokenCollection {
        const start = logStart(middleware.io);
        var mapped = params;
        mapped.textDocument = .{ .uri = doc.zig_uri };
        const result = (try middleware.requestZlsLocked(arena, "textDocument/semanticTokens/full", mapped)) orelse {
            log.debug("Zig semantic current init_full uri={s} result=null reason=zls_null elapsed_ns={}", .{
                zy_uri,
                elapsedNs(middleware.io, start),
            });
            return null;
        };
        const translated_data = try middleware.translateSemanticTokenRangeForDocument(arena, doc, @constCast(result.data));
        const owned_zy_data = try middleware.allocator.dupe(u32, translated_data);
        errdefer middleware.allocator.free(owned_zy_data);
        const current = try middleware.replaceSemanticTokensCurrentOwned(zy_uri, doc, owned_zy_data, null);
        log.debug("Zig semantic current init_full uri={s} zls_tokens={} translated_tokens={} elapsed_ns={}", .{
            zy_uri,
            result.data.len / 5,
            translated_data.len / 5,
            elapsedNs(middleware.io, start),
        });
        return current;
    }

    fn updateSemanticTokensCurrent(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        doc: *ZigDocument,
        current: *const SemanticTokenCollection,
        maybe_dirty: ?SemanticDirtyRange,
    ) Error!void {
        if (std.mem.eql(u8, doc.zig_text, current.zig_text)) {
            try middleware.updateSemanticTokensCurrentWithoutZigChange(zy_uri, doc, current, maybe_dirty);
            return;
        }

        const start = logStart(middleware.io);
        const dirty = maybe_dirty orelse
            (try semanticDirtyRangeFromDiff(arena, current.zy_text, doc.zy_text)) orelse
            fullSemanticDirtyRange(current.zy_text, doc.zy_text);
        const current_zy_range = expandSemanticDirtyRange(dirty.current);
        var route: enum { update_range, update_whole_range } = .update_range;
        const map_start = logStart(middleware.io);
        const dirty_zig_ranges_owned = try zyRangeToSortedZigRanges(
            middleware.allocator,
            &doc.code_map,
            doc.version,
            doc.zy_text,
            doc.zig_text,
            current_zy_range,
        );
        defer middleware.allocator.free(dirty_zig_ranges_owned);

        var fallback_zig_ranges = [_]types.Range{fullDocumentRange(doc.zig_text)};
        const dirty_zig_ranges = if (dirty_zig_ranges_owned.len == 0) blk: {
            route = .update_whole_range;
            break :blk fallback_zig_ranges[0..];
        } else dirty_zig_ranges_owned;
        var zig_range = dirty_zig_ranges[0];
        for (dirty_zig_ranges[1..]) |range| {
            zig_range = rangeUnion(zig_range, range);
        }
        const map_ns = elapsedNs(middleware.io, map_start);

        const mapped: types.SemanticTokensRangeParams = .{
            .textDocument = .{ .uri = doc.zig_uri },
            .range = zig_range,
            .workDoneToken = null,
            .partialResultToken = null,
        };
        const zls_start = logStart(middleware.io);
        const range_result = (try middleware.requestZlsLocked(arena, "textDocument/semanticTokens/range", mapped)) orelse {
            log.debug("Zig semantic current {t} uri={s} result=null reason=zls_range_null map_ns={} zls_ns={} elapsed_ns={}", .{
                route,
                zy_uri,
                map_ns,
                elapsedNs(middleware.io, zls_start),
                elapsedNs(middleware.io, start),
            });
            return error.RequestFailed;
        };
        const zls_ns = elapsedNs(middleware.io, zls_start);
        const filter_translate_start = logStart(middleware.io);
        const current_range_tokens = middleware.translateSemanticTokenRangeForDocumentFiltered(
            arena,
            doc,
            range_result.data,
            zig_range,
            current_zy_range,
        ) catch |err| switch (err) {
            error.UnexpectedResponse => {
                log.debug("Zig semantic current {t} uri={s} result=null reason=range_translate_unexpected map_ns={} zls_ns={} filter_translate_ns={} elapsed_ns={}", .{
                    route,
                    zy_uri,
                    map_ns,
                    zls_ns,
                    elapsedNs(middleware.io, filter_translate_start),
                    elapsedNs(middleware.io, start),
                });
                return error.RequestFailed;
            },
            else => return err,
        };
        const filter_translate_ns = elapsedNs(middleware.io, filter_translate_start);
        const rebuild_start = logStart(middleware.io);
        var rebuilt = try rebuildSemanticTokensFromRange(
            middleware.allocator,
            current.zy_index,
            dirty,
            current_zy_range,
            current_range_tokens.data,
        );
        errdefer rebuilt.deinit(middleware.allocator);
        const rebuild_ns = elapsedNs(middleware.io, rebuild_start);
        const store_start = logStart(middleware.io);
        _ = try middleware.replaceSemanticTokensCurrentOwned(zy_uri, doc, rebuilt.data, rebuilt.index);
        const store_ns = elapsedNs(middleware.io, store_start);
        log.debug("Zig semantic current {t} uri={s} zig_ranges={} zig_start={}:{} zig_end={}:{} zls_tokens={} scanned_tokens={} translated_tokens={} map_ns={} zls_ns={} filter_translate_ns={} rebuild_ns={} store_ns={} elapsed_ns={}", .{
            route,
            zy_uri,
            dirty_zig_ranges.len,
            zig_range.start.line,
            zig_range.start.character,
            zig_range.end.line,
            zig_range.end.character,
            range_result.data.len / 5,
            current_range_tokens.scanned_count,
            current_range_tokens.translated_count,
            map_ns,
            zls_ns,
            filter_translate_ns,
            rebuild_ns,
            store_ns,
            elapsedNs(middleware.io, start),
        });
    }

    fn updateSemanticTokensCurrentWithoutZigChange(
        middleware: *Middleware,
        zy_uri: []const u8,
        doc: *ZigDocument,
        current: *const SemanticTokenCollection,
        maybe_dirty: ?SemanticDirtyRange,
    ) Error!void {
        const start = logStart(middleware.io);
        const dirty = maybe_dirty orelse
            (try semanticDirtyRangeFromDiff(middleware.allocator, current.zy_text, doc.zy_text));
        const current_zy_data = if (dirty) |range|
            try rebuildSemanticTokenDataWithoutZigChange(middleware.allocator, current.zy_index, range)
        else
            try middleware.allocator.dupe(u32, current.zy_data);
        errdefer middleware.allocator.free(current_zy_data);
        _ = try middleware.replaceSemanticTokensCurrentOwned(zy_uri, doc, current_zy_data, null);
        log.debug("Zig semantic current update_no_zig_change uri={s} token_count={} elapsed_ns={}", .{
            zy_uri,
            current_zy_data.len / 5,
            elapsedNs(middleware.io, start),
        });
    }

    fn replaceSemanticTokensCurrentOwned(
        middleware: *Middleware,
        zy_uri: []const u8,
        doc: *ZigDocument,
        owned_zy_data: []u32,
        owned_zy_index: ?[]AbsoluteSemanticToken,
    ) OOM!*const SemanticTokenCollection {
        const state = middleware.documents.getPtr(zy_uri) orelse unreachable;
        const replacement = if (owned_zy_index) |index|
            try SemanticTokenCollection.initOwnedWithIndex(
                middleware.allocator,
                doc.version,
                doc.zy_text,
                doc.zig_text,
                owned_zy_data,
                index,
            )
        else
            try SemanticTokenCollection.initOwned(
                middleware.allocator,
                doc.version,
                doc.zy_text,
                doc.zig_text,
                owned_zy_data,
            );
        errdefer comptime unreachable;
        if (state.semantic_tokens_current) |*old| old.deinit(middleware.allocator);
        state.semantic_tokens_current = replacement;
        return &(state.semantic_tokens_current.?);
    }

    fn storeSemanticTokensSnapshotFromCurrent(
        middleware: *Middleware,
        zy_uri: []const u8,
        current: *const SemanticTokenCollection,
    ) OOM![]const u8 {
        var owned_by_store = false;
        const owned_zy_data = try middleware.allocator.dupe(u32, current.zy_data);
        errdefer if (!owned_by_store) middleware.allocator.free(owned_zy_data);
        owned_by_store = true;
        return try middleware.storeSemanticTokensSnapshotOwned(zy_uri, owned_zy_data);
    }

    fn aliasCodeBlockRenameEdits(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        zy_uri: []const u8,
        alias_name: []const u8,
        new_name: []const u8,
        zy_ranges: []const ts.Range,
        offset_encoding: lsp.offsets.Encoding,
    ) Error!?[]const types.TextEdit {
        const start = logStart(middleware.io);
        log.debug("Zig alias rename <- uri={s} ranges={} alias_len={} new_name_len={}", .{
            zy_uri,
            zy_ranges.len,
            alias_name.len,
            new_name.len,
        });
        const doc = try middleware.documentReady(zy_uri);
        var edits: std.ArrayList(types.TextEdit) = .empty;
        errdefer edits.deinit(arena);
        var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer seen_starts.deinit(arena);

        for (zy_ranges) |zy_range| {
            const span_index = doc.code_map.indexForZyRange(zy_range) orelse {
                log.debug("Zig alias rename -> uri={s} result=null reason=unmapped_zy_range elapsed_ns={}", .{
                    zy_uri,
                    elapsedNs(middleware.io, start),
                });
                return null;
            };
            const translator = try doc.code_map.spanTranslator(
                middleware.allocator,
                doc.version,
                doc.zy_text,
                doc.zig_text,
                span_index,
            );

            try appendAliasRenameEditsFromDiff(
                arena,
                &edits,
                &seen_starts,
                doc.zy_text,
                zy_range,
                doc.zig_text,
                doc.code_map.zig_span.items[span_index].zig_range,
                translator.diffEdits(),
                alias_name,
                new_name,
                offset_encoding,
            );
        }

        const result = try edits.toOwnedSlice(arena);
        log.debug("Zig alias rename -> uri={s} edit_count={} elapsed_ns={}", .{
            zy_uri,
            result.len,
            elapsedNs(middleware.io, start),
        });
        return result;
    }

    fn request(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        comptime method: []const u8,
        params: lsp.ParamsType(method),
    ) Error!lsp.ResultType(method) {
        try middleware.drainPendingZlsUpdates();
        return try middleware.requestZlsLocked(arena, method, params);
    }

    fn requestZlsLocked(
        middleware: *Middleware,
        arena: std.mem.Allocator,
        comptime method: []const u8,
        params: lsp.ParamsType(method),
    ) Error!lsp.ResultType(method) {
        middleware.zls_mutex.lockUncancelable(middleware.io);
        defer middleware.zls_mutex.unlock(middleware.io);

        const start = logStart(middleware.io);
        log.debug("ZLS library <- {s}", .{method});
        const result = try middleware.zls_library.request(arena, method, params);
        try middleware.processCapturedZlsMessages();
        log.debug("ZLS library -> {s} elapsed_ns={}", .{
            method,
            elapsedNs(middleware.io, start),
        });
        return result;
    }

    fn processCapturedZlsMessages(middleware: *Middleware) Error!void {
        const messages = try middleware.zls_library.drainCapturedMessages(middleware.allocator);
        defer middleware.allocator.free(messages);

        for (messages) |json_message| {
            const consumed = middleware.handleZlsMessage(json_message) catch |err| blk: {
                log.warn("ZLS library message ignored: {}", .{err});
                break :blk false;
            };
            if (!consumed) middleware.allocator.free(json_message);
        }
    }

    fn documentReady(middleware: *Middleware, zy_uri: []const u8) Error!*ZigDocument {
        try middleware.drainPendingZlsUpdates();
        const state = middleware.documents.getPtr(zy_uri) orelse return error.MissingZigDocument;
        const doc = state.currentGeneration() orelse return error.MissingZigDocument;
        if (doc.generation_error != null) return error.RequestFailed;
        return doc;
    }

    fn documentForZigUri(middleware: *Middleware, zig_uri: []const u8) ?*DocumentState {
        var it = middleware.documents.iterator();
        while (it.next()) |entry| {
            const current = entry.value_ptr.current orelse continue;
            if (std.mem.eql(u8, current.zig_uri, zig_uri)) return entry.value_ptr;
        }
        return null;
    }

    fn handleZlsDiagnostics(
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

        const state = middleware.documentForZigUri(params.uri) orelse {
            log.debug("ZLS diagnostics ignored uri={s} reason=unknown_zig_uri count={}", .{
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
        log.debug("ZLS diagnostics stored zy_uri={s} zig_uri={s} zls_version={?} current_version={} zls_count={} translated_count={}", .{
            doc.zy_uri,
            doc.zig_uri,
            params.version,
            doc.version,
            params.diagnostics.len,
            doc.zls_diagnostics.len,
        });
        for (doc.zls_diagnostics, 0..) |diagnostic, index| {
            if (index >= 3) break;
            log.debug("ZLS diagnostic detail zy_uri={s} index={} range={any} severity={?} message={s}", .{
                doc.zy_uri,
                index,
                diagnostic.range,
                diagnostic.severity,
                diagnostic.message,
            });
        }
        return .{
            .zy_uri = try middleware.allocator.dupe(u8, doc.zy_uri),
            .version = doc.version,
        };
    }

    fn handleZlsMessage(middleware: *Middleware, json_message: []u8) Error!bool {
        log.debug("ZLS read message bytes={}", .{json_message.len});
        const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, middleware.allocator, json_message, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        switch (parsed.value) {
            .response => |response| {
                log.debug("ZLS ignored captured response id={?}", .{response.id});
                return false;
            },
            .request => |zls_request| {
                log.debug("ZLS ignored request method={s}", .{zls_request.method});
                return false;
            },
            .notification => |notification| {
                if (std.mem.eql(u8, notification.method, "textDocument/publishDiagnostics")) {
                    if (try middleware.handleZlsDiagnostics(notification.params)) |published| {
                        if (middleware.diagnostics_context) |context| {
                            if (middleware.diagnostics_publisher) |publisher| {
                                publisher(context, published.zy_uri, published.version);
                            }
                        }
                        middleware.allocator.free(published.zy_uri);
                    }
                } else {
                    log.debug("ZLS ignored notification method={s}", .{notification.method});
                }
                return false;
            },
        }
    }
};

const PublishedDiagnostics = struct {
    zy_uri: []u8,
    version: i32,
};

pub const Error =
    OOM ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    std.process.RunError ||
    ZlsAdapter.Error ||
    lsp.Transport.WriteError ||
    JsonParseError ||
    error{
        ChildProcessFailed,
        MissingZigDocument,
        RequestFailed,
        UnexpectedResponse,
        UnsupportedUri,
    };

const max_pending_zls_updates = 64;
const ZlsUpdateWorkerFuture = std.Io.Future(void);

const ZlsChangeUpdate = struct {
    zig_uri: []u8,
    version: i32,
    generation_id: usize,
    zig_text: []u8,
    sequence: usize,

    fn deinit(update: *ZlsChangeUpdate, allocator: std.mem.Allocator) void {
        allocator.free(update.zig_uri);
        allocator.free(update.zig_text);
    }
};

const ZigDocument = struct {
    generation_id: usize,
    zy_uri: []u8,
    zy_path: []u8,
    zy_text: []const u8,
    zig_uri: []u8,
    zig_text: []u8,
    code_map: CodeMap,
    generation_error: ?[]u8,
    grammar_diagnostics: []types.Diagnostic,
    zls_diagnostics: []types.Diagnostic,
    zls_diagnostics_version: ?i32,
    version: i32,

    fn deinit(doc: *ZigDocument, allocator: std.mem.Allocator) void {
        allocator.free(doc.zy_uri);
        allocator.free(doc.zy_path);
        allocator.free(doc.zy_text);
        allocator.free(doc.zig_uri);
        allocator.free(doc.zig_text);
        doc.code_map.deinit(allocator);
        if (doc.generation_error) |message| allocator.free(message);
        freeStoredDiagnostics(allocator, doc.grammar_diagnostics);
        freeStoredDiagnostics(allocator, doc.zls_diagnostics);
    }
};

const DocumentState = struct {
    current: ?ZigDocument,
    latest_requested_version: i32,
    in_flight_version: ?i32,
    opened: bool,
    zls_synced_generation_id: ?usize,
    semantic_tokens_current: ?SemanticTokenCollection,
    semantic_tokens: std.ArrayListUnmanaged(SemanticTokensSnapshot),
    next_semantic_tokens_result_id: usize,

    fn currentGeneration(state: *DocumentState) ?*ZigDocument {
        return &(state.current orelse return null);
    }

    fn currentForVersion(state: *DocumentState, version: ?i32) ?*ZigDocument {
        const current = state.currentGeneration() orelse return null;
        if (version) |value| {
            if (current.version != value) return null;
        } else {
            if (state.in_flight_version != null) return null;
            if (state.zls_synced_generation_id != current.generation_id) return null;
        }
        return current;
    }

    fn deinit(state: *DocumentState, allocator: std.mem.Allocator) void {
        if (state.current) |*current| current.deinit(allocator);
        if (state.semantic_tokens_current) |*semantic_tokens_current| semantic_tokens_current.deinit(allocator);
        for (state.semantic_tokens.items) |*semantic_tokens| semantic_tokens.deinit(allocator);
        state.semantic_tokens.deinit(allocator);
    }
};

const SemanticTokenCollection = struct {
    version: i32,
    zy_text: []u8,
    zig_text: []u8,
    zy_data: []u32,
    zy_index: []AbsoluteSemanticToken,

    fn initOwned(
        allocator: std.mem.Allocator,
        version: i32,
        zy_text: []const u8,
        zig_text: []const u8,
        owned_zy_data: []u32,
    ) OOM!SemanticTokenCollection {
        errdefer allocator.free(owned_zy_data);
        const owned_zy_index = try semanticTokenIndexFromData(allocator, owned_zy_data);
        errdefer allocator.free(owned_zy_index);
        return initOwnedWithIndex(
            allocator,
            version,
            zy_text,
            zig_text,
            owned_zy_data,
            owned_zy_index,
        );
    }

    fn initOwnedWithIndex(
        allocator: std.mem.Allocator,
        version: i32,
        zy_text: []const u8,
        zig_text: []const u8,
        owned_zy_data: []u32,
        owned_zy_index: []AbsoluteSemanticToken,
    ) OOM!SemanticTokenCollection {
        const owned_zy_text = try allocator.dupe(u8, zy_text);
        errdefer allocator.free(owned_zy_text);
        const owned_zig_text = try allocator.dupe(u8, zig_text);
        errdefer allocator.free(owned_zig_text);
        return .{
            .version = version,
            .zy_text = owned_zy_text,
            .zig_text = owned_zig_text,
            .zy_data = owned_zy_data,
            .zy_index = owned_zy_index,
        };
    }

    fn deinit(collection: *SemanticTokenCollection, allocator: std.mem.Allocator) void {
        allocator.free(collection.zy_text);
        allocator.free(collection.zig_text);
        allocator.free(collection.zy_data);
        allocator.free(collection.zy_index);
    }
};

const SemanticTokensSnapshot = struct {
    zy_result_id: []u8,
    zy_data: []u32,

    fn deinit(snapshot: *SemanticTokensSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(snapshot.zy_result_id);
        allocator.free(snapshot.zy_data);
    }
};

pub const disabled: ZigMiddleware = .{ .mode = .disabled };

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Error!ZigMiddleware {
    return initImpl(io, allocator, environ_map) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn("Zig middleware disabled: {}", .{err});
            return .disabled;
        },
    };
}

fn initImpl(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Error!ZigMiddleware {
    log.info("Starting ZLS middleware", .{});
    try checkZitron(allocator, io);

    var zls_library = try ZlsAdapter.initFromEnvironmentMap(io, allocator, environ_map);
    errdefer zls_library.deinit();
    const zls_completion_triggers = try dupeStringSlices(allocator, zls_library.completionTriggerCharacters());
    errdefer freeStringSlices(allocator, zls_completion_triggers);

    const mware = try allocator.create(Middleware);
    errdefer comptime unreachable;
    mware.* = .{
        .allocator = allocator,
        .io = io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = zls_library,
        .zls_completion_triggers = zls_completion_triggers,
        .next_generation_id = 1,
    };
    mware.zls_updates = .init(&mware.zls_update_buffer);
    mware.zls_update_worker = std.Io.concurrent(io, Middleware.runZlsUpdateWorker, .{mware}) catch |err| blk: {
        log.debug("ZLS update worker unavailable reason={}", .{err});
        break :blk null;
    };
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
    zy_text: []const u8,
    zy_root: ts.Node,
) Error!void {
    switch (middleware.mode) {
        .disabled => {},
        .enabled => |mware| try mware.syncDocument(uri, version, zy_text, zy_root),
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
    zy_uri: []const u8,
    params: types.HoverParams,
) Error!?types.Hover {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardHover(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("hover", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardDefinition(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.DefinitionParams,
) Error!lsp.ResultType("textDocument/definition") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardDefinition(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("definition", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardDeclaration(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.DeclarationParams,
) Error!lsp.ResultType("textDocument/declaration") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardDeclaration(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("declaration", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardReferences(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.ReferenceParams,
) Error!lsp.ResultType("textDocument/references") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardReferences(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("references", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardDocumentHighlight(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.DocumentHighlightParams,
) Error!lsp.ResultType("textDocument/documentHighlight") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardDocumentHighlight(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("documentHighlight", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardCompletion(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.CompletionParams,
) Error!lsp.ResultType("textDocument/completion") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardCompletion(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("completion", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardSignatureHelp(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.SignatureHelpParams,
) Error!lsp.ResultType("textDocument/signatureHelp") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardSignatureHelp(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("signatureHelp", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardInlayHint(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.InlayHintParams,
) Error!lsp.ResultType("textDocument/inlayHint") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardInlayHint(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("inlayHint", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardDocumentSymbols(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
) Error!?[]const types.DocumentSymbol {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardDocumentSymbols(arena, zy_uri) catch |err| {
            try suppressForwardRequestFailure("documentSymbol", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardSemanticTokensFull(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.SemanticTokensParams,
) Error!lsp.ResultType("textDocument/semanticTokens/full") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardSemanticTokensFull(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("semanticTokens/full", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardSemanticTokensFullDelta(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.SemanticTokensDeltaParams,
) Error!lsp.ResultType("textDocument/semanticTokens/full/delta") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardSemanticTokensFullDelta(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("semanticTokens/full/delta", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardSemanticTokensRange(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.SemanticTokensRangeParams,
) Error!lsp.ResultType("textDocument/semanticTokens/range") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardSemanticTokensRange(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("semanticTokens/range", zy_uri, err);
            return null;
        },
    };
}

pub fn forwardRename(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    params: types.RenameParams,
) Error!lsp.ResultType("textDocument/rename") {
    return switch (middleware.mode) {
        .disabled => null,
        .enabled => |mware| mware.forwardRename(arena, zy_uri, params) catch |err| {
            try suppressForwardRequestFailure("rename", zy_uri, err);
            return null;
        },
    };
}

pub fn aliasCodeBlockRenameEdits(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    zy_uri: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    zy_ranges: []const ts.Range,
    offset_encoding: lsp.offsets.Encoding,
) Error!?[]const types.TextEdit {
    return switch (middleware.mode) {
        .disabled => &.{},
        .enabled => |mware| mware.aliasCodeBlockRenameEdits(
            arena,
            zy_uri,
            alias_name,
            new_name,
            zy_ranges,
            offset_encoding,
        ) catch |err| {
            try suppressForwardRequestFailure("aliasRename", zy_uri, err);
            return null;
        },
    };
}

fn suppressForwardRequestFailure(comptime operation: []const u8, zy_uri: []const u8, err: Error) Error!void {
    switch (err) {
        error.RequestFailed => log.debug("Zig forward {s} -> uri={s} result=null reason=request_failed", .{
            operation,
            zy_uri,
        }),
        else => return err,
    }
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

    const zy = try allocator.dupe(u8, "zitron");
    errdefer allocator.free(zy);
    return .{
        .range = .{
            .start = .{ .line = zero_based_line, .character = 0 },
            .end = .{ .line = zero_based_line, .character = 0 },
        },
        .severity = .Error,
        .source = zy,
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
    if (diagnostic.source) |zy| allocator.free(zy);
    if (diagnostic.code) |code| switch (code) {
        .number => {},
        .string => |string| allocator.free(string),
    };
    if (diagnostic.codeDescription) |description| allocator.free(description.href);
    if (diagnostic.tags) |tags| allocator.free(tags);
}

fn translateZlsDiagnostics(
    allocator: std.mem.Allocator,
    doc: *ZigDocument,
    diagnostics: []const types.Diagnostic,
) OOM![]types.Diagnostic {
    var translated: std.ArrayList(types.Diagnostic) = .empty;
    errdefer {
        for (translated.items) |diagnostic| freeStoredDiagnostic(allocator, diagnostic);
        translated.deinit(allocator);
    }
    var context = RequestTranslationContext{
        .allocator = allocator,
        .map = &doc.code_map,
        .document_version = doc.version,
        .zy_text = doc.zy_text,
        .zig_text = doc.zig_text,
        .active_span_index = null,
    };
    defer context.deinit();

    for (diagnostics) |diagnostic| {
        const zy_range = (try context.zigRangeToZy(diagnostic.range)) orelse continue;
        const stored = try cloneStoredDiagnostic(allocator, diagnostic, zy_range, "zls");
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

/// Mapping between original Zitron code blocks and translated Zig code.
pub const CodeMap = struct {
    pub const empty: CodeMap = .{
        .zig_span = .empty,
        .zy_range = .empty,
        .fast_column_mapping = .empty,
        .zy_order = .empty,
        .translators = .empty,
    };

    /// Zig spans are stored in Zig-line order, which is the order encountered
    /// while scanning the translated Zig file.
    zig_span: std.ArrayList(ZigSpan),
    /// Zy ranges for the zig spans.  Indexes are kept in lockstep with
    /// `zig_span`, but the range retains exact tree-sitter byte and point data.
    zy_range: std.ArrayList(ts.Range),
    /// Whether a span came from a direct `%code`/`%include` shortcut.
    fast_column_mapping: std.ArrayList(bool),
    /// Indexes into `zig_span` and `zy_range`, sorted by zy-line order for zy -> zig
    /// lookups. The buffer is retained across updates.
    zy_order: std.ArrayList(usize),
    translators: SpanTranslators,

    /// Half-open byte range in either the zy or zig text.
    pub const ByteRange = struct {
        start: usize,
        end: usize,
    };

    pub const Mutation = struct {
        zy: types.Range,
        zig: types.Range,
    };

    pub const TranslatedPosition = union(enum) {
        shared: types.Position,
        mutant: Mutation,
    };

    /// One contiguous zig range. Zy-line offsets keep the legacy LSP
    /// position mapping; `zy_range` keeps the actual zy code-block extent.
    const ZigSpan = struct {
        /// First zero-based line in the original `.zy` document.
        zy_line: u32,
        /// First zero-based line in the translated Zig document.
        zig_line: u32,
        /// First zero-based character in the translated Zig document.
        zig_column: u32,
        /// Number of contiguous mapped lines shared by both coordinate systems.
        line_count: u32,
        /// Half-open byte range in the translated Zig document.
        zig_range: ByteRange,

        /// Exclusive zy-line end.  Keeping this as a helper avoids repeating
        /// the half-open interval convention at every lookup site.
        fn zyEnd(span: ZigSpan) u32 {
            return span.zy_line + span.line_count;
        }

        /// Exclusive zig-line end, matching `zyEnd` in length.
        fn zigEnd(span: ZigSpan) u32 {
            return span.zig_line + span.line_count;
        }

        /// Compares a zy line against this half-open span.
        fn orderZy(span: ZigSpan, line: u32) std.math.Order {
            if (line < span.zy_line) return .lt;
            if (line < span.zyEnd()) return .eq;
            return .gt;
        }

        /// Compares a zig line against this half-open span.
        fn orderZig(span: ZigSpan, line: u32) std.math.Order {
            if (line < span.zig_line) return .lt;
            if (line < span.zigEnd()) return .eq;
            return .gt;
        }

        fn zyPositionToZig(span: ZigSpan, position: types.Position) types.Position {
            const line_delta = position.line -| span.zy_line;
            return .{
                .line = span.zig_line + line_delta,
                .character = if (position.line < span.zy_line) 0 else position.character,
            };
        }

        fn zigPositionToZy(span: ZigSpan, position: types.Position) types.Position {
            return .{
                .line = span.zy_line + (position.line - span.zig_line),
                .character = position.character,
            };
        }
    };

    const ActiveSpan = struct {
        zig_span: ZigSpan,
        zy_range: ts.Range,
        fast_column_mapping: bool,
    };

    /// Rebuilds the map from Zitron `#line` markers.
    pub fn update(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        zy_root: ts.Node,
        zy_text: []const u8,
        zig_text: []u8,
        zy_path: []const u8,
    ) OOM!void {
        map.zig_span.clearRetainingCapacity();
        map.zy_range.clearRetainingCapacity();
        map.fast_column_mapping.clearRetainingCapacity();
        map.zy_order.clearRetainingCapacity();

        try map.collectSpans(allocator, zy_root, zy_text, zig_text, zy_path);
        try map.rebuildZyOrder(allocator);
        try map.translators.resetForSpans(allocator, map);
    }

    /// Frees the reusable span and index buffers.
    pub fn deinit(map: *CodeMap, allocator: std.mem.Allocator) void {
        map.zig_span.deinit(allocator);
        map.zy_range.deinit(allocator);
        map.fast_column_mapping.deinit(allocator);
        map.zy_order.deinit(allocator);
        map.translators.deinit(allocator);
        map.* = .empty;
    }

    /// Translates a zy position to zig coordinates by finding the
    /// earliest span that contains the zy line and preserving the column.
    pub fn zyPositionToZig(map: *const CodeMap, position: types.Position) ?types.Position {
        const zy_order_index = map.findZyIndex(position.line) orelse return null;
        const span_index = map.zy_order.items[zy_order_index];
        return map.zyPositionToZigInSpan(span_index, position);
    }

    /// Translates a zig position back to zy coordinates by finding the
    /// zig-order span containing the zig line and preserving column.
    pub fn zigPositionToZy(map: *const CodeMap, position: types.Position) ?types.Position {
        const span_index = map.findZigIndex(position.line) orelse return null;
        return map.zigPositionToZyInSpan(span_index, position);
    }

    fn zySpanIndexForPosition(map: *const CodeMap, position: types.Position) ?usize {
        const zy_order_index = map.findZyIndex(position.line) orelse return null;
        return map.zy_order.items[zy_order_index];
    }

    fn zyPositionToZigInSpan(map: *const CodeMap, span_index: usize, position: types.Position) types.Position {
        const span = map.zig_span.items[span_index];
        return span.zyPositionToZig(position);
    }

    fn zigPositionToZyInSpan(map: *const CodeMap, span_index: usize, position: types.Position) types.Position {
        const span = map.zig_span.items[span_index];
        return span.zigPositionToZy(position);
    }

    fn zyPositionToZigInSpanFromText(
        map: *const CodeMap,
        span_index: usize,
        zy_text: []const u8,
        position: types.Position,
    ) types.Position {
        const span = map.zig_span.items[span_index];
        var translated = span.zyPositionToZig(position);
        if (map.fast_column_mapping.items[span_index] and position.line == span.zy_line) {
            translated.character = translated.character -| map.fastFirstLineZyColumn(span_index, zy_text);
        }
        return translated;
    }

    fn zigPositionToZyInSpanFromText(
        map: *const CodeMap,
        span_index: usize,
        zy_text: []const u8,
        position: types.Position,
    ) types.Position {
        const span = map.zig_span.items[span_index];
        var translated = span.zigPositionToZy(position);
        if (map.fast_column_mapping.items[span_index] and position.line == span.zig_line) {
            translated.character += map.fastFirstLineZyColumn(span_index, zy_text);
        }
        return translated;
    }

    fn fastFirstLineZyColumn(map: *const CodeMap, span_index: usize, zy_text: []const u8) u32 {
        const range = map.zy_range.items[span_index];
        if (map.zig_span.items[span_index].zy_line != range.start_point.row) return 0;

        var column = range.start_point.column;
        if (column == 0) return column;

        const start = @min(range.start_byte, zy_text.len);
        const prefix = zy_text[lineStartBefore(zy_text, start)..start];
        if (!linePrefixHasFastCodeDirective(prefix)) return 0;

        var index = range.start_byte;
        const end = @min(range.end_byte, zy_text.len);
        while (index < end and zy_text[index] != '\n') : (index += 1) {
            switch (zy_text[index]) {
                ' ', '\t' => column += 1,
                else => break,
            }
        }
        return column;
    }

    fn lineStartBefore(zy_text: []const u8, end: usize) usize {
        var index = end;
        while (index > 0 and zy_text[index - 1] != '\n') index -= 1;
        return index;
    }

    fn linePrefixHasFastCodeDirective(prefix: []const u8) bool {
        const open_brace = std.mem.lastIndexOfScalar(u8, prefix, '{') orelse return false;
        const before_brace = std.mem.trim(u8, prefix[0..open_brace], " \t");
        const name_end = std.mem.indexOfAny(u8, before_brace, " \t") orelse before_brace.len;
        const name = before_brace[0..name_end];
        return std.mem.eql(u8, name, "code") or
            std.mem.eql(u8, name, "include") or
            std.mem.eql(u8, name, "%code") or
            std.mem.eql(u8, name, "%include");
    }

    /// Translates a zig range only when every zig line in the range is
    /// covered by adjacent mapped spans.  Gaps represent template/zig-only
    /// Zig and cannot be reported as a zy range.
    pub fn zigRangeToZy(map: *const CodeMap, range: types.Range) OOM!?types.Range {
        var index = map.findZigIndex(range.start.line) orelse return null;
        while (map.zig_span.items[index].orderZig(range.end.line) != .eq) {
            const next_index = index + 1;
            if (next_index >= map.zig_span.items.len) return null;
            if (map.zig_span.items[next_index].zig_line != map.zig_span.items[index].zigEnd()) return null;
            index = next_index;
        }

        return .{
            .start = map.zigPositionToZy(range.start).?,
            .end = map.zigPositionToZy(range.end).?,
        };
    }

    fn zigSpanIndexForRange(map: *const CodeMap, range: types.Range) ?usize {
        const index = map.findZigIndex(range.start.line) orelse return null;
        const span = map.zig_span.items[index];
        if (span.orderZig(range.end.line) != .eq and !(range.end.line == span.zigEnd() and range.end.character == 0)) {
            return null;
        }
        return index;
    }

    fn spanTranslator(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        document_version: i32,
        zy_text: []const u8,
        zig_text: []const u8,
        span_index: usize,
    ) OOM!*SpanTranslator {
        return try map.translators.get(allocator, map, document_version, zy_text, zig_text, span_index);
    }

    fn translatorAt(map: *CodeMap, span_index: usize) *SpanTranslator {
        return map.translators.at(span_index);
    }

    /// Scans zig text for `#line` comments and coalesces consecutive mapped
    /// lines into zig-order spans.
    fn collectSpans(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        zy_root: ts.Node,
        zy_text: []const u8,
        zig_text: []u8,
        zy_path: []const u8,
    ) OOM!void {
        var zig_line: u32 = 0;
        var zig_offset: usize = 0;
        var active_span: ?ActiveSpan = null;
        var zig_lines = std.mem.splitScalar(u8, zig_text, '\n');
        while (zig_lines.next()) |line| : (zig_line += 1) {
            const line_end = zig_offset + line.len;
            const next_zig_offset = if (line_end < zig_text.len) line_end + 1 else line_end;

            if (parseLineDirective(line)) |directive| {
                try map.processActiveSpan(allocator, &active_span, zig_line, zig_offset);
                if (std.mem.eql(u8, directive.path, zy_path)) {
                    if (zigCodeSpanForLine(zy_text, zy_root, directive.line)) |zy_span| {
                        active_span = .{
                            .zig_span = .{
                                .zy_line = directive.line,
                                .zig_line = zig_line + 1,
                                .zig_column = columnAtOffset(zig_text, next_zig_offset),
                                .line_count = 0,
                                .zig_range = .{
                                    .start = next_zig_offset,
                                    .end = next_zig_offset,
                                },
                            },
                            .zy_range = zy_span.range,
                            .fast_column_mapping = zy_span.fast_column_mapping,
                        };
                    }
                }
            }

            zig_offset = next_zig_offset;
        }

        try map.processActiveSpan(allocator, &active_span, zig_line, zig_offset);
    }

    fn columnAtOffset(text: []const u8, offset: usize) u32 {
        var index = @min(offset, text.len);
        while (index > 0 and text[index - 1] != '\n') index -= 1;
        return @intCast(offset - index);
    }

    fn processActiveSpan(
        map: *CodeMap,
        allocator: std.mem.Allocator,
        active_span: *?ActiveSpan,
        end_zig_line: u32,
        end_zig_offset: usize,
    ) OOM!void {
        var span = active_span.* orelse return;
        active_span.* = null;
        const line_count = end_zig_line - span.zig_span.zig_line;
        if (line_count == 0) return;
        span.zig_span.line_count = line_count;
        span.zig_span.zig_range.end = end_zig_offset;
        try map.zig_span.append(allocator, span.zig_span);
        errdefer _ = map.zig_span.pop();
        try map.zy_range.append(allocator, span.zy_range);
        errdefer _ = map.zy_range.pop();
        try map.fast_column_mapping.append(allocator, span.fast_column_mapping);
    }

    /// Rebuilds the zy-order index over the current span buffer.
    fn rebuildZyOrder(map: *CodeMap, allocator: std.mem.Allocator) OOM!void {
        try map.zy_order.ensureTotalCapacity(allocator, map.zig_span.items.len);
        for (0..map.zig_span.items.len) |index| {
            try map.zy_order.append(allocator, index);
        }
        std.mem.sort(usize, map.zy_order.items, map.zig_span.items, zyIndexLessThan);
    }

    /// Returns the number of spans in the map.  Tests use this to assert
    /// that multi-line ranges stay coalesced instead of becoming per-line nodes.
    fn len(map: *const CodeMap) usize {
        return map.zig_span.items.len;
    }

    fn indexForZyRange(map: *const CodeMap, range: ts.Range) ?usize {
        for (map.zy_range.items, 0..) |candidate, index| {
            if (candidate.start_byte == range.start_byte and candidate.end_byte == range.end_byte) {
                return index;
            }
        }
        return null;
    }

    /// Finds a zig-order span containing a zig line.
    fn findZig(map: *const CodeMap, line: u32) ?ZigSpan {
        const index = map.findZigIndex(line) orelse return null;
        return map.zig_span.items[index];
    }

    /// Finds the index of a zig-order span containing a zig line.
    fn findZigIndex(map: *const CodeMap, line: u32) ?usize {
        var low: usize = 0;
        var high: usize = map.zig_span.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (map.zig_span.items[mid].orderZig(line)) {
                .lt => high = mid,
                .eq => return mid,
                .gt => low = mid + 1,
            }
        }

        return null;
    }

    /// Finds the earliest zig span containing a zy line.
    fn findZy(map: *const CodeMap, line: u32) ?ZigSpan {
        const index = map.findZyIndex(line) orelse return null;
        return map.zig_span.items[map.zy_order.items[index]];
    }

    fn spanInZyOrder(map: *const CodeMap, index: usize) ZigSpan {
        return map.zig_span.items[map.zy_order.items[index]];
    }

    fn firstZyIndexPossiblyIntersecting(map: *const CodeMap, range: types.Range) usize {
        var low: usize = 0;
        var high: usize = map.zy_order.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const span = map.spanInZyOrder(mid);
            if (span.zyEnd() <= range.start.line) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    /// Finds the zy-order index of the earliest zig span containing a
    /// zy line.
    fn findZyIndex(map: *const CodeMap, line: u32) ?usize {
        var low: usize = 0;
        var high: usize = map.zy_order.items.len;
        var found: ?usize = null;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const span = map.spanInZyOrder(mid);
            switch (span.orderZy(line)) {
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

    /// Sorts zy indexes by zy start, then zig start.  The
    /// zig tie-breaker keeps defensive duplicate mappings deterministic.
    fn zyIndexLessThan(spans: []const ZigSpan, lhs_index: usize, rhs_index: usize) bool {
        const lhs = spans[lhs_index];
        const rhs = spans[rhs_index];
        if (lhs.zy_line != rhs.zy_line) return lhs.zy_line < rhs.zy_line;
        if (lhs.zig_line != rhs.zig_line) return lhs.zig_line < rhs.zig_line;
        return lhs_index < rhs_index;
    }
};

const SpanTranslator = struct {
    zig_span: CodeMap.ZigSpan,
    zy_range: ts.Range,
    document_version: i32,
    zy_text: []u8,
    zig_text: []u8,
    difference: ?Diff,
    zy_to_zig_cursor: DiffCursor,
    zig_to_zy_cursor: DiffCursor,

    const OffsetTranslation = union(enum) {
        shared: usize,
        mutant: CodeMap.Mutation,
    };

    const DiffCursor = struct {
        const init: DiffCursor = .{
            .edit_index = 0,
            .zy_cursor = 0,
            .zig_cursor = 0,
        };

        edit_index: usize,
        zy_cursor: usize,
        zig_cursor: usize,
    };

    fn init(zig_span: CodeMap.ZigSpan, zy_range: ts.Range) SpanTranslator {
        return .{
            .zig_span = zig_span,
            .zy_range = zy_range,
            .document_version = std.math.minInt(i32),
            .zy_text = &.{},
            .zig_text = &.{},
            .difference = null,
            .zy_to_zig_cursor = .init,
            .zig_to_zy_cursor = .init,
        };
    }

    fn updateSpan(translator: *SpanTranslator, zig_span: CodeMap.ZigSpan, zy_range: ts.Range) void {
        translator.zig_span = zig_span;
        translator.zy_range = zy_range;
        translator.resetCursors();
    }

    fn deinit(translator: *SpanTranslator, allocator: std.mem.Allocator) void {
        if (translator.difference) |*difference| difference.deinit(allocator);
        allocator.free(translator.zy_text);
        allocator.free(translator.zig_text);
        translator.* = undefined;
    }

    fn ensureFresh(
        translator: *SpanTranslator,
        allocator: std.mem.Allocator,
        current_version: i32,
        zy_doc: []const u8,
        zig_doc: []const u8,
    ) OOM!void {
        if (translator.document_version == current_version) return;

        const current_zig = translator.currentZigSlice(zig_doc);
        if (translator.difference != null and std.mem.eql(u8, translator.zig_text, current_zig)) {
            translator.document_version = current_version;
            return;
        }

        if (translator.difference) |*difference| {
            difference.deinit(allocator);
            translator.difference = null;
        }

        try translator.replaceText(allocator, &translator.zy_text, translator.currentZySlice(zy_doc));
        try translator.replaceText(allocator, &translator.zig_text, current_zig);

        var difference = Diff.init(.default);
        errdefer difference.deinit(allocator);
        _ = try difference.diff(allocator, translator.zy_text, translator.zig_text);
        translator.difference = difference;
        translator.document_version = current_version;
        translator.resetCursors();
    }

    fn resetCursors(translator: *SpanTranslator) void {
        translator.zy_to_zig_cursor = .init;
        translator.zig_to_zy_cursor = .init;
    }

    fn replaceText(
        translator: *SpanTranslator,
        allocator: std.mem.Allocator,
        target: *[]u8,
        source: []const u8,
    ) OOM!void {
        _ = translator;
        const resized = try allocator.realloc(target.*, source.len);
        if (source.len != 0) @memcpy(resized, source);
        target.* = resized;
    }

    fn currentZySlice(translator: *const SpanTranslator, zy_doc: []const u8) []const u8 {
        return zy_doc[translator.zy_range.start_byte..translator.zy_range.end_byte];
    }

    fn currentZigSlice(translator: *const SpanTranslator, zig_doc: []const u8) []const u8 {
        return zig_doc[translator.zig_span.zig_range.start..translator.zig_span.zig_range.end];
    }

    fn zyPositionToZig(translator: *SpanTranslator, position: types.Position) CodeMap.TranslatedPosition {
        const rel = translator.zyIndexForPosition(position);
        return switch (translator.zyOffsetToZig(rel)) {
            .shared => |zig_rel| .{ .shared = translator.zigPositionForRel(zig_rel) },
            .mutant => |mutation| .{ .mutant = mutation },
        };
    }

    fn zigPositionToZy(translator: *SpanTranslator, position: types.Position) CodeMap.TranslatedPosition {
        const rel = translator.zigIndexForPosition(position);
        return switch (translator.zigOffsetToZy(rel)) {
            .shared => |zy_rel| .{ .shared = translator.zyPositionForRel(zy_rel) },
            .mutant => |mutation| .{ .mutant = mutation },
        };
    }

    fn zigRangeToZy(translator: *SpanTranslator, range: types.Range) ?types.Range {
        if (!translator.containsZigPosition(range.start, false) or
            !translator.containsZigPosition(range.end, true))
        {
            return null;
        }

        const rel_start = translator.zigIndexForPosition(range.start);
        const rel_end = translator.zigIndexForPosition(range.end);
        if (!translator.zigIntervalShared(rel_start, rel_end)) return null;

        return .{
            .start = sharedPosition(translator.zigPositionToZy(range.start)) orelse return null,
            .end = sharedPosition(translator.zigPositionToZy(range.end)) orelse return null,
        };
    }

    fn containsZigRange(translator: *const SpanTranslator, range: types.Range) bool {
        return translator.containsZigPosition(range.start, false) and
            translator.containsZigPosition(range.end, true);
    }

    fn containsZigPosition(translator: *const SpanTranslator, position: types.Position, allow_end: bool) bool {
        if (position.line < translator.zig_span.zig_line) return false;
        if (position.line > translator.zig_span.zigEnd()) return false;
        if (position.line == translator.zig_span.zig_line and position.character < translator.zig_span.zig_column) return false;
        if (position.line == translator.zig_span.zigEnd()) {
            return allow_end and position.character == 0;
        }
        return true;
    }

    fn zyOffsetToZig(translator: *SpanTranslator, rel: usize) OffsetTranslation {
        if (rel < translator.zy_to_zig_cursor.zy_cursor) {
            translator.zy_to_zig_cursor = .init;
        }

        const edits = translator.diffEdits();
        var zy_cursor = translator.zy_to_zig_cursor.zy_cursor;
        var zig_cursor = translator.zy_to_zig_cursor.zig_cursor;
        var index = translator.zy_to_zig_cursor.edit_index;
        while (index < edits.len) {
            const edit = edits[index];
            switch (edit.operation) {
                .equal => {
                    const zy_end = zy_cursor + edit.text.len;
                    translator.zy_to_zig_cursor = .{
                        .edit_index = index,
                        .zy_cursor = zy_cursor,
                        .zig_cursor = zig_cursor,
                    };
                    if (rel < zy_end or (rel == zy_end and zy_end == translator.zyLength())) {
                        return .{ .shared = zig_cursor + (rel - zy_cursor) };
                    }
                    zy_cursor = zy_end;
                    zig_cursor += edit.text.len;
                    index += 1;
                },
                .delete, .insert => {
                    const mutation_start_zy = zy_cursor;
                    const mutation_start_zig = zig_cursor;
                    const mutation_start_index = index;
                    while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                        switch (edits[index].operation) {
                            .delete => zy_cursor += edits[index].text.len,
                            .insert => zig_cursor += edits[index].text.len,
                            .equal => unreachable,
                        }
                    }
                    translator.zy_to_zig_cursor = .{
                        .edit_index = mutation_start_index,
                        .zy_cursor = mutation_start_zy,
                        .zig_cursor = mutation_start_zig,
                    };
                    if (rel == mutation_start_zy) {
                        return .{ .shared = if (zy_cursor == mutation_start_zy)
                            zig_cursor
                        else
                            mutation_start_zig };
                    }
                    if (mutation_start_zy < rel and rel < zy_cursor) {
                        return .{ .mutant = translator.zyMutation(
                            mutation_start_zy,
                            zy_cursor,
                            mutation_start_zig,
                            zig_cursor,
                        ) };
                    }
                    translator.zy_to_zig_cursor = .{
                        .edit_index = index,
                        .zy_cursor = zy_cursor,
                        .zig_cursor = zig_cursor,
                    };
                },
            }
        }
        if (rel == zy_cursor) return .{ .shared = zig_cursor };
        return .{ .mutant = translator.zyMutation(0, translator.zyLength(), 0, translator.zigLength()) };
    }

    fn zigOffsetToZy(translator: *SpanTranslator, rel: usize) OffsetTranslation {
        if (rel < translator.zig_to_zy_cursor.zig_cursor) {
            translator.zig_to_zy_cursor = .init;
        }

        const edits = translator.diffEdits();
        var zy_cursor = translator.zig_to_zy_cursor.zy_cursor;
        var zig_cursor = translator.zig_to_zy_cursor.zig_cursor;
        var index = translator.zig_to_zy_cursor.edit_index;
        while (index < edits.len) {
            const edit = edits[index];
            switch (edit.operation) {
                .equal => {
                    const zig_end = zig_cursor + edit.text.len;
                    translator.zig_to_zy_cursor = .{
                        .edit_index = index,
                        .zy_cursor = zy_cursor,
                        .zig_cursor = zig_cursor,
                    };
                    if (rel < zig_end or (rel == zig_end and zig_end == translator.zigLength())) {
                        return .{ .shared = zy_cursor + (rel - zig_cursor) };
                    }
                    zy_cursor += edit.text.len;
                    zig_cursor = zig_end;
                    index += 1;
                },
                .delete, .insert => {
                    const mutation_start_zy = zy_cursor;
                    const mutation_start_zig = zig_cursor;
                    const mutation_start_index = index;
                    while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                        switch (edits[index].operation) {
                            .delete => zy_cursor += edits[index].text.len,
                            .insert => zig_cursor += edits[index].text.len,
                            .equal => unreachable,
                        }
                    }
                    translator.zig_to_zy_cursor = .{
                        .edit_index = mutation_start_index,
                        .zy_cursor = mutation_start_zy,
                        .zig_cursor = mutation_start_zig,
                    };
                    if (rel == mutation_start_zig) {
                        return .{ .shared = if (zig_cursor == mutation_start_zig)
                            zy_cursor
                        else
                            mutation_start_zy };
                    }
                    if (mutation_start_zig < rel and rel < zig_cursor) {
                        return .{ .mutant = translator.zyMutation(
                            mutation_start_zy,
                            zy_cursor,
                            mutation_start_zig,
                            zig_cursor,
                        ) };
                    }
                    translator.zig_to_zy_cursor = .{
                        .edit_index = index,
                        .zy_cursor = zy_cursor,
                        .zig_cursor = zig_cursor,
                    };
                },
            }
        }
        if (rel == zig_cursor) return .{ .shared = zy_cursor };
        return .{ .mutant = translator.zyMutation(0, translator.zyLength(), 0, translator.zigLength()) };
    }

    fn zigIntervalShared(translator: *SpanTranslator, start: usize, end: usize) bool {
        if (start == end) return translator.zigOffsetToZy(start) == .shared;
        if (end < start) return false;
        if (start < translator.zig_to_zy_cursor.zig_cursor) {
            translator.zig_to_zy_cursor = .init;
        }

        const edits = translator.diffEdits();
        var zy_cursor = translator.zig_to_zy_cursor.zy_cursor;
        var zig_cursor = translator.zig_to_zy_cursor.zig_cursor;
        var index = translator.zig_to_zy_cursor.edit_index;
        while (index < edits.len) {
            const edit = edits[index];
            switch (edit.operation) {
                .equal => {
                    const equal_start = zig_cursor;
                    const equal_end = equal_start + edit.text.len;
                    translator.zig_to_zy_cursor = .{
                        .edit_index = index,
                        .zy_cursor = zy_cursor,
                        .zig_cursor = zig_cursor,
                    };
                    if (equal_start <= start and start < equal_end and end <= equal_end) {
                        if (start == equal_start and end == equal_end) return false;
                        return true;
                    }
                    zy_cursor += edit.text.len;
                    zig_cursor = equal_end;
                    index += 1;
                },
                .delete, .insert => {
                    const mutation_start_zy = zy_cursor;
                    const mutation_start_zig = zig_cursor;
                    const mutation_start_index = index;
                    while (index < edits.len and edits[index].operation != .equal) : (index += 1) {
                        switch (edits[index].operation) {
                            .delete => zy_cursor += edits[index].text.len,
                            .insert => zig_cursor += edits[index].text.len,
                            .equal => unreachable,
                        }
                    }
                    translator.zig_to_zy_cursor = .{
                        .edit_index = mutation_start_index,
                        .zy_cursor = mutation_start_zy,
                        .zig_cursor = mutation_start_zig,
                    };
                    if (start < zig_cursor and end > mutation_start_zig) return false;
                    translator.zig_to_zy_cursor = .{
                        .edit_index = index,
                        .zy_cursor = zy_cursor,
                        .zig_cursor = zig_cursor,
                    };
                },
            }
        }

        return false;
    }

    fn diffEdits(translator: *const SpanTranslator) []const Edit {
        return translator.difference.?.edits.items;
    }

    fn zyMutation(
        translator: *const SpanTranslator,
        zy_start: usize,
        zy_end: usize,
        zig_start: usize,
        zig_end: usize,
    ) CodeMap.Mutation {
        return .{
            .zy = translator.zyRangeFromRel(zy_start, zy_end),
            .zig = translator.zigRangeFromRel(zig_start, zig_end),
        };
    }

    fn zyLength(translator: *const SpanTranslator) usize {
        return translator.zy_text.len;
    }

    fn zigLength(translator: *const SpanTranslator) usize {
        return translator.zig_text.len;
    }

    fn zyIndexForPosition(translator: *const SpanTranslator, position: types.Position) usize {
        return lsp.offsets.positionToIndex(translator.zy_text, translator.relativeZyPosition(position), .@"utf-8");
    }

    fn zigIndexForPosition(translator: *const SpanTranslator, position: types.Position) usize {
        return lsp.offsets.positionToIndex(translator.zig_text, translator.relativeZigPosition(position), .@"utf-8");
    }

    fn relativeZyPosition(translator: *const SpanTranslator, position: types.Position) types.Position {
        const line = position.line - translator.zy_range.start_point.row;
        return .{
            .line = line,
            .character = if (line == 0) position.character - translator.zy_range.start_point.column else position.character,
        };
    }

    fn relativeZigPosition(translator: *const SpanTranslator, position: types.Position) types.Position {
        const line = position.line - translator.zig_span.zig_line;
        return .{
            .line = line,
            .character = if (line == 0) position.character - translator.zig_span.zig_column else position.character,
        };
    }

    fn zyPositionForRel(translator: *const SpanTranslator, rel: usize) types.Position {
        const relative = lsp.offsets.indexToPosition(translator.zy_text, rel, .@"utf-8");
        return .{
            .line = translator.zy_range.start_point.row + relative.line,
            .character = if (relative.line == 0) translator.zy_range.start_point.column + relative.character else relative.character,
        };
    }

    fn zigPositionForRel(translator: *const SpanTranslator, rel: usize) types.Position {
        const relative = lsp.offsets.indexToPosition(translator.zig_text, rel, .@"utf-8");
        return .{
            .line = translator.zig_span.zig_line + relative.line,
            .character = if (relative.line == 0) translator.zig_span.zig_column + relative.character else relative.character,
        };
    }

    fn zyRangeFromRel(translator: *const SpanTranslator, start: usize, end: usize) types.Range {
        return .{
            .start = translator.zyPositionForRel(start),
            .end = translator.zyPositionForRel(end),
        };
    }

    fn zigRangeFromRel(translator: *const SpanTranslator, start: usize, end: usize) types.Range {
        return .{
            .start = translator.zigPositionForRel(start),
            .end = translator.zigPositionForRel(end),
        };
    }
};

const SpanTranslators = struct {
    const empty: SpanTranslators = .{ .slots = .empty };

    slots: std.ArrayList(SpanTranslator),

    fn get(
        cache: *SpanTranslators,
        allocator: std.mem.Allocator,
        map: *const CodeMap,
        document_version: i32,
        zy_text: []const u8,
        zig_text: []const u8,
        span_index: usize,
    ) OOM!*SpanTranslator {
        try cache.ensureSlots(allocator, map, span_index + 1);
        const translator = &cache.slots.items[span_index];
        try translator.ensureFresh(allocator, document_version, zy_text, zig_text);
        return translator;
    }

    fn at(cache: *SpanTranslators, span_index: usize) *SpanTranslator {
        return &cache.slots.items[span_index];
    }

    fn resetForSpans(cache: *SpanTranslators, allocator: std.mem.Allocator, map: *const CodeMap) OOM!void {
        while (cache.slots.items.len > map.zig_span.items.len) {
            var translator = cache.slots.pop().?;
            translator.deinit(allocator);
        }
        for (cache.slots.items, 0..) |*translator, index| {
            translator.updateSpan(map.zig_span.items[index], map.zy_range.items[index]);
        }
        try cache.ensureSlots(allocator, map, map.zig_span.items.len);
    }

    fn ensureSlots(
        cache: *SpanTranslators,
        allocator: std.mem.Allocator,
        map: *const CodeMap,
        count: usize,
    ) OOM!void {
        try cache.slots.ensureTotalCapacity(allocator, count);
        while (cache.slots.items.len < count) {
            const span_index = cache.slots.items.len;
            cache.slots.appendAssumeCapacity(SpanTranslator.init(
                map.zig_span.items[span_index],
                map.zy_range.items[span_index],
            ));
        }
    }

    fn reset(cache: *SpanTranslators, allocator: std.mem.Allocator) void {
        for (cache.slots.items) |*translator| {
            translator.deinit(allocator);
        }
        cache.slots.clearRetainingCapacity();
    }

    fn deinit(cache: *SpanTranslators, allocator: std.mem.Allocator) void {
        cache.reset(allocator);
        cache.slots.deinit(allocator);
        cache.* = .empty;
    }

    fn len(cache: *const SpanTranslators) usize {
        return cache.slots.items.len;
    }

    fn freshLen(cache: *const SpanTranslators, document_version: i32) usize {
        var count: usize = 0;
        for (cache.slots.items) |translator| {
            if (translator.document_version == document_version) count += 1;
        }
        return count;
    }
};

const RequestTranslationContext = struct {
    allocator: std.mem.Allocator,
    map: *CodeMap,
    document_version: i32,
    zy_text: []const u8,
    zig_text: []const u8,
    active_span_index: ?usize,

    fn deinit(context: *RequestTranslationContext) void {
        _ = context;
    }

    fn zyPositionToZig(context: *RequestTranslationContext, position: types.Position) OOM!?types.Position {
        const span_index = context.active_span_index orelse context.map.zySpanIndexForPosition(position) orelse return null;
        return try context.zyPositionToZigInSpan(span_index, position);
    }

    fn zyPositionToZigInSpan(
        context: *RequestTranslationContext,
        span_index: usize,
        position: types.Position,
    ) OOM!?types.Position {
        if (context.map.fast_column_mapping.items[span_index]) {
            const zy_index = lsp.offsets.positionToIndex(context.zy_text, position, .@"utf-8");
            const zy_range = context.map.zy_range.items[span_index];
            if (zy_index < zy_range.start_byte or zy_index > zy_range.end_byte) return null;
            return context.map.zyPositionToZigInSpanFromText(span_index, context.zy_text, position);
        }

        const translator = try context.translatorForSpanIndex(span_index);
        const zy_index = lsp.offsets.positionToIndex(context.zy_text, position, .@"utf-8");
        if (zy_index < translator.zy_range.start_byte or zy_index > translator.zy_range.end_byte) return null;
        return sharedPosition(translator.zyPositionToZig(position));
    }

    fn zigRangeToZy(context: *RequestTranslationContext, range: types.Range) OOM!?types.Range {
        const span_index = context.map.zigSpanIndexForRange(range) orelse return null;
        if (context.map.fast_column_mapping.items[span_index]) {
            return .{
                .start = context.map.zigPositionToZyInSpanFromText(span_index, context.zy_text, range.start),
                .end = context.map.zigPositionToZyInSpanFromText(span_index, context.zy_text, range.end),
            };
        }

        const translator = try context.translatorForZigRange(range) orelse return null;
        return translator.zigRangeToZy(range);
    }

    fn zigPositionToZy(context: *RequestTranslationContext, position: types.Position) OOM!?types.Position {
        const span_index = context.map.findZigIndex(position.line) orelse return null;
        const span = context.map.zig_span.items[span_index];
        if (position.line == span.zigEnd() and position.character != 0) return null;
        if (context.map.fast_column_mapping.items[span_index]) {
            return context.map.zigPositionToZyInSpanFromText(span_index, context.zy_text, position);
        }

        const translator = try context.translatorForZigPosition(position) orelse return null;
        return sharedPosition(translator.zigPositionToZy(position));
    }

    fn translatorForZigRange(context: *RequestTranslationContext, range: types.Range) OOM!?*SpanTranslator {
        const span_index = context.map.findZigIndex(range.start.line) orelse return null;
        const span = context.map.zig_span.items[span_index];
        if (span.orderZig(range.end.line) != .eq and !(range.end.line == span.zigEnd() and range.end.character == 0)) {
            return null;
        }

        return try context.translatorForSpanIndex(span_index);
    }

    fn translatorForZigPosition(context: *RequestTranslationContext, position: types.Position) OOM!?*SpanTranslator {
        const span_index = context.map.findZigIndex(position.line) orelse return null;
        const span = context.map.zig_span.items[span_index];
        if (position.line == span.zigEnd() and position.character != 0) return null;
        return try context.translatorForSpanIndex(span_index);
    }

    fn translatorForSpanIndex(context: *RequestTranslationContext, span_index: usize) OOM!*SpanTranslator {
        return try context.map.spanTranslator(
            context.allocator,
            context.document_version,
            context.zy_text,
            context.zig_text,
            span_index,
        );
    }
};

const ZigPositionCursor = struct {
    context: *RequestTranslationContext,
    span_index: ?usize,

    fn zigPositionToZy(cursor: *ZigPositionCursor, position: types.Position) OOM!?types.Position {
        const translator = try cursor.translatorForPosition(position) orelse return null;
        const rel = cursor.zigIndexForPosition(translator, position) orelse return null;
        const translated = translator.zigOffsetToZy(rel);
        const zy_rel = switch (translated) {
            .shared => |zy_rel| zy_rel,
            .mutant => return null,
        };
        return cursor.zyPositionForRel(translator, zy_rel);
    }

    fn zigRangeToZy(cursor: *ZigPositionCursor, range: types.Range) OOM!?types.Range {
        const translator = try cursor.translatorForPosition(range.start) orelse return null;
        if (!translator.containsZigPosition(range.start, false) or
            !translator.containsZigPosition(range.end, true))
        {
            return null;
        }

        const rel_start = cursor.zigIndexForPosition(translator, range.start) orelse return null;
        const rel_end = cursor.zigIndexForPosition(translator, range.end) orelse return null;
        if (rel_end < rel_start or !translator.zigIntervalShared(rel_start, rel_end)) return null;

        const start_rel = switch (translator.zigOffsetToZy(rel_start)) {
            .shared => |zy_rel| zy_rel,
            .mutant => return null,
        };
        const end_rel = switch (translator.zigOffsetToZy(rel_end)) {
            .shared => |zy_rel| zy_rel,
            .mutant => return null,
        };
        return .{
            .start = cursor.zyPositionForRel(translator, start_rel),
            .end = cursor.zyPositionForRel(translator, end_rel),
        };
    }

    fn translatorForPosition(cursor: *ZigPositionCursor, position: types.Position) OOM!?*SpanTranslator {
        if (cursor.span_index) |span_index| {
            const span = cursor.context.map.zig_span.items[span_index];
            if (spanContainsZigPosition(span, position)) {
                return cursor.context.map.translatorAt(span_index);
            }

            if (position.line >= span.zigEnd()) {
                var next_index = span_index + 1;
                while (next_index < cursor.context.map.zig_span.items.len) : (next_index += 1) {
                    const next_span = cursor.context.map.zig_span.items[next_index];
                    if (position.line < next_span.zig_line) break;
                    if (spanContainsZigPosition(next_span, position)) {
                        try cursor.resetToSpan(next_index);
                        return cursor.context.map.translatorAt(next_index);
                    }
                }
            }
        }

        const span_index = cursor.context.map.findZigIndex(position.line) orelse return null;
        const span = cursor.context.map.zig_span.items[span_index];
        if (!spanContainsZigPosition(span, position)) return null;
        try cursor.resetToSpan(span_index);
        return cursor.context.map.translatorAt(span_index);
    }

    fn resetToSpan(cursor: *ZigPositionCursor, span_index: usize) OOM!void {
        _ = try cursor.context.translatorForSpanIndex(span_index);
        cursor.span_index = span_index;
    }

    fn zigIndexForPosition(
        cursor: *ZigPositionCursor,
        translator: *const SpanTranslator,
        position: types.Position,
    ) ?usize {
        _ = cursor;
        if (!translator.containsZigPosition(position, true)) return null;
        const index = translator.zigIndexForPosition(position);
        return if (index <= translator.zigLength()) index else null;
    }

    fn zyPositionForRel(
        cursor: *ZigPositionCursor,
        translator: *const SpanTranslator,
        zy_rel: usize,
    ) types.Position {
        _ = cursor;
        return translator.zyPositionForRel(zy_rel);
    }

    fn spanContainsZigPosition(span: CodeMap.ZigSpan, position: types.Position) bool {
        if (position.line < span.zig_line) return false;
        if (position.line > span.zigEnd()) return false;
        if (position.line == span.zig_line and position.character < span.zig_column) return false;
        if (position.line == span.zigEnd()) return position.character == 0;
        return true;
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

fn rangeLessThan(_: void, lhs: types.Range, rhs: types.Range) bool {
    if (positionLessThan(lhs.start, rhs.start)) return true;
    if (positionLessThan(rhs.start, lhs.start)) return false;
    return positionLessThan(lhs.end, rhs.end);
}

fn semanticDirtyRangeFromDiff(
    allocator: std.mem.Allocator,
    previous_zy_text: []const u8,
    current_zy_text: []const u8,
) OOM!?SemanticDirtyRange {
    var difference = Diff.init(.default);
    defer difference.deinit(allocator);
    _ = try difference.diff(allocator, previous_zy_text, current_zy_text);

    var previous_cursor: types.Position = .{ .line = 0, .character = 0 };
    var current_cursor: types.Position = .{ .line = 0, .character = 0 };
    var previous_dirty: ?types.Range = null;
    var current_dirty: ?types.Range = null;

    var index: usize = 0;
    while (index < difference.edits.items.len) {
        const item = difference.edits.items[index];
        switch (item.operation) {
            .equal => {
                previous_cursor = advanceUtf8Position(previous_cursor, item.text);
                current_cursor = advanceUtf8Position(current_cursor, item.text);
                index += 1;
            },
            .insert, .delete => {
                const previous_start = previous_cursor;
                const current_start = current_cursor;
                while (index < difference.edits.items.len) : (index += 1) {
                    const edit = difference.edits.items[index];
                    switch (edit.operation) {
                        .equal => break,
                        .insert => current_cursor = advanceUtf8Position(current_cursor, edit.text),
                        .delete => previous_cursor = advanceUtf8Position(previous_cursor, edit.text),
                    }
                }

                previous_dirty = rangeUnion(previous_dirty, .{
                    .start = previous_start,
                    .end = previous_cursor,
                });
                current_dirty = rangeUnion(current_dirty, .{
                    .start = current_start,
                    .end = current_cursor,
                });
            },
        }
    }

    return if (previous_dirty) |previous| .{
        .previous = previous,
        .current = current_dirty.?,
    } else null;
}

fn fullSemanticDirtyRange(previous_zy_text: []const u8, current_zy_text: []const u8) SemanticDirtyRange {
    return .{
        .previous = fullDocumentRange(previous_zy_text),
        .current = fullDocumentRange(current_zy_text),
    };
}

fn fullDocumentRange(text: []const u8) types.Range {
    return .{
        .start = .{ .line = 0, .character = 0 },
        .end = lsp.offsets.indexToPosition(text, text.len, .@"utf-8"),
    };
}

fn advanceUtf8Position(start_position: types.Position, text: []const u8) types.Position {
    const relative = lsp.offsets.indexToPosition(text, text.len, .@"utf-8");
    return if (relative.line == 0) .{
        .line = start_position.line,
        .character = start_position.character + relative.character,
    } else .{
        .line = start_position.line + relative.line,
        .character = relative.character,
    };
}

fn expandSemanticDirtyRange(range: types.Range) types.Range {
    return .{
        .start = .{
            .line = if (range.start.line == 0) 0 else range.start.line - 1,
            .character = 0,
        },
        .end = .{
            .line = range.end.line + 2,
            .character = 0,
        },
    };
}

fn zyRangeToZigRange(
    allocator: std.mem.Allocator,
    code_map: *CodeMap,
    document_version: i32,
    zy_text: []const u8,
    zig_text: []const u8,
    zy_range: types.Range,
) OOM!?types.Range {
    var translation_context = RequestTranslationContext{
        .allocator = allocator,
        .map = code_map,
        .document_version = document_version,
        .zy_text = zy_text,
        .zig_text = zig_text,
        .active_span_index = null,
    };
    defer translation_context.deinit();

    var mapped_range: ?types.Range = null;
    var zy_order_index = code_map.firstZyIndexPossiblyIntersecting(zy_range);
    while (zy_order_index < code_map.zy_order.items.len) : (zy_order_index += 1) {
        const span_index = code_map.zy_order.items[zy_order_index];
        const span_zy_range = zyRangeFromTsRange(code_map.zy_range.items[span_index]);
        if (!positionLessThan(span_zy_range.start, zy_range.end)) break;

        const request_range = rangeIntersection(zy_range, span_zy_range) orelse continue;
        const zig_range = if (code_map.fast_column_mapping.items[span_index])
            types.Range{
                .start = code_map.zyPositionToZigInSpanFromText(span_index, zy_text, request_range.start),
                .end = code_map.zyPositionToZigInSpanFromText(span_index, zy_text, request_range.end),
            }
        else
            types.Range{
                .start = (try translation_context.zyPositionToZigInSpan(span_index, request_range.start)) orelse continue,
                .end = (try translation_context.zyPositionToZigInSpan(span_index, request_range.end)) orelse continue,
            };
        mapped_range = rangeUnion(mapped_range, zig_range);
    }
    return mapped_range;
}

fn zyRangeToSortedZigRanges(
    allocator: std.mem.Allocator,
    code_map: *CodeMap,
    document_version: i32,
    zy_text: []const u8,
    zig_text: []const u8,
    zy_range: types.Range,
) OOM![]types.Range {
    var translation_context = RequestTranslationContext{
        .allocator = allocator,
        .map = code_map,
        .document_version = document_version,
        .zy_text = zy_text,
        .zig_text = zig_text,
        .active_span_index = null,
    };
    defer translation_context.deinit();

    const dirty_spans = try allocator.alloc(bool, code_map.zig_span.items.len);
    defer allocator.free(dirty_spans);
    @memset(dirty_spans, false);

    var zy_order_index = code_map.firstZyIndexPossiblyIntersecting(zy_range);
    while (zy_order_index < code_map.zy_order.items.len) : (zy_order_index += 1) {
        const span_index = code_map.zy_order.items[zy_order_index];
        const span_zy_range = zyRangeFromTsRange(code_map.zy_range.items[span_index]);
        if (!positionLessThan(span_zy_range.start, zy_range.end)) break;
        if (rangeIntersection(zy_range, span_zy_range) != null) {
            dirty_spans[span_index] = true;
        }
    }

    var ranges: std.ArrayList(types.Range) = .empty;
    errdefer ranges.deinit(allocator);

    for (dirty_spans, 0..) |dirty_span, span_index| {
        if (!dirty_span) continue;
        const span_zy_range = zyRangeFromTsRange(code_map.zy_range.items[span_index]);
        const request_range = rangeIntersection(zy_range, span_zy_range) orelse continue;
        const span = code_map.zig_span.items[span_index];
        const zig_range = if (rangeContainsRange(zy_range, span_zy_range))
            rangeFromByteRange(zig_text, span.zig_range.start, span.zig_range.end)
        else if (code_map.fast_column_mapping.items[span_index])
            types.Range{
                .start = code_map.zyPositionToZigInSpanFromText(span_index, zy_text, request_range.start),
                .end = code_map.zyPositionToZigInSpanFromText(span_index, zy_text, request_range.end),
            }
        else
            types.Range{
                .start = (try translation_context.zyPositionToZigInSpan(span_index, request_range.start)) orelse continue,
                .end = (try translation_context.zyPositionToZigInSpan(span_index, request_range.end)) orelse continue,
            };
        if (rangeIsEmpty(zig_range)) continue;
        try ranges.append(allocator, zig_range);
    }

    if (ranges.items.len == 0) return try ranges.toOwnedSlice(allocator);

    var coalesced_len: usize = 0;
    for (ranges.items) |range| {
        if (coalesced_len == 0) {
            ranges.items[0] = range;
            coalesced_len = 1;
            continue;
        }

        const previous = &ranges.items[coalesced_len - 1];
        if (!positionLessThan(previous.end, range.start)) {
            previous.end = positionMax(previous.end, range.end);
        } else {
            ranges.items[coalesced_len] = range;
            coalesced_len += 1;
        }
    }
    ranges.items.len = coalesced_len;
    return try ranges.toOwnedSlice(allocator);
}

fn zyRangeFromTsRange(range: ts.Range) types.Range {
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
    zy_text: []const u8,
    zy_range: ts.Range,
    zig_text: []const u8,
    zig_range: CodeMap.ByteRange,
    diff_edits: []const Edit,
    alias_name: []const u8,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    var zy_cursor: usize = 0;
    var zig_cursor: usize = 0;
    for (diff_edits) |edit| {
        switch (edit.operation) {
            .equal => {
                try appendAliasRenameEditsFromEqual(
                    arena,
                    edits,
                    seen_starts,
                    zy_text,
                    @as(usize, zy_range.start_byte) + zy_cursor,
                    zig_text,
                    zig_range.start + zig_cursor,
                    edit.text,
                    alias_name,
                    new_name,
                    offset_encoding,
                );
                zy_cursor += edit.text.len;
                zig_cursor += edit.text.len;
            },
            .insert => zig_cursor += edit.text.len,
            .delete => {
                try appendAliasRenameEditsFromDelete(
                    arena,
                    edits,
                    seen_starts,
                    zy_text,
                    @as(usize, zy_range.start_byte) + zy_cursor,
                    edit.text,
                    alias_name,
                    new_name,
                    offset_encoding,
                );
                zy_cursor += edit.text.len;
            },
        }
    }
}

fn appendAliasRenameEditsFromEqual(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    zy_text: []const u8,
    zy_start: usize,
    zig_text: []const u8,
    zig_start: usize,
    equal_text: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    // TODO: Drop this when alias rename uses token-based diffing instead of string diffing.
    var index: usize = 0;
    while (index < equal_text.len) : (index += 1) {
        const zy_absolute = zy_start + index;
        const zig_absolute = zig_start + index;
        if (equal_text[index] == '@' and
            std.mem.startsWith(u8, equal_text[index + 1 ..], alias_name) and
            isAliasBoundary(zy_text, zy_absolute + 1, alias_name.len) and
            !isAliasBoundary(zig_text, zig_absolute + 1, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                zy_text,
                zy_absolute,
                zy_absolute + 1 + alias_name.len,
                try std.fmt.allocPrint(arena, "@{s}", .{new_name}),
                offset_encoding,
            );
            index += alias_name.len;
            continue;
        }

        if (std.mem.startsWith(u8, equal_text[index..], alias_name) and
            isAliasBoundary(zy_text, zy_absolute, alias_name.len) and
            !isAliasBoundary(zig_text, zig_absolute, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                zy_text,
                zy_absolute,
                zy_absolute + alias_name.len,
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
    zy_text: []const u8,
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
            isAliasBoundary(zy_text, absolute + 1, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                zy_text,
                absolute,
                absolute + 1 + alias_name.len,
                try std.fmt.allocPrint(arena, "@{s}", .{new_name}),
                offset_encoding,
            );
            index += alias_name.len;
            continue;
        }

        if (std.mem.startsWith(u8, deleted_text[index..], alias_name) and
            isAliasBoundary(zy_text, absolute, alias_name.len))
        {
            try appendAliasCodeEdit(
                arena,
                edits,
                seen_starts,
                zy_text,
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
    zy_text: []const u8,
    start: usize,
    end: usize,
    new_text: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    const gop = try seen_starts.getOrPut(arena, start);
    if (gop.found_existing) return;

    try edits.append(arena, .{
        .range = lsp.offsets.locToRange(zy_text, .{
            .start = start,
            .end = end,
        }, offset_encoding),
        .newText = new_text,
    });
}

fn isAliasBoundary(zy_text: []const u8, start: usize, len: usize) bool {
    if (start > 0 and isAliasByte(zy_text[start - 1])) return false;
    const end = start + len;
    return end >= zy_text.len or !isAliasByte(zy_text[end]);
}

fn isAliasByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const ZigCodeSpan = struct {
    range: ts.Range,
    fast_column_mapping: bool,
};

fn zigCodeSpanForLine(zy_text: []const u8, zy_root: ts.Node, line: u32) ?ZigCodeSpan {
    const line_start: ts.Point = .{ .row = line, .column = 0 };
    var node = zy_root.descendantForPointRange(line_start, lineEndPoint(zy_root, line)) orelse return null;
    if (std.mem.eql(u8, node.kind(), "zig_code")) return zigCodeSpan(zy_text, node);

    while (true) {
        const zig_code = descendantOfKindOnLine(node, "zig_code", line) orelse {
            node = node.parent() orelse return null;
            continue;
        };
        return zigCodeSpan(zy_text, zig_code);
    }
}

fn zigCodeSpan(zy_text: []const u8, zig_code: ts.Node) ZigCodeSpan {
    return .{
        .range = zig_code.range(),
        .fast_column_mapping = isFastCodeDirective(zy_text, zig_code),
    };
}

fn isFastCodeDirective(zy_text: []const u8, zig_code: ts.Node) bool {
    const code_block = zig_code.parent() orelse return false;
    if (!std.mem.eql(u8, code_block.kind(), "code_block")) return false;
    const directive = code_block.parent() orelse return false;
    if (!std.mem.eql(u8, directive.kind(), "directive")) return false;
    const name_node = directiveNameChild(directive) orelse return false;
    const name = zy_text[name_node.startByte()..name_node.endByte()];
    return std.mem.eql(u8, name, "code") or
        std.mem.eql(u8, name, "include") or
        std.mem.eql(u8, name, "%code") or
        std.mem.eql(u8, name, "%include");
}

fn directiveNameChild(directive: ts.Node) ?ts.Node {
    const child_count = directive.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = directive.namedChild(index).?;
        if (isDirectiveNameNode(child)) return child;
    }
    return null;
}

fn isDirectiveNameNode(node: ts.Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "arg_directive_name") or
        std.mem.eql(u8, kind, "directive_name") or
        std.mem.eql(u8, kind, "token_directive_name") or
        std.mem.eql(u8, kind, "bad_directive_name") or
        std.mem.eql(u8, kind, "impl_name");
}

fn lineEndPoint(zy_root: ts.Node, line: u32) ts.Point {
    const zy_end = zy_root.endPoint();
    if (zy_end.row == line) return zy_end;
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

/// Parsed form of a zig `// #line N path` marker. Zitron emits these
/// markers to connect translated Zig lines back to original Zitron lines.
const LineDirective = struct {
    /// Directive line number converted to zero-based LSP lines.
    line: u32,
    /// Path payload from the directive; only spans for the zy `.zy` path are
    /// mapped back to the client document.
    path: []const u8,
};

/// Recognizes the exact zig-line marker format used by Zitron.
fn parseLineDirective(line: []const u8) ?LineDirective {
    const prefix = "// #line ";

    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    if (!std.mem.startsWith(u8, line[index..], prefix)) return null;
    index += prefix.len;

    const number_start = index;
    while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
    const number_end = index;
    if (number_start == number_end) return null;
    const line_number = std.fmt.parseInt(u32, line[number_start..number_end], 10) catch return null;

    if (index >= line.len or (line[index] != ' ' and line[index] != '\t')) return null;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    if (index == line.len) return null;

    return .{
        .line = line_number -| 1,
        .path = line[index..],
    };
}

pub fn translateHover(hover_result: *types.Hover, map: *RequestTranslationContext) OOM!void {
    if (hover_result.range) |range| {
        hover_result.range = try map.zigRangeToZy(range);
    }
}

pub fn translateDefinition(
    arena: std.mem.Allocator,
    definition_result: lsp.types.Definition.Result,
    map: *RequestTranslationContext,
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?lsp.types.Definition.Result {
    return switch (definition_result) {
        .definition => |definition_value| if (try translateDefinitionValue(arena, definition_value, map, zig_uri, zy_uri)) |translated|
            .{ .definition = translated }
        else
            null,
        .definition_links => |links| blk: {
            var translated: std.ArrayList(types.DefinitionLink) = .empty;
            for (links) |link| {
                if (try translateDefinitionLink(link, map, zig_uri, zy_uri)) |mapped| {
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
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?types.Definition {
    return switch (definition_result) {
        .location => |location| if (try translateLocation(location, map, zig_uri, zy_uri)) |translated|
            .{ .location = translated }
        else
            null,
        .locations => |locations| blk: {
            var translated: std.ArrayList(types.Location) = .empty;
            for (locations) |location| {
                if (try translateLocation(location, map, zig_uri, zy_uri)) |mapped| {
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
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?types.DefinitionLink {
    if (!std.mem.eql(u8, link.targetUri, zig_uri)) return link;
    return .{
        .originSelectionRange = if (link.originSelectionRange) |range| try map.zigRangeToZy(range) else null,
        .targetUri = zy_uri,
        .targetRange = (try map.zigRangeToZy(link.targetRange)) orelse return null,
        .targetSelectionRange = (try map.zigRangeToZy(link.targetSelectionRange)) orelse return null,
    };
}

pub fn translateLocations(
    arena: std.mem.Allocator,
    locations: []const types.Location,
    map: *RequestTranslationContext,
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?[]const types.Location {
    var translated: std.ArrayList(types.Location) = .empty;
    for (locations) |location| {
        if (try translateLocation(location, map, zig_uri, zy_uri)) |mapped| {
            try translated.append(arena, mapped);
        }
    }

    return if (translated.items.len == 0) null else try translated.toOwnedSlice(arena);
}

fn translateDocumentHighlights(
    arena: std.mem.Allocator,
    highlights: []const types.DocumentHighlight,
    map: *RequestTranslationContext,
) OOM!?[]const types.DocumentHighlight {
    var translated: std.ArrayList(types.DocumentHighlight) = .empty;
    var position_cursor = ZigPositionCursor{ .context = map, .span_index = null };
    for (highlights) |highlight| {
        if (try translateDocumentHighlight(highlight, &position_cursor)) |mapped| {
            try translated.append(arena, mapped);
        }
    }

    return if (translated.items.len == 0) null else try translated.toOwnedSlice(arena);
}

fn translateDocumentHighlight(
    highlight: types.DocumentHighlight,
    position_cursor: *ZigPositionCursor,
) OOM!?types.DocumentHighlight {
    return .{
        .range = (try position_cursor.zigRangeToZy(highlight.range)) orelse return null,
        .kind = highlight.kind,
    };
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
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM![]const types.InlayHint {
    var translated: std.ArrayList(types.InlayHint) = .empty;
    var position_cursor = ZigPositionCursor{ .context = map, .span_index = null };
    for (hints) |hint| {
        if (try translateInlayHint(arena, hint, map, &position_cursor, zig_uri, zy_uri)) |mapped| {
            try translated.append(arena, mapped);
        }
    }
    return try translated.toOwnedSlice(arena);
}

fn translateSemanticTokenData(
    arena: std.mem.Allocator,
    data: []u32,
    map: *RequestTranslationContext,
) Error![]const u32 {
    const token_ranges = try arena.alloc(SemanticTokenRange, map.map.zig_span.items.len);
    @memset(token_ranges, .empty);
    const span_mappings = try semanticSpanMappings(arena, map.map, map.zig_text);

    var line: u32 = 0;
    var character: u32 = 0;
    var write_index: usize = 0;
    var position_cursor = ZigPositionCursor{ .context = map, .span_index = null };

    var index: usize = 0;
    while (index + 4 < data.len) : (index += 5) {
        line += data[index];
        character = if (data[index] == 0) character + data[index + 1] else data[index + 1];
        const length = data[index + 2];
        const token_type = data[index + 3];
        const token_modifiers = data[index + 4];

        const zig_range: types.Range = .{
            .start = .{ .line = line, .character = character },
            .end = .{ .line = line, .character = character + length },
        };
        const span_index = map.map.zigSpanIndexForRange(zig_range) orelse continue;
        const zy_range = (try translateSemanticTokenRange(
            map,
            &position_cursor,
            span_mappings,
            span_index,
            zig_range,
        )) orelse continue;
        if (zy_range.start.line != zy_range.end.line) continue;
        if (zy_range.end.character < zy_range.start.character) continue;

        var range = &token_ranges[span_index];
        if (!range.seen) {
            range.* = .{
                .start = write_index,
                .end = write_index,
                .seen = true,
            };
        } else if (range.end != write_index) {
            return error.UnexpectedResponse;
        }

        const out = data[write_index..][0..5];
        out[0] = zy_range.start.line;
        out[1] = zy_range.start.character;
        out[2] = zy_range.end.character - zy_range.start.character;
        out[3] = token_type;
        out[4] = token_modifiers;
        write_index += 5;
        range.end = write_index;
    }

    const translated = data[0..write_index];
    try reorderSemanticTokenRanges(translated, token_ranges, map.map.zy_order.items);
    return encodeSemanticTokenDataInPlace(translated);
}

fn translateSemanticTokenRangeData(
    arena: std.mem.Allocator,
    data: []u32,
    map: *RequestTranslationContext,
) Error![]const u32 {
    const span_mappings = try semanticSpanMappings(arena, map.map, map.zig_text);
    defer arena.free(span_mappings);
    var position_cursor = ZigPositionCursor{ .context = map, .span_index = null };
    var translated: std.ArrayList(AbsoluteSemanticToken) = .empty;
    defer translated.deinit(arena);

    var line: u32 = 0;
    var character: u32 = 0;
    var index: usize = 0;
    while (index + 4 < data.len) : (index += 5) {
        line += data[index];
        character = if (data[index] == 0) character + data[index + 1] else data[index + 1];
        const length = data[index + 2];
        const token_type = data[index + 3];
        const token_modifiers = data[index + 4];

        const zig_range: types.Range = .{
            .start = .{ .line = line, .character = character },
            .end = .{ .line = line, .character = character + length },
        };
        const span_index = map.map.zigSpanIndexForRange(zig_range) orelse continue;
        const zy_range = (try translateSemanticTokenRange(
            map,
            &position_cursor,
            span_mappings,
            span_index,
            zig_range,
        )) orelse continue;
        if (zy_range.start.line != zy_range.end.line) continue;
        if (zy_range.end.character < zy_range.start.character) continue;

        try translated.append(arena, .{
            .line = zy_range.start.line,
            .character = zy_range.start.character,
            .length = zy_range.end.character - zy_range.start.character,
            .token_type = token_type,
            .token_modifiers = token_modifiers,
        });
    }

    const tokens = translated.items;
    std.mem.sort(AbsoluteSemanticToken, tokens, {}, absoluteSemanticTokenLessThan);

    const encoded = try arena.alloc(u32, tokens.len * 5);
    for (tokens, 0..) |token, token_index| {
        const out = encoded[token_index * 5 ..][0..5];
        out[0] = token.line;
        out[1] = token.character;
        out[2] = token.length;
        out[3] = token.token_type;
        out[4] = token.token_modifiers;
    }
    return encodeSemanticTokenDataInPlace(encoded);
}

const FilteredSemanticTokens = struct {
    data: []const u32,
    scanned_count: usize,
    translated_count: usize,
};

fn translateSemanticTokenRangeDataFiltered(
    arena: std.mem.Allocator,
    data: []const u32,
    map: *RequestTranslationContext,
    requested_zig_range: types.Range,
    replacement_zy_range: types.Range,
) Error!FilteredSemanticTokens {
    if (rangeIsEmpty(replacement_zy_range)) {
        return .{
            .data = try arena.alloc(u32, 0),
            .scanned_count = 0,
            .translated_count = 0,
        };
    }

    var position_cursor = ZigPositionCursor{ .context = map, .span_index = null };
    var mapped_span_index: ?usize = null;
    var mapped_span: SemanticSpanMapping = undefined;
    var translated: std.ArrayList(AbsoluteSemanticToken) = .empty;
    defer translated.deinit(arena);

    var line: u32 = 0;
    var character: u32 = 0;
    var index: usize = 0;
    var scanned_count: usize = 0;
    while (index + 4 < data.len) : (index += 5) {
        line += data[index];
        character = if (data[index] == 0) character + data[index + 1] else data[index + 1];
        const length = data[index + 2];
        const token_type = data[index + 3];
        const token_modifiers = data[index + 4];

        const zig_range: types.Range = .{
            .start = .{ .line = line, .character = character },
            .end = .{ .line = line, .character = character + length },
        };
        scanned_count += 1;
        if (!positionLessThan(zig_range.start, requested_zig_range.end)) break;
        if (!positionLessThan(requested_zig_range.start, zig_range.end)) continue;

        const span_index = map.map.zigSpanIndexForRange(zig_range) orelse continue;
        if (mapped_span_index != span_index) {
            mapped_span_index = span_index;
            mapped_span = semanticSpanMappingForSpan(
                map.zig_text,
                map.map.zig_span.items[span_index],
                map.map.fast_column_mapping.items[span_index],
            );
        }
        const zy_range = (try translateSemanticTokenRangeFromMapping(
            map,
            &position_cursor,
            mapped_span,
            span_index,
            zig_range,
        )) orelse continue;
        if (rangeIntersection(zy_range, replacement_zy_range) == null) continue;
        if (zy_range.start.line != zy_range.end.line) continue;
        if (zy_range.end.character < zy_range.start.character) continue;

        try translated.append(arena, .{
            .line = zy_range.start.line,
            .character = zy_range.start.character,
            .length = zy_range.end.character - zy_range.start.character,
            .token_type = token_type,
            .token_modifiers = token_modifiers,
        });
    }

    const tokens = translated.items;
    std.mem.sort(AbsoluteSemanticToken, tokens, {}, absoluteSemanticTokenLessThan);

    const encoded = try arena.alloc(u32, tokens.len * 5);
    for (tokens, 0..) |token, token_index| {
        const out = encoded[token_index * 5 ..][0..5];
        out[0] = token.line;
        out[1] = token.character;
        out[2] = token.length;
        out[3] = token.token_type;
        out[4] = token.token_modifiers;
    }
    return .{
        .data = try encodeSemanticTokenDataInPlace(encoded),
        .scanned_count = scanned_count,
        .translated_count = tokens.len,
    };
}

fn semanticSpanMappings(
    arena: std.mem.Allocator,
    code_map: *const CodeMap,
    zig_text: []const u8,
) OOM![]const SemanticSpanMapping {
    const mappings = try arena.alloc(SemanticSpanMapping, code_map.zig_span.items.len);
    for (mappings, code_map.zig_span.items, code_map.fast_column_mapping.items) |*mapping, span, fast| {
        mapping.* = semanticSpanMappingForSpan(zig_text, span, fast);
    }
    return mappings;
}

fn semanticSpanMappingForSpan(
    zig_text: []const u8,
    span: CodeMap.ZigSpan,
    fast_column_mapping: bool,
) SemanticSpanMapping {
    return .{
        .zig_range = rangeFromByteRange(zig_text, span.zig_range.start, span.zig_range.end),
        .fast_column_mapping = fast_column_mapping,
    };
}

fn translateSemanticTokenRange(
    map: *RequestTranslationContext,
    position_cursor: *ZigPositionCursor,
    span_mappings: []const SemanticSpanMapping,
    span_index: usize,
    zig_range: types.Range,
) OOM!?types.Range {
    return translateSemanticTokenRangeFromMapping(
        map,
        position_cursor,
        span_mappings[span_index],
        span_index,
        zig_range,
    );
}

fn translateSemanticTokenRangeFromMapping(
    map: *RequestTranslationContext,
    position_cursor: *ZigPositionCursor,
    mapping: SemanticSpanMapping,
    span_index: usize,
    zig_range: types.Range,
) OOM!?types.Range {
    if (!rangeContainsRange(mapping.zig_range, zig_range)) return null;

    if (mapping.fast_column_mapping) {
        return .{
            .start = map.map.zigPositionToZyInSpanFromText(span_index, map.zy_text, zig_range.start),
            .end = map.map.zigPositionToZyInSpanFromText(span_index, map.zy_text, zig_range.end),
        };
    }

    return try position_cursor.zigRangeToZy(zig_range);
}

const SemanticSpanMapping = struct {
    zig_range: types.Range,
    fast_column_mapping: bool,
};

fn rangeContainsRange(outer: types.Range, inner: types.Range) bool {
    return !positionLessThan(inner.start, outer.start) and !positionLessThan(outer.end, inner.end);
}

const SemanticTokenRange = struct {
    start: usize,
    end: usize,
    seen: bool,

    const empty: SemanticTokenRange = .{
        .start = 0,
        .end = 0,
        .seen = false,
    };

    fn len(range: SemanticTokenRange) usize {
        return range.end - range.start;
    }
};

fn reorderSemanticTokenRanges(
    data: []u32,
    token_ranges: []SemanticTokenRange,
    zy_order: []const usize,
) Error!void {
    var out_start: usize = 0;
    for (zy_order) |span_index| {
        const range = token_ranges[span_index];
        if (!range.seen) continue;
        if (range.start < out_start) return error.UnexpectedResponse;

        const token_data_len = range.len();
        if (range.start != out_start) {
            std.mem.rotate(u32, data[out_start..range.end], range.start - out_start);
            for (token_ranges) |*other| {
                if (other.seen and other.start >= out_start and other.end <= range.start) {
                    other.start += token_data_len;
                    other.end += token_data_len;
                }
            }
            token_ranges[span_index].start = out_start;
            token_ranges[span_index].end = out_start + token_data_len;
        }

        out_start += token_data_len;
    }
}

fn encodeSemanticTokenDataInPlace(data: []u32) Error![]const u32 {
    return encodeSemanticTokenDataInPlaceFromBase(data, null);
}

fn encodeSemanticTokenDataInPlaceFromBase(
    data: []u32,
    previous_token: ?AbsoluteSemanticToken,
) Error![]const u32 {
    var previous_line: u32 = if (previous_token) |token| token.line else 0;
    var previous_character: u32 = if (previous_token) |token| token.character else 0;

    var index: usize = 0;
    while (index + 4 < data.len) : (index += 5) {
        const line = data[index];
        const character = data[index + 1];
        if (line < previous_line or
            (line == previous_line and character < previous_character))
        {
            return error.UnexpectedResponse;
        }

        data[index] = line - previous_line;
        data[index + 1] = if (data[index] == 0) character - previous_character else character;
        previous_line = line;
        previous_character = character;
    }

    return data;
}

fn applySemanticTokenEdits(
    allocator: std.mem.Allocator,
    previous: []const u32,
    edits: []const types.SemanticTokensEdit,
) Error![]u32 {
    var updated: std.ArrayList(u32) = .empty;
    errdefer updated.deinit(allocator);

    var cursor: usize = 0;
    for (edits) |edit| {
        const start: usize = @intCast(edit.start);
        const delete_count: usize = @intCast(edit.deleteCount);
        if (start < cursor or start > previous.len or start + delete_count > previous.len) {
            return error.UnexpectedResponse;
        }

        try updated.appendSlice(allocator, previous[cursor..start]);
        if (edit.data) |data| try updated.appendSlice(allocator, data);
        cursor = start + delete_count;
    }
    try updated.appendSlice(allocator, previous[cursor..]);
    return try updated.toOwnedSlice(allocator);
}

fn semanticTokenDeltaEdits(
    allocator: std.mem.Allocator,
    previous: []const u32,
    current: []const u32,
) OOM![]const types.SemanticTokensEdit {
    var prefix: usize = 0;
    while (prefix < previous.len and prefix < current.len and previous[prefix] == current[prefix]) {
        prefix += 1;
    }

    var previous_suffix = previous.len;
    var current_suffix = current.len;
    while (previous_suffix > prefix and current_suffix > prefix and previous[previous_suffix - 1] == current[current_suffix - 1]) {
        previous_suffix -= 1;
        current_suffix -= 1;
    }

    if (prefix == previous.len and prefix == current.len) {
        return try allocator.alloc(types.SemanticTokensEdit, 0);
    }

    const edit_start = semanticTokenDataSlotStart(prefix);
    const previous_edit_end = semanticTokenDataSlotEnd(previous_suffix);
    const current_edit_end = semanticTokenDataSlotEnd(current_suffix);

    const inserted = try allocator.dupe(u32, current[edit_start..current_edit_end]);
    errdefer allocator.free(inserted);
    const edits = try allocator.alloc(types.SemanticTokensEdit, 1);
    edits[0] = .{
        .start = @intCast(edit_start),
        .deleteCount = @intCast(previous_edit_end - edit_start),
        .data = inserted,
    };
    return edits;
}

fn semanticTokenDataSlotStart(index: usize) usize {
    return index - (index % 5);
}

fn semanticTokenDataSlotEnd(index: usize) usize {
    const remainder = index % 5;
    return if (remainder == 0) index else index + (5 - remainder);
}

const AbsoluteSemanticToken = struct {
    line: u32,
    character: u32,
    length: u32,
    token_type: u32,
    token_modifiers: u32,

    fn endPosition(token: AbsoluteSemanticToken) types.Position {
        return .{
            .line = token.line,
            .character = token.character + token.length,
        };
    }

    fn startPosition(token: AbsoluteSemanticToken) types.Position {
        return .{
            .line = token.line,
            .character = token.character,
        };
    }
};

fn absoluteSemanticTokenLessThan(_: void, lhs: AbsoluteSemanticToken, rhs: AbsoluteSemanticToken) bool {
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    if (lhs.character != rhs.character) return lhs.character < rhs.character;
    if (lhs.length != rhs.length) return lhs.length < rhs.length;
    if (lhs.token_type != rhs.token_type) return lhs.token_type < rhs.token_type;
    return lhs.token_modifiers < rhs.token_modifiers;
}

fn semanticTokenIndexFromData(
    allocator: std.mem.Allocator,
    data: []const u32,
) OOM![]AbsoluteSemanticToken {
    const token_count = data.len / 5;
    const index = try allocator.alloc(AbsoluteSemanticToken, token_count);
    errdefer comptime unreachable;

    var line: u32 = 0;
    var character: u32 = 0;
    var token_index: usize = 0;
    var data_index: usize = 0;
    while (data_index + 4 < data.len) : ({
        data_index += 5;
        token_index += 1;
    }) {
        line += data[data_index];
        character = if (data[data_index] == 0) character + data[data_index + 1] else data[data_index + 1];
        index[token_index] = .{
            .line = line,
            .character = character,
            .length = data[data_index + 2],
            .token_type = data[data_index + 3],
            .token_modifiers = data[data_index + 4],
        };
    }
    return index;
}

const SemanticTokenRebuild = struct {
    data: []u32,
    index: []AbsoluteSemanticToken,

    fn deinit(rebuilt: *SemanticTokenRebuild, allocator: std.mem.Allocator) void {
        allocator.free(rebuilt.data);
        allocator.free(rebuilt.index);
    }
};

fn rebuildSemanticTokensFromRange(
    allocator: std.mem.Allocator,
    previous_index: []const AbsoluteSemanticToken,
    dirty: SemanticDirtyRange,
    replacement_range: types.Range,
    current_range_data: []const u32,
) Error!SemanticTokenRebuild {
    const current_range_index = try semanticTokenIndexFromData(allocator, current_range_data);
    defer allocator.free(current_range_index);
    std.mem.sort(AbsoluteSemanticToken, current_range_index, {}, absoluteSemanticTokenLessThan);

    var rebuilt: std.ArrayList(AbsoluteSemanticToken) = .empty;
    defer rebuilt.deinit(allocator);

    for (previous_index) |previous_token| {
        const previous_range = semanticTokenRange(previous_token);
        if (semanticTokenAffectedByDirty(previous_range, dirty.previous)) continue;

        const current_token = if (!positionLessThan(previous_token.startPosition(), dirty.previous.end))
            try transformSemanticTokenAfterDirty(previous_token, dirty)
        else
            previous_token;

        if (semanticTokenIntersectsRange(semanticTokenRange(current_token), replacement_range)) continue;
        if (semanticTokenIntersectsAny(current_token, current_range_index)) continue;
        try rebuilt.append(allocator, current_token);
    }

    try rebuilt.appendSlice(allocator, current_range_index);
    std.mem.sort(AbsoluteSemanticToken, rebuilt.items, {}, absoluteSemanticTokenLessThan);

    const data = try semanticTokenDataFromIndex(allocator, rebuilt.items);
    errdefer allocator.free(data);
    return .{
        .data = data,
        .index = try rebuilt.toOwnedSlice(allocator),
    };
}

fn rebuildSemanticTokenDataFromRange(
    allocator: std.mem.Allocator,
    previous_index: []const AbsoluteSemanticToken,
    dirty: SemanticDirtyRange,
    replacement_range: types.Range,
    current_range_data: []const u32,
) Error![]u32 {
    const rebuilt = try rebuildSemanticTokensFromRange(
        allocator,
        previous_index,
        dirty,
        replacement_range,
        current_range_data,
    );
    allocator.free(rebuilt.index);
    return rebuilt.data;
}

fn rebuildSemanticTokenDataWithoutZigChange(
    allocator: std.mem.Allocator,
    previous_index: []const AbsoluteSemanticToken,
    dirty: SemanticDirtyRange,
) Error![]u32 {
    var rebuilt: std.ArrayList(AbsoluteSemanticToken) = .empty;
    defer rebuilt.deinit(allocator);

    for (previous_index) |previous_token| {
        const previous_range = semanticTokenRange(previous_token);
        if (semanticTokenAffectedByDirty(previous_range, dirty.previous)) continue;

        const current_token = if (!positionLessThan(previous_token.startPosition(), dirty.previous.end))
            try transformSemanticTokenAfterDirty(previous_token, dirty)
        else
            previous_token;
        try rebuilt.append(allocator, current_token);
    }

    std.mem.sort(AbsoluteSemanticToken, rebuilt.items, {}, absoluteSemanticTokenLessThan);
    return try semanticTokenDataFromIndex(allocator, rebuilt.items);
}

fn semanticTokenDataFromIndex(
    allocator: std.mem.Allocator,
    tokens: []const AbsoluteSemanticToken,
) Error![]u32 {
    const data = try allocator.alloc(u32, tokens.len * 5);
    errdefer allocator.free(data);

    for (tokens, 0..) |token, token_index| {
        const out = data[token_index * 5 ..][0..5];
        out[0] = token.line;
        out[1] = token.character;
        out[2] = token.length;
        out[3] = token.token_type;
        out[4] = token.token_modifiers;
    }

    _ = try encodeSemanticTokenDataInPlace(data);
    return data;
}

fn semanticTokenDataForRange(
    allocator: std.mem.Allocator,
    tokens: []const AbsoluteSemanticToken,
    range: types.Range,
) Error![]u32 {
    if (rangeIsEmpty(range)) return try allocator.alloc(u32, 0);

    const first = firstSemanticTokenIntersectingOrAfter(tokens, range.start);
    var end = first;
    while (end < tokens.len and positionLessThan(tokens[end].startPosition(), range.end)) {
        end += 1;
    }

    var kept: std.ArrayList(AbsoluteSemanticToken) = .empty;
    defer kept.deinit(allocator);
    for (tokens[first..end]) |token| {
        if (rangeIntersection(semanticTokenRange(token), range) != null) {
            try kept.append(allocator, token);
        }
    }
    return try semanticTokenDataFromIndex(allocator, kept.items);
}

fn firstSemanticTokenIntersectingOrAfter(
    tokens: []const AbsoluteSemanticToken,
    start: types.Position,
) usize {
    var low: usize = 0;
    var high: usize = tokens.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (positionLessThan(start, tokens[mid].endPosition())) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    return low;
}

fn semanticTokenIntersectsAny(
    token: AbsoluteSemanticToken,
    sorted_tokens: []const AbsoluteSemanticToken,
) bool {
    const range = semanticTokenRange(token);
    const first = firstSemanticTokenIntersectingOrAfter(sorted_tokens, range.start);
    var index = first;
    while (index < sorted_tokens.len and positionLessThan(sorted_tokens[index].startPosition(), range.end)) : (index += 1) {
        if (rangeIntersection(range, semanticTokenRange(sorted_tokens[index])) != null) return true;
    }
    return false;
}

fn semanticTokenRange(token: AbsoluteSemanticToken) types.Range {
    return .{
        .start = token.startPosition(),
        .end = token.endPosition(),
    };
}

fn semanticTokenAffectedByDirty(token_range: types.Range, dirty_range: types.Range) bool {
    if (!rangeIsEmpty(dirty_range)) return rangeIntersection(token_range, dirty_range) != null;
    return positionLessThan(token_range.start, dirty_range.start) and
        positionLessThan(dirty_range.start, token_range.end);
}

fn semanticTokenIntersectsRange(token_range: types.Range, replacement_range: types.Range) bool {
    if (rangeIsEmpty(replacement_range)) return false;
    return rangeIntersection(token_range, replacement_range) != null;
}

fn rangeIsEmpty(range: types.Range) bool {
    return !positionLessThan(range.start, range.end);
}

fn transformSemanticTokenAfterDirty(
    token: AbsoluteSemanticToken,
    dirty: SemanticDirtyRange,
) Error!AbsoluteSemanticToken {
    const start = transformPositionAfterDirty(token.startPosition(), dirty);
    const end = transformPositionAfterDirty(token.endPosition(), dirty);
    if (start.line != end.line or end.character < start.character) return error.UnexpectedResponse;
    return .{
        .line = start.line,
        .character = start.character,
        .length = end.character - start.character,
        .token_type = token.token_type,
        .token_modifiers = token.token_modifiers,
    };
}

fn transformPositionAfterDirty(position: types.Position, dirty: SemanticDirtyRange) types.Position {
    if (positionLessThan(position, dirty.previous.end)) return position;
    if (position.line == dirty.previous.end.line) {
        return .{
            .line = dirty.current.end.line,
            .character = dirty.current.end.character + (position.character - dirty.previous.end.character),
        };
    }

    const line_delta = @as(i64, dirty.current.end.line) - @as(i64, dirty.previous.end.line);
    return .{
        .line = adjustLine(position.line, line_delta),
        .character = position.character,
    };
}

fn adjustLine(line: u32, line_delta: i64) u32 {
    return if (line_delta >= 0)
        line + @as(u32, @intCast(line_delta))
    else
        line - @as(u32, @intCast(-line_delta));
}

fn semanticTokenDataRange(data: []const u32) ?types.Range {
    var line: u32 = 0;
    var character: u32 = 0;
    var range: ?types.Range = null;

    var index: usize = 0;
    while (index + 4 < data.len) : (index += 5) {
        line += data[index];
        character = if (data[index] == 0) character + data[index + 1] else data[index + 1];
        range = rangeUnion(range, .{
            .start = .{ .line = line, .character = character },
            .end = .{ .line = line, .character = character + data[index + 2] },
        });
    }

    return range;
}

fn freeSemanticTokenEdits(allocator: std.mem.Allocator, edits: []const types.SemanticTokensEdit) void {
    for (edits) |edit| {
        if (edit.data) |data| allocator.free(data);
    }
    allocator.free(edits);
}

fn translateInlayHint(
    arena: std.mem.Allocator,
    hint: types.InlayHint,
    map: *RequestTranslationContext,
    position_cursor: *ZigPositionCursor,
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?types.InlayHint {
    var translated = hint;
    translated.position = (try position_cursor.zigPositionToZy(hint.position)) orelse return null;
    translated.label = switch (hint.label) {
        .string => hint.label,
        .inlay_hint_label_parts => |parts| blk: {
            const translated_parts = try arena.alloc(types.InlayHintLabelPart, parts.len);
            for (parts, translated_parts) |part, *translated_part| {
                translated_part.* = part;
                if (part.location) |location| {
                    translated_part.location = try translateLocation(location, map, zig_uri, zy_uri);
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
        .document_symbols => |symbols| {
            var position_cursor = ZigPositionCursor{ .context = map, .span_index = null };
            return translateDocumentSymbolSlice(arena, symbols, &position_cursor);
        },
        .symbol_informations => null,
    };
}

pub fn translateWorkspaceEdit(
    arena: std.mem.Allocator,
    workspace_edit: types.WorkspaceEdit,
    map: *RequestTranslationContext,
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?types.WorkspaceEdit {
    var translated = workspace_edit;
    var has_changes = false;

    if (workspace_edit.changes) |changes| {
        var translated_changes = std.json.ArrayHashMap([]const types.TextEdit){};
        var it = changes.map.iterator();
        while (it.next()) |entry| {
            const uri = entry.key_ptr.*;
            const edits = entry.value_ptr.*;
            const translated_edits = if (std.mem.eql(u8, uri, zig_uri))
                try translateTextEdits(arena, edits, map)
            else
                edits;
            if (translated_edits.len == 0) continue;

            const translated_uri = if (std.mem.eql(u8, uri, zig_uri)) zy_uri else uri;
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
                    if (try translateTextDocumentEdit(arena, edit, map, zig_uri, zy_uri)) |translated_edit| {
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

fn translateLocation(location: types.Location, map: *RequestTranslationContext, zig_uri: []const u8, zy_uri: []const u8) OOM!?types.Location {
    if (!std.mem.eql(u8, location.uri, zig_uri)) return location;
    return .{
        .uri = zy_uri,
        .range = (try map.zigRangeToZy(location.range)) orelse return null,
    };
}

fn translateDocumentSymbolSlice(
    arena: std.mem.Allocator,
    symbols: []const types.DocumentSymbol,
    position_cursor: *ZigPositionCursor,
) OOM!?[]const types.DocumentSymbol {
    var translated: std.ArrayList(types.DocumentSymbol) = .empty;
    for (symbols) |symbol| {
        if (startsWithYy(symbol.name)) {
            if (symbol.children) |children| {
                if (try translateDocumentSymbolSlice(arena, children, position_cursor)) |mapped_children| {
                    try translated.appendSlice(arena, mapped_children);
                }
            }
            continue;
        }
        if (try translateDocumentSymbol(arena, symbol, position_cursor)) |mapped| {
            try translated.append(arena, mapped);
        }
    }

    return if (translated.items.len == 0) null else try translated.toOwnedSlice(arena);
}

fn translateDocumentSymbol(
    arena: std.mem.Allocator,
    symbol: types.DocumentSymbol,
    position_cursor: *ZigPositionCursor,
) OOM!?types.DocumentSymbol {
    return .{
        .name = symbol.name,
        .detail = symbol.detail,
        .kind = symbol.kind,
        .tags = symbol.tags,
        .deprecated = symbol.deprecated,
        .range = (try position_cursor.zigRangeToZy(symbol.range)) orelse return null,
        .selectionRange = (try position_cursor.zigRangeToZy(symbol.selectionRange)) orelse return null,
        .children = if (symbol.children) |children| try translateDocumentSymbolSlice(arena, children, position_cursor) else null,
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
            .insert = (try map.zigRangeToZy(edit.insert)) orelse return null,
            .replace = (try map.zigRangeToZy(edit.replace)) orelse return null,
        } },
    };
}

fn translateCompletionDefaultEditRange(
    edit_range: lsp.types.ClientCapabilities.TextDocument.Completion.EditRange,
    map: *RequestTranslationContext,
) OOM!?lsp.types.ClientCapabilities.TextDocument.Completion.EditRange {
    return switch (edit_range) {
        .range => |range| .{ .range = (try map.zigRangeToZy(range)) orelse return null },
        .edit_range_with_insert_replace => |ranges| .{ .edit_range_with_insert_replace = .{
            .insert = (try map.zigRangeToZy(ranges.insert)) orelse return null,
            .replace = (try map.zigRangeToZy(ranges.replace)) orelse return null,
        } },
    };
}

fn translateTextEdit(edit: types.TextEdit, map: *RequestTranslationContext) OOM!?types.TextEdit {
    return .{
        .range = (try map.zigRangeToZy(edit.range)) orelse return null,
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
    zig_uri: []const u8,
    zy_uri: []const u8,
) OOM!?types.TextDocumentEdit {
    if (!std.mem.eql(u8, edit.textDocument.uri, zig_uri)) return edit;

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
            .uri = zy_uri,
            .version = null,
        },
        .edits = try translated_edits.toOwnedSlice(arena),
    };
}

fn translateAnnotatedTextEdit(edit: types.TextEdit.Annotated, map: *RequestTranslationContext) OOM!?types.TextEdit.Annotated {
    return .{
        .annotationId = edit.annotationId,
        .range = (try map.zigRangeToZy(edit.range)) orelse return null,
        .newText = edit.newText,
    };
}

fn translateSnippetTextEdit(edit: types.TextDocumentEdit.Snippet, map: *RequestTranslationContext) OOM!?types.TextDocumentEdit.Snippet {
    return .{
        .range = (try map.zigRangeToZy(edit.range)) orelse return null,
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

const zls_position_encodings = [_]types.PositionEncodingKind{.@"utf-8"};
const zls_hover_content_formats = [_]types.MarkupKind{ .markdown, .plaintext };
const zls_diagnostic_tags = [_]types.DiagnosticTag{ .Unnecessary, .Deprecated };
pub const semantic_token_types = [_][]const u8{
    "namespace",
    "type",
    "class",
    "enum",
    "interface",
    "struct",
    "typeParameter",
    "parameter",
    "variable",
    "property",
    "enumMember",
    "event",
    "function",
    "method",
    "macro",
    "keyword",
    "modifier",
    "comment",
    "string",
    "escapeSequence",
    "number",
    "regexp",
    "operator",
    "decorator",
    "errorTag",
    "builtin",
    "label",
    "keywordLiteral",
};
pub const semantic_token_modifiers = [_][]const u8{
    "declaration",
    "definition",
    "readonly",
    "static",
    "deprecated",
    "abstract",
    "async",
    "modification",
    "documentation",
    "defaultLibrary",
    "generic",
    "mutable",
    "_",
};
const zls_semantic_token_formats = [_]types.TokenFormat{.relative};

fn zlsInitializeParams() types.InitializeParams {
    return .{
        .processId = null,
        .clientInfo = .{ .name = "lsp_zitron" },
        .capabilities = .{
            .general = .{
                .positionEncodings = &zls_position_encodings,
            },
            .textDocument = .{
                .completion = .{
                    .completionItem = .{
                        .snippetSupport = true,
                    },
                },
                .hover = .{
                    .contentFormat = &zls_hover_content_formats,
                },
                .signatureHelp = .{
                    .signatureInformation = .{
                        .documentationFormat = &zls_hover_content_formats,
                        .parameterInformation = .{
                            .labelOffsetSupport = true,
                        },
                        .activeParameterSupport = true,
                    },
                    .contextSupport = true,
                },
                .documentSymbol = .{
                    .hierarchicalDocumentSymbolSupport = true,
                },
                .publishDiagnostics = .{
                    .relatedInformation = true,
                    .tagSupport = .{ .valueSet = &zls_diagnostic_tags },
                    .versionSupport = true,
                    .codeDescriptionSupport = true,
                    .dataSupport = true,
                },
                .inlayHint = .{},
                .semanticTokens = .{
                    .requests = .{
                        .range = .{ .bool = true },
                        .full = .{ .client_semantic_tokens_request_full_delta = .{ .delta = true } },
                    },
                    .tokenTypes = &semantic_token_types,
                    .tokenModifiers = &semantic_token_modifiers,
                    .formats = &zls_semantic_token_formats,
                    .overlappingTokenSupport = false,
                    .multilineTokenSupport = false,
                },
            },
        },
    };
}

fn warnIfZlsSemanticTokenLegendDrift(provider: ?types.ServerCapabilities.SemanticTokensOptions) void {
    const legend = if (provider) |semantic_tokens| switch (semantic_tokens) {
        .semantic_tokens_options => |options| options.legend,
        .semantic_tokens_registration_options => |options| options.legend,
    } else {
        log.warn("ZLS did not advertise semantic tokens; lsp_zitron static semantic token legend may be stale", .{});
        return;
    };
    if (!semanticTokenLegendMatches(legend)) {
        log.warn("ZLS semantic token legend differs from lsp_zitron static legend; token indices may need updating", .{});
    }
}

fn semanticTokenLegendMatches(legend: types.SemanticTokensLegend) bool {
    return stringSlicesEqual(&semantic_token_types, legend.tokenTypes) and
        stringSlicesEqual(&semantic_token_modifiers, legend.tokenModifiers);
}

fn stringSlicesEqual(expected: []const []const u8, actual: []const []const u8) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs, rhs)) return false;
    }
    return true;
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

const ZitronResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runZitron(
    allocator: std.mem.Allocator,
    io: std.Io,
    zy_path: []const u8,
    zy_text: []const u8,
) Error!ZitronResult {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zitron", "-Ful", zy_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    try std.Io.File.writeStreamingAll(child.stdin.?, io, zy_text);
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

fn zigUriForZyUri(allocator: std.mem.Allocator, uri: []const u8) Error![]u8 {
    const suffix = ".zy";
    if (std.mem.endsWith(u8, uri, suffix)) {
        return try std.fmt.allocPrint(allocator, "{s}.zitron.zig", .{uri[0 .. uri.len - suffix.len]});
    }
    return try std.fmt.allocPrint(allocator, "{s}.zitron.zig", .{uri});
}

fn parseCodeMapForTest(zy_text: []const u8, zig_text: []const u8, zy_path: []const u8) !CodeMap {
    var allocated_zy: ?[]u8 = null;
    defer if (allocated_zy) |zy| testing_allocator.free(zy);
    const effective_zy = if (std.mem.indexOf(u8, zy_text, "// #line") == null) zy_text else zy: {
        allocated_zy = try genericZigCodeZyForZigTest(zig_text);
        break :zy allocated_zy.?;
    };

    const tree = try parseZitronTreeForTest(effective_zy);
    defer tree.destroy();

    const zig = try testing_allocator.dupe(u8, zig_text);
    defer testing_allocator.free(zig);

    var map: CodeMap = .empty;
    errdefer map.deinit(testing_allocator);
    try map.update(testing_allocator, tree.rootNode(), effective_zy, zig, zy_path);
    return map;
}

fn makeTestZigDocument(
    allocator: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    zy_text: []const u8,
    zig_text: []const u8,
) !ZigDocument {
    var map = try parseCodeMapForTest(zy_text, zig_text, "zy.zy");
    errdefer map.deinit(allocator);

    return .{
        .generation_id = @intCast(version),
        .zy_uri = try allocator.dupe(u8, uri),
        .zy_path = try allocator.dupe(u8, "zy.zy"),
        .zy_text = try allocator.dupe(u8, zy_text),
        .zig_uri = try zigUriForZyUri(allocator, uri),
        .zig_text = try allocator.dupe(u8, zig_text),
        .code_map = map,
        .generation_error = null,
        .grammar_diagnostics = &.{},
        .zls_diagnostics = &.{},
        .zls_diagnostics_version = null,
        .version = version,
    };
}

fn makeTestDocumentState(
    allocator: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    zy_text: []const u8,
    zig_text: []const u8,
) !DocumentState {
    return .{
        .current = try makeTestZigDocument(allocator, uri, version, zy_text, zig_text),
        .latest_requested_version = version,
        .in_flight_version = null,
        .opened = false,
        .zls_synced_generation_id = null,
        .semantic_tokens_current = null,
        .semantic_tokens = .empty,
        .next_semantic_tokens_result_id = 1,
    };
}

fn setTestSemanticTokensCurrent(
    state: *DocumentState,
    allocator: std.mem.Allocator,
    version: i32,
    zy_text: []const u8,
    zig_text: []const u8,
    data: []const u32,
) !void {
    const owned_data = try allocator.dupe(u32, data);
    errdefer allocator.free(owned_data);
    state.semantic_tokens_current = try SemanticTokenCollection.initOwned(
        allocator,
        version,
        zy_text,
        zig_text,
        owned_data,
    );
}

fn requestTranslationContextForTest(
    map: *CodeMap,
    zy_text: []const u8,
    zig_text: []const u8,
    position: types.Position,
) !RequestTranslationContext {
    return .{
        .allocator = testing_allocator,
        .map = map,
        .document_version = 1,
        .zy_text = zy_text,
        .zig_text = zig_text,
        .active_span_index = map.zySpanIndexForPosition(position) orelse return error.UnexpectedCodeMap,
    };
}

fn genericZigCodeZyForZigTest(zig_text: []const u8) OOM![]u8 {
    var max_zy_line: u32 = 0;
    var zig_line_count: u32 = 0;
    var zig_lines = std.mem.splitScalar(u8, zig_text, '\n');
    while (zig_lines.next()) |line| {
        if (parseLineDirective(line)) |directive| {
            max_zy_line = @max(max_zy_line, directive.line);
        }
        zig_line_count += 1;
    }

    var zy: std.ArrayList(u8) = .empty;
    errdefer zy.deinit(testing_allocator);
    try zy.appendSlice(testing_allocator, "%code {\n");
    for (0..max_zy_line + zig_line_count + 1) |_| {
        try zy.append(testing_allocator, '\n');
    }
    try zy.appendSlice(testing_allocator, "}\n");
    return try zy.toOwnedSlice(testing_allocator);
}

fn parseZitronTreeForTest(zy_text: []const u8) !*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(zitronLanguage());
    return parser.parseString(zy_text, null) orelse error.ParseFailed;
}

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

test "code map translates zy and zig positions" {
    const zig =
        \\const std = @import("std");
        \\// #line 10 samples/calc.zy
        \\ answer = A;
        \\// #line 50 samples/calc.zig
        \\const zig_only = true;
        \\// #line 11 samples/calc.zy
        \\ next = answer;
    ;

    var map = try parseCodeMapForTest(zig, zig, "samples/calc.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Position{ .line = 2, .character = 5 }, map.zyPositionToZig(.{
        .line = 9,
        .character = 5,
    }).?);
    try expectEqual(types.Position{ .line = 10, .character = 8 }, map.zigPositionToZy(.{
        .line = 6,
        .character = 8,
    }).?);
    try expectEqual(@as(?types.Position, null), map.zigPositionToZy(.{
        .line = 4,
        .character = 0,
    }));
}

test "code map extraction preserves line directive text" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
        \\rule ::= TOKEN. { result = token; }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\
        \\const answer = 42;
        \\// #line 4 zy.zy
        \\ result = token;
        \\// #line 99 zy.zig
        \\const zig_only = true;
    ;
    const extracted = try testing_allocator.dupe(u8, zig);
    defer testing_allocator.free(extracted);
    const tree = try parseZitronTreeForTest(zy);
    defer tree.destroy();
    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);

    try map.update(testing_allocator, tree.rootNode(), zy, extracted, "zy.zy");

    try expectEqualStrings(zig, extracted);
    try expectEqual(@as(usize, 2), map.len());
    try expectEqual(types.Position{ .line = 2, .character = 5 }, map.zyPositionToZig(.{
        .line = 1,
        .character = 5,
    }).?);
    try expectEqual(types.Position{ .line = 3, .character = 8 }, map.zigPositionToZy(.{
        .line = 4,
        .character = 8,
    }).?);
}

test "code map translates only fully mapped zig ranges" {
    const zig =
        \\// #line 20 zy.zy
        \\const a = 1;
        \\const b = 2;
        \\// #line 40 zy.zig
        \\const zig_only = true;
    ;

    var map = try parseCodeMapForTest(zig, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Range{
        .start = .{ .line = 19, .character = 2 },
        .end = .{ .line = 20, .character = 7 },
    }, (try map.zigRangeToZy(.{
        .start = .{ .line = 1, .character = 2 },
        .end = .{ .line = 2, .character = 7 },
    })).?);

    try expectEqual(@as(?types.Range, null), try map.zigRangeToZy(.{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    }));
}

test "code map stores one span for a multi-line mapped range" {
    const zig =
        \\// #line 20 zy.zy
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ;

    var map = try parseCodeMapForTest(zig, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(@as(u32, 3), map.zig_span.items[0].line_count);
    try expectEqual(types.Position{ .line = 21, .character = 9 }, map.zigPositionToZy(.{
        .line = 3,
        .character = 9,
    }).?);
}

test "code map handles duplicate line directives deterministically" {
    const zig =
        \\// #line 5 zy.zy
        \\const first = 1;
        \\// #line 5 zy.zy
        \\const second = 2;
    ;

    var map = try parseCodeMapForTest(zig, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(types.Position{ .line = 1, .character = 6 }, map.zyPositionToZig(.{
        .line = 4,
        .character = 6,
    }).?);
    try expectEqual(types.Position{ .line = 4, .character = 6 }, map.zigPositionToZy(.{
        .line = 3,
        .character = 6,
    }).?);
}

test "code map stores zy and zig byte ranges" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
        \\rule ::= TOKEN. { result = token; }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\
        \\const answer = 42;
        \\// #line 4 zy.zy
        \\ result = token; // #line 99 zy.zig
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 2), map.len());

    const code_zig_span = map.zig_span.items[0];
    const code_zy_range = map.zy_range.items[0];
    try expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, zy, "{\n").? + 1)), code_zy_range.start_byte);
    try expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, zy, "}\n").?)), code_zy_range.end_byte);
    try expectEqual(std.mem.indexOf(u8, zig, "\n\n").? + 1, code_zig_span.zig_range.start);
    try expectEqual(std.mem.indexOf(u8, zig, "// #line 4").?, code_zig_span.zig_range.end);

    const action_zig_span = map.zig_span.items[1];
    const action_zy_range = map.zy_range.items[1];
    try expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, zy, "{ result").? + 1)), action_zy_range.start_byte);
    try expectEqual(@as(u32, @intCast(std.mem.lastIndexOfScalar(u8, zy, '}').?)), action_zy_range.end_byte);
    try expectEqual(std.mem.indexOf(u8, zig, " result").?, action_zig_span.zig_range.start);
    try expectEqual(zig.len, action_zig_span.zig_range.end);
}

test "code map marks directive shortcuts as fast column mappings" {
    const zy =
        \\%include {
        \\const include_answer = 1;
        \\}
        \\%code {
        \\const code_answer = 2;
        \\}
        \\rule ::= TOKEN. { result = token; }
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const include_answer = 1;
        \\// #line 5 zy.zy
        \\const code_answer = 2;
        \\// #line 7 zy.zy
        \\ result = token;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 3), map.len());
    try std.testing.expect(map.fast_column_mapping.items[0]);
    try std.testing.expect(map.fast_column_mapping.items[1]);
    try std.testing.expect(!map.fast_column_mapping.items[2]);
}

test "directive shortcut fast mapping honors first-line zy column skew" {
    const zy =
        \\%code { const code_answer = 2; }
        \\%include { const include_answer = 1; }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\const code_answer = 2;
        \\// #line 2 zy.zy
        \\const include_answer = 1;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(@as(usize, 2), map.len());
    try std.testing.expect(map.fast_column_mapping.items[0]);
    try std.testing.expect(map.fast_column_mapping.items[1]);

    const zy_code_answer = std.mem.indexOf(u8, zy, "code_answer").?;
    const zig_code_answer = std.mem.indexOf(u8, zig, "code_answer").?;
    const zy_include_answer = std.mem.indexOf(u8, zy, "include_answer").?;
    const zig_include_answer = std.mem.indexOf(u8, zig, "include_answer").?;

    try expectEqual(types.Range{
        .start = lsp.offsets.indexToPosition(zig, zig_code_answer, .@"utf-8"),
        .end = lsp.offsets.indexToPosition(zig, zig_code_answer + "code_answer".len, .@"utf-8"),
    }, (try zyRangeToZigRange(
        testing_allocator,
        &map,
        0,
        zy,
        zig,
        .{
            .start = lsp.offsets.indexToPosition(zy, zy_code_answer, .@"utf-8"),
            .end = lsp.offsets.indexToPosition(zy, zy_code_answer + "code_answer".len, .@"utf-8"),
        },
    )).?);

    try expectEqual(types.Range{
        .start = lsp.offsets.indexToPosition(zig, zig_include_answer, .@"utf-8"),
        .end = lsp.offsets.indexToPosition(zig, zig_include_answer + "include_answer".len, .@"utf-8"),
    }, (try zyRangeToZigRange(
        testing_allocator,
        &map,
        0,
        zy,
        zig,
        .{
            .start = lsp.offsets.indexToPosition(zy, zy_include_answer, .@"utf-8"),
            .end = lsp.offsets.indexToPosition(zy, zy_include_answer + "include_answer".len, .@"utf-8"),
        },
    )).?);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var zig_tokens = [_]u32{
        1, 6, "code_answer".len,    8, 0,
        2, 6, "include_answer".len, 8, 0,
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateSemanticTokenData(
        arena_state.allocator(),
        &zig_tokens,
        &context,
    );

    try expectEqualSlices(u32, &.{
        0, 14, "code_answer".len,    8, 0,
        1, 17, "include_answer".len, 8, 0,
    }, translated);
    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(0));
}

test "directive shortcut fast mapping clamps ranges before line directive span" {
    const zy =
        \\rule ::= TOKEN. {
        \\const answer = 42;
        \\}
    ;
    const zig = "const answer = 42;";

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 1,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = 16,
        .end_byte = zy.len - 1,
        .start_point = .{ .row = 0, .column = 16 },
        .end_point = .{ .row = 2, .column = 0 },
    });
    try map.fast_column_mapping.append(testing_allocator, true);
    try map.rebuildZyOrder(testing_allocator);

    try expectEqual(types.Position{ .line = 0, .character = 0 }, map.zyPositionToZigInSpanFromText(0, zy, .{
        .line = 0,
        .character = 16,
    }));
    try expectEqual(types.Range{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 8 },
    }, (try zyRangeToZigRange(
        testing_allocator,
        &map,
        0,
        zy,
        zig,
        .{
            .start = .{ .line = 0, .character = 16 },
            .end = .{ .line = 1, .character = 8 },
        },
    )).?);
}

test "code map reports optimized-away code blocks as unmapped" {
    const zy =
        \\%impl @first(A) {
        \\    A = B;
        \\}
        \\%impl @second(B) {
        \\    B = C;
        \\}
    ;
    const zig =
        \\// #line 1 zy.zy
        \\    yygotominor.yy0 = yymsp[0].minor.yy42;
    ;

    const tree = try parseZitronTreeForTest(zy);
    defer tree.destroy();
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    const mapped_range = (zigCodeSpanForLine(zy, tree.rootNode(), 1) orelse return error.UnexpectedCodeMap).range;
    const unmapped_range = (zigCodeSpanForLine(zy, tree.rootNode(), 4) orelse return error.UnexpectedCodeMap).range;
    try std.testing.expect(map.indexForZyRange(mapped_range) != null);
    try expectEqual(@as(?usize, null), map.indexForZyRange(unmapped_range));
}

test "alias code block rename refuses unmapped zy blocks" {
    const zy =
        \\%impl @first(A) {
        \\    A = B;
        \\}
        \\%impl @second(B) {
        \\    B = C;
        \\}
    ;
    const zig =
        \\// #line 1 zy.zy
        \\    yygotominor.yy0 = yymsp[0].minor.yy42;
    ;
    const uri = "file:///zy.zy";

    const tree = try parseZitronTreeForTest(zy);
    defer tree.destroy();
    const mapped_range = (zigCodeSpanForLine(zy, tree.rootNode(), 1) orelse return error.UnexpectedCodeMap).range;
    const unmapped_range = (zigCodeSpanForLine(zy, tree.rootNode(), 4) orelse return error.UnexpectedCodeMap).range;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    errdefer map.deinit(testing_allocator);

    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, .{
        .current = .{
            .generation_id = 1,
            .zy_uri = try testing_allocator.dupe(u8, uri),
            .zy_path = try testing_allocator.dupe(u8, "zy.zy"),
            .zy_text = try testing_allocator.dupe(u8, zy),
            .zig_uri = try zigUriForZyUri(testing_allocator, uri),
            .zig_text = try testing_allocator.dupe(u8, zig),
            .code_map = map,
            .generation_error = null,
            .grammar_diagnostics = &.{},
            .zls_diagnostics = &.{},
            .zls_diagnostics_version = null,
            .version = 1,
        },
        .latest_requested_version = 1,
        .in_flight_version = null,
        .opened = false,
        .zls_synced_generation_id = null,
        .semantic_tokens_current = null,
        .semantic_tokens = .empty,
        .next_semantic_tokens_result_id = 1,
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

test "ZLS initialize advertises snippet completion support" {
    const params = zlsInitializeParams();
    const text_document = params.capabilities.textDocument orelse return error.UnexpectedCapability;
    const completion = text_document.completion orelse return error.UnexpectedCapability;
    const completion_item = completion.completionItem orelse return error.UnexpectedCapability;

    try std.testing.expect(completion_item.snippetSupport orelse false);

    const signature_help = text_document.signatureHelp orelse return error.UnexpectedCapability;
    const signature_information = signature_help.signatureInformation orelse return error.UnexpectedCapability;
    try std.testing.expect(signature_help.contextSupport orelse false);
    try std.testing.expect(signature_information.activeParameterSupport orelse false);
}

test "forward requests return null while generation has errors" {
    const uri = "file:///zy.zy";
    const zy = "%code { broken }";
    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    var zig_middleware: ZigMiddleware = .{ .mode = .{ .enabled = &middleware } };

    switch (zig_middleware.mode) {
        .disabled => unreachable,
        .enabled => |mware| {
            const key = try testing_allocator.dupe(u8, uri);
            errdefer testing_allocator.free(key);
            try mware.documents.put(testing_allocator, key, .{
                .current = .{
                    .generation_id = 1,
                    .zy_uri = try testing_allocator.dupe(u8, uri),
                    .zy_path = try testing_allocator.dupe(u8, "zy.zy"),
                    .zy_text = try testing_allocator.dupe(u8, zy),
                    .zig_uri = try zigUriForZyUri(testing_allocator, uri),
                    .zig_text = try testing_allocator.dupe(u8, ""),
                    .code_map = .empty,
                    .generation_error = try testing_allocator.dupe(u8, "generation failed"),
                    .grammar_diagnostics = &.{},
                    .zls_diagnostics = &.{},
                    .zls_diagnostics_version = null,
                    .version = 1,
                },
                .latest_requested_version = 1,
                .in_flight_version = null,
                .opened = false,
                .zls_synced_generation_id = null,
                .semantic_tokens_current = null,
                .semantic_tokens = .empty,
                .next_semantic_tokens_result_id = 1,
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

    try std.testing.expect(@hasDecl(ZigMiddleware, "forwardSignatureHelp"));
    const signature_help_result = try zig_middleware.forwardSignatureHelp(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 0 },
    });
    try std.testing.expect(signature_help_result == null);

    const inlay_result = try zig_middleware.forwardInlayHint(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 16 },
        },
    });
    try std.testing.expect(inlay_result == null);

    try std.testing.expect(@hasDecl(ZigMiddleware, "forwardDocumentHighlight"));
    const highlight_result = try zig_middleware.forwardDocumentHighlight(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 0 },
    });
    try std.testing.expect(highlight_result == null);
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

test "ZLS diagnostics translate to zy ranges and default zy" {
    const zy =
        \\rule ::= value. {
        \\    const result: MissingType = value;
        \\}
    ;
    const zig =
        \\// #line 1 zy.zy
        \\    const result: MissingType = value;
    ;
    const missing_start = std.mem.indexOf(u8, zig, "MissingType") orelse return error.NeedleNotFound;
    const missing_end = missing_start + "MissingType".len;
    const tags = [_]types.Diagnostic.Tag{.Unnecessary};
    const zls_diagnostics = [_]types.Diagnostic{
        .{
            .range = .{
                .start = lsp.offsets.indexToPosition(zig, missing_start, .@"utf-8"),
                .end = lsp.offsets.indexToPosition(zig, missing_end, .@"utf-8"),
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
            .message = "zig-only diagnostic",
        },
    };

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    errdefer map.deinit(testing_allocator);
    var doc: ZigDocument = .{
        .generation_id = 1,
        .zy_uri = try testing_allocator.dupe(u8, "file:///zy.zy"),
        .zy_path = try testing_allocator.dupe(u8, "zy.zy"),
        .zy_text = try testing_allocator.dupe(u8, zy),
        .zig_uri = try testing_allocator.dupe(u8, "file:///zy.zitron.zig"),
        .zig_text = try testing_allocator.dupe(u8, zig),
        .code_map = map,
        .generation_error = null,
        .grammar_diagnostics = &.{},
        .zls_diagnostics = &.{},
        .zls_diagnostics_version = null,
        .version = 1,
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
    var state = try makeTestDocumentState(testing_allocator, "file:///zy.zy", 1, "zy", "zig");
    defer state.deinit(testing_allocator);

    try std.testing.expect(state.currentForVersion(1) != null);
    try std.testing.expect(state.currentForVersion(2) == null);
}

test "document state rejects version-null diagnostics while generation is in flight" {
    var state = try makeTestDocumentState(testing_allocator, "file:///zy.zy", 1, "zy", "zig");
    defer state.deinit(testing_allocator);

    state.zls_synced_generation_id = state.current.?.generation_id;
    state.in_flight_version = 2;
    try std.testing.expect(state.currentForVersion(null) == null);
}

test "document state accepts version-null diagnostics when current generation was synced" {
    var state = try makeTestDocumentState(testing_allocator, "file:///zy.zy", 1, "zy", "zig");
    defer state.deinit(testing_allocator);

    state.zls_synced_generation_id = state.current.?.generation_id;
    try std.testing.expect(state.currentForVersion(null) != null);
}

test "ZLS diagnostics for stale generation do not replace current diagnostics" {
    const uri = "file:///zy.zy";
    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, try makeTestDocumentState(
        testing_allocator,
        uri,
        2,
        "rule ::= TOKEN. { result = token; }",
        "// #line 1 zy.zy\n result = token;",
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
        \\  "uri": "file:///zy.zitron.zig",
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

test "ZLS diagnostics with null version publish after repeated current syncs" {
    const uri = "file:///zy.zy";
    const zy =
        \\rule ::= value. {
        \\    const result: MissingType = value;
        \\}
    ;
    const zig =
        \\// #line 1 zy.zy
        \\    const result: MissingType = value;
    ;

    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, try makeTestDocumentState(testing_allocator, uri, 2, zy, zig));
    defer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var state = removed.value;
        state.deinit(testing_allocator);
        middleware.documents.deinit(testing_allocator);
    }
    {
        const state = middleware.documents.getPtr(uri).?;
        state.zls_synced_generation_id = state.current.?.generation_id;
    }

    const params_json =
        \\{
        \\  "uri": "file:///zy.zitron.zig",
        \\  "version": null,
        \\  "diagnostics": [{
        \\    "range": {
        \\      "start": { "line": 1, "character": 18 },
        \\      "end": { "line": 1, "character": 29 }
        \\    },
        \\    "severity": 1,
        \\    "zy": "zls",
        \\    "message": "use of undeclared identifier 'MissingType'"
        \\  }]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing_allocator, params_json, .{});
    defer parsed.deinit();

    const published = (try middleware.handleZlsDiagnostics(parsed.value)).?;
    defer testing_allocator.free(published.zy_uri);

    try expectEqual(@as(i32, 2), published.version);
    try expectEqualStrings(uri, published.zy_uri);
    const state = middleware.documents.getPtr(uri).?;
    const current = state.currentForVersion(2).?;
    try expectEqual(@as(usize, 1), current.zls_diagnostics.len);
    try expectEqual(@as(i32, 2), current.zls_diagnostics_version.?);
    try expectEqualStrings("use of undeclared identifier 'MissingType'", current.zls_diagnostics[0].message);
}

test "request span translator applies zy column offset" {
    const zy =
        \\rule ::= TOKEN.   { result = token; }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ result = token;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    const zy_position = lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "result").?, .@"utf-8");
    const translator = try map.spanTranslator(
        testing_allocator,
        0,
        zy,
        zig,
        map.zySpanIndexForPosition(zy_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(types.Position{
        .line = 1,
        .character = @intCast(std.mem.indexOf(u8, " result = token;", "result").?),
    }, sharedPosition(translator.zyPositionToZig(zy_position)) orelse return error.UnexpectedCodeMap);
}

test "request span translator nulls mutated zig aliases" {
    const zy =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    const zy_position = lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "pik_elist_append").?, .@"utf-8");
    const translator = try map.spanTranslator(
        testing_allocator,
        0,
        zy,
        zig,
        map.zySpanIndexForPosition(zy_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(types.Position{
        .line = 1,
        .character = @intCast(std.mem.indexOf(u8, zig, "pik_elist_append").? - std.mem.lastIndexOfScalar(u8, zig[0..std.mem.indexOf(u8, zig, "pik_elist_append").?], '\n').? - 1),
    }, sharedPosition(translator.zyPositionToZig(zy_position)) orelse return error.UnexpectedCodeMap);

    try expectEqual(
        lsp.offsets.indexToPosition(zig, std.mem.indexOf(u8, zig, "yygotominor").?, .@"utf-8"),
        sharedPosition(translator.zyPositionToZig(lsp.offsets.indexToPosition(
            zy,
            std.mem.indexOf(u8, zy, "A =").?,
            .@"utf-8",
        ))) orelse return error.UnexpectedCodeMap,
    );

    try std.testing.expect(translator.zigRangeToZy(.{
        .start = lsp.offsets.indexToPosition(zig, std.mem.indexOf(u8, zig, "yygotominor").?, .@"utf-8"),
        .end = lsp.offsets.indexToPosition(zig, std.mem.indexOf(u8, zig, " =").?, .@"utf-8"),
    }) == null);
}

test "request span translator maps zig alias boundary points" {
    const zy =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    const zy_call = std.mem.indexOf(u8, zy, "pik_elist_append").?;
    const zy_alias = zy_call + std.mem.indexOf(u8, zy[zy_call..], "X").?;
    const zig_call = std.mem.indexOf(u8, zig, "pik_elist_append").?;
    const zig_alias = zig_call + std.mem.indexOf(u8, zig[zig_call..], "yymsp").?;
    const zy_position = lsp.offsets.indexToPosition(zy, zy_alias, .@"utf-8");
    const zig_position = lsp.offsets.indexToPosition(zig, zig_alias, .@"utf-8");

    const translator = try map.spanTranslator(
        testing_allocator,
        0,
        zy,
        zig,
        map.zySpanIndexForPosition(zy_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(
        zy_position,
        sharedPosition(translator.zigPositionToZy(zig_position)) orelse return error.UnexpectedCodeMap,
    );
    try std.testing.expect(sharedPosition(translator.zigPositionToZy(lsp.offsets.indexToPosition(
        zig,
        zig_alias + 1,
        .@"utf-8",
    ))) == null);
    try std.testing.expect(translator.zigRangeToZy(.{
        .start = zig_position,
        .end = lsp.offsets.indexToPosition(zig, zig_alias + "yymsp".len, .@"utf-8"),
    }) == null);

    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = map.zySpanIndexForPosition(zy_position) orelse return error.UnexpectedCodeMap,
    };
    defer context.deinit();

    const hints = [_]types.InlayHint{.{
        .position = zig_position,
        .label = .{ .string = "obj:" },
        .kind = .Parameter,
    }};

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateInlayHints(
        arena_state.allocator(),
        &hints,
        &context,
        "file:///zy.zitron.zig",
        "file:///zy.zy",
    );

    try expectEqual(@as(usize, 1), translated.len);
    try expectEqual(zy_position, translated[0].position);
}

test "alias code block rename edits come from zy-side deletes" {
    const zy =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, @X, local_X); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = pik_elist_append(p, yymsp[0].minor.yy42, local_X);
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zy_range = map.zy_range.items[0];
    const zig_range = map.zig_span.items[0].zig_range;
    var difference = Diff.init(.default);
    defer difference.deinit(testing_allocator);
    _ = try difference.diff(
        testing_allocator,
        zy[zy_range.start_byte..zy_range.end_byte],
        zig[zig_range.start..zig_range.end],
    );

    var edits: std.ArrayList(types.TextEdit) = .empty;
    defer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);
    try appendAliasRenameEditsFromDiff(
        arena,
        &edits,
        &seen_starts,
        zy,
        zy_range,
        zig,
        zig_range,
        difference.edits.items,
        "X",
        "Item",
        .@"utf-8",
    );

    try expectEqual(@as(usize, 1), edits.items.len);
    try expectEqualStrings("@X", lsp.offsets.rangeToSlice(zy, edits.items[0].range, .@"utf-8"));
    try expectEqualStrings("@Item", edits.items[0].newText);
}

test "alias code block rename catches lhs aliases matched inside zig types" {
    const zy =
        \\form(F) ::= list(L).   { F = L; // F-overwrites-L }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ (yymsp - 1)[1].minor.@"?Form" = (yymsp - 1)[1].minor.@"Form"; // F-overwrites-L
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zy_range = map.zy_range.items[0];
    const zig_range = map.zig_span.items[0].zig_range;
    var difference = Diff.init(.default);
    defer difference.deinit(testing_allocator);
    _ = try difference.diff(
        testing_allocator,
        zy[zy_range.start_byte..zy_range.end_byte],
        zig[zig_range.start..zig_range.end],
    );

    var edits: std.ArrayList(types.TextEdit) = .empty;
    defer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);
    try appendAliasRenameEditsFromDiff(
        arena,
        &edits,
        &seen_starts,
        zy,
        zy_range,
        zig,
        zig_range,
        difference.edits.items,
        "F",
        "FormValue",
        .@"utf-8",
    );

    try expectEqual(@as(usize, 1), edits.items.len);
    try expectEqualStrings("F", lsp.offsets.rangeToSlice(zy, edits.items[0].range, .@"utf-8"));
    try expectEqualStrings("FormValue", edits.items[0].newText);
    try expectEqual(
        std.mem.indexOf(u8, zy, "F =").?,
        lsp.offsets.positionToIndex(zy, edits.items[0].range.start, .@"utf-8"),
    );
}

test "request span translator handles zig line directive after action" {
    const zy =
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
        \\// #line 200 zy.zig
        \\zig_only();
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(@as(usize, 1), map.len());
    try expectEqual(std.mem.indexOf(u8, zig, "// #line 200").?, map.zig_span.items[0].zig_range.end);
    const zy_position = lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "pik_elist_append").?, .@"utf-8");
    const translator = try map.spanTranslator(
        testing_allocator,
        0,
        zy,
        zig,
        map.zySpanIndexForPosition(zy_position) orelse return error.UnexpectedCodeMap,
    );

    try expectEqual(lsp.offsets.indexToPosition(
        zig,
        std.mem.indexOf(u8, zig, "pik_elist_append").?,
        .@"utf-8",
    ), sharedPosition(translator.zyPositionToZig(lsp.offsets.indexToPosition(
        zy,
        std.mem.indexOf(u8, zy, "pik_elist_append").?,
        .@"utf-8",
    ))) orelse return error.UnexpectedCodeMap);
}

test "request translation context maps reference ranges in other spans" {
    const zy =
        \\document ::= statement_list(X).  { pik_render(p, X); }
        \\statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ pik_render(p, yymsp[0].minor.yy0);
        \\// #line 2 zy.zy
        \\ yygotominor.yy0 = pik_elist_append(p, null, yymsp[0].minor.yy42);
        \\// #line 200 zy.zig
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    const active_position = lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "pik_render").?, .@"utf-8");
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = map.zySpanIndexForPosition(active_position) orelse return error.UnexpectedCodeMap,
    };
    defer context.deinit();

    const zig_call = std.mem.indexOf(u8, zig, "pik_elist_append").?;
    const locations = [_]types.Location{.{
        .uri = "file:///zy.zitron.zig",
        .range = .{
            .start = lsp.offsets.indexToPosition(zig, zig_call, .@"utf-8"),
            .end = lsp.offsets.indexToPosition(zig, zig_call + "pik_elist_append".len, .@"utf-8"),
        },
    }};

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = (try translateLocations(
        arena_state.allocator(),
        &locations,
        &context,
        "file:///zy.zitron.zig",
        "file:///zy.zy",
    )) orelse return error.UnexpectedCodeMap;

    const zy_call = std.mem.indexOf(u8, zy, "pik_elist_append").?;
    try expectEqual(lsp.offsets.indexToPosition(zy, zy_call, .@"utf-8"), translated[0].range.start);
    try expectEqual(lsp.offsets.indexToPosition(zy, zy_call + "pik_elist_append".len, .@"utf-8"), translated[0].range.end);
}

test "request translation context maps document highlight ranges" {
    const zy =
        \\rule ::= item. {
        \\    const answer = item;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\    const answer = yymsp[0].minor.yy0;
        \\// #line 200 zy.zig
        \\zig_only();
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    const active_position = lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "answer").?, .@"utf-8");
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = map.zySpanIndexForPosition(active_position) orelse return error.UnexpectedCodeMap,
    };
    defer context.deinit();

    const zig_answer = std.mem.indexOf(u8, zig, "answer").?;
    const zig_only = std.mem.indexOf(u8, zig, "zig_only").?;
    const highlights = [_]types.DocumentHighlight{
        .{
            .range = .{
                .start = lsp.offsets.indexToPosition(zig, zig_answer, .@"utf-8"),
                .end = lsp.offsets.indexToPosition(zig, zig_answer + "answer".len, .@"utf-8"),
            },
            .kind = .Read,
        },
        .{
            .range = .{
                .start = lsp.offsets.indexToPosition(zig, zig_only, .@"utf-8"),
                .end = lsp.offsets.indexToPosition(zig, zig_only + "zig_only".len, .@"utf-8"),
            },
            .kind = .Write,
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = (try translateDocumentHighlights(arena_state.allocator(), &highlights, &context)) orelse return error.UnexpectedCodeMap;
    const zy_answer = std.mem.indexOf(u8, zy, "answer").?;
    try expectEqual(@as(usize, 1), translated.len);
    try expectEqual(lsp.offsets.indexToPosition(zy, zy_answer, .@"utf-8"), translated[0].range.start);
    try expectEqual(lsp.offsets.indexToPosition(zy, zy_answer + "answer".len, .@"utf-8"), translated[0].range.end);
    try expectEqual(types.DocumentHighlight.Kind.Read, translated[0].kind.?);
}

test "request translation context rejects zy positions before active zy range" {
    const zy = "rule ::= item. { const answer = item; }";
    const zig =
        \\// #line 1 zy.zy
        \\ const answer = yymsp[0].minor.yy0;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    const grammar_index = std.mem.indexOf(u8, zy, "item.") orelse return error.NeedleNotFound;
    const grammar_position = lsp.offsets.indexToPosition(zy, grammar_index, .@"utf-8");
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = map.zySpanIndexForPosition(grammar_position) orelse return error.UnexpectedCodeMap,
    };
    defer context.deinit();

    try expectEqual(@as(?types.Position, null), try context.zyPositionToZig(grammar_position));
}

test "request span translator handles one leading newline edit" {
    const zy = "\nconst answer = 42;";
    const zig = "const answer = 42;";
    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = 0,
        .end_byte = @intCast(zy.len),
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = 1, .column = @intCast("const answer = 42;".len) },
    });
    try map.fast_column_mapping.append(testing_allocator, false);
    const translator = try map.spanTranslator(testing_allocator, 0, zy, zig, 0);

    try expectEqual(types.Position{ .line = 0, .character = 6 }, sharedPosition(translator.zyPositionToZig(.{
        .line = 1,
        .character = 6,
    })) orelse return error.UnexpectedCodeMap);
    try expectEqual(types.Position{ .line = 0, .character = 0 }, sharedPosition(translator.zyPositionToZig(.{
        .line = 0,
        .character = 0,
    })) orelse return error.UnexpectedCodeMap);
}

test "translates hover and definition results back to zy ranges" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        zy,
        zig,
        lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "answer").?, .@"utf-8"),
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
        .uri = "file:///zy.zitron.zig",
        .range = .{
            .start = .{ .line = 1, .character = 6 },
            .end = .{ .line = 1, .character = 12 },
        },
    } };
    const translated = try translateDefinition(
        testing_allocator,
        .{ .definition = definition },
        &context,
        "file:///zy.zitron.zig",
        "file:///zy.zy",
    );
    switch (translated.?) {
        .definition => |translated_definition| switch (translated_definition) {
            .location => |location| {
                try expectEqualStrings("file:///zy.zy", location.uri);
                try expectEqual(@as(u32, 1), location.range.start.line);
                try expectEqual(@as(u32, 6), location.range.start.character);
            },
            else => return error.UnexpectedDefinition,
        },
        else => return error.UnexpectedDefinition,
    }
}

test "translates completion edits back to zy ranges" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        zy,
        zig,
        lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "answer").?, .@"utf-8"),
    );
    defer context.deinit();
    try expectEqual(@as(u32, 1), map.zigPositionToZy(.{
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

test "translates inlay hints back to zy positions" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        zy,
        zig,
        lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "answer").?, .@"utf-8"),
    );
    defer context.deinit();

    var label_parts = [_]types.InlayHintLabelPart{.{
        .value = ": i32",
        .location = .{
            .uri = "file:///zig.zig",
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

    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(0));
    const translated = try translateInlayHints(
        arena_state.allocator(),
        &other_hints,
        &context,
        "file:///zig.zig",
        "file:///zy.zy",
    );

    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(0));
    try expectEqual(@as(usize, 2), translated.len);
    try expectEqual(@as(u32, 1), translated[0].position.line);
    try expectEqual(@as(u32, 12), translated[0].position.character);
    try expectEqual(@as(u32, 1), translated[0].textEdits.?[0].range.start.line);
    switch (translated[0].label) {
        .inlay_hint_label_parts => |parts| {
            try expectEqualStrings("file:///zy.zy", parts[0].location.?.uri);
            try expectEqual(@as(u32, 1), parts[0].location.?.range.start.line);
            try expectEqual(@as(u32, 6), parts[0].location.?.range.start.character);
        },
        else => return error.UnexpectedInlayHint,
    }
}

test "translates inlay hints on first block line with zy column skew" {
    const prefix = "prefix ";
    const zy = prefix ++ "const answer = 42;";
    const zig = "const answer = 42;";

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = prefix.len,
        .end_byte = @intCast(zy.len),
        .start_point = .{ .row = 0, .column = prefix.len },
        .end_point = .{ .row = 0, .column = @intCast(zy.len) },
    });
    try map.fast_column_mapping.append(testing_allocator, false);
    try map.rebuildZyOrder(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
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
        "file:///zig.zig",
        "file:///zy.zy",
    );

    try expectEqual(@as(usize, 1), translated.len);
    try expectEqual(types.Position{ .line = 0, .character = prefix.len + 12 }, translated[0].position);
}

test "zig position cursor translates zig ranges" {
    const prefix = "prefix ";
    const zy = prefix ++ "const answer = 42;";
    const zig = "const answer = 42;";

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = prefix.len,
        .end_byte = @intCast(zy.len),
        .start_point = .{ .row = 0, .column = prefix.len },
        .end_point = .{ .row = 0, .column = @intCast(zy.len) },
    });
    try map.fast_column_mapping.append(testing_allocator, false);
    try map.rebuildZyOrder(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var cursor = ZigPositionCursor{ .context = &context, .span_index = null };
    try expectEqual(types.Range{
        .start = .{ .line = 0, .character = 13 },
        .end = .{ .line = 0, .character = 19 },
    }, (try cursor.zigRangeToZy(.{
        .start = .{ .line = 0, .character = 6 },
        .end = .{ .line = 0, .character = 12 },
    })) orelse return error.UnexpectedCodeMap);
    try expectEqual(types.Range{
        .start = .{ .line = 0, .character = 22 },
        .end = .{ .line = 0, .character = 24 },
    }, (try cursor.zigRangeToZy(.{
        .start = .{ .line = 0, .character = 15 },
        .end = .{ .line = 0, .character = 17 },
    })) orelse return error.UnexpectedCodeMap);
}

test "span translators keep independent diff cursors" {
    const zy_line0 = "aaa bbb ccc";
    const zy_line1 = "mmm nnn ooo";
    const zig_line0 = "aaa XX bbb ccc";
    const zig_line1 = "mmm YY nnn ooo";
    const zy = zy_line0 ++ "\n" ++ zy_line1;
    const zig = zig_line0 ++ "\n" ++ zig_line1;

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig_line0.len },
    });
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 1,
        .zig_line = 1,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = zig_line0.len + 1, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = 0,
        .end_byte = zy_line0.len,
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = 0, .column = zy_line0.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = zy_line0.len + 1,
        .end_byte = zy.len,
        .start_point = .{ .row = 1, .column = 0 },
        .end_point = .{ .row = 1, .column = zy_line1.len },
    });
    try map.fast_column_mapping.append(testing_allocator, false);
    try map.fast_column_mapping.append(testing_allocator, false);
    try map.rebuildZyOrder(testing_allocator);

    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var cursor = ZigPositionCursor{ .context = &context, .span_index = null };
    try expectEqual(types.Range{
        .start = .{ .line = 0, .character = 4 },
        .end = .{ .line = 0, .character = 7 },
    }, (try cursor.zigRangeToZy(.{
        .start = .{ .line = 0, .character = 7 },
        .end = .{ .line = 0, .character = 10 },
    })) orelse return error.UnexpectedCodeMap);
    const first_cursor = map.translators.at(0).zig_to_zy_cursor;
    try std.testing.expect(first_cursor.edit_index > 0);

    try expectEqual(types.Range{
        .start = .{ .line = 1, .character = 4 },
        .end = .{ .line = 1, .character = 7 },
    }, (try cursor.zigRangeToZy(.{
        .start = .{ .line = 1, .character = 7 },
        .end = .{ .line = 1, .character = 10 },
    })) orelse return error.UnexpectedCodeMap);
    try expectEqual(first_cursor, map.translators.at(0).zig_to_zy_cursor);
    try std.testing.expect(map.translators.at(1).zig_to_zy_cursor.edit_index > 0);
}

test "semantic dirty range mapping uses full covered span extents" {
    const zy =
        \\first(A) ::= token(T). { A = first(T); }
        \\second(B) ::= token(T). { B = second(T); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = first(yymsp[0].minor.yy42);
        \\// #line 2 zy.zy
        \\ yygotominor.yy0 = second(yymsp[0].minor.yy42);
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(map.len(), map.translators.len());

    const ranges = try zyRangeToSortedZigRanges(
        testing_allocator,
        &map,
        1,
        zy,
        zig,
        fullDocumentRange(zy),
    );
    defer testing_allocator.free(ranges);

    try expectEqual(@as(usize, 2), ranges.len);
    try expectEqual(rangeFromByteRange(zig, map.zig_span.items[0].zig_range.start, map.zig_span.items[0].zig_range.end), ranges[0]);
    try expectEqual(rangeFromByteRange(zig, map.zig_span.items[1].zig_range.start, map.zig_span.items[1].zig_range.end), ranges[1]);
    try expectEqual(@as(usize, 0), map.translators.freshLen(1));
}

test "semantic token edits apply to encoded token arrays" {
    const previous = [_]u32{ 0, 0, 5, 1, 0, 0, 6, 3, 2, 0 };
    const edits = [_]types.SemanticTokensEdit{
        .{
            .start = 5,
            .deleteCount = 5,
            .data = &.{ 0, 7, 4, 3, 0 },
        },
    };

    const updated = try applySemanticTokenEdits(testing_allocator, &previous, &edits);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{ 0, 0, 5, 1, 0, 0, 7, 4, 3, 0 }, updated);
}

test "semantic token legend includes ZLS custom entries" {
    try expectEqualStrings("escapeSequence", semantic_token_types[19]);
    try expectEqualStrings("errorTag", semantic_token_types[24]);
    try expectEqualStrings("builtin", semantic_token_types[25]);
    try expectEqualStrings("label", semantic_token_types[26]);
    try expectEqualStrings("keywordLiteral", semantic_token_types[27]);
    try expectEqualStrings("generic", semantic_token_modifiers[10]);
    try expectEqualStrings("mutable", semantic_token_modifiers[11]);
    try expectEqualStrings("_", semantic_token_modifiers[12]);
}

test "semantic token legend drift is detectable" {
    try std.testing.expect(semanticTokenLegendMatches(.{
        .tokenTypes = &semantic_token_types,
        .tokenModifiers = &semantic_token_modifiers,
    }));
    try std.testing.expect(!semanticTokenLegendMatches(.{
        .tokenTypes = &semantic_token_types,
        .tokenModifiers = &.{
            "declaration",
            "definition",
            "readonly",
            "static",
            "deprecated",
            "abstract",
            "async",
            "modification",
            "documentation",
            "defaultLibrary",
            "generic",
            "changed",
            "_",
        },
    }));
}

test "semantic token delta uses one zy-side edit" {
    const previous = [_]u32{ 0, 0, 5, 1, 0, 0, 6, 3, 2, 0 };
    const current = [_]u32{ 0, 0, 5, 1, 0, 0, 7, 4, 3, 0, 1, 2, 6, 4, 0 };

    const edits = try semanticTokenDeltaEdits(testing_allocator, &previous, &current);
    defer freeSemanticTokenEdits(testing_allocator, edits);

    try expectEqual(@as(usize, 1), edits.len);
    try expectEqual(@as(u32, 5), edits[0].start);
    try expectEqual(@as(u32, 5), edits[0].deleteCount);
    try expectEqualSlices(u32, &.{ 0, 7, 4, 3, 0, 1, 2, 6, 4, 0 }, edits[0].data.?);

    const applied = try applySemanticTokenEdits(testing_allocator, &previous, edits);
    defer testing_allocator.free(applied);
    try expectEqualSlices(u32, &current, applied);
}

test "semantic token delta aligns column-shift edit to token slots" {
    const previous = [_]u32{
        0, 0,  5, 1, 0,
        0, 20, 3, 2, 0,
        1, 4,  4, 3, 0,
    };
    const current = [_]u32{
        0, 0, 5, 1, 0,
        0, 5, 3, 2, 0,
        1, 4, 4, 3, 0,
    };

    const edits = try semanticTokenDeltaEdits(testing_allocator, &previous, &current);
    defer freeSemanticTokenEdits(testing_allocator, edits);

    try expectEqual(@as(usize, 1), edits.len);
    try expectEqual(@as(u32, 5), edits[0].start);
    try expectEqual(@as(u32, 5), edits[0].deleteCount);
    try expectEqualSlices(u32, &.{ 0, 5, 3, 2, 0 }, edits[0].data.?);

    const applied = try applySemanticTokenEdits(testing_allocator, &previous, edits);
    defer testing_allocator.free(applied);
    try expectEqualSlices(u32, &current, applied);
}

test "semantic token range rebuild preserves suffix token" {
    const previous = [_]u32{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        2, 0, 4, 3, 0,
    };
    const current_range = [_]u32{
        1, 0, 4, 2, 0,
    };
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
        .current = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
    }, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 2, .character = 0 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0, 5, 1, 0,
        1, 0, 4, 2, 0,
        2, 0, 4, 3, 0,
    }, updated);
}

test "semantic token range rebuild shifts suffix after line delete" {
    const previous = [_]u32{
        0, 0, 5, 1, 0,
        2, 0, 3, 2, 0,
        2, 0, 4, 3, 0,
        1, 0, 6, 4, 0,
    };
    const current_range = [_]u32{
        1, 0, 3, 2, 0,
    };
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 3, .character = 0 },
        },
        .current = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
    }, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 2, .character = 0 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        2, 0, 4, 3, 0,
        1, 0, 6, 4, 0,
    }, updated);
}

test "semantic token range rebuild preserves sparse gaps between returned tokens" {
    const previous = [_]u32{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        1, 0, 4, 3, 0,
        2, 0, 6, 4, 0,
    };
    const current_range = [_]u32{
        1, 0, 3, 2, 0,
        2, 0, 4, 5, 0,
    };
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
        .current = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
    }, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 2, .character = 0 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        1, 0, 4, 3, 0,
        1, 0, 4, 5, 0,
        1, 0, 6, 4, 0,
    }, updated);
}

test "semantic token range rebuild treats returned token overlap as authoritative" {
    const previous = [_]u32{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        1, 0, 4, 3, 0,
        2, 0, 6, 4, 0,
    };
    const current_range = [_]u32{
        2, 0, 4, 5, 0,
    };
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
        .current = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
    }, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 2, .character = 0 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0, 5, 1, 0,
        2, 0, 4, 5, 0,
        2, 0, 6, 4, 0,
    }, updated);
}

test "semantic token range rebuild preserves adjacent sparse omissions" {
    const previous = [_]u32{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        1, 0, 4, 3, 0,
        1, 0, 6, 4, 0,
    };
    const current_range = [_]u32{
        2, 0, 4, 5, 0,
    };
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 2, .character = 0 },
            .end = .{ .line = 3, .character = 0 },
        },
        .current = .{
            .start = .{ .line = 2, .character = 0 },
            .end = .{ .line = 3, .character = 0 },
        },
    }, .{
        .start = .{ .line = 2, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        1, 0, 4, 5, 0,
        1, 0, 6, 4, 0,
    }, updated);
}

test "semantic token range rebuild deletes stale tokens omitted by refreshed range" {
    const previous = [_]u32{
        0, 0, 5, 1, 0,
        1, 0, 3, 2, 0,
        2, 0, 6, 3, 0,
    };
    const current_range = [_]u32{};
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 2, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
        .current = .{
            .start = .{ .line = 2, .character = 0 },
            .end = .{ .line = 2, .character = 0 },
        },
    }, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0, 5, 1, 0,
        3, 0, 6, 3, 0,
    }, updated);
}

test "semantic token range rebuild shifts same-line suffix columns" {
    const previous = [_]u32{
        0, 0,  5, 1, 0,
        0, 10, 3, 2, 0,
    };
    const current_range = [_]u32{};
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 0, .character = 5 },
            .end = .{ .line = 0, .character = 5 },
        },
        .current = .{
            .start = .{ .line = 0, .character = 5 },
            .end = .{ .line = 0, .character = 8 },
        },
    }, .{
        .start = .{ .line = 0, .character = 5 },
        .end = .{ .line = 0, .character = 8 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0,  5, 1, 0,
        0, 13, 3, 2, 0,
    }, updated);
}

test "semantic token range rebuild invalidates insertion inside token" {
    const previous = [_]u32{
        0, 0,  5, 1, 0,
        0, 10, 3, 2, 0,
    };
    const current_range = [_]u32{
        0, 0, 6, 3, 0,
    };
    const previous_index = try semanticTokenIndexFromData(testing_allocator, &previous);
    defer testing_allocator.free(previous_index);

    const updated = try rebuildSemanticTokenDataFromRange(testing_allocator, previous_index, .{
        .previous = .{
            .start = .{ .line = 0, .character = 2 },
            .end = .{ .line = 0, .character = 2 },
        },
        .current = .{
            .start = .{ .line = 0, .character = 2 },
            .end = .{ .line = 0, .character = 3 },
        },
    }, .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 8 },
    }, &current_range);
    defer testing_allocator.free(updated);

    try expectEqualSlices(u32, &.{
        0, 0,  6, 3, 0,
        0, 11, 3, 2, 0,
    }, updated);
}

fn semanticFilterLineTextForTest(allocator: std.mem.Allocator, line_count: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (0..line_count) |_| {
        try text.appendSlice(allocator, "token_line\n");
    }
    return try text.toOwnedSlice(allocator);
}

fn identitySemanticFilterMapForTest(allocator: std.mem.Allocator, text: []const u8, line_count: usize) !CodeMap {
    var map: CodeMap = .empty;
    errdefer map.deinit(allocator);

    try map.zig_span.append(allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = @intCast(line_count),
        .zig_range = .{ .start = 0, .end = text.len },
    });
    try map.zy_range.append(allocator, .{
        .start_byte = 0,
        .end_byte = @intCast(text.len),
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = @intCast(line_count), .column = 0 },
    });
    try map.fast_column_mapping.append(allocator, true);
    try map.rebuildZyOrder(allocator);
    return map;
}

fn semanticFilterTokenDataForTest(allocator: std.mem.Allocator, line_count: usize) ![]u32 {
    const tokens = try allocator.alloc(AbsoluteSemanticToken, line_count);
    defer allocator.free(tokens);
    for (tokens, 0..) |*token, index| {
        token.* = .{
            .line = @intCast(index),
            .character = 0,
            .length = 5,
            .token_type = @intCast(index % 7),
            .token_modifiers = 0,
        };
    }
    return try semanticTokenDataFromIndex(allocator, tokens);
}

fn expectFilteredTokenLines(data: []const u32, expected_lines: []const u32) !void {
    const index = try semanticTokenIndexFromData(testing_allocator, data);
    defer testing_allocator.free(index);

    try expectEqual(expected_lines.len, index.len);
    for (expected_lines, index) |expected_line, token| {
        try expectEqual(expected_line, token.line);
        try expectEqual(@as(u32, 0), token.character);
        try expectEqual(@as(u32, 5), token.length);
    }
}

test "filtered semantic token translation keeps early source range" {
    const line_count = 128;
    const text = try semanticFilterLineTextForTest(testing_allocator, line_count);
    defer testing_allocator.free(text);
    var map = try identitySemanticFilterMapForTest(testing_allocator, text, line_count);
    defer map.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 1,
        .zy_text = text,
        .zig_text = text,
        .active_span_index = null,
    };
    defer context.deinit();
    const data = try semanticFilterTokenDataForTest(testing_allocator, line_count);
    defer testing_allocator.free(data);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const replacement_range: types.Range = .{
        .start = .{ .line = 2, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    };
    const filtered = try translateSemanticTokenRangeDataFiltered(arena_state.allocator(), data, &context, replacement_range, replacement_range);

    try expectEqual(@as(usize, 4), filtered.scanned_count);
    try expectEqual(@as(usize, 1), filtered.translated_count);
    try expectFilteredTokenLines(filtered.data, &.{2});
}

test "filtered semantic token translation keeps source range near end" {
    const line_count = 128;
    const text = try semanticFilterLineTextForTest(testing_allocator, line_count);
    defer testing_allocator.free(text);
    var map = try identitySemanticFilterMapForTest(testing_allocator, text, line_count);
    defer map.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 1,
        .zy_text = text,
        .zig_text = text,
        .active_span_index = null,
    };
    defer context.deinit();
    const data = try semanticFilterTokenDataForTest(testing_allocator, line_count);
    defer testing_allocator.free(data);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const replacement_range: types.Range = .{
        .start = .{ .line = 126, .character = 0 },
        .end = .{ .line = 127, .character = 0 },
    };
    const filtered = try translateSemanticTokenRangeDataFiltered(arena_state.allocator(), data, &context, replacement_range, replacement_range);

    try expectEqual(@as(usize, line_count), filtered.scanned_count);
    try expectEqual(@as(usize, 1), filtered.translated_count);
    try expectFilteredTokenLines(filtered.data, &.{126});
}

test "filtered semantic token translation keeps contiguous source replacement range" {
    const line_count = 32;
    const text = try semanticFilterLineTextForTest(testing_allocator, line_count);
    defer testing_allocator.free(text);
    var map = try identitySemanticFilterMapForTest(testing_allocator, text, line_count);
    defer map.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 1,
        .zy_text = text,
        .zig_text = text,
        .active_span_index = null,
    };
    defer context.deinit();
    const data = try semanticFilterTokenDataForTest(testing_allocator, line_count);
    defer testing_allocator.free(data);
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const replacement_range: types.Range = .{
        .start = .{ .line = 2, .character = 0 },
        .end = .{ .line = 8, .character = 0 },
    };
    const filtered = try translateSemanticTokenRangeDataFiltered(arena_state.allocator(), data, &context, replacement_range, replacement_range);

    try expectEqual(@as(usize, 9), filtered.scanned_count);
    try expectEqual(@as(usize, 6), filtered.translated_count);
    try expectFilteredTokenLines(filtered.data, &.{ 2, 3, 4, 5, 6, 7 });
}

test "semantic token range translator sorts translated range tokens by zy position" {
    const zy =
        \\%code {
        \\const first = 1;
        \\const second = 2;
        \\}
    ;
    const zig =
        \\// #line 3 zy.zy
        \\const second = 2;
        \\// #line 2 zy.zy
        \\const first = 1;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 1,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var zig_tokens = [_]u32{
        1, 6, 6, 8, 0,
        2, 6, 5, 8, 0,
    };
    const translated = try translateSemanticTokenRangeData(testing_allocator, &zig_tokens, &context);
    defer testing_allocator.free(translated);

    try expectEqualSlices(u32, &.{
        1, 6, 5, 8, 0,
        1, 6, 6, 8, 0,
    }, translated);
}

test "semantic dirty range comes from snapshot diff for line move" {
    const previous =
        \\a
        \\b
        \\c
        \\
    ;
    const current =
        \\a
        \\c
        \\b
        \\
    ;

    const dirty = (try semanticDirtyRangeFromDiff(testing_allocator, previous, current)) orelse return error.UnexpectedResponse;
    try expectEqual(@as(u32, 1), dirty.previous.start.line);
    try expectEqual(@as(u32, 0), dirty.previous.start.character);
    try expectEqual(@as(u32, 3), dirty.previous.end.line);
    try expectEqual(@as(u32, 0), dirty.previous.end.character);
    try expectEqual(@as(u32, 1), dirty.current.start.line);
    try expectEqual(@as(u32, 0), dirty.current.start.character);
    try expectEqual(@as(u32, 3), dirty.current.end.line);
    try expectEqual(@as(u32, 0), dirty.current.end.character);
}

test "semantic token requests serve fresh current collection without zls" {
    const uri = "file:///zy.zy";
    const zy =
        \\first
        \\second
        \\third
    ;
    const zig = "zig\n";
    const current_data = [_]u32{
        1, 0, 5, 1, 0,
        1, 2, 3, 2, 0,
    };

    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    defer middleware.documents.deinit(testing_allocator);
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, try makeTestDocumentState(testing_allocator, uri, 3, zy, zig));
    defer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var state = removed.value;
        state.deinit(testing_allocator);
    }
    const state = middleware.documents.getPtr(uri).?;
    try setTestSemanticTokensCurrent(state, testing_allocator, 3, zy, zig, &current_data);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const full = (try middleware.forwardSemanticTokensFull(arena, uri, .{
        .textDocument = .{ .uri = uri },
    })) orelse return error.UnexpectedResponse;
    try expectEqualStrings("lsp-zitron-semantic-1", full.resultId.?);
    try expectEqualSlices(u32, &current_data, full.data);
    const baseline_result_id = try testing_allocator.dupe(u8, full.resultId.?);
    defer testing_allocator.free(baseline_result_id);

    const range = (try middleware.forwardSemanticTokensRange(arena, uri, .{
        .textDocument = .{ .uri = uri },
        .range = .{
            .start = .{ .line = 2, .character = 0 },
            .end = .{ .line = 2, .character = 10 },
        },
    })) orelse return error.UnexpectedResponse;
    try expectEqual(@as(?[]const u8, null), range.resultId);
    try expectEqualSlices(u32, &.{ 2, 2, 3, 2, 0 }, range.data);

    const delta = (try middleware.forwardSemanticTokensFullDelta(arena, uri, .{
        .textDocument = .{ .uri = uri },
        .previousResultId = full.resultId.?,
    })) orelse return error.UnexpectedResponse;
    const delta_result = switch (delta) {
        .semantic_tokens_delta => |value| value,
        .semantic_tokens => return error.UnexpectedResponse,
    };
    try expectEqualStrings("lsp-zitron-semantic-2", delta_result.resultId.?);
    try expectEqual(@as(usize, 0), delta_result.edits.len);

    for (0..max_semantic_token_snapshots + 2) |_| {
        const touched = (try middleware.forwardSemanticTokensFullDelta(arena, uri, .{
            .textDocument = .{ .uri = uri },
            .previousResultId = baseline_result_id,
        })) orelse return error.UnexpectedResponse;
        const touched_delta = switch (touched) {
            .semantic_tokens_delta => |value| value,
            .semantic_tokens => return error.UnexpectedResponse,
        };
        try expectEqual(@as(usize, 0), touched_delta.edits.len);
    }

    const unknown = (try middleware.forwardSemanticTokensFullDelta(arena, uri, .{
        .textDocument = .{ .uri = uri },
        .previousResultId = "missing",
    })) orelse return error.UnexpectedResponse;
    const unknown_full = switch (unknown) {
        .semantic_tokens => |value| value,
        .semantic_tokens_delta => return error.UnexpectedResponse,
    };
    try expectEqualStrings("lsp-zitron-semantic-13", unknown_full.resultId.?);
    try expectEqualSlices(u32, &current_data, unknown_full.data);
}

test "stale semantic token current updates without zls when zig is unchanged" {
    const uri = "file:///zy.zy";
    const previous_zy =
        \\a
        \\b
    ;
    const current_zy =
        \\x
        \\a
        \\b
    ;
    const zig = "zig\n";
    const previous_data = [_]u32{
        1, 0, 1, 1, 0,
    };

    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    defer middleware.documents.deinit(testing_allocator);
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, try makeTestDocumentState(testing_allocator, uri, 2, current_zy, zig));
    defer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var state = removed.value;
        state.deinit(testing_allocator);
    }
    const state = middleware.documents.getPtr(uri).?;
    try setTestSemanticTokensCurrent(state, testing_allocator, 1, previous_zy, zig, &previous_data);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const current = (try middleware.ensureSemanticTokensCurrent(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
    })) orelse return error.UnexpectedResponse;

    try expectEqual(@as(i32, 2), current.version);
    try expectEqualStrings(current_zy, current.zy_text);
    try expectEqualStrings(zig, current.zig_text);
    try expectEqualSlices(u32, &.{ 2, 0, 1, 1, 0 }, current.zy_data);
}

test "stale document dirty range does not under-cover semantic current update" {
    const uri = "file:///zy.zy";
    const previous_zy =
        \\a
        \\b
        \\c
    ;
    const current_zy =
        \\x
        \\a
        \\b
        \\c
    ;
    const zig = "zig\n";
    const previous_data = [_]u32{
        2, 0, 1, 1, 0,
    };

    var middleware: Middleware = .{
        .allocator = testing_allocator,
        .io = std.Options.debug_io,
        .diagnostics_context = null,
        .diagnostics_publisher = null,
        .documents_mutex = .init,
        .documents = .empty,
        .zls_mutex = .init,
        .zls_library = undefined,
        .zls_completion_triggers = &.{},
        .next_generation_id = 1,
    };
    defer middleware.documents.deinit(testing_allocator);
    const key = try testing_allocator.dupe(u8, uri);
    errdefer testing_allocator.free(key);
    try middleware.documents.put(testing_allocator, key, try makeTestDocumentState(testing_allocator, uri, 4, current_zy, zig));
    defer {
        const removed = middleware.documents.fetchRemove(uri).?;
        testing_allocator.free(removed.key);
        var state = removed.value;
        state.deinit(testing_allocator);
    }
    const state = middleware.documents.getPtr(uri).?;
    try setTestSemanticTokensCurrent(state, testing_allocator, 1, previous_zy, zig, &previous_data);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const current = (try middleware.ensureSemanticTokensCurrent(arena_state.allocator(), uri, .{
        .textDocument = .{ .uri = uri },
    })) orelse return error.UnexpectedResponse;

    try expectEqual(@as(i32, 4), current.version);
    try expectEqualStrings(current_zy, current.zy_text);
    try expectEqualStrings(zig, current.zig_text);
    try expectEqualSlices(u32, &.{ 3, 0, 1, 1, 0 }, current.zy_data);
}

test "translates semantic tokens and drops zig-only spans" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
        \\// #line 80 zy.zig
        \\const zig_only = true;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var zig_tokens = [_]u32{
        1, 6, 6,  8,  0,
        0, 9, 2,  19, 0,
        2, 6, 14, 8,  0,
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateSemanticTokenData(
        arena_state.allocator(),
        &zig_tokens,
        &context,
    );

    try expectEqualSlices(u32, &.{
        1, 6, 6, 8,  0,
        0, 9, 2, 19, 0,
    }, translated);
    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(0));
}

test "semantic token inline action spans use column-aware slow path" {
    const prefix = "statement(A) ::= TOKEN. { ";
    const zig = "const answer = 42;";
    const zy = prefix ++ zig ++ " }";
    const zig_len: u32 = @intCast(zig.len);
    const zy_len: u32 = @intCast(zy.len);
    const answer_zy_column: u32 = @intCast(prefix.len + 6);

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig_len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = prefix.len,
        .end_byte = prefix.len + zig.len,
        .start_point = .{ .row = 0, .column = @intCast(prefix.len) },
        .end_point = .{ .row = 0, .column = @intCast(prefix.len + zig.len) },
    });
    try map.fast_column_mapping.append(testing_allocator, false);
    try map.rebuildZyOrder(testing_allocator);

    const mapped_range = (try zyRangeToZigRange(
        testing_allocator,
        &map,
        0,
        zy,
        zig,
        .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = zy_len },
        },
    )) orelse return error.UnexpectedCodeMap;
    try expectEqual(types.Range{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = zig_len },
    }, mapped_range);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var zig_tokens = [_]u32{ 0, 6, 6, 8, 0 };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateSemanticTokenData(
        arena_state.allocator(),
        &zig_tokens,
        &context,
    );

    try expectEqualSlices(u32, &.{ 0, answer_zy_column, 6, 8, 0 }, translated);
    try expectEqual(@as(usize, 1), map.translators.freshLen(0));
}

test "semantic token slow path drops partial source-token matches and reencodes following tokens" {
    const zy = "A = pik_position_between(X, P1, P2);\n";
    const zig = "A = pik_position_between(X, stack[1], P2);\n";
    const function_zy_column: u32 = @intCast(std.mem.indexOf(u8, zy, "pik_position_between").?);
    const function_zig_column: u32 = @intCast(std.mem.indexOf(u8, zig, "pik_position_between").?);
    const one_zig_column: u32 = @intCast(std.mem.indexOf(u8, zig, "[1]").? + 1);
    const p2_zy_column: u32 = @intCast(std.mem.indexOf(u8, zy, "P2").?);
    const p2_zig_column: u32 = @intCast(std.mem.indexOf(u8, zig, "P2").?);

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = 0,
        .end_byte = zy.len,
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = 1, .column = 0 },
    });
    try map.fast_column_mapping.append(testing_allocator, false);
    try map.rebuildZyOrder(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var position_cursor = ZigPositionCursor{ .context = &context, .span_index = null };
    try std.testing.expect(try position_cursor.zigRangeToZy(.{
        .start = .{ .line = 0, .character = one_zig_column },
        .end = .{ .line = 0, .character = one_zig_column + 1 },
    }) == null);

    var zig_tokens = [_]u32{
        0, function_zig_column,                  20, 12, 0,
        0, one_zig_column - function_zig_column, 1,  20, 0,
        0, p2_zig_column - one_zig_column,       2,  8,  0,
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateSemanticTokenData(
        arena_state.allocator(),
        &zig_tokens,
        &context,
    );

    try expectEqualSlices(u32, &.{
        0, function_zy_column,                20, 12, 0,
        0, p2_zy_column - function_zy_column, 2,  8,  0,
    }, translated);
}

test "translates semantic tokens in zy span order" {
    const zy =
        \\const first = 1;
        \\const middle = 0;
        \\const second = 2;
    ;
    const zig =
        \\const second = 2;
        \\const first = 1;
    ;
    const zy_first_end = std.mem.indexOfScalar(u8, zy, '\n').?;
    const zy_second_start = std.mem.indexOf(u8, zy, "const second").?;
    const zig_first_line_end = std.mem.indexOfScalar(u8, zig, '\n').?;

    var map: CodeMap = .empty;
    defer map.deinit(testing_allocator);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 2,
        .zig_line = 0,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = 0, .end = zig_first_line_end },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = @intCast(zy_second_start),
        .end_byte = @intCast(zy.len),
        .start_point = .{ .row = 2, .column = 0 },
        .end_point = .{ .row = 2, .column = @intCast(zy.len - zy_second_start) },
    });
    try map.fast_column_mapping.append(testing_allocator, true);
    try map.zig_span.append(testing_allocator, .{
        .zy_line = 0,
        .zig_line = 1,
        .zig_column = 0,
        .line_count = 1,
        .zig_range = .{ .start = zig_first_line_end + 1, .end = zig.len },
    });
    try map.zy_range.append(testing_allocator, .{
        .start_byte = 0,
        .end_byte = @intCast(zy_first_end),
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = 0, .column = @intCast(zy_first_end) },
    });
    try map.fast_column_mapping.append(testing_allocator, true);
    try map.rebuildZyOrder(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
        .active_span_index = null,
    };
    defer context.deinit();

    var zig_tokens = [_]u32{
        0, 6, 6, 8, 0,
        1, 6, 5, 8, 0,
    };

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = try translateSemanticTokenData(
        arena_state.allocator(),
        &zig_tokens,
        &context,
    );

    try expectEqualSlices(u32, &.{
        0, 6, 5, 8, 0,
        2, 6, 6, 8, 0,
    }, translated);
}

test "translates inlay hints with one cached diff per touched block" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
        \\%code {
        \\const other = answer;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
        \\// #line 5 zy.zy
        \\const other = answer;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(@as(usize, 2), map.len());
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
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

    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(0));
    const translated = try translateInlayHints(
        arena_state.allocator(),
        &hints,
        &context,
        "file:///zig.zig",
        "file:///zy.zy",
    );

    try expectEqual(@as(usize, 2), translated.len);
    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 2), map.translators.freshLen(0));
    try expectEqual(@as(u32, 1), translated[0].position.line);
    try expectEqual(@as(u32, 4), translated[1].position.line);
}

test "span translator marks identical stale zig slice fresh without rebuilding diff" {
    const zy = "rule(A) ::= token(T). { A = T; }";
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = yymsp[0].minor.yy42;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    const first = try map.spanTranslator(testing_allocator, 1, zy, zig, 0);
    const first_edits = first.diffEdits().ptr;
    try expectEqual(@as(i32, 1), first.document_version);
    try expectEqual(@as(usize, 1), map.translators.freshLen(1));

    const tree = try parseZitronTreeForTest(zy);
    defer tree.destroy();
    const updated = try testing_allocator.dupe(u8, zig);
    defer testing_allocator.free(updated);
    try map.update(testing_allocator, tree.rootNode(), zy, updated, "zy.zy");
    try expectEqual(@as(usize, 0), map.translators.freshLen(2));

    const second = try map.spanTranslator(testing_allocator, 2, zy, zig, 0);
    try std.testing.expect(first == second);
    try expectEqual(@as(i32, 2), second.document_version);
    try std.testing.expect(first_edits == second.diffEdits().ptr);
}

test "span translator refreshes owned text and diff when stale zig slice changes" {
    const zy = "rule(A) ::= token(T). { A = T; }";
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = yymsp[0].minor.yy42;
    ;
    const updated_zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = yymsp[1].minor.yy42;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    const first = try map.spanTranslator(testing_allocator, 1, zy, zig, 0);
    const first_zig_text = try testing_allocator.dupe(u8, first.zig_text);
    defer testing_allocator.free(first_zig_text);
    try expectEqual(@as(i32, 1), first.document_version);

    const tree = try parseZitronTreeForTest(zy);
    defer tree.destroy();
    const updated = try testing_allocator.dupe(u8, updated_zig);
    defer testing_allocator.free(updated);
    try map.update(testing_allocator, tree.rootNode(), zy, updated, "zy.zy");

    const refreshed = try map.spanTranslator(testing_allocator, 2, zy, updated_zig, 0);
    try std.testing.expect(first == refreshed);
    try expectEqual(@as(i32, 2), refreshed.document_version);
    try expectEqualStrings(updated_zig[map.zig_span.items[0].zig_range.start..map.zig_span.items[0].zig_range.end], refreshed.zig_text);
    try std.testing.expect(!std.mem.eql(u8, first_zig_text, refreshed.zig_text));
    const zig_answer = lsp.offsets.indexToPosition(updated_zig, std.mem.indexOf(u8, updated_zig, "yygotominor").?, .@"utf-8");
    try expectEqual(
        lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "A =").?, .@"utf-8"),
        sharedPosition(refreshed.zigPositionToZy(zig_answer)) orelse return error.UnexpectedCodeMap,
    );
}

test "span translators refresh only touched stale spans" {
    const zy =
        \\first(A) ::= token(T). { A = first(T); }
        \\second(B) ::= token(T). { B = second(T); }
    ;
    const zig =
        \\// #line 1 zy.zy
        \\ yygotominor.yy0 = first(yymsp[0].minor.yy42);
        \\// #line 2 zy.zy
        \\ yygotominor.yy0 = second(yymsp[0].minor.yy42);
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    try expectEqual(@as(usize, 2), map.translators.len());

    _ = try map.spanTranslator(testing_allocator, 1, zy, zig, 0);
    try expectEqual(@as(usize, 1), map.translators.freshLen(1));

    const tree = try parseZitronTreeForTest(zy);
    defer tree.destroy();
    const updated = try testing_allocator.dupe(u8, zig);
    defer testing_allocator.free(updated);
    try map.update(testing_allocator, tree.rootNode(), zy, updated, "zy.zy");
    try expectEqual(@as(usize, 0), map.translators.freshLen(2));

    _ = try map.spanTranslator(testing_allocator, 2, zy, zig, 1);
    try expectEqual(@as(usize, 1), map.translators.freshLen(1));
    try expectEqual(@as(usize, 1), map.translators.freshLen(2));
}

test "code map preserves span translators and refreshes them across regeneration" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
    ;
    const updated_zig =
        \\// #line 2 zy.zy
        \\const answer = 43;
    ;

    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);

    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(0));
    const first = try map.spanTranslator(testing_allocator, 0, zy, zig, 0);
    const second = try map.spanTranslator(testing_allocator, 0, zy, zig, 0);
    try std.testing.expect(first == second);
    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 1), map.translators.freshLen(0));

    const updated_tree = try parseZitronTreeForTest(zy);
    defer updated_tree.destroy();
    const updated = try testing_allocator.dupe(u8, updated_zig);
    defer testing_allocator.free(updated);
    try map.update(testing_allocator, updated_tree.rootNode(), zy, updated, "zy.zy");
    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 0), map.translators.freshLen(1));

    _ = try map.spanTranslator(testing_allocator, 1, zy, updated, 0);
    try expectEqual(map.len(), map.translators.len());
    try expectEqual(@as(usize, 1), map.translators.freshLen(1));
}

test "translates workspace edit changes back to zy ranges" {
    const zy =
        \\%code {
        \\const answer = 42;
        \\}
    ;
    const zig =
        \\// #line 2 zy.zy
        \\const answer = 42;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = try requestTranslationContextForTest(
        &map,
        zy,
        zig,
        lsp.offsets.indexToPosition(zy, std.mem.indexOf(u8, zy, "answer").?, .@"utf-8"),
    );
    defer context.deinit();

    const zig_edits = [_]types.TextEdit{
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
    try changes.map.put(testing_allocator, "file:///zy.zitron.zig", &zig_edits);
    try changes.map.put(testing_allocator, "file:///other.zig", &other_edits);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const translated = (try translateWorkspaceEdit(
        arena_state.allocator(),
        .{ .changes = changes },
        &context,
        "file:///zy.zitron.zig",
        "file:///zy.zy",
    )) orelse return error.UnexpectedWorkspaceEdit;

    const translated_changes = translated.changes orelse return error.UnexpectedWorkspaceEdit;
    const zy_edits = translated_changes.map.get("file:///zy.zy") orelse return error.UnexpectedWorkspaceEdit;
    try expectEqual(@as(usize, 1), zy_edits.len);
    try expectEqual(types.Range{
        .start = .{ .line = 1, .character = 6 },
        .end = .{ .line = 1, .character = 12 },
    }, zy_edits[0].range);
    try expectEqualStrings("solution", zy_edits[0].newText);

    const preserved_edits = translated_changes.map.get("file:///other.zig") orelse return error.UnexpectedWorkspaceEdit;
    try expectEqual(@as(usize, 1), preserved_edits.len);
    try expectEqualStrings("other", preserved_edits[0].newText);
}

test "translates document symbols and drops zig yy symbols" {
    const zy =
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
    const zig =
        \\// #line 5 zy.zy
        \\pub const Token = struct {
        \\    pub fn lit() void {}
        \\};
        \\// #line 80 zy.zig
        \\const zig_only = true;
        \\// #line 20 zy.zy
        \\const yyFallback = 1;
    ;
    var map = try parseCodeMapForTest(zy, zig, "zy.zy");
    defer map.deinit(testing_allocator);
    var context = RequestTranslationContext{
        .allocator = testing_allocator,
        .map = &map,
        .document_version = 0,
        .zy_text = zy,
        .zig_text = zig,
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
            .name = "zig_only",
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
const ZlsAdapter = @import("zls.zig");
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
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const log = std.log.scoped(.zig_middleware);
