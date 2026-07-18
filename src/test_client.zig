//! Tiny subprocess client for the lsp-kit-backed smoke server.
const error_set = error{
    UnexpectedResponse,
    MissingResult,
    MissingServerInfo,
    ChildProcessFailed,
    MissingWorkDoneProgress,
    MissingSemanticTokensRefresh,
};
const Error = error_set ||
    zitron.FixtureError ||
    std.process.SpawnError ||
    std.process.Args.Iterator.InitError ||
    std.process.Child.WaitError ||
    lsp.Transport.ReadError ||
    lsp.Transport.WriteError ||
    JsonParseError ||
    std.Io.Dir.RealPathFileAllocError ||
    OOM ||
    error{
        NeedleNotFound,
        Overflow,
        TestExpectedEqual,
        TestUnexpectedResult,
    };

var saw_work_done_progress_create = false;
var saw_progress_begin = false;
var saw_progress_end = false;
var saw_semantic_tokens_refresh = false;

/// Runs the end-to-end stdio smoke client against the built server binary.
pub fn main(init: std.process.Init) Error!void {
    const allocator = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.skip();
    const server_path = args.next() orelse "zig-out/bin/lsp_zitron";
    const fixture_text = try zitron.loadSmokeFixtureAlloc(init.io, allocator);
    defer allocator.free(fixture_text);
    const fixture_uri = try fixtureUriAlloc(init.io, allocator);
    defer allocator.free(fixture_uri);

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
                .workspace = .{
                    .semanticTokens = .{ .refreshSupport = true },
                },
                .window = .{
                    .workDoneProgress = true,
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

    const overlap_insert_position = try positionAfterText(fixture_text, "%code {\n");
    const overlap_edits = [_][]const u8{
        "const smoke_overlap_00 = 0;\n",
        "const smoke_overlap_01 = smoke_overlap_00 + 1;\n",
        "const smoke_overlap_02 = smoke_overlap_01 + 1;\n",
        "const smoke_overlap_03 = smoke_overlap_02 + 1;\n",
        "const smoke_overlap_04 = smoke_overlap_03 + 1;\n",
        "const smoke_overlap_05 = smoke_overlap_04 + 1;\n",
        "const smoke_overlap_06 = smoke_overlap_05 + 1;\n",
        "const smoke_overlap_07 = smoke_overlap_06 + 1;\n",
        "const smoke_overlap_08 = smoke_overlap_07 + 1;\n",
        "const smoke_overlap_09 = smoke_overlap_08 + 1;\n",
        "const smoke_overlap_10 = smoke_overlap_09 + 1;\n",
        "const smoke_overlap_11 = smoke_overlap_10 + 1;\n",
        "const smoke_overlap_12 = smoke_overlap_11 + 1;\n",
        "const smoke_overlap_13 = smoke_overlap_12 + 1;\n",
        "const smoke_overlap_14 = smoke_overlap_13 + 1;\n",
        "const smoke_overlap_15 = smoke_overlap_14 + 1;\n",
    };
    for (overlap_edits, 2..) |edit_text, version| {
        try transport.transport.writeNotification(
            init.io,
            allocator,
            "textDocument/didChange",
            lsp.ParamsType("textDocument/didChange"),
            .{
                .textDocument = .{
                    .uri = fixture_uri,
                    .version = @intCast(version),
                },
                .contentChanges = &.{
                    .{ .text_document_content_change_partial = .{
                        .range = .{
                            .start = overlap_insert_position,
                            .end = overlap_insert_position,
                        },
                        .rangeLength = 0,
                        .text = edit_text,
                    } },
                },
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 3 },
        "textDocument/hover",
        lsp.ParamsType("textDocument/hover"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfText(fixture_text, "document ::= statement_list"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectHoverResponse(init.io, allocator, &transport.transport);

    const document_rule_index = try byteIndexOf(fixture_text, "document ::= statement_list");

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 4 },
        "textDocument/definition",
        lsp.ParamsType("textDocument/definition"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfTextAfter(fixture_text, document_rule_index + "document ::= ".len, "statement_list"),
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectDefinitionResponse(init.io, allocator, &transport.transport, fixture_uri);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 5 },
        "textDocument/hover",
        lsp.ParamsType("textDocument/hover"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = try positionOfText(fixture_text, "Pik.init"),
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
            .position = try positionOfTextAfter(fixture_text, document_rule_index + "document ::= ".len, "statement_list"),
            .context = .{ .includeDeclaration = false },
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectReferencesResponse(init.io, allocator, &transport.transport, fixture_uri);

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

    const pik_init_position = try positionOfText(fixture_text, "Pik.init");
    const pik_init_call_position = try positionAfterText(fixture_text, "Pik.init(");
    const pik_member_position = try positionAfterText(fixture_text, "Pik.");
    const full_range = lsp.types.flat.Range{
        .start = lsp.types.flat.Position{ .line = 0, .character = 0 },
        .end = lsp.offsets.indexToPosition(fixture_text, fixture_text.len, offset_encoding),
    };

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 9 },
        "textDocument/completion",
        lsp.ParamsType("textDocument/completion"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_member_position,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 9);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 10 },
        "textDocument/signatureHelp",
        lsp.ParamsType("textDocument/signatureHelp"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_init_call_position,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 10);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 11 },
        "textDocument/declaration",
        lsp.ParamsType("textDocument/declaration"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_init_position,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 11);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 12 },
        "textDocument/definition",
        lsp.ParamsType("textDocument/definition"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_init_position,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 12);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 13 },
        "textDocument/references",
        lsp.ParamsType("textDocument/references"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_init_position,
            .context = .{ .includeDeclaration = false },
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 13);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 14 },
        "textDocument/documentHighlight",
        lsp.ParamsType("textDocument/documentHighlight"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_init_position,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 14);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 15 },
        "textDocument/inlayHint",
        lsp.ParamsType("textDocument/inlayHint"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .range = full_range,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 15);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 16 },
        "textDocument/semanticTokens/full",
        lsp.ParamsType("textDocument/semanticTokens/full"),
        .{
            .textDocument = .{ .uri = fixture_uri },
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 16);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 17 },
        "textDocument/semanticTokens/range",
        lsp.ParamsType("textDocument/semanticTokens/range"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .range = full_range,
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 17);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 18 },
        "textDocument/semanticTokens/full/delta",
        lsp.ParamsType("textDocument/semanticTokens/full/delta"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .previousResultId = "smoke-missing-previous-result",
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 18);

    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 19 },
        "textDocument/rename",
        lsp.ParamsType("textDocument/rename"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = pik_init_position,
            .newName = "smokeRenamed",
        },
        .{ .emit_null_optional_fields = false },
    );
    try expectSuccessfulResponse(init.io, allocator, &transport.transport, 19);

    const slash_grammar_position = try positionOfText(fixture_text, "STAR SLASH PERCENT");
    try transport.transport.writeRequest(
        init.io,
        allocator,
        .{ .number = 20 },
        "textDocument/references",
        lsp.ParamsType("textDocument/references"),
        .{
            .textDocument = .{ .uri = fixture_uri },
            .position = .{
                .line = slash_grammar_position.line,
                .character = slash_grammar_position.character + @as(u32, "STAR ".len),
            },
            .context = .{ .includeDeclaration = false },
        },
        .{ .emit_null_optional_fields = false },
    );
    const slash_code_index = try byteIndexOf(fixture_text, "TokenKind.SLASH");
    var slash_code_position = try positionOfTextAfter(fixture_text, slash_code_index, "SLASH");
    slash_code_position.line += overlap_edits.len;
    try expectTerminalReferencesResponse(
        init.io,
        allocator,
        &transport.transport,
        fixture_uri,
        slash_code_position,
    );

    if (!saw_work_done_progress_create or !saw_progress_begin or !saw_progress_end) {
        return error_set.MissingWorkDoneProgress;
    }
    if (!saw_semantic_tokens_refresh) {
        return error_set.MissingSemanticTokensRefresh;
    }

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
    const json_message = try readResponseJsonMessage(io, allocator, transport, 1);
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
    const json_message = try readResponseJsonMessage(io, allocator, transport, 3);
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
            try expect(std.mem.indexOf(u8, content.value, "rule definition `document`") != null);
            try expect(std.mem.indexOf(u8, content.value, "definition.class") != null);
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectDefinitionResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    fixture_uri: []const u8,
) Error!void {
    const json_message = try readResponseJsonMessage(io, allocator, transport, 4);
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
                try expect(location.range.start.line > 0);
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
    const json_message = try readResponseJsonMessage(io, allocator, transport, id);
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
    const json_message = try readResponseJsonMessage(io, allocator, transport, id);
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

fn expectSuccessfulResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    id: i64,
) Error!void {
    const json_message = try readResponseJsonMessage(io, allocator, transport, id);
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
                .result => {},
                .@"error" => return error_set.UnexpectedResponse,
            }
        },
        else => return error_set.UnexpectedResponse,
    }
}

