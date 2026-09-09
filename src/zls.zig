//! In-process adapter around upstream ZLS.
//!
//! `ZigMiddleware` owns one of these for all embedded-Zig ZLS work.

const Adapter = @This();

io: std.Io,
allocator: std.mem.Allocator,
environ_map: *std.process.Environ.Map,
config_manager: *upstream.configuration.Manager,
capture_transport: *CaptureTransport,
server: *upstream.Server,
completion_triggers: []const []const u8,

pub const Error =
    std.mem.Allocator.Error ||
    std.Io.Cancelable ||
    upstream.Server.Error ||
    error{
        Unexpected,
        UnexpectedResponse,
    };

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: std.process.Environ.Map,
) Error!Adapter {
    const owned_environ_map = try allocator.create(std.process.Environ.Map);
    errdefer allocator.destroy(owned_environ_map);
    owned_environ_map.* = environ_map;
    errdefer owned_environ_map.deinit();

    const config_manager = try allocator.create(upstream.configuration.Manager);
    errdefer allocator.destroy(config_manager);
    config_manager.* = try upstream.configuration.Manager.init(io, allocator, owned_environ_map);
    errdefer config_manager.deinit();

    var config: upstream.configuration.UnresolvedConfig = .{
        .semantic_tokens = .full,
        .prefer_ast_check_as_child_process = true,
        .inlay_hints_exclude_single_argument = false,
        .inlay_hints_show_builtin = true,
    };
    try config_manager.setConfiguration(.frontend, &config);

    var resolve_result = try config_manager.resolveConfiguration(allocator);
    resolve_result.deinit(allocator);

    const capture_transport = try allocator.create(CaptureTransport);
    errdefer allocator.destroy(capture_transport);
    capture_transport.* = CaptureTransport.init(allocator);
    errdefer capture_transport.deinit();

    const server = try upstream.Server.create(.{
        .io = io,
        .allocator = allocator,
        .transport = &capture_transport.transport,
        .config_manager = config_manager,
    });
    errdefer server.destroy();

    var adapter: Adapter = .{
        .io = io,
        .allocator = allocator,
        .environ_map = owned_environ_map,
        .config_manager = config_manager,
        .capture_transport = capture_transport,
        .server = server,
        .completion_triggers = &.{},
    };
    errdefer adapter.deinit();

    var init_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer init_arena_state.deinit();
    const init_arena = init_arena_state.allocator();

    const result = try adapter.server.sendRequestSync(init_arena, "initialize", initializeParams());
    if (result.serverInfo == null and result.capabilities.completionProvider == null) {
        return error.UnexpectedResponse;
    }
    if (result.capabilities.completionProvider) |completion_options| {
        if (completion_options.triggerCharacters) |trigger_characters| {
            adapter.completion_triggers = try dupeStringSlices(allocator, trigger_characters);
        }
    }

    try adapter.server.sendNotificationSync(allocator, "initialized", .{});
    adapter.discardCapturedMessages();
    return adapter;
}

