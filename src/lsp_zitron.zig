//! Zitron Language Server
//!
//! Implementation of a language server for Zitron, an LALR(1) parser
//! generator based on a port of D. Richard Hipp's Lemon.

/// The language-server name reported during LSP initialization.
pub const server_name = "zitron-ls";

const server_version = "0.0.1";
const zitron_completion_triggers = [_][]const u8{ "%", "(" };
const zitron_signature_help_triggers = [_][]const u8{ "(", ";", "," };
const zitron_signature_help_retriggers = [_][]const u8{ ";", "," };
const first_server_request_id = 1_000_000;

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

/// Errors that can occur while loading the configured fixture source.
pub const FixtureError = std.Io.Dir.ReadFileAllocError;

const DefinitionLikeRoute = enum {
    declaration,
    definition,
};

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
        .signatureHelpProvider = .{
            .triggerCharacters = &zitron_signature_help_triggers,
            .retriggerCharacters = &zitron_signature_help_retriggers,
        },
        .hoverProvider = .{ .bool = true },
        .declarationProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = true },
        .typeDefinitionProvider = .{ .bool = true },
        .referencesProvider = .{ .bool = true },
        .documentHighlightProvider = .{ .bool = true },
        .documentSymbolProvider = .{ .bool = true },
        .renameProvider = .{ .bool = true },
        .documentFormattingProvider = .{ .bool = true },
        .inlayHintProvider = .{ .inlay_hint_options = .{} },
        .semanticTokensProvider = .{ .semantic_tokens_options = .{
            .legend = .{
                .tokenTypes = &ZigMiddleware.semantic_token_types,
                .tokenModifiers = &ZigMiddleware.semantic_token_modifiers,
            },
            .range = .{ .bool = true },
            .full = .{ .semantic_tokens_full_delta = .{ .delta = true } },
        } },
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
    documents: std.StringHashMapUnmanaged(Document),
    tags_query: *ts.Query,
    rename_query: *ts.Query,
    token_enum_query: *ts.Query,
    offset_encoding: lsp.offsets.Encoding,
    zig_middleware: ZigMiddleware,
    client_transport: ?*lsp.Transport,
    io: ?std.Io,
    client_supports_work_done_progress: bool,
    client_supports_semantic_tokens_refresh: bool,
    client_supports_inlay_hints_refresh: bool,
    client_supports_watched_files_dynamic_registration: bool,
    next_server_request_id: i64,

    /// Creates a server instance and compiles the grammar tag query.
    pub fn init(allocator: std.mem.Allocator) ts.Query.Error!Server {
        var query_error_offset: u32 = 0;
        const tags_query = try ts.Query.create(zitronLanguage(), tags_query_source, &query_error_offset);
        errdefer tags_query.destroy();
        const rename_query = try ts.Query.create(zitronLanguage(), rename_query_source, &query_error_offset);
        errdefer rename_query.destroy();
        const token_enum_query = try ts.Query.create(zitronLanguage(), token_enum_query_source, &query_error_offset);
        errdefer comptime unreachable;

        return .{
            .allocator = allocator,
            .documents = .empty,
            .tags_query = tags_query,
            .rename_query = rename_query,
            .token_enum_query = token_enum_query,
            .offset_encoding = .@"utf-16",
            .zig_middleware = .disabled,
            .client_transport = null,
            .io = null,
            .client_supports_work_done_progress = false,
            .client_supports_semantic_tokens_refresh = false,
            .client_supports_inlay_hints_refresh = false,
            .client_supports_watched_files_dynamic_registration = false,
            .next_server_request_id = first_server_request_id,
        };
    }

    /// Creates a server instance with the production Zig middleware enabled.
    pub fn initProduction(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
    ) Error!Server {
        var server = try init(allocator);
        errdefer server.deinit();
        server.zig_middleware = try ZigMiddleware.init(io, allocator, environ_map);
        server.io = io;
        return server;
    }

    pub fn setClientTransport(server: *Server, transport: *lsp.Transport) void {
        server.client_transport = transport;
        server.zig_middleware.setDiagnosticsPublisher(server, publishZlsDiagnostics);
        server.zig_middleware.setRefreshPublisher(server, publishZlsRefresh);
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
        server.token_enum_query.destroy();
        server.rename_query.destroy();
        server.tags_query.destroy();
    }

    fn logStart(server: *const Server) ?std.Io.Timestamp {
        const io = server.io orelse return null;
        return std.Io.Clock.awake.now(io);
    }

    fn logElapsedNs(server: *const Server, start: ?std.Io.Timestamp) i96 {
        const io = server.io orelse return 0;
        const started = start orelse return 0;
        return started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    }

    fn publishMergedDiagnostics(server: *Server, uri: []const u8, version: i32) Error!void {
        if (server.client_transport == null or server.io == null) return;
        var arena_state = std.heap.ArenaAllocator.init(server.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var diagnostics: std.ArrayList(types.Diagnostic) = .empty;
        try server.zig_middleware.appendDiagnostics(arena, &diagnostics, uri);
        try server.publishDiagnostics(uri, version, diagnostics.items);
    }

    fn publishZlsDiagnostics(context: *anyopaque, source_uri: []const u8, version: i32) void {
        const server: *Server = @ptrCast(@alignCast(context));
        server.publishMergedDiagnostics(source_uri, version) catch |err| {
            log.warn("LSP publish diagnostics failed for uri={s}: {}", .{ source_uri, err });
        };
    }

    fn publishZlsRefresh(context: *anyopaque, kind: ZigMiddleware.RefreshKind) void {
        const server: *Server = @ptrCast(@alignCast(context));
        const result = switch (kind) {
            .semantic_tokens => server.refreshSemanticTokens(),
            .inlay_hints => server.refreshInlayHints(),
        };
        result catch |err| {
            log.warn("LSP ZLS refresh forwarding failed kind={t}: {}", .{ kind, err });
        };
    }

    fn publishDiagnostics(
        server: *Server,
        uri: []const u8,
        version: ?i32,
        diagnostics: []const types.Diagnostic,
    ) Error!void {
        const transport = server.client_transport orelse return;
        const io = server.io orelse return;
        log.debug("LSP -> textDocument/publishDiagnostics uri={s} version={?} diagnostics={}", .{
            uri,
            version,
            diagnostics.len,
        });
        try transport.writeNotification(
            io,
            server.allocator,
            "textDocument/publishDiagnostics",
            lsp.ParamsType("textDocument/publishDiagnostics"),
            .{
                .uri = uri,
                .version = version,
                .diagnostics = diagnostics,
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    fn definitionLikeAtPosition(
        server: *Server,
        route: DefinitionLikeRoute,
        arena: std.mem.Allocator,
        uri: []const u8,
        position: types.Position,
        work_done_token: ?types.ProgressToken,
        partial_result_token: ?types.ProgressToken,
    ) Error!lsp.ResultType("textDocument/definition") {
        const doc = server.getDocument(uri) orelse return null;
        return switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, position)) {
            .no_match => null,
            .unsupported_zig_code => switch (route) {
                .declaration => try server.zig_middleware.forwardDeclaration(arena, uri, .{
                    .textDocument = .{ .uri = uri },
                    .position = position,
                    .workDoneToken = work_done_token,
                    .partialResultToken = partial_result_token,
                }),
                .definition => try server.zig_middleware.forwardDefinition(arena, uri, .{
                    .textDocument = .{ .uri = uri },
                    .position = position,
                    .workDoneToken = work_done_token,
                    .partialResultToken = partial_result_token,
                }),
            },
            .symbol => |symbol| switch (symbol.kind) {
                .rule_definition, .token_class_definition, .action_definition => .{
                    .definition = .{
                        .location = doc.locationForNode(
                            uri,
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
                            uri,
                            definition.name_node,
                            server.offset_encoding,
                        ),
                    },
                } else null,
                .token_class_reference => if (doc.findTokenClassDefinition(
                    server.tags_query,
                    symbol.symbol_name,
                )) |definition| .{
                    .definition = .{
                        .location = doc.locationForNode(
                            uri,
                            definition.name_node,
                            server.offset_encoding,
                        ),
                    },
                } else null,
                .terminal_reference => null,
                .action_implementation => if (doc.findActionDefinition(server.tags_query, symbol.symbol_name)) |definition| .{
                    .definition = .{
                        .location = doc.locationForNode(
                            uri,
                            definition.name_node,
                            server.offset_encoding,
                        ),
                    },
                } else null,
            },
        };
    }

    /// LSP `initialize` handler required by `lsp-kit`.
    pub fn initialize(
        server: *Server,
        allocator: std.mem.Allocator,
        params: types.InitializeParams,
    ) types.InitializeResult {
        const start = server.logStart();
        const encoding_count = if (params.capabilities.general) |general|
            if (general.positionEncodings) |encodings| encodings.len else 0
        else
            0;
        log.debug("LSP <- initialize client={s} encodings={}", .{
            if (params.clientInfo) |client_info| client_info.name else "",
            encoding_count,
        });
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
        if (params.capabilities.window) |window| {
            server.client_supports_work_done_progress = window.workDoneProgress orelse false;
        }
        if (params.capabilities.workspace) |workspace| {
            if (workspace.didChangeWatchedFiles) |watched_files| {
                server.client_supports_watched_files_dynamic_registration =
                    watched_files.dynamicRegistration orelse false;
            }
            if (workspace.semanticTokens) |semantic_tokens| {
                server.client_supports_semantic_tokens_refresh = semantic_tokens.refreshSupport orelse false;
            }
            if (workspace.inlayHint) |inlay_hints| {
                server.client_supports_inlay_hints_refresh = inlay_hints.refreshSupport orelse false;
            }
        }

        const result: types.InitializeResult = .{
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
        log.debug("LSP -> initialize encoding={t} elapsed_ns={}", .{
            server.offset_encoding,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `initialized` handler required by `lsp-kit`.
    pub fn initialized(server: *Server, _: std.mem.Allocator, _: types.InitializedParams) Error!void {
        log.debug("LSP <- initialized", .{});
        try server.registerBuildFileWatcher();
        log.debug("LSP -> initialized", .{});
    }

    //| Handlers
    //|
    //| `lsp-kit` passes in a per-message arena on requests.  Sometimes we use it,
    //| sometimes we don't.

    /// Format the live source and return one complete-document replacement.
    pub fn @"textDocument/formatting"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DocumentFormattingParams,
    ) Error!lsp.ResultType("textDocument/formatting") {
        const document = server.getDocument(params.textDocument.uri) orelse return null;
        const io = server.io orelse return null;
        const start = server.logStart();
        const formatted = try formatter.format(io, arena, document.source, document.tree.rootNode(), .{});
        const changed = !std.mem.eql(u8, formatted, document.source);
        defer log.debug("LSP -> textDocument/formatting source_bytes={} formatted_bytes={} changed={} elapsed_ns={}", .{
            document.source.len, formatted.len, changed, server.logElapsedNs(start),
        });
        if (!changed) return &.{};
        const edits = try arena.alloc(types.TextEdit, 1);
        edits[0] = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = lsp.offsets.indexToPosition(document.source, document.source.len, server.offset_encoding),
            },
            .newText = formatted,
        };
        return edits;
    }

    /// LSP `textDocument/didOpen` handler that stores the full document text.
    pub fn @"textDocument/didOpen"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidOpenTextDocumentParams,
    ) Error!void {
        const start = server.logStart();
        log.debug("LSP <- textDocument/didOpen uri={s} version={} bytes={}", .{
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text.len,
        });
        try server.putDocument(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
        const doc = server.getDocument(params.textDocument.uri) orelse return error.InvalidParams;
        try server.zig_middleware.syncDocument(
            params.textDocument.uri,
            params.textDocument.version,
            doc.source,
            doc.tree.rootNode(),
        );
        try server.publishMergedDiagnostics(params.textDocument.uri, params.textDocument.version);
        try server.warmSemanticTokens(params.textDocument.uri);
        log.debug("LSP -> textDocument/didOpen uri={s} source_bytes={} elapsed_ns={}", .{
            params.textDocument.uri,
            doc.source.len,
            server.logElapsedNs(start),
        });
    }

    /// LSP `textDocument/didChange` handler that applies incremental document changes.
    pub fn @"textDocument/didChange"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidChangeTextDocumentParams,
    ) Error!void {
        const start = server.logStart();
        log.debug("LSP <- textDocument/didChange uri={s} version={} changes={}", .{
            params.textDocument.uri,
            params.textDocument.version,
            params.contentChanges.len,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse return error.InvalidParams;
        try doc.updateIncremental(
            server.allocator,
            params.textDocument.version,
            params.contentChanges,
            server.offset_encoding,
        );
        try server.zig_middleware.syncDocument(
            params.textDocument.uri,
            params.textDocument.version,
            doc.source,
            doc.tree.rootNode(),
        );
        try server.publishMergedDiagnostics(params.textDocument.uri, params.textDocument.version);
        log.debug("LSP -> textDocument/didChange uri={s} source_bytes={} elapsed_ns={}", .{
            params.textDocument.uri,
            doc.source.len,
            server.logElapsedNs(start),
        });
    }

    /// LSP `textDocument/didClose` handler that drops cached document state.
    pub fn @"textDocument/didClose"(
        server: *Server,
        _: std.mem.Allocator,
        params: types.DidCloseTextDocumentParams,
    ) void {
        const start = server.logStart();
        log.debug("LSP <- textDocument/didClose uri={s}", .{params.textDocument.uri});
        server.publishDiagnostics(params.textDocument.uri, null, &.{}) catch |err| {
            log.warn("LSP publish diagnostics failed while closing uri={s}: {}", .{ params.textDocument.uri, err });
        };
        server.zig_middleware.closeDocument(params.textDocument.uri);
        server.removeDocument(params.textDocument.uri);
        log.debug("LSP -> textDocument/didClose uri={s} elapsed_ns={}", .{
            params.textDocument.uri,
            server.logElapsedNs(start),
        });
    }

    /// Forwards changed `build.zig` filesystem events into the embedded ZLS store.
    pub fn @"workspace/didChangeWatchedFiles"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DidChangeWatchedFilesParams,
    ) Error!void {
        var changes: std.ArrayList(types.FileEvent) = .empty;
        for (params.changes) |change| {
            if (change.type != .Changed or !std.mem.endsWith(u8, change.uri, "/build.zig")) continue;
            try changes.append(arena, change);
        }
        if (changes.items.len == 0) return;

        log.debug("LSP <- workspace/didChangeWatchedFiles build.zig changes={}", .{changes.items.len});
        try server.zig_middleware.didChangeWatchedFiles(arena, .{ .changes = changes.items });
        log.debug("LSP -> workspace/didChangeWatchedFiles", .{});
    }

    /// LSP `textDocument/completion` handler for directive completions.
    pub fn @"textDocument/completion"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.CompletionParams,
    ) Error!lsp.ResultType("textDocument/completion") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/completion uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/completion uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        if (doc.containsZigCodeAtPosition(server.offset_encoding, params.position)) {
            const result = try server.zig_middleware.forwardCompletion(arena, params.textDocument.uri, params);
            log.debug("LSP -> textDocument/completion uri={s} route=zig result_count={} null={} elapsed_ns={}", .{
                params.textDocument.uri,
                completionResultCount(result),
                result == null,
                server.logElapsedNs(start),
            });
            return result;
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
        ) orelse {
            log.debug("LSP -> textDocument/completion uri={s} route=zitron result=null elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };

        const result: lsp.ResultType("textDocument/completion") = .{ .completion_items = items };
        log.debug("LSP -> textDocument/completion uri={s} route=zitron result_count={} elapsed_ns={}", .{
            params.textDocument.uri,
            items.len,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/signatureHelp` handler for Zitron named actions.
    pub fn @"textDocument/signatureHelp"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.SignatureHelpParams,
    ) Error!lsp.ResultType("textDocument/signatureHelp") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/signatureHelp uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/signatureHelp uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        if (doc.containsZigCodeAtPosition(server.offset_encoding, params.position)) {
            const result = try server.zig_middleware.forwardSignatureHelp(arena, params.textDocument.uri, params);
            log.debug("LSP -> textDocument/signatureHelp uri={s} route=zig result_count={} null={} elapsed_ns={}", .{
                params.textDocument.uri,
                if (result) |help| help.signatures.len else 0,
                result == null,
                server.logElapsedNs(start),
            });
            return result;
        }

        const result = try completion.signatureHelp(
            arena,
            doc.source,
            doc.tree.rootNode(),
            params.position,
            server.offset_encoding,
        );
        log.debug("LSP -> textDocument/signatureHelp uri={s} route=zitron result_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            if (result) |help| help.signatures.len else 0,
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/hover` handler for Zitron grammar symbols.
    pub fn @"textDocument/hover"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.HoverParams,
    ) Error!?types.Hover {
        const start = server.logStart();
        log.debug("LSP <- textDocument/hover uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/hover uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        const value = switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => {
                log.debug("LSP -> textDocument/hover uri={s} result=null reason=no_match elapsed_ns={}", .{
                    params.textDocument.uri,
                    server.logElapsedNs(start),
                });
                return null;
            },
            .unsupported_zig_code => {
                const result = try server.zig_middleware.forwardHover(arena, params.textDocument.uri, params);
                log.debug("LSP -> textDocument/hover uri={s} route=zig null={} elapsed_ns={}", .{
                    params.textDocument.uri,
                    result == null,
                    server.logElapsedNs(start),
                });
                return result;
            },
            .symbol => |symbol| try hoverMarkdownForSymbol(arena, symbol, doc.hoverDirectiveForSymbol(symbol)),
        };

        const result: ?types.Hover = .{
            .contents = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = value,
                },
            },
        };
        log.debug("LSP -> textDocument/hover uri={s} route=zitron null=false elapsed_ns={}", .{
            params.textDocument.uri,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/definition` handler for grammar symbol lookups.
    pub fn @"textDocument/definition"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DefinitionParams,
    ) Error!lsp.ResultType("textDocument/definition") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/definition uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        if (server.getDocument(params.textDocument.uri) == null) {
            log.debug("LSP -> textDocument/definition uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        }
        const result = try server.definitionLikeAtPosition(
            .definition,
            arena,
            params.textDocument.uri,
            params.position,
            params.workDoneToken,
            params.partialResultToken,
        );
        log.debug("LSP -> textDocument/definition uri={s} result_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            definitionResultCount(result),
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/typeDefinition` handler for grammar value types and embedded Zig.
    pub fn @"textDocument/typeDefinition"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.TypeDefinitionParams,
    ) Error!lsp.ResultType("textDocument/typeDefinition") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/typeDefinition uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/typeDefinition uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        const result: lsp.ResultType("textDocument/typeDefinition") = switch (doc.typeDefinitionAtPosition(
            server.offset_encoding,
            params.position,
        )) {
            .no_match => null,
            .unsupported_zig_code => try server.zig_middleware.forwardTypeDefinition(
                arena,
                params.textDocument.uri,
                params,
            ),
            .target => |target| .{ .definition = .{ .location = doc.locationForNode(
                params.textDocument.uri,
                target,
                server.offset_encoding,
            ) } },
        };
        log.debug("LSP -> textDocument/typeDefinition uri={s} result_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            definitionResultCount(result),
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/declaration` handler; Zig declarations and definitions are equivalent.
    pub fn @"textDocument/declaration"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DeclarationParams,
    ) Error!lsp.ResultType("textDocument/declaration") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/declaration uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        if (server.getDocument(params.textDocument.uri) == null) {
            log.debug("LSP -> textDocument/declaration uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        }
        const result = try server.definitionLikeAtPosition(
            .declaration,
            arena,
            params.textDocument.uri,
            params.position,
            params.workDoneToken,
            params.partialResultToken,
        );
        log.debug("LSP -> textDocument/declaration uri={s} result_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            definitionResultCount(result),
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/references` handler for same-document grammar symbol lookups.
    pub fn @"textDocument/references"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.ReferenceParams,
    ) Error!lsp.ResultType("textDocument/references") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/references uri={s} position={any} include_declaration={}", .{
            params.textDocument.uri,
            params.position,
            params.context.includeDeclaration,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/references uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        const result: lsp.ResultType("textDocument/references") = switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, params.position)) {
            .no_match => null,
            .unsupported_zig_code => blk: {
                const zig_result = try server.zig_middleware.forwardReferences(arena, params.textDocument.uri, params);
                const enum_member = zig_result.enum_member orelse break :blk zig_result.references;

                var token_enum_name = try doc.tokenEnumName(server.allocator, server.token_enum_query);
                if (!std.mem.eql(u8, enum_member.enum_name, token_enum_name)) {
                    token_enum_name = try doc.refreshTokenEnumName(server.allocator, server.token_enum_query);
                }
                if (!std.mem.eql(u8, enum_member.enum_name, token_enum_name)) break :blk zig_result.references;

                const grammar_references = try doc.findTerminalReferences(
                    server.tags_query,
                    arena,
                    params.textDocument.uri,
                    enum_member.member_name,
                    server.offset_encoding,
                );
                break :blk try mergeLocations(arena, zig_result.references, grammar_references);
            },
            .symbol => |symbol| blk: {
                const grammar_references = try doc.findReferences(
                    server.tags_query,
                    arena,
                    params.textDocument.uri,
                    symbol,
                    params.context.includeDeclaration,
                    server.offset_encoding,
                );
                if (symbol.kind != .terminal_reference) break :blk grammar_references;

                const enum_name = try doc.tokenEnumName(server.allocator, server.token_enum_query);
                const enum_result = try server.zig_middleware.terminalEnumReferences(
                    arena,
                    params.textDocument.uri,
                    enum_name,
                    symbol.symbol_name,
                    params.context.includeDeclaration,
                );
                const zig_references = switch (enum_result) {
                    .unavailable => null,
                    .references => |references| references,
                    .enum_member_missing => retry: {
                        const stale_enum_name = try arena.dupe(u8, enum_name);
                        const refreshed_name = try doc.refreshTokenEnumName(server.allocator, server.token_enum_query);
                        if (std.mem.eql(u8, stale_enum_name, refreshed_name)) break :retry null;
                        const retry_result = try server.zig_middleware.terminalEnumReferences(
                            arena,
                            params.textDocument.uri,
                            refreshed_name,
                            symbol.symbol_name,
                            params.context.includeDeclaration,
                        );
                        break :retry switch (retry_result) {
                            .references => |references| references,
                            .unavailable, .enum_member_missing => null,
                        };
                    },
                };
                break :blk try mergeLocations(arena, grammar_references, zig_references);
            },
        };
        log.debug("LSP -> textDocument/references uri={s} result_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            if (result) |locations| locations.len else 0,
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/documentHighlight` handler for grammar-side and embedded Zig highlights.
    pub fn @"textDocument/documentHighlight"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DocumentHighlightParams,
    ) Error!lsp.ResultType("textDocument/documentHighlight") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/documentHighlight uri={s} position={any}", .{
            params.textDocument.uri,
            params.position,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/documentHighlight uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        const local_highlights = try doc.documentHighlights(
            server.tags_query,
            arena,
            params.position,
            server.offset_encoding,
        );
        const zig_highlights = if (doc.containsZigCodeAtPosition(server.offset_encoding, params.position))
            try server.zig_middleware.forwardDocumentHighlight(arena, params.textDocument.uri, params)
        else
            null;
        var highlights: std.ArrayList(types.DocumentHighlight) = .empty;
        if (local_highlights) |local| {
            try highlights.appendSlice(arena, local);
        }
        if (zig_highlights) |forwarded| {
            try highlights.appendSlice(arena, forwarded);
        }
        const result: lsp.ResultType("textDocument/documentHighlight") = if (highlights.items.len == 0)
            null
        else
            try highlights.toOwnedSlice(arena);
        log.debug("LSP -> textDocument/documentHighlight uri={s} local_count={} zig_count={} total_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            if (local_highlights) |local| local.len else 0,
            if (zig_highlights) |forwarded| forwarded.len else 0,
            if (result) |result_highlights| result_highlights.len else 0,
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/inlayHint` handler for grammar and embedded Zig inlay hints.
    pub fn @"textDocument/inlayHint"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.InlayHintParams,
    ) Error!lsp.ResultType("textDocument/inlayHint") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/inlayHint uri={s} range={any}", .{
            params.textDocument.uri,
            params.range,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/inlayHint uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        const grammar_hints = try doc.inlayHints(arena, params.range, server.offset_encoding);
        const zig_hints = try server.zig_middleware.forwardInlayHint(arena, params.textDocument.uri, params);
        var hints: std.ArrayList(types.InlayHint) = .empty;
        try hints.appendSlice(arena, grammar_hints);
        if (zig_hints) |forwarded| {
            try hints.appendSlice(arena, forwarded);
        }
        const result: lsp.ResultType("textDocument/inlayHint") = if (hints.items.len == 0)
            null
        else
            try hints.toOwnedSlice(arena);
        log.debug("LSP -> textDocument/inlayHint uri={s} result_count={} null={} elapsed_ns={}", .{
            params.textDocument.uri,
            if (result) |result_hints| result_hints.len else 0,
            result == null,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/documentSymbol` handler for document-local grammar symbols.
    pub fn @"textDocument/documentSymbol"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.DocumentSymbolParams,
    ) Error!lsp.ResultType("textDocument/documentSymbol") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/documentSymbol uri={s}", .{params.textDocument.uri});
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/documentSymbol uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
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
        const owned_symbols = try symbols.toOwnedSlice(arena);
        const result: lsp.ResultType("textDocument/documentSymbol") = .{
            .document_symbols = owned_symbols,
        };
        log.debug("LSP -> textDocument/documentSymbol uri={s} local_count={} total_count={} elapsed_ns={}", .{
            params.textDocument.uri,
            local_symbols.len,
            owned_symbols.len,
            server.logElapsedNs(start),
        });
        return result;
    }

    pub fn @"textDocument/semanticTokens/full"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.SemanticTokensParams,
    ) Error!lsp.ResultType("textDocument/semanticTokens/full") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/semanticTokens/full uri={s}", .{params.textDocument.uri});
        const result = try server.zig_middleware.forwardSemanticTokensFull(arena, params.textDocument.uri, params);
        log.debug("LSP -> textDocument/semanticTokens/full uri={s} null={} token_count={} elapsed_ns={}", .{
            params.textDocument.uri,
            result == null,
            if (result) |tokens| tokens.data.len / 5 else 0,
            server.logElapsedNs(start),
        });
        return result;
    }

    pub fn @"textDocument/semanticTokens/full/delta"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.SemanticTokensDeltaParams,
    ) Error!lsp.ResultType("textDocument/semanticTokens/full/delta") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/semanticTokens/full/delta uri={s} previous={s}", .{
            params.textDocument.uri,
            params.previousResultId,
        });
        const result = try server.zig_middleware.forwardSemanticTokensFullDelta(arena, params.textDocument.uri, params);
        const token_count = if (result) |tokens| switch (tokens) {
            .semantic_tokens => |full| full.data.len / 5,
            .semantic_tokens_delta => 0,
        } else 0;
        const edit_count = if (result) |tokens| switch (tokens) {
            .semantic_tokens => 0,
            .semantic_tokens_delta => |delta| delta.edits.len,
        } else 0;
        log.debug("LSP -> textDocument/semanticTokens/full/delta uri={s} null={} token_count={} edit_count={} elapsed_ns={}", .{
            params.textDocument.uri,
            result == null,
            token_count,
            edit_count,
            server.logElapsedNs(start),
        });
        return result;
    }

    pub fn @"textDocument/semanticTokens/range"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.SemanticTokensRangeParams,
    ) Error!lsp.ResultType("textDocument/semanticTokens/range") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/semanticTokens/range uri={s} range={any}", .{
            params.textDocument.uri,
            params.range,
        });
        const result = try server.zig_middleware.forwardSemanticTokensRange(arena, params.textDocument.uri, params);
        log.debug("LSP -> textDocument/semanticTokens/range uri={s} null={} token_count={} elapsed_ns={}", .{
            params.textDocument.uri,
            result == null,
            if (result) |tokens| tokens.data.len / 5 else 0,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `textDocument/rename` handler for document-local grammar symbols.
    pub fn @"textDocument/rename"(
        server: *Server,
        arena: std.mem.Allocator,
        params: types.RenameParams,
    ) Error!lsp.ResultType("textDocument/rename") {
        const start = server.logStart();
        log.debug("LSP <- textDocument/rename uri={s} position={any} new_name_len={}", .{
            params.textDocument.uri,
            params.position,
            params.newName.len,
        });
        const doc = server.getDocument(params.textDocument.uri) orelse {
            log.debug("LSP -> textDocument/rename uri={s} result=null reason=missing_document elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
        if (doc.containsZigCodeAtPosition(server.offset_encoding, params.position)) {
            const result = try server.zig_middleware.forwardRename(arena, params.textDocument.uri, params);
            log.debug("LSP -> textDocument/rename uri={s} route=zig edit_count={} null={} elapsed_ns={}", .{
                params.textDocument.uri,
                workspaceEditResultCount(result),
                result == null,
                server.logElapsedNs(start),
            });
            return result;
        }

        const symbol = doc.renameSymbolAtPosition(
            server.rename_query,
            server.tags_query,
            server.offset_encoding,
            params.position,
        ) orelse {
            log.debug("LSP -> textDocument/rename uri={s} route=zitron result=null reason=no_symbol elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        };
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
        if (all_edits.items.len == 0) {
            log.debug("LSP -> textDocument/rename uri={s} route=zitron result=null reason=no_edits elapsed_ns={}", .{
                params.textDocument.uri,
                server.logElapsedNs(start),
            });
            return null;
        }

        var changes = std.json.ArrayHashMap([]const types.TextEdit){};
        const owned_edits = try all_edits.toOwnedSlice(arena);
        try changes.map.put(arena, params.textDocument.uri, owned_edits);
        const result: lsp.ResultType("textDocument/rename") = .{ .changes = changes };
        log.debug("LSP -> textDocument/rename uri={s} route=zitron edit_count={} elapsed_ns={}", .{
            params.textDocument.uri,
            owned_edits.len,
            server.logElapsedNs(start),
        });
        return result;
    }

    /// LSP `shutdown` handler required by `lsp-kit`.
    pub fn shutdown(server: *Server, _: std.mem.Allocator, _: void) ?void {
        const start = server.logStart();
        log.debug("LSP <- shutdown", .{});
        log.debug("LSP -> shutdown elapsed_ns={}", .{server.logElapsedNs(start)});
        return null;
    }

    /// LSP `exit` handler required by `lsp-kit`.
    pub fn exit(server: *Server, _: std.mem.Allocator, _: void) void {
        const start = server.logStart();
        log.debug("LSP <- exit", .{});
        log.debug("LSP -> exit elapsed_ns={}", .{server.logElapsedNs(start)});
    }

    /// LSP response hook; server-initiated requests have no result-bearing follow-up.
    pub fn onResponse(server: *Server, _: std.mem.Allocator, response: lsp.JsonRPCMessage.Response) void {
        const start = server.logStart();
        log.debug("LSP <- response id_present={}", .{response.id != null});
        log.debug("LSP -> response elapsed_ns={}", .{server.logElapsedNs(start)});
    }

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

    fn warmSemanticTokens(server: *Server, uri: []const u8) Error!void {
        const start = server.logStart();
        const token = server.nextProgressToken();
        try server.beginWorkDoneProgress(token, "Building semantic tokens", uri);
        defer server.endWorkDoneProgress(token, "Ready") catch |err| {
            log.warn("LSP semantic-token progress end failed uri={s}: {}", .{ uri, err });
        };

        var arena_state = std.heap.ArenaAllocator.init(server.allocator);
        defer arena_state.deinit();
        _ = try server.zig_middleware.forwardSemanticTokensFull(
            arena_state.allocator(),
            uri,
            .{
                .textDocument = .{ .uri = uri },
                .workDoneToken = null,
                .partialResultToken = null,
            },
        );
        try server.refreshSemanticTokens();
        log.debug("LSP semanticTokens/warm uri={s} elapsed_ns={}", .{
            uri,
            server.logElapsedNs(start),
        });
    }

    fn nextRequestId(server: *Server) lsp.JsonRPCMessage.ID {
        const id = server.next_server_request_id;
        server.next_server_request_id += 1;
        return .{ .number = id };
    }

    fn nextProgressToken(server: *Server) types.ProgressToken {
        const token = server.next_server_request_id;
        server.next_server_request_id += 1;
        return .{ .integer = @intCast(token) };
    }

    fn beginWorkDoneProgress(
        server: *Server,
        token: types.ProgressToken,
        title: []const u8,
        message: []const u8,
    ) Error!void {
        if (!server.client_supports_work_done_progress) return;
        const transport = server.client_transport orelse return;
        const io = server.io orelse return;

        try transport.writeRequest(
            io,
            server.allocator,
            server.nextRequestId(),
            "window/workDoneProgress/create",
            lsp.ParamsType("window/workDoneProgress/create"),
            .{ .token = token },
            .{ .emit_null_optional_fields = false },
        );
        try transport.writeNotification(
            io,
            server.allocator,
            "$/progress",
            struct {
                token: types.ProgressToken,
                value: struct {
                    kind: []const u8,
                    title: []const u8,
                    message: []const u8,
                },
            },
            .{
                .token = token,
                .value = .{
                    .kind = "begin",
                    .title = title,
                    .message = message,
                },
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    fn endWorkDoneProgress(
        server: *Server,
        token: types.ProgressToken,
        message: []const u8,
    ) Error!void {
        if (!server.client_supports_work_done_progress) return;
        const transport = server.client_transport orelse return;
        const io = server.io orelse return;

        try transport.writeNotification(
            io,
            server.allocator,
            "$/progress",
            struct {
                token: types.ProgressToken,
                value: struct {
                    kind: []const u8,
                    message: []const u8,
                },
            },
            .{
                .token = token,
                .value = .{ .kind = "end", .message = message },
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    fn refreshSemanticTokens(server: *Server) Error!void {
        if (!server.client_supports_semantic_tokens_refresh) return;
        const transport = server.client_transport orelse return;
        const io = server.io orelse return;

        try transport.writeRequest(
            io,
            server.allocator,
            server.nextRequestId(),
            "workspace/semanticTokens/refresh",
            ?void,
            null,
            .{ .emit_null_optional_fields = false },
        );
    }

    fn refreshInlayHints(server: *Server) Error!void {
        if (!server.client_supports_inlay_hints_refresh) return;
        const transport = server.client_transport orelse return;
        const io = server.io orelse return;

        try transport.writeRequest(
            io,
            server.allocator,
            server.nextRequestId(),
            "workspace/inlayHint/refresh",
            ?void,
            null,
            .{ .emit_null_optional_fields = false },
        );
    }

    fn registerBuildFileWatcher(server: *Server) Error!void {
        if (!server.client_supports_watched_files_dynamic_registration) return;
        const transport = server.client_transport orelse return;
        const io = server.io orelse return;

        const Watcher = struct {
            globPattern: []const u8,
            kind: u32,
        };
        const Registration = struct {
            id: []const u8,
            method: []const u8,
            registerOptions: struct {
                watchers: []const Watcher,
            },
        };
        const watchers = [_]Watcher{.{
            .globPattern = "**/build.zig",
            .kind = @intFromEnum(types.WatchKind.Change),
        }};
        const registrations = [_]Registration{.{
            .id = "zitron-ls-build-zig-change",
            .method = "workspace/didChangeWatchedFiles",
            .registerOptions = .{ .watchers = &watchers },
        }};

        try transport.writeRequest(
            io,
            server.allocator,
            server.nextRequestId(),
            "client/registerCapability",
            struct { registrations: []const Registration },
            .{ .registrations = &registrations },
            .{ .emit_null_optional_fields = false },
        );
    }

    fn getDocument(server: *Server, uri: []const u8) ?*Document {
        return server.documents.getPtr(uri);
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

    fn mergeLocations(
        arena: std.mem.Allocator,
        first: ?[]const types.Location,
        second: ?[]const types.Location,
    ) OOM!lsp.ResultType("textDocument/references") {
        if (first == null) return second;
        if (second == null) return first;

        var merged: std.ArrayList(types.Location) = .empty;
        try merged.appendSlice(arena, first.?);
        try merged.appendSlice(arena, second.?);
        return try merged.toOwnedSlice(arena);
    }

    fn workspaceEditResultCount(result: lsp.ResultType("textDocument/rename")) usize {
        const value = result orelse return 0;
        var count: usize = 0;
        if (value.changes) |changes| {
            var it = changes.map.iterator();
            while (it.next()) |entry| {
                count += entry.value_ptr.*.len;
            }
        }
        if (value.documentChanges) |document_changes| {
            for (document_changes) |change| {
                switch (change) {
                    .text_document_edit => |edit| count += edit.edits.len,
                    else => {},
                }
            }
        }
        return count;
    }

    fn hasLocationAt(locations: []const types.Location, uri: []const u8, position: types.Position) bool {
        for (locations) |location| {
            if (!std.mem.eql(u8, location.uri, uri)) continue;
            if (std.meta.eql(location.range.start, position)) return true;
        }

        return false;
    }

    fn hasHighlightAt(highlights: []const types.DocumentHighlight, position: types.Position) bool {
        for (highlights) |highlight| {
            if (std.meta.eql(highlight.range.start, position)) return true;
        }

        return false;
    }

    fn expectHighlightAtWithKind(
        highlights: []const types.DocumentHighlight,
        position: types.Position,
        expected_kind: ?types.DocumentHighlight.Kind,
    ) !void {
        for (highlights) |highlight| {
            if (std.meta.eql(highlight.range.start, position)) {
                try expectEqual(expected_kind, highlight.kind);
                return;
            }
        }

        return error.UnexpectedDocumentHighlights;
    }

    fn hoverMarkdownForSymbol(
        arena: std.mem.Allocator,
        symbol: Document.SemanticSymbol,
        directive: ?[]const u8,
    ) OOM![]const u8 {
        const description = switch (symbol.kind) {
            .rule_definition => "rule definition",
            .rule_reference => "rule reference",
            .token_class_definition => "token class definition",
            .token_class_reference => "token class reference",
            .terminal_reference => "terminal reference",
            .action_definition => "named action definition",
            .action_implementation => "named action implementation",
        };

        if (directive) |text| {
            return std.fmt.allocPrint(
                arena,
                "```zitron\n{s}\n```",
                .{text},
            );
        }
        switch (symbol.kind) {
            .rule_definition, .rule_reference => return arena.dupe(u8, "```zitron\n%default_type void\n```"),
            else => {},
        }
        return std.fmt.allocPrint(
            arena,
            "{s} `{s}`",
            .{ description, symbol.symbol_name },
        );
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

fn expectHoverContains(
    server: *Server,
    arena: std.mem.Allocator,
    uri: []const u8,
    position: types.Position,
    expected: []const u8,
) !void {
    const hover = (try server.@"textDocument/hover"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = position,
    })) orelse return error.UnexpectedHoverContents;
    switch (hover.contents) {
        .markup_content => |content| try expect(std.mem.indexOf(u8, content.value, expected) != null),
        else => return error.UnexpectedHoverContents,
    }
}

fn expectInlayHintAfter(
    source: []const u8,
    hints: []const types.InlayHint,
    start_index: usize,
    alias_name: []const u8,
    label: []const u8,
) !void {
    const alias_index = std.mem.indexOf(u8, source[start_index..], alias_name) orelse return error.NeedleNotFound;
    const position = lsp.offsets.indexToPosition(source, start_index + alias_index + alias_name.len, test_offset_encoding);
    for (hints) |hint| {
        if (!std.meta.eql(hint.position, position)) continue;
        switch (hint.label) {
            .string => |hint_label| if (std.mem.eql(u8, hint_label, label)) return,
            else => return error.UnexpectedInlayHints,
        }
    }
    return error.UnexpectedInlayHints;
}

/// Loads the configured fixture source into memory for smoke tests and helpers.
pub fn loadFixtureAlloc(io: std.Io, allocator: std.mem.Allocator) FixtureError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, build_options.fixture_path, allocator, .limited(1024 * 1024));
}

pub fn fixturePath() []const u8 {
    return build_options.fixture_path;
}

pub fn loadSmokeFixtureAlloc(io: std.Io, allocator: std.mem.Allocator) FixtureError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, build_options.smoke_fixture_path, allocator, .limited(1024 * 1024));
}

pub fn smokeFixturePath() []const u8 {
    return build_options.smoke_fixture_path;
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
    const capabilities = serverCapabilities(testing_allocator, .@"utf-16", null);
    lsp.basic_server.validateServerCapabilities(
        Server,
        capabilities,
    );

    const signature_help = capabilities.signatureHelpProvider.?;
    try expectEqualStrings("(", signature_help.triggerCharacters.?[0]);
    try expectEqualStrings(";", signature_help.triggerCharacters.?[1]);
    try expectEqualStrings(",", signature_help.triggerCharacters.?[2]);
    try expectEqualStrings(";", signature_help.retriggerCharacters.?[0]);
    try expectEqualStrings(",", signature_help.retriggerCharacters.?[1]);

    const semantic_tokens = switch (capabilities.semanticTokensProvider.?) {
        .semantic_tokens_options => |options| options,
        else => return error.UnexpectedServerCapabilities,
    };
    const semantic_range = semantic_tokens.range orelse return error.UnexpectedServerCapabilities;
    switch (semantic_range) {
        .bool => |supported| try expect(supported),
        else => return error.UnexpectedServerCapabilities,
    }

    const json = try std.json.Stringify.valueAlloc(
        testing_allocator,
        capabilities,
        .{ .emit_null_optional_fields = false },
    );
    defer testing_allocator.free(json);
    try expect(std.mem.indexOf(u8, json, "\"semanticTokensProvider\"") != null);
    try expect(std.mem.indexOf(u8, json, "\"range\":true") != null);
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

test "server supports declaration as definition for grammar symbols" {
    try expect(@hasDecl(Server, "textDocument/declaration"));
    if (comptime @hasDecl(Server, "textDocument/declaration")) {
        var server = try Server.init(testing_allocator);
        defer server.deinit();

        const sample = try loadFixtureAlloc(std.testing.io, testing_allocator);
        defer testing_allocator.free(sample);

        try server.putDocument("file:///samples/calc.zy", 1, sample);

        const calc_rule_index = try byteIndexOf(sample, "calc ::= expr");
        const declaration = (try server.@"textDocument/declaration"(testing_allocator, .{
            .textDocument = .{ .uri = "file:///samples/calc.zy" },
            .position = try positionOfTextAfter(sample, calc_rule_index + 1, "expr"),
        })) orelse return error.UnexpectedDefinitionTarget;
        switch (declaration) {
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
    }
}

test "embedded tags query compiles for the zitron grammar" {
    var error_offset: u32 = 0;
    const query = try ts.Query.create(zitronLanguage(), tags_query_source, &error_offset);
    defer query.destroy();

    try expectEqual(@as(u32, 16), query.patternCount());
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

test "server returns rule action signature help from aliases" {
    try expect(@hasDecl(Server, "textDocument/signatureHelp"));
    if (comptime @hasDecl(Server, "textDocument/signatureHelp")) {
        var server = try Server.init(testing_allocator);
        defer server.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena_state.deinit();

        const sample = "pair(P) ::= m_form(K) discard m_form(V). @on_pair2(P; ";
        try server.putDocument("file:///samples/signature_help.zy", 1, sample);

        const help = (try server.@"textDocument/signatureHelp"(arena_state.allocator(), .{
            .textDocument = .{ .uri = "file:///samples/signature_help.zy" },
            .position = lsp.offsets.indexToPosition(sample, sample.len, test_offset_encoding),
        })) orelse return error.UnexpectedSignatureHelp;

        try expectEqual(@as(usize, 1), help.signatures.len);
        try expectEqualStrings("@on_pair2(P; K, V)", help.signatures[0].label);
        try expectEqual(@as(u32, 1), help.activeParameter.?);
    }
}

test "server returns impl signature help from named action definition" {
    try expect(@hasDecl(Server, "textDocument/signatureHelp"));
    if (comptime @hasDecl(Server, "textDocument/signatureHelp")) {
        var server = try Server.init(testing_allocator);
        defer server.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena_state.deinit();

        const sample =
            \\pair(P) ::= m_form(K) discard m_form(V). @on_pair2(P; K, V)
            \\%impl @on_pair2(P; K,
        ;
        try server.putDocument("file:///samples/impl_signature_help.zy", 1, sample);

        const help = (try server.@"textDocument/signatureHelp"(arena_state.allocator(), .{
            .textDocument = .{ .uri = "file:///samples/impl_signature_help.zy" },
            .position = lsp.offsets.indexToPosition(sample, sample.len, test_offset_encoding),
        })) orelse return error.UnexpectedSignatureHelp;

        try expectEqual(@as(usize, 1), help.signatures.len);
        try expectEqualStrings("@on_pair2(P; K, V)", help.signatures[0].label);
        try expectEqual(@as(u32, 2), help.activeParameter.?);
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
}

test "string terminals participate in grammar symbol operations" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/string_terminals.zy";
    const sample =
        \\%token_type Token
        \\%token "{" "}".
        \\start ::= "{" "}". ["{"]
    ;
    try server.putDocument(uri, 1, sample);
    const doc = server.getDocument(uri).?;
    try expect(!doc.parsed.has_error);

    const rule_start = try byteIndexOf(sample, "start ::=");
    const rule_terminal = try positionOfTextAfter(sample, rule_start, "\"{\"");
    switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, rule_terminal)) {
        .symbol => |symbol| {
            try expectEqual(Document.SemanticKind.terminal_reference, symbol.kind);
            try expectEqualStrings("\"{\"", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }

    try expectHoverContains(
        &server,
        arena_state.allocator(),
        uri,
        rule_terminal,
        "```zitron\n%token_type Token\n```",
    );

    const references = (try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = rule_terminal,
        .context = .{ .includeDeclaration = false },
    })) orelse return error.UnexpectedReferences;
    try expectEqual(@as(usize, 3), references.len);
    try expect(Server.hasLocationAt(references, uri, try positionOfTextAfter(sample, try byteIndexOf(sample, "%token"), "\"{\"")));
    try expect(Server.hasLocationAt(references, uri, rule_terminal));
    try expect(Server.hasLocationAt(references, uri, try positionOfTextAfter(sample, try byteIndexOf(sample, "[\"{\"]"), "\"{\"")));

    const type_definition = (try server.@"textDocument/typeDefinition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = rule_terminal,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (type_definition) {
        .definition => |target| switch (target) {
            .location => |location| try expectEqual(types.Position{ .line = 0, .character = 12 }, location.range.start),
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const rename = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = rule_terminal,
        .newName = "\"[\"",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, rename, uri, "\"{\"", "\"[\"", 3);
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

    const type_definition = try server.@"textDocument/typeDefinition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = position,
    });
    try expect(type_definition == null);

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
            .start = position,
            .end = .{ .line = position.line, .character = position.character + @as(u32, @intCast("answer = A".len)) },
        },
    });
    try expect(inlay_hints == null);
}

test "type definition resolves grammar particles to their assigning directives" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/type_definition.zy";
    const sample =
        \\%token_type Token
        \\%default_type Default
        \\%type expr Expr
        \\%type expr LatestExpr
        \\start ::= expr(A) fallback(F) NUMBER(N) PLUS|MINUS(O).
    ;
    try server.putDocument(uri, 1, sample);

    const Test = struct {
        fn expectDirective(
            server_ptr: *Server,
            arena: std.mem.Allocator,
            document_uri: []const u8,
            source: []const u8,
            after_index: usize,
            particle: []const u8,
            expected_line: u32,
            expected_character: u32,
        ) !void {
            const result = (try server_ptr.@"textDocument/typeDefinition"(arena, .{
                .textDocument = .{ .uri = document_uri },
                .position = try positionOfTextAfter(source, after_index, particle),
            })) orelse return error.UnexpectedDefinitionTarget;
            switch (result) {
                .definition => |target| switch (target) {
                    .location => |location| {
                        try expectEqualStrings(document_uri, location.uri);
                        try expectEqual(expected_line, location.range.start.line);
                        try expectEqual(expected_character, location.range.start.character);
                    },
                    else => return error.UnexpectedDefinitionTarget,
                },
                else => return error.UnexpectedDefinitionTarget,
            }
        }
    };

    const rule = try byteIndexOf(sample, "start ::=");
    try Test.expectDirective(&server, arena_state.allocator(), uri, sample, rule, "expr", 3, 6);
    try Test.expectDirective(&server, arena_state.allocator(), uri, sample, rule, "fallback", 1, 14);
    try Test.expectDirective(&server, arena_state.allocator(), uri, sample, rule, "NUMBER", 0, 12);
    try Test.expectDirective(&server, arena_state.allocator(), uri, sample, rule, "PLUS", 0, 12);
}

test "token classes behave as named multiterminals across grammar features" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/token_class.zy";
    const sample =
        \\%default_type Default
        \\%token_class additive PLUS|MINUS .
        \\%type expr Expr
        \\start ::= expr(A) additive(O) comparison.
        \\expr(A) ::= additive(B).
        \\%token_class comparison EQ|NE .
        \\%token_type Token
        \\other ::= comp
    ;
    try server.putDocument(uri, 1, sample);

    const definition_name = try positionOfTextAfter(sample, try byteIndexOf(sample, "%token_class"), "additive");
    const first_reference = try positionOfTextAfter(sample, try byteIndexOf(sample, "start ::="), "additive");
    const second_reference = try positionOfTextAfter(sample, try byteIndexOf(sample, "expr(A) ::="), "additive");
    const doc = server.getDocument(uri).?;

    switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, definition_name)) {
        .symbol => |symbol| try expectEqual(Document.SemanticKind.token_class_definition, symbol.kind),
        else => return error.UnexpectedResolution,
    }
    switch (doc.resolveAtPosition(server.tags_query, server.offset_encoding, first_reference)) {
        .symbol => |symbol| try expectEqual(Document.SemanticKind.token_class_reference, symbol.kind),
        else => return error.UnexpectedResolution,
    }

    const hover = (try server.@"textDocument/hover"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = first_reference,
    })) orelse return error.UnexpectedHoverContents;
    switch (hover.contents) {
        .markup_content => |content| {
            try expect(std.mem.indexOf(u8, content.value, "```zitron\n%token_class additive PLUS|MINUS .\n```") != null);
            try expect(std.mem.indexOf(u8, content.value, "capture") == null);
        },
        else => return error.UnexpectedHoverContents,
    }

    try expectHoverContains(
        &server,
        arena_state.allocator(),
        uri,
        definition_name,
        "```zitron\n%token_class additive PLUS|MINUS .\n```",
    );
    try expectHoverContains(
        &server,
        arena_state.allocator(),
        uri,
        try positionOfTextAfter(sample, try byteIndexOf(sample, "start ::="), "expr"),
        "```zitron\n%type expr Expr\n```",
    );
    try expectHoverContains(
        &server,
        arena_state.allocator(),
        uri,
        try positionOfText(sample, "start ::="),
        "```zitron\n%default_type Default\n```",
    );
    try expectHoverContains(
        &server,
        arena_state.allocator(),
        uri,
        try positionOfTextAfter(sample, try byteIndexOf(sample, "%token_class"), "PLUS"),
        "```zitron\n%token_type Token\n```",
    );

    const definition = (try server.@"textDocument/definition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = first_reference,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (definition) {
        .definition => |target| switch (target) {
            .location => |location| try expectEqual(definition_name, location.range.start),
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const type_definition = (try server.@"textDocument/typeDefinition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = first_reference,
    })) orelse return error.UnexpectedDefinitionTarget;
    switch (type_definition) {
        .definition => |target| switch (target) {
            .location => |location| {
                try expectEqual(@as(u32, 6), location.range.start.line);
                try expectEqual(@as(u32, 12), location.range.start.character);
            },
            else => return error.UnexpectedDefinitionTarget,
        },
        else => return error.UnexpectedDefinitionTarget,
    }

    const references = (try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = first_reference,
        .context = .{ .includeDeclaration = true },
    })) orelse return error.UnexpectedDefinitionTarget;
    try expectEqual(@as(usize, 3), references.len);
    try expect(Server.hasLocationAt(references, uri, definition_name));
    try expect(Server.hasLocationAt(references, uri, first_reference));
    try expect(Server.hasLocationAt(references, uri, second_reference));

    const highlights = (try server.@"textDocument/documentHighlight"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = first_reference,
    })) orelse return error.UnexpectedDocumentHighlights;
    try expectEqual(@as(usize, 3), highlights.len);
    try Server.expectHighlightAtWithKind(highlights, definition_name, .Write);
    try Server.expectHighlightAtWithKind(highlights, first_reference, .Read);
    try Server.expectHighlightAtWithKind(highlights, second_reference, .Read);

    const symbols = (try server.@"textDocument/documentSymbol"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
    })).?.document_symbols;
    var maybe_token_class_symbol: ?types.DocumentSymbol = null;
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "additive")) maybe_token_class_symbol = symbol;
    }
    const token_class_symbol = maybe_token_class_symbol orelse return error.UnexpectedDocumentSymbols;
    try expectEqualStrings("token class", token_class_symbol.detail.?);
    try expectEqual(types.SymbolKind.Constant, token_class_symbol.kind);

    const rename = (try server.@"textDocument/rename"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = first_reference,
        .newName = "operator",
    })) orelse return error.UnexpectedRenameResult;
    try expectRenameEdits(sample, rename, uri, "additive", "operator", 3);

    const completion_result = (try server.@"textDocument/completion"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = lsp.offsets.indexToPosition(sample, sample.len, test_offset_encoding),
    })) orelse return error.UnexpectedCompletionResult;
    const completion_items = switch (completion_result) {
        .completion_items => |items| items,
        else => return error.UnexpectedCompletionResult,
    };
    const token_class_completion = completionItemWithLabel(completion_items, "comparison") orelse return error.UnexpectedCompletionResult;
    try expectEqualStrings("token class", token_class_completion.detail.?);
    try expectEqual(types.CompletionItemKind.Constant, token_class_completion.kind.?);

    const hints = (try server.@"textDocument/inlayHint"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 100, .character = 0 },
        },
    })) orelse return error.UnexpectedInlayHints;
    const first_rule = try byteIndexOf(sample, "start ::=");
    try expectInlayHintAfter(sample, hints, first_rule, "O", ": Token");
    const second_rule = try byteIndexOf(sample, "expr(A) ::=");
    try expectInlayHintAfter(sample, hints, second_rule, "B", ": Token");

    const untyped_uri = "file:///samples/untyped_token_class.zy";
    const untyped_sample =
        \\%default_type Default
        \\%token_class operators PLUS|MINUS .
        \\start ::= operators(O).
    ;
    try server.putDocument(untyped_uri, 1, untyped_sample);
    const untyped_doc = server.getDocument(untyped_uri).?;
    const untyped_reference = try positionOfTextAfter(untyped_sample, try byteIndexOf(untyped_sample, "start ::="), "operators");
    switch (untyped_doc.typeDefinitionAtPosition(server.offset_encoding, untyped_reference)) {
        .no_match => {},
        else => return error.UnexpectedDefinitionTarget,
    }
    const untyped_hints = try untyped_doc.inlayHints(
        arena_state.allocator(),
        .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 100, .character = 0 },
        },
        server.offset_encoding,
    );
    try expectEqual(@as(usize, 0), untyped_hints.len);
}

test "server returns grammar inlay hints with disabled Zig middleware" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const sample =
        \\%type expr f64
        \\calc ::= expr(A).
    ;

    try server.putDocument("file:///samples/grammar_inlay.zy", 1, sample);

    const inlay_hints = (try server.@"textDocument/inlayHint"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/grammar_inlay.zy" },
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 100, .character = 0 },
        },
    })) orelse return error.UnexpectedInlayHints;

    try expectEqual(@as(usize, 1), inlay_hints.len);
    switch (inlay_hints[0].label) {
        .string => |label| try expectEqualStrings(": f64", label),
        else => return error.UnexpectedInlayHints,
    }
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
            try expectEqualStrings("```zitron\n%default_type void\n```", content.value);
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

    const number_rhs_index = try byteIndexOf(sample, "factor(A) ::= NUMBER(N).");
    const number_references = (try server.@"textDocument/references"(arena_state.allocator(), .{
        .textDocument = .{ .uri = "file:///samples/calc.zy" },
        .position = try positionOfTextAfter(sample, number_rhs_index, "NUMBER"),
        .context = .{ .includeDeclaration = false },
    })) orelse return error.UnexpectedDefinitionTarget;
    try expectEqual(@as(usize, 1), number_references.len);
    try expect(Server.hasLocationAt(number_references, "file:///samples/calc.zy", try positionOfTextAfter(sample, number_rhs_index, "NUMBER")));
}

test "document highlights cover directives identifiers and named actions" {
    var server = try Server.init(testing_allocator);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const uri = "file:///samples/document_highlight.zy";
    const sample =
        \\%type expr f64
        \\%type term f64
        \\%token_type Token
        \\calc ::= expr(A).
        \\expr(A) ::= term(A) PLUS|MINUS PLUS. @on_expr(A)
        \\term(A) ::= PLUS(A).
        \\%impl @on_expr(A) { _ = A; }
    ;
    try server.putDocument(uri, 1, sample);

    const directive_highlights = (try server.@"textDocument/documentHighlight"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "%type"),
    })) orelse return error.UnexpectedDocumentHighlights;
    try expectEqual(@as(usize, 2), directive_highlights.len);
    try expect(Server.hasHighlightAt(directive_highlights, try positionOfText(sample, "%type")));
    const second_type = try byteIndexOfAfter(sample, 1, "%type");
    try expect(Server.hasHighlightAt(directive_highlights, lsp.offsets.indexToPosition(sample, second_type, test_offset_encoding)));
    try Server.expectHighlightAtWithKind(directive_highlights, try positionOfText(sample, "%type"), null);

    _ = arena_state.reset(.retain_capacity);

    const nonterminal_highlights = (try server.@"textDocument/documentHighlight"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "expr(A)"),
    })) orelse return error.UnexpectedDocumentHighlights;
    try expectEqual(@as(usize, 3), nonterminal_highlights.len);
    try expect(Server.hasHighlightAt(nonterminal_highlights, try positionOfTextAfter(sample, try byteIndexOf(sample, "%type expr"), "expr")));
    try expect(Server.hasHighlightAt(nonterminal_highlights, try positionOfText(sample, "expr(A) ::= term")));
    const calc_ref = try byteIndexOf(sample, "calc ::= expr(A)");
    try expect(Server.hasHighlightAt(nonterminal_highlights, try positionOfTextAfter(sample, calc_ref, "expr")));
    try Server.expectHighlightAtWithKind(
        nonterminal_highlights,
        try positionOfText(sample, "expr(A) ::= term"),
        .Write,
    );
    try Server.expectHighlightAtWithKind(
        nonterminal_highlights,
        try positionOfTextAfter(sample, calc_ref, "expr"),
        .Read,
    );

    _ = arena_state.reset(.retain_capacity);

    const terminal_highlights = (try server.@"textDocument/documentHighlight"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "PLUS|MINUS"),
    })) orelse return error.UnexpectedDocumentHighlights;
    try expectEqual(@as(usize, 3), terminal_highlights.len);
    try expect(Server.hasHighlightAt(terminal_highlights, try positionOfText(sample, "PLUS|MINUS")));
    const second_plus = try byteIndexOfAfter(sample, try byteIndexOf(sample, "PLUS|MINUS") + 1, "PLUS");
    try expect(Server.hasHighlightAt(terminal_highlights, lsp.offsets.indexToPosition(sample, second_plus, test_offset_encoding)));
    const term_plus = try byteIndexOf(sample, "term(A) ::= PLUS(A)");
    try expect(Server.hasHighlightAt(terminal_highlights, try positionOfTextAfter(sample, term_plus, "PLUS")));
    try Server.expectHighlightAtWithKind(terminal_highlights, try positionOfText(sample, "PLUS|MINUS"), null);

    _ = arena_state.reset(.retain_capacity);

    const action_highlights = (try server.@"textDocument/documentHighlight"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = try positionOfText(sample, "on_expr(A)"),
    })) orelse return error.UnexpectedDocumentHighlights;
    try expectEqual(@as(usize, 2), action_highlights.len);
    try expect(Server.hasHighlightAt(action_highlights, try positionOfText(sample, "@on_expr(A)")));
    const impl_action = try byteIndexOf(sample, "%impl @on_expr(A)");
    try expect(Server.hasHighlightAt(action_highlights, try positionOfTextAfter(sample, impl_action, "@on_expr(A)")));
    try Server.expectHighlightAtWithKind(action_highlights, try positionOfText(sample, "@on_expr(A)"), null);
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

test "formatting returns a whole document replacement in each position encoding" {
    const source = "foo::= \"😀\" . // café";
    const uri = "file:///formatting.zy";
    inline for (.{ lsp.offsets.Encoding.@"utf-8", lsp.offsets.Encoding.@"utf-16", lsp.offsets.Encoding.@"utf-32" }) |encoding| {
        var server = try Server.init(testing_allocator);
        defer server.deinit();
        server.io = std.testing.io;
        server.offset_encoding = encoding;
        try server.putDocument(uri, 1, source);
        var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const params = types.DocumentFormattingParams{
            .textDocument = .{ .uri = uri },
            .options = .{ .tabSize = 4, .insertSpaces = true },
        };
        const edits = (try server.@"textDocument/formatting"(arena, params)).?;
        try expectEqual(@as(usize, 1), edits.len);
        try expectEqualStrings(source, lsp.offsets.rangeToSlice(source, edits[0].range, encoding));
        try expectEqualStrings(source, server.getDocument(uri).?.source);
        try expectEqualStrings("foo ::= \"😀\".   // café", edits[0].newText);
        try server.getDocument(uri).?.updateIncremental(testing_allocator, 2, &.{
            .{ .text_document_content_change_whole_document = .{ .text = edits[0].newText } },
        }, encoding);
        try expectEqual(edits[0].newText.len, server.getDocument(uri).?.tree.rootNode().endByte());
        const unchanged = (try server.@"textDocument/formatting"(arena, params)).?;
        try expectEqual(@as(usize, 0), unchanged.len);
    }
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
const ZlsAdapter = @import("zls.zig");
const completion = @import("completion.zig");
const formatter = @import("zitron-format");
const lsp = @import("lsp");
const types = lsp.types.flat;
const build_options = @import("build_options");
const ts = @import("tree-sitter");
const tags_query_source = @embedFile("zitron-tags-query");
const rename_query_source = @embedFile("zitron-rename-query");
const token_enum_query_source = @embedFile("zitron-token-enum-query");
const zitron_grammar = @import("tree_sitter_zitron");
const test_offset_encoding: lsp.offsets.Encoding = .@"utf-8";
const log = std.log.scoped(.@"zitron-ls");

comptime {
    std.testing.refAllDecls(Document);
    std.testing.refAllDecls(ZigMiddleware);
    std.testing.refAllDecls(ZlsAdapter);
}
