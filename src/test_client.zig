//! Tiny subprocess client for the lsp-kit-backed smoke server.
const std = @import("std");
const zitron = @import("lsp_zitron");
const offset_encoding: zitron.lsp.offsets.Encoding = .@"utf-8";

const error_set = error{
    UnexpectedResponse,
    MissingResult,
    MissingServerInfo,
    ChildProcessFailed,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const server_path = if (args.len > 1) args[1] else "zig-out/bin/lsp_zitron";
    const fixture_text = try zitron.loadFixtureAlloc(allocator);
    defer allocator.free(fixture_text);

    var child = std.process.Child.init(&.{server_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    var read_buffer: [4096]u8 = undefined;
    var transport = zitron.lsp.Transport.Stdio.init(
        &read_buffer,
        child.stdout.?,
        child.stdin.?,
    );

    try transport.transport.writeRequest(
        allocator,
        .{ .number = 1 },
        "initialize",
        zitron.lsp.ParamsType("initialize"),
        .{
            .processId = null,
            .clientInfo = .{ .name = "lsp_zitron_test_client" },
            .capabilities = .{},
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectInitializeResponse(allocator, &transport.transport);

    try transport.transport.writeNotification(
        allocator,
        "initialized",
        zitron.lsp.ParamsType("initialized"),
        .{},
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeNotification(
        allocator,
        "textDocument/didOpen",
        zitron.lsp.ParamsType("textDocument/didOpen"),
        .{
            .textDocument = .{
                .uri = "file:///samples/calc.zy",
                .languageId = "zitron",
                .version = 1,
                .text = fixture_text,
            },
        },
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeNotification(
        allocator,
        "textDocument/didChange",
        zitron.lsp.ParamsType("textDocument/didChange"),
        .{
            .textDocument = .{
                .uri = "file:///samples/calc.zy",
                .version = 2,
            },
            .contentChanges = &.{
                .{ .literal_1 = .{ .text = fixture_text } },
            },
        },
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeRequest(
        allocator,
        .{ .number = 3 },
        "textDocument/hover",
        zitron.lsp.ParamsType("textDocument/hover"),
        .{
            .textDocument = .{ .uri = "file:///samples/calc.zy" },
            .position = try positionOfText(fixture_text, "calc ::= expr"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectHoverResponse(allocator, &transport.transport);

    const calc_rule_index = try byteIndexOf(fixture_text, "calc ::= expr");

    try transport.transport.writeRequest(
        allocator,
        .{ .number = 4 },
        "textDocument/definition",
        zitron.lsp.ParamsType("textDocument/definition"),
        .{
            .textDocument = .{ .uri = "file:///samples/calc.zy" },
            .position = try positionOfTextAfter(fixture_text, calc_rule_index + 1, "expr"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectDefinitionResponse(allocator, &transport.transport);

    try transport.transport.writeRequest(
        allocator,
        .{ .number = 5 },
        "textDocument/hover",
        zitron.lsp.ParamsType("textDocument/hover"),
        .{
            .textDocument = .{ .uri = "file:///samples/calc.zy" },
            .position = try positionOfText(fixture_text, "answer = A"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectNullResponse(allocator, &transport.transport, 5);

    try transport.transport.writeNotification(
        allocator,
        "textDocument/didClose",
        zitron.lsp.ParamsType("textDocument/didClose"),
        .{
            .textDocument = .{ .uri = "file:///samples/calc.zy" },
        },
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeRequest(
        allocator,
        .{ .number = 2 },
        "shutdown",
        zitron.lsp.ParamsType("shutdown"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    try expectShutdownResponse(allocator, &transport.transport);

    try transport.transport.writeNotification(
        allocator,
        "exit",
        zitron.lsp.ParamsType("exit"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    child.stdin.?.close();
    child.stdin = null;

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

fn expectInitializeResponse(
    allocator: std.mem.Allocator,
    transport: *zitron.lsp.Transport,
) !void {
    const json_message = try transport.readJsonMessage(allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(zitron.lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const initialize_result = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 1 })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| break :blk maybe_result orelse return error_set.MissingResult,
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    };

    const result = try std.json.parseFromValue(zitron.types.InitializeResult, allocator, initialize_result, .{
        .ignore_unknown_fields = true,
    });
    defer result.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{s} {s}\n", .{
        (result.value.serverInfo orelse return error_set.MissingServerInfo).name,
        json_message,
    });
}

fn expectHoverResponse(
    allocator: std.mem.Allocator,
    transport: *zitron.lsp.Transport,
) !void {
    const json_message = try transport.readJsonMessage(allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(zitron.lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const hover_value = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 3 })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| break :blk maybe_result orelse return error_set.MissingResult,
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    };

    const hover = try std.json.parseFromValue(zitron.types.Hover, allocator, hover_value, .{
        .ignore_unknown_fields = true,
    });
    defer hover.deinit();

    switch (hover.value.contents) {
        .MarkupContent => |content| {
            try std.testing.expect(std.mem.indexOf(u8, content.value, "rule definition `calc`") != null);
            try std.testing.expect(std.mem.indexOf(u8, content.value, "definition.class") != null);
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectDefinitionResponse(
    allocator: std.mem.Allocator,
    transport: *zitron.lsp.Transport,
) !void {
    const json_message = try transport.readJsonMessage(allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(zitron.lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const definition_value = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 4 })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| break :blk maybe_result orelse return error_set.MissingResult,
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    };

    const definition = try std.json.parseFromValue(
        zitron.lsp.ResultType("textDocument/definition"),
        allocator,
        definition_value,
        .{ .ignore_unknown_fields = true },
    );
    defer definition.deinit();

    const resolved = definition.value orelse return error_set.UnexpectedResponse;
    switch (resolved) {
        .Definition => |target| switch (target) {
            .Location => |location| {
                try std.testing.expectEqualStrings("file:///samples/calc.zy", location.uri);
                try std.testing.expectEqual(@as(u32, 48), location.range.start.line);
                try std.testing.expectEqual(@as(u32, 0), location.range.start.character);
            },
            else => return error_set.UnexpectedResponse,
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectNullResponse(
    allocator: std.mem.Allocator,
    transport: *zitron.lsp.Transport,
    id: i64,
) !void {
    const json_message = try transport.readJsonMessage(allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(zitron.lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    switch (parsed.value) {
        .response => |response| {
            if (response.id == null or !response.id.?.eql(.{ .number = id })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| {
                    if (maybe_result) |result| {
                        if (result != .null) return error_set.UnexpectedResponse;
                    }
                },
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectShutdownResponse(
    allocator: std.mem.Allocator,
    transport: *zitron.lsp.Transport,
) !void {
    const json_message = try transport.readJsonMessage(allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(zitron.lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    switch (parsed.value) {
        .response => |response| {
            if (response.id == null or !response.id.?.eql(.{ .number = 2 })) {
                return error_set.UnexpectedResponse;
            }
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn byteIndexOf(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse error.NeedleNotFound;
}

fn byteIndexOfAfter(haystack: []const u8, start_index: usize, needle: []const u8) !usize {
    const relative = std.mem.indexOf(u8, haystack[start_index..], needle) orelse return error.NeedleNotFound;
    return start_index + relative;
}

fn positionOfText(haystack: []const u8, needle: []const u8) !zitron.types.Position {
    const index = try byteIndexOf(haystack, needle);
    return zitron.lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}

fn positionOfTextAfter(haystack: []const u8, start_index: usize, needle: []const u8) !zitron.types.Position {
    const index = try byteIndexOfAfter(haystack, start_index, needle);
    return zitron.lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}