fn expectReferencesResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    fixture_uri: []const u8,
) Error!void {
    const json_message = try readResponseJsonMessage(io, allocator, transport, 6);
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
    try expect(resolved.len > 0);
    for (resolved) |location| {
        try expectEqualStrings(fixture_uri, location.uri);
    }
}

fn expectTerminalReferencesResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    fixture_uri: []const u8,
    zig_use_position: lsp.types.Position,
) Error!void {
    const json_message = try readResponseJsonMessage(io, allocator, transport, 20);
    defer allocator.free(json_message);

    const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const references_value = switch (parsed.value) {
        .response => |response| blk: {
            if (response.id == null or !response.id.?.eql(.{ .number = 20 })) {
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
    var found_zig_use = false;
    for (resolved) |location| {
        try expectEqualStrings(fixture_uri, location.uri);
        found_zig_use = found_zig_use or std.meta.eql(location.range.start, zig_use_position);
    }
    try expect(found_zig_use);
}

fn expectCompletionResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try readResponseJsonMessage(io, allocator, transport, 7);
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
    const json_message = try readResponseJsonMessage(io, allocator, transport, 8);
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

    try expect(hasDocumentSymbol(symbols, "document", .Class));
    try expect(hasDocumentSymbol(symbols, "statement_list", .Class));
}

fn expectShutdownResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
) Error!void {
    const json_message = try readResponseJsonMessage(io, allocator, transport, 2);
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

fn readResponseJsonMessage(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    id: i64,
) Error![]u8 {
    while (true) {
        const json_message = try transport.readJsonMessage(io, allocator);
        errdefer allocator.free(json_message);

        const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, json_message, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        switch (parsed.value) {
            .response => |response| {
                if (response.id == null or !response.id.?.eql(.{ .number = id })) {
                    return error_set.UnexpectedResponse;
                }
                return json_message;
            },
            .notification => {
                try observeServerNotification(parsed.value.notification);
                allocator.free(json_message);
                continue;
            },
            .request => {
                try answerServerRequest(io, allocator, transport, parsed.value.request);
                allocator.free(json_message);
                continue;
            },
        }
    }
}

fn observeServerNotification(notification: lsp.JsonRPCMessage.Notification) Error!void {
    if (!std.mem.eql(u8, notification.method, "$/progress")) return;
    const params = notification.params orelse return error_set.UnexpectedResponse;
    const params_object = switch (params) {
        .object => |object| object,
        else => return error_set.UnexpectedResponse,
    };
    const value = params_object.get("value") orelse return error_set.UnexpectedResponse;
    const value_object = switch (value) {
        .object => |object| object,
        else => return error_set.UnexpectedResponse,
    };
    const kind = switch (value_object.get("kind") orelse return error_set.UnexpectedResponse) {
        .string => |kind| kind,
        else => return error_set.UnexpectedResponse,
    };
    if (std.mem.eql(u8, kind, "begin")) {
        saw_progress_begin = true;
    } else if (std.mem.eql(u8, kind, "end")) {
        saw_progress_end = true;
    }
}

fn answerServerRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    request: lsp.JsonRPCMessage.Request,
) Error!void {
    if (std.mem.eql(u8, request.method, "window/workDoneProgress/create")) {
        saw_work_done_progress_create = true;
    } else if (std.mem.eql(u8, request.method, "workspace/semanticTokens/refresh")) {
        saw_semantic_tokens_refresh = true;
    } else {
        return error_set.UnexpectedResponse;
    }

    try transport.writeResponse(
        io,
        allocator,
        request.id,
        ?void,
        null,
        .{ .emit_null_optional_fields = false },
    );
}

fn byteIndexOf(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!usize {
    return std.mem.indexOf(u8, haystack, needle) orelse error.NeedleNotFound;
}

fn byteIndexOfAfter(haystack: []const u8, start_index: usize, needle: []const u8) error{NeedleNotFound}!usize {
    const relative = std.mem.indexOf(u8, haystack[start_index..], needle) orelse return error.NeedleNotFound;
    return start_index + relative;
}

fn fixtureUriAlloc(io: std.Io, allocator: std.mem.Allocator) (std.Io.Dir.RealPathFileAllocError || OOM)![]u8 {
    const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(io, zitron.smokeFixturePath(), allocator);
    defer allocator.free(absolute_path);
    return std.mem.concat(allocator, u8, &.{ "file://", absolute_path });
}

fn positionOfText(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!lsp.types.flat.Position {
    const index = try byteIndexOf(haystack, needle);
    return lsp.offsets.indexToPosition(haystack, index, offset_encoding);
}

fn positionAfterText(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!lsp.types.flat.Position {
    const index = try byteIndexOf(haystack, needle);
    return lsp.offsets.indexToPosition(haystack, index + needle.len, offset_encoding);
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
