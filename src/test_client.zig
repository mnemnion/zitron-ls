//! Tiny subprocess client for the lsp-kit-backed smoke server.
const error_set = error{
    UnexpectedResponse,
    MissingResult,
    MissingServerInfo,
    ChildProcessFailed,
};
const Error = error_set ||
    zitron.FixtureError ||
    std.process.SpawnError ||
    std.process.Args.Iterator.InitError ||
    std.process.Child.WaitError ||
    lsp.Transport.ReadError ||
    lsp.Transport.WriteError ||
    JsonParseError ||
    OOM ||
    error{
        NeedleNotFound,
        Overflow,
        TestExpectedEqual,
        TestUnexpectedResult,
    };

/// Runs the end-to-end stdio smoke client against the built server binary.
pub fn main(init: std.process.Init) Error!void {
    const allocator = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.skip();
    const server_path = args.next() orelse "zig-out/bin/lsp_zitron";
    const fixture_text = try zitron.loadFixtureAlloc(init.io, allocator);
    defer allocator.free(fixture_text);
    const fixture_end_position = lsp.offsets.indexToPosition(fixture_text, fixture_text.len, offset_encoding);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{server_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(init.io);

    var read_buffer: [4096]u8 = undefined;
    var transport = lsp.Transport.Stdio.init(
        &read_buffer,
        child.stdout.?,
        child.stdin.?,
    );

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 1 },
        "initialize",
        lsp.ParamsType("initialize"),
        .{
            .processId = null,
            .clientInfo = .{ .name = "lsp_zitron_test_client" },
            .capabilities = .{
                .general = .{
                    .positionEncodings = &.{ .@"utf-8", .@"utf-16" },
                },
            },
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectInitializeResponse(init.io, allocator, &transport.transport);

    try transport.transport.writeNotification(
        init.io,
        allocator,
        "initialized",
        lsp.ParamsType("initialized"),
        .{},
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeNotification(
        init.io,
        allocator,
        "textDocument/didOpen",
        lsp.ParamsType("textDocument/didOpen"),
        .{
            .textDocument = .{
                .uri = fixture_uri,
                .languageId = .{ .custom_value = "zitron" },
                .version = 1,
                .text = fixture_text,
            },
        },
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeNotification(
        init.io,
        allocator,
        "textDocument/didChange",
        lsp.ParamsType("textDocument/didChange"),
        .{
            .textDocument = .{
                .uri = fixture_uri,
                .version = 2,
            },
            .contentChanges = &.{
                .{ .text_document_content_change_partial = .{
                    .range = .{
                        .start = fixture_end_position,
                        .end = fixture_end_position,
                    },
                    .rangeLength = 0,
                    .text = "\n",
                } },
            },
        },
        .{ .emit_null_optional_fields = false },
    );

    const expect_anchor = try positionOfText(fixture_text, "    try std.testing.expectApproxEqAbs");
    try transport.transport.writeNotification(
        init.io,
        allocator,
        "textDocument/didChange",
        lsp.ParamsType("textDocument/didChange"),
        .{
            .textDocument = .{
                .uri = fixture_uri,
                .version = 3,
            },
            .contentChanges = &.{
                .{ .text_document_content_change_partial = .{
                    .range = .{
                        .start = expect_anchor,
                        .end = expect_anchor,
                    },
                    .rangeLength = 0,
                    .text =
                    \\    const smoke_a = 1;
                    \\    const smoke_b = smoke_a + 1;
                    \\    _ = smoke_b;
                    \\
                    ,
                } },
            },
        },
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 3 },
        "textDocument/hover",
        lsp.ParamsType("textDocument/hover"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfText(fixture_text, "calc ::= expr"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectHoverResponse(init.io, allocator, &transport.transport);

    const calc_rule_index = try byteIndexOf(fixture_text, "calc ::= expr");

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 4 },
        "textDocument/definition",
        lsp.ParamsType("textDocument/definition"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfTextAfter(fixture_text, calc_rule_index + 1, "expr"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectDefinitionResponse(init.io, allocator, &transport.transport);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 5 },
        "textDocument/hover",
        lsp.ParamsType("textDocument/hover"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfText(fixture_text, "answer = A"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectAnyResponse(init.io, allocator, &transport.transport, 5);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 6 },
        "textDocument/references",
        lsp.ParamsType("textDocument/references"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfTextAfter(fixture_text, calc_rule_index + 1, "expr"),
            .context = .{ .includeDeclaration = false },
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectReferencesResponse(init.io, allocator, &transport.transport);

    const token_type_anchor = try byteIndexOf(fixture_text, "%token_type");
    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 7 },
        "textDocument/completion",
        lsp.ParamsType("textDocument/completion"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = lsp.offsets.indexToPosition(fixture_text, token_type_anchor + 2, offset_encoding),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectCompletionResponse(init.io, allocator, &transport.transport);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 8 },
        "textDocument/documentSymbol",
        lsp.ParamsType("textDocument/documentSymbol"),
        .{
            .textDocument = .{ .uri = fixture_uri },
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectDocumentSymbolsResponse(init.io, allocator, &transport.transport);

    try transport.transport.writeNotification(
        init.io,
        allocator,
        "textDocument/didClose",
        lsp.ParamsType("textDocument/didClose"),
        .{
            .textDocument = .{ .uri = fixture_uri },
        },
        .{ .emit_null_optional_fields = false },
    );

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 2 },
        "shutdown",
        lsp.ParamsType("shutdown"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    try expectShutdownResponse(init.io, allocator, &transport.transport);

    try transport.transport.writeNotification(
        init.io,
        allocator,
        "exit",
        lsp.ParamsType("exit"),
        {},
        .{ .emit_null_optional_fields = false },
    );
    child.stdin.?.close(init.io);
    child.stdin = null;

    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

fn expectInitializeResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
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

    const result = try std.json.parseFromValue(lsp.types.flat.InitializeResult, allocator, initialize_result, .{
        .ignore_unknown_fields = true,
    });
    defer result.deinit();

    try expectEqual(lsp.types.flat.PositionEncodingKind.@"utf-8", result.value.capabilities.positionEncoding.?);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout.interface.print("{s} {s}\n", .{
        (result.value.serverInfo orelse return error_set.MissingServerInfo).name,
        json_message,
    }) catch |err| switch (err) {
        error.WriteFailed => return stdout.err.?,
    };
    try stdout.flush();
}

fn expectHoverResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
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

    const hover = try std.json.parseFromValue(lsp.types.Hover, allocator, hover_value, .{
        .ignore_unknown_fields = true,
    });
    defer hover.deinit();

    switch (hover.value.contents) {
        .markup_content => |content| {
            try expect(std.mem.indexOf(u8, content.value, "rule definition `calc`") != null);
            try expect(std.mem.indexOf(u8, content.value, "definition.class") != null);
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectDefinitionResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
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
        lsp.ResultType("textDocument/definition"),
        allocator,
        definition_value,
        .{ .ignore_unknown_fields = true },
    );
    defer definition.deinit();

    const resolved = definition.value orelse return error_set.UnexpectedResponse;
    switch (resolved) {
        .definition => |target| switch (target) {
            .location => |location| {
                try expectEqualStrings(fixture_uri, location.uri);
                try expectEqual(@as(u32, 48), location.range.start.line);
                try expectEqual(@as(u32, 0), location.range.start.character);
            },
            else => return error_set.UnexpectedResponse,
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectNullResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    id: i64,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
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

fn expectAnyResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    id: i64,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    switch (parsed.value) {
        .response => |response| {
            if (response.id == null or !response.id.?.eql(.{ .number = id })) {
                return error_set.UnexpectedResponse;
            }
            _ = response.result_or_error;
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectReferencesResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const references_value = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 6 })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| break :blk maybe_result orelse return error_set.MissingResult,
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    };

    const references = try std.json.parseFromValue(
        lsp.ResultType("textDocument/references"),
        allocator,
        references_value,
        .{ .ignore_unknown_fields = true },
    );
    defer references.deinit();

    const resolved = references.value orelse return error_set.UnexpectedResponse;
    try expectEqual(@as(usize, 4), resolved.len);
    for (resolved) |location| {
        try expectEqualStrings(fixture_uri, location.uri);
    }
}

fn expectCompletionResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const completion_value = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 7 })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| break :blk maybe_result orelse return error_set.MissingResult,
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    };

    const completion = try std.json.parseFromValue(
        lsp.ResultType("textDocument/completion"),
        allocator,
        completion_value,
        .{ .ignore_unknown_fields = true },
    );
    defer completion.deinit();

    const resolved = completion.value orelse return error_set.UnexpectedResponse;
    const items = switch (resolved) {
        .completion_items => |items| items,
        .completion_list => |list| list.items,
    };

    try expect(items.len >= 2);
    try expect(hasCompletionLabel(items, "%token_type"));
    try expect(hasCompletionLabel(items, "%type"));
    try expect(!hasCompletionLabel(items, "%ifdef"));
}

fn expectDocumentSymbolsResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const symbols_value = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 8 })) {
                return error_set.UnexpectedResponse;
            }
            switch (response.result_or_error) {
                .result => |maybe_result| break :blk maybe_result orelse return error_set.MissingResult,
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    };

    const symbols_result = try std.json.parseFromValue(
        lsp.ResultType("textDocument/documentSymbol"),
        allocator,
        symbols_value,
        .{ .ignore_unknown_fields = true },
    );
    defer symbols_result.deinit();

    const resolved = symbols_result.value orelse return error_set.UnexpectedResponse;
    const symbols = switch (resolved) {
        .document_symbols => |items| items,
        .symbol_informations => return error_set.UnexpectedResponse,
    };

    try expect(hasDocumentSymbol(symbols, "calc", .Class));
    try expect(hasDocumentSymbol(symbols, "expr", .Class));
}

