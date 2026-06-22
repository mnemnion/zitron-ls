//! In-process adapter around upstream ZLS.
//!
//! `ZigMiddleware` owns one of these beside the spawned ZLS server. Ported
//! methods call this adapter directly; unported methods keep using the server
//! fallback until they are migrated.

const Adapter = @This();

io: std.Io,
allocator: std.mem.Allocator,
environ_map: *std.process.Environ.Map,
config_manager: upstream.configuration.Manager,
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

    var config_manager = try upstream.configuration.Manager.init(io, allocator, owned_environ_map);
    errdefer config_manager.deinit();

    var config: upstream.configuration.UnresolvedConfig = .{
        .semantic_tokens = .full,
        .prefer_ast_check_as_child_process = false,
        .inlay_hints_exclude_single_argument = false,
        .inlay_hints_show_builtin = true,
    };
    try config_manager.setConfiguration(.frontend, &config);

    var resolve_result = try config_manager.resolveConfiguration(allocator);
    resolve_result.deinit(allocator);
    config_manager.config.prefer_ast_check_as_child_process = false;

    const server = try upstream.Server.create(.{
        .io = io,
        .allocator = allocator,
        .transport = null,
        .config_manager = &config_manager,
    });
    errdefer server.destroy();

    var adapter: Adapter = .{
        .io = io,
        .allocator = allocator,
        .environ_map = owned_environ_map,
        .config_manager = config_manager,
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
    if (adapter.server.status == .initialized) {
        _ = adapter.server.sendRequestSync(adapter.allocator, "shutdown", {}) catch {};
        adapter.server.sendNotificationSync(adapter.allocator, "exit", {}) catch {};
    }
    adapter.server.destroy();
    freeStringSlices(adapter.allocator, adapter.completion_triggers);
    adapter.config_manager.deinit();
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

pub fn request(
    adapter: *Adapter,
    arena: std.mem.Allocator,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) Error!lsp.ResultType(method) {
    return adapter.server.sendRequestSync(arena, method, params);
}

fn initializeParams() types.InitializeParams {
    return .{
        .clientInfo = .{ .name = "lsp_zitron" },
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

test "adapter initializes, syncs, requests, and closes a document" {
    var env = std.process.Environ.Map.init(testing_allocator);
    try env.put("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    var adapter = try Adapter.init(std.testing.io, testing_allocator, env);
    defer adapter.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uri = "untitled:///lsp-zitron-adapter.zig";
    try adapter.openDocument(arena, uri, 1,
        \\const Token = enum { number };
        \\
        \\fn reduce(yymsp: []Token) Token {
        \\    // #line 12 sample.zy
        \\    const alpha = yymsp[0];
        \\    return alpha;
        \\}
        \\
    );

    const hover = try adapter.request(arena, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 6 },
    });
    try std.testing.expect(hover != null);

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
    try adapter.closeDocument(arena, uri);
}

const std = @import("std");
const upstream = @import("zls");
const lsp = upstream.lsp;
const types = lsp.types.flat;
const testing_allocator = std.testing.allocator;

const position_encodings = [_]types.PositionEncodingKind{.@"utf-8"};
const markup_formats = [_]types.MarkupKind{ .markdown, .plaintext };
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