pub fn initFromEnvironmentMap(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Error!Adapter {
    var owned = try environ_map.clone(allocator);
    errdefer owned.deinit();
    return try init(io, allocator, owned);
}

pub fn initFromEnvironment(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) Error!Adapter {
    var environ_map = try environ.createMap(allocator);
    errdefer environ_map.deinit();
    return try init(io, allocator, environ_map);
}

pub fn deinit(adapter: *Adapter) void {
    adapter.server.destroy();
    freeStringSlices(adapter.allocator, adapter.completion_triggers);
    adapter.config_manager.deinit();
    adapter.allocator.destroy(adapter.config_manager);
    adapter.capture_transport.deinit();
    adapter.allocator.destroy(adapter.capture_transport);
    adapter.environ_map.deinit();
    adapter.allocator.destroy(adapter.environ_map);
    adapter.* = undefined;
}

pub fn completionTriggerCharacters(adapter: *const Adapter) []const []const u8 {
    return adapter.completion_triggers;
}

pub fn openDocument(
    adapter: *Adapter,
    arena: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    text: []const u8,
) Error!void {
    try adapter.server.sendNotificationSync(arena, "textDocument/didOpen", .{
        .textDocument = .{
            .uri = uri,
            .languageId = .{ .custom_value = "zig" },
            .version = version,
            .text = text,
        },
    });
}

pub fn changeDocument(
    adapter: *Adapter,
    arena: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    changes: []const types.TextDocumentContentChangeEvent,
) Error!void {
    try adapter.server.sendNotificationSync(arena, "textDocument/didChange", .{
        .textDocument = .{
            .uri = uri,
            .version = version,
        },
        .contentChanges = changes,
    });
}

pub fn replaceDocument(
    adapter: *Adapter,
    arena: std.mem.Allocator,
    uri: []const u8,
    version: i32,
    text: []const u8,
) Error!void {
    try adapter.changeDocument(arena, uri, version, &.{
        .{ .text_document_content_change_whole_document = .{ .text = text } },
    });
}

pub fn closeDocument(adapter: *Adapter, arena: std.mem.Allocator, uri: []const u8) Error!void {
    try adapter.server.sendNotificationSync(arena, "textDocument/didClose", .{
        .textDocument = .{ .uri = uri },
    });
}

pub fn didChangeWatchedFiles(
    adapter: *Adapter,
    arena: std.mem.Allocator,
    params: types.DidChangeWatchedFilesParams,
) Error!void {
    for (params.changes) |change| {
        if (change.type != .Changed or !std.mem.endsWith(u8, change.uri, "/build.zig")) continue;
        const uri = upstream.Uri.parse(arena, change.uri) catch return error.Unexpected;
        // A discovered build file may exist only in the build-file table.  The
        // ZLS 0.16.0 watched-file route requires a document handle and rejects
        // changed file-scheme URIs, so use the library invalidator directly.
        adapter.server.document_store.invalidateBuildFile(uri);
    }
}

pub fn request(
    adapter: *Adapter,
    arena: std.mem.Allocator,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) Error!lsp.ResultType(method) {
    const result = try adapter.server.sendRequestSync(arena, method, params);
    return result;
}

pub fn drainCapturedMessages(adapter: *Adapter, allocator: std.mem.Allocator) error{OutOfMemory}![][]u8 {
    adapter.server.wait_group.await(adapter.io) catch {};
    adapter.server.wait_group = .init;
    return try adapter.capture_transport.drain(allocator);
}

pub fn discardCapturedMessages(adapter: *Adapter) void {
    adapter.capture_transport.discard();
}

fn initializeParams() types.InitializeParams {
    return .{
        .clientInfo = .{ .name = "zitron-ls" },
        .capabilities = .{
            .general = .{
                .positionEncodings = &position_encodings,
            },
            .textDocument = .{
                .hover = .{
                    .contentFormat = &markup_formats,
                },
                .completion = .{
                    .completionItem = .{
                        .snippetSupport = true,
                        .documentationFormat = &markup_formats,
                        .labelDetailsSupport = true,
                    },
                },
                .signatureHelp = .{
                    .signatureInformation = .{
                        .documentationFormat = &markup_formats,
                        .activeParameterSupport = true,
                    },
                    .contextSupport = true,
                },
                .publishDiagnostics = .{
                    .tagSupport = .{ .valueSet = &diagnostic_tags },
                },
                .semanticTokens = .{
                    .requests = .{
                        .range = .{ .bool = true },
                        .full = .{ .client_semantic_tokens_request_full_delta = .{ .delta = true } },
                    },
                    .tokenTypes = &semantic_token_types,
                    .tokenModifiers = &semantic_token_modifiers,
                    .formats = &semantic_token_formats,
                    .overlappingTokenSupport = true,
                    .multilineTokenSupport = true,
                    .serverCancelSupport = false,
                    .augmentsSyntaxTokens = false,
                },
            },
            .workspace = .{
                .semanticTokens = .{ .refreshSupport = true },
                .inlayHint = .{ .refreshSupport = true },
            },
        },
    };
}

fn dupeStringSlices(allocator: std.mem.Allocator, slices: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const owned = try allocator.alloc([]const u8, slices.len);
    errdefer allocator.free(owned);
    for (slices, 0..) |slice, index| {
        owned[index] = try allocator.dupe(u8, slice);
    }
    return owned;
}

fn freeStringSlices(allocator: std.mem.Allocator, slices: []const []const u8) void {
    for (slices) |slice| allocator.free(slice);
    allocator.free(slices);
}

fn freeCapturedMessages(allocator: std.mem.Allocator, messages: [][]u8) void {
    for (messages) |message| allocator.free(message);
    allocator.free(messages);
}

fn capturedMessagesContain(messages: []const []const u8, needle: []const u8) bool {
    for (messages) |message| {
        if (std.mem.indexOf(u8, message, needle) != null) return true;
    }
    return false;
}

const CaptureTransport = struct {
    transport: lsp.Transport,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex,
    messages: std.ArrayListUnmanaged([]u8),

    fn init(allocator: std.mem.Allocator) CaptureTransport {
        return .{
            .transport = .{ .vtable = &.{
                .readJsonMessage = CaptureTransport.readJsonMessage,
                .writeJsonMessage = CaptureTransport.writeJsonMessage,
            } },
            .allocator = allocator,
            .mutex = .init,
            .messages = .empty,
        };
    }

    fn deinit(capture: *CaptureTransport) void {
        capture.discard();
        capture.messages.deinit(capture.allocator);
        capture.* = undefined;
    }

    fn drain(capture: *CaptureTransport, allocator: std.mem.Allocator) error{OutOfMemory}![][]u8 {
        capture.mutex.lockUncancelable(std.Options.debug_io);
        defer capture.mutex.unlock(std.Options.debug_io);

        const messages = try capture.messages.toOwnedSlice(allocator);
        capture.messages = .empty;
        return messages;
    }

    fn discard(capture: *CaptureTransport) void {
        capture.mutex.lockUncancelable(std.Options.debug_io);
        defer capture.mutex.unlock(std.Options.debug_io);

        for (capture.messages.items) |message| capture.allocator.free(message);
        capture.messages.clearRetainingCapacity();
    }

    fn readJsonMessage(
        _: *lsp.Transport,
        _: std.Io,
        _: std.mem.Allocator,
    ) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(
        transport: *lsp.Transport,
        _: std.Io,
        json_message: []const u8,
    ) lsp.Transport.WriteError!void {
        const capture: *CaptureTransport = @fieldParentPtr("transport", transport);
        const owned = capture.allocator.dupe(u8, json_message) catch @panic("out of memory capturing ZLS message");

        capture.mutex.lockUncancelable(std.Options.debug_io);
        defer capture.mutex.unlock(std.Options.debug_io);
        capture.messages.append(capture.allocator, owned) catch @panic("out of memory capturing ZLS message");
    }
};

test "adapter initializes, syncs, requests, and closes a document" {
    var env = std.process.Environ.Map.init(testing_allocator);
    try env.put("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    var adapter = try Adapter.init(std.testing.io, testing_allocator, env);
    defer adapter.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uri = "untitled:///zitron-ls-adapter.zig";
    try adapter.openDocument(arena, uri, 1,
        \\const Token = enum { number, @"{" };
        \\
        \\fn brace() Token {
        \\    return .@"{";
        \\}
        \\
        \\fn reduce(yymsp: []Token) Token {
        \\    // #line 12 sample.zy
        \\    const alpha = yymsp[0];
        \\    return alpha;
        \\}
        \\
    );
    const open_messages = try adapter.drainCapturedMessages(testing_allocator);
    defer freeCapturedMessages(testing_allocator, open_messages);
    try std.testing.expect(capturedMessagesContain(open_messages, "textDocument/publishDiagnostics"));

    const hover = try adapter.request(arena, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 6 },
    });
    try std.testing.expect(hover != null);
    const quoted_hover = (try adapter.request(arena, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 30 },
    })) orelse return error.UnexpectedResponse;
    switch (quoted_hover.contents) {
        .markup_content => |content| try std.testing.expect(std.mem.indexOf(u8, content.value, "```zig\n@\"{\"\n```") != null),
        else => return error.UnexpectedResponse,
    }
    const quoted_references = (try adapter.request(arena, "textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 30 },
        .context = .{ .includeDeclaration = false },
        .workDoneToken = null,
        .partialResultToken = null,
    })) orelse return error.UnexpectedResponse;
    var found_quoted_use = false;
    for (quoted_references) |reference| {
        if (reference.range.start.line == 3) found_quoted_use = true;
    }
    try std.testing.expect(found_quoted_use);

    try adapter.replaceDocument(arena, uri, 2,
        \\const Token = enum { number };
        \\
        \\fn reduce(yymsp: []Token) Token {
        \\    // #line 12 sample.zy
        \\    const beta = yymsp[0];
        \\    return beta;
        \\}
        \\
    );
    const change_messages = try adapter.drainCapturedMessages(testing_allocator);
    defer freeCapturedMessages(testing_allocator, change_messages);
    try std.testing.expect(capturedMessagesContain(change_messages, "textDocument/publishDiagnostics"));
    try adapter.closeDocument(arena, uri);
}

const std = @import("std");
const upstream = @import("zls");
const lsp = upstream.lsp;
const types = lsp.types.flat;
const testing_allocator = std.testing.allocator;

const position_encodings = [_]types.PositionEncodingKind{.@"utf-8"};
const markup_formats = [_]types.MarkupKind{ .markdown, .plaintext };
const diagnostic_tags = [_]types.DiagnosticTag{ .Unnecessary, .Deprecated };
const semantic_token_formats = [_]types.TokenFormat{.relative};
const semantic_token_types = [_][]const u8{
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
    "number",
    "regexp",
    "operator",
    "decorator",
    "keywordLiteral",
    "errorTag",
    "builtin",
    "label",
};
const semantic_token_modifiers = [_][]const u8{
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
