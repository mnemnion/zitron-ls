//! Shared language-server state and configuration.
const std = @import("std");
const build_options = @import("build_options");
pub const lsp = @import("lsp");
pub const types = lsp.types;
const ts = @import("tree-sitter");
const zitron_grammar = @import("tree_sitter_zitron");

pub const server_name = "lsp_zitron";
pub const server_version = "0.0.1";

pub const ParseSummary = struct {
    root_kind: []const u8,
    has_error: bool,
};

pub fn fixturePath() []const u8 {
    return build_options.fixture_path;
}

pub fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

pub fn loadFixtureAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, fixturePath(), 64 * 1024);
}

pub fn parseSource(source: []const u8) !ParseSummary {
    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(zitronLanguage());

    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    return .{
        .root_kind = root.kind(),
        .has_error = root.hasError(),
    };
}

pub fn serverCapabilities() types.ServerCapabilities {
    return .{
        .textDocumentSync = .{ .TextDocumentSyncKind = .None },
        .hoverProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = false },
    };
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    fixture_source: []u8,
    startup_parse: ParseSummary,

    pub fn init(allocator: std.mem.Allocator) !Server {
        const fixture_source = try loadFixtureAlloc(allocator);
        errdefer allocator.free(fixture_source);

        return .{
            .allocator = allocator,
            .fixture_source = fixture_source,
            .startup_parse = try parseSource(fixture_source),
        };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.fixture_source);
    }

    fn refreshFixtureParse(self: *Server) !ParseSummary {
        self.startup_parse = try parseSource(self.fixture_source);
        return self.startup_parse;
    }

    pub fn initialize(
        self: *Server,
        _: std.mem.Allocator,
        _: types.InitializeParams,
    ) types.InitializeResult {
        _ = self;
        return .{
            .capabilities = serverCapabilities(),
            .serverInfo = .{
                .name = server_name,
                .version = server_version,
            },
        };
    }

    pub fn initialized(_: *Server, _: std.mem.Allocator, _: types.InitializedParams) void {}

    pub fn @"textDocument/hover"(
        self: *Server,
        arena: std.mem.Allocator,
        _: types.HoverParams,
    ) !?types.Hover {
        const parsed = try self.refreshFixtureParse();
        const value = try std.fmt.allocPrint(
            arena,
            "fixture `{s}` parsed as `{s}` (has_error={})",
            .{ fixturePath(), parsed.root_kind, parsed.has_error },
        );

        return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .markdown,
                    .value = value,
                },
            },
        };
    }

    pub fn shutdown(_: *Server, _: std.mem.Allocator, _: void) ?void {
        return null;
    }

    pub fn exit(_: *Server, _: std.mem.Allocator, _: void) void {}

    pub fn onResponse(_: *Server, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
};

test "server capabilities match the implemented handlers" {
    lsp.basic_server.validateServerCapabilities(Server, serverCapabilities());
}

test "tree-sitter zitron parses the configured fixture" {
    const sample = try loadFixtureAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sample);

    const parsed = try parseSource(sample);

    try std.testing.expectEqualStrings("source_file", parsed.root_kind);
    try std.testing.expect(!parsed.has_error);
}

test "server init eagerly parses the configured fixture" {
    var server = try Server.init(std.testing.allocator);
    defer server.deinit();

    try std.testing.expectEqualStrings("source_file", server.startup_parse.root_kind);
    try std.testing.expect(!server.startup_parse.has_error);
}