fn expectShutdownResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try transport.readJsonMessage(io, allocator);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
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

fn byteIndexOf(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!usize {
    return std.mem.indexOf(u8, haystack, needle) orelse error.NeedleNotFound;
}

fn byteIndexOfAfter(haystack: []const u8, start_index: usize, needle: []const u8) error{NeedleNotFound}!usize {
    const relative = std.mem.indexOf(u8, haystack[start_index..], needle) orelse return error.NeedleNotFound;
    return start_index + relative;
}

fn positionOfText(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!lsp.types.flat.Position {
    const index = try byteIndexOf(haystack, needle);
    return lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}

fn positionOfTextAfter(haystack: []const u8, start_index: usize, needle: []const u8) error{NeedleNotFound}!lsp.types.flat.Position {
    const index = try byteIndexOfAfter(haystack, start_index, needle);
    return lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}

fn hasCompletionLabel(items: []const lsp.types.flat.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

fn hasDocumentSymbol(
    items: []const lsp.types.flat.DocumentSymbol,
    name: []const u8,
    kind: lsp.types.flat.SymbolKind,
) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name) and item.kind == kind) return true;
        if (item.children) |children| {
            if (hasDocumentSymbol(children, name, kind)) return true;
        }
    }
    return false;
}

const std = @import("std");
const JsonParseError = std.json.ParseFromValueError || error{
    BufferUnderrun,
    SyntaxError,
    UnexpectedEndOfInput,
    ValueTooLong,
};
const OOM = std.mem.Allocator.Error;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const lsp = @import("lsp");
const zitron = @import("lsp_zitron");
const offset_encoding: lsp.offsets.Encoding = .@"utf-8";
const fixture_uri = "file:///Users/atman/Dropbox/deck/z/lsp_zitron/samples/calc.zy";
