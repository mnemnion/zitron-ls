//! Zig middleware for generated Zitron parser code.

allocator: std.mem.Allocator,
io: std.Io,
zls_child: std.process.Child,
zls_transport: lsp.Transport.Stdio,
zls_read_buffer: []u8,
documents: std.StringHashMapUnmanaged(GeneratedDocument),
next_request_id: i64,

const ZigMiddleware = @This();

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

pub fn init(io: std.Io, allocator: std.mem.Allocator) Error!ZigMiddleware {
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

    var middleware: ZigMiddleware = .{
        .allocator = allocator,
        .io = io,
        .zls_child = child,
        .zls_transport = lsp.Transport.Stdio.init(read_buffer, child.stdout.?, child.stdin.?),
        .zls_read_buffer = read_buffer,
        .documents = .empty,
        .next_request_id = 1,
    };
    errdefer middleware.deinit();

    try middleware.initializeZls();
    return middleware;
}

pub fn deinit(middleware: *ZigMiddleware) void {
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

pub fn syncDocument(
    middleware: *ZigMiddleware,
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

    var line_map = try LineMap.parse(middleware.allocator, generated.stdout, doc.source_path);
    errdefer line_map.deinit(middleware.allocator);

    if (doc.opened) {
        var text_edits = try diff.edits(middleware.allocator, doc.generated_text, generated.stdout, .@"utf-8");
        defer diff.deinitTextEdits(middleware.allocator, &text_edits);

        const content_changes = try textEditsToContentChanges(middleware.allocator, text_edits.items);
        defer middleware.allocator.free(content_changes);

        try middleware.zls_transport.transport.writeNotification(
            middleware.io,
            middleware.allocator,
            "textDocument/didChange",
            lsp.ParamsType("textDocument/didChange"),
            .{
                .textDocument = .{ .uri = doc.generated_uri, .version = version },
                .contentChanges = content_changes,
            },
            .{ .emit_null_optional_fields = false },
        );
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
    if (doc.line_map) |*old_map| old_map.deinit(middleware.allocator);
    doc.generated_text = generated.stdout;
    doc.line_map = line_map;
}

pub fn closeDocument(middleware: *ZigMiddleware, uri: []const u8) void {
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

pub fn forwardHover(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.HoverParams,
) Error!?types.Hover {
    const doc = try middleware.documentReady(source_uri);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = doc.line_map.?.sourcePositionToGenerated(params.position) orelse return null;

    var result = try middleware.request(arena, "textDocument/hover", mapped);
    if (result) |*hover_result| translateHover(hover_result, doc.line_map.?);
    return result;
}

pub fn forwardDefinition(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.DefinitionParams,
) Error!lsp.ResultType("textDocument/definition") {
    const doc = try middleware.documentReady(source_uri);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = doc.line_map.?.sourcePositionToGenerated(params.position) orelse return null;

    const result = (try middleware.request(arena, "textDocument/definition", mapped)) orelse return null;
    return try translateDefinition(arena, result, doc.line_map.?, doc.generated_uri, doc.source_uri);
}

pub fn forwardReferences(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.ReferenceParams,
) Error!lsp.ResultType("textDocument/references") {
    const doc = try middleware.documentReady(source_uri);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = doc.line_map.?.sourcePositionToGenerated(params.position) orelse return null;

    const result = (try middleware.request(arena, "textDocument/references", mapped)) orelse return null;
    return try translateLocations(arena, result, doc.line_map.?, doc.generated_uri, doc.source_uri);
}

pub fn forwardCompletion(
    middleware: *ZigMiddleware,
    arena: std.mem.Allocator,
    source_uri: []const u8,
    params: types.CompletionParams,
) Error!lsp.ResultType("textDocument/completion") {
    const doc = try middleware.documentReady(source_uri);
    var mapped = params;
    mapped.textDocument = .{ .uri = doc.generated_uri };
    mapped.position = doc.line_map.?.sourcePositionToGenerated(params.position) orelse return null;

    var result = try middleware.request(arena, "textDocument/completion", mapped);
    try translateCompletionResult(arena, &result, doc.line_map.?);
    return result;
}

/// Bidirectional line mapping derived from Zitron `// #line` comments.
pub const LineMap = struct {
    entries: []Entry,

    // TODO: make this less crappy.  O(logₙ), not O(n).  Range map.
    // I don't even understand how this can work, how are we mapping a line
    // which is inside of a range?  This is sketchy, this doesn't check out.

    const Entry = struct {
        generated_line: u32,
        source_line: u32,
    };

    pub fn parse(allocator: std.mem.Allocator, generated_text: []const u8, source_path: []const u8) OOM!LineMap {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(allocator);

        var generated_line: u32 = 0;
        var active_source_line: ?u32 = null;
        var lines = std.mem.splitScalar(u8, generated_text, '\n');
        while (lines.next()) |line| : (generated_line += 1) {
            if (parseLineDirective(line)) |directive| {
                active_source_line = if (std.mem.eql(u8, directive.path, source_path))
                    directive.line
                else
                    null;
                continue;
            }

            if (active_source_line) |source_line| {
                try entries.append(allocator, .{
                    .generated_line = generated_line,
                    .source_line = source_line,
                });
                active_source_line = source_line + 1;
            }
        }

        return .{ .entries = try entries.toOwnedSlice(allocator) };
    }

    pub fn deinit(map: *LineMap, allocator: std.mem.Allocator) void {
        allocator.free(map.entries);
    }

    pub fn sourcePositionToGenerated(map: LineMap, position: types.Position) ?types.Position {
        for (map.entries) |entry| {
            if (entry.source_line == position.line) {
                return .{
                    .line = entry.generated_line,
                    .character = position.character,
                };
            }
        }

        return null;
    }

    pub fn generatedPositionToSource(map: LineMap, position: types.Position) ?types.Position {
        for (map.entries) |entry| {
            if (entry.generated_line == position.line) {
                return .{
                    .line = entry.source_line,
                    .character = position.character,
                };
            }
        }

        return null;
    }

    pub fn generatedRangeToSource(map: LineMap, range: types.Range) ?types.Range {
        var line = range.start.line;
        while (line <= range.end.line) : (line += 1) {
            if (map.generatedPositionToSource(.{
                .line = line,
                .character = 0,
            }) == null) return null;
        }

        return .{
            .start = map.generatedPositionToSource(range.start).?,
            .end = map.generatedPositionToSource(range.end).?,
        };
    }
};

const LineDirective = struct {
    line: u32,
    path: []const u8,
};

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

fn trimLeft(slice: []const u8, values_to_strip: []const u8) []const u8 {
    var index: usize = 0;
    while (index < slice.len and std.mem.indexOfScalar(u8, values_to_strip, slice[index]) != null) {
        index += 1;
    }
    return slice[index..];
}

pub fn translateHover(hover_result: *types.Hover, map: LineMap) void {
    if (hover_result.range) |range| {
        hover_result.range = map.generatedRangeToSource(range);
    }
}

pub fn translateDefinition(
    arena: std.mem.Allocator,
    definition_result: lsp.types.Definition.Result,
    map: LineMap,
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
    map: LineMap,
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
    map: LineMap,
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
    map: LineMap,
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
    map: LineMap,
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

fn translateLocation(location: types.Location, map: LineMap, generated_uri: []const u8, source_uri: []const u8) ?types.Location {
    if (!std.mem.eql(u8, location.uri, generated_uri)) return location;
    return .{
        .uri = source_uri,
        .range = map.generatedRangeToSource(location.range) orelse return null,
    };
}

fn translateCompletionItems(
    arena: std.mem.Allocator,
    items_const: []const types.CompletionItem,
    map: LineMap,
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

fn translateCompletionTextEdit(text_edit: types.CompletionItem.TextEdit, map: LineMap) ?types.CompletionItem.TextEdit {
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
    map: LineMap,
) ?lsp.types.ClientCapabilities.TextDocument.Completion.EditRange {
    return switch (edit_range) {
        .range => |range| .{ .range = map.generatedRangeToSource(range) orelse return null },
        .edit_range_with_insert_replace => |ranges| .{ .edit_range_with_insert_replace = .{
            .insert = map.generatedRangeToSource(ranges.insert) orelse return null,
            .replace = map.generatedRangeToSource(ranges.replace) orelse return null,
        } },
    };
}

fn translateTextEdit(edit: types.TextEdit, map: LineMap) ?types.TextEdit {
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

fn initializeZls(middleware: *ZigMiddleware) Error!void {
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
            },
        },
        .{ .emit_null_optional_fields = false },
    );
    const initialize_response = try middleware.readResponseForId(middleware.allocator, id);
    middleware.allocator.free(initialize_response);
    try middleware.zls_transport.transport.writeNotification(
        middleware.io,
        middleware.allocator,
        "initialized",
        lsp.ParamsType("initialized"),
        .{},
        .{ .emit_null_optional_fields = false },
    );
}

fn shutdownZls(middleware: *ZigMiddleware) Error!void {
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

fn request(
    middleware: *ZigMiddleware,
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

fn readResponseForId(middleware: *ZigMiddleware, allocator: std.mem.Allocator, id: lsp.JsonRPCMessage.ID) Error![]u8 {
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

fn nextRequestId(middleware: *ZigMiddleware) lsp.JsonRPCMessage.ID {
    const id = middleware.next_request_id;
    middleware.next_request_id += 1;
    return .{ .number = id };
}

fn documentReady(middleware: *ZigMiddleware, source_uri: []const u8) Error!*GeneratedDocument {
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

fn textEditsToContentChanges(
    allocator: std.mem.Allocator,
    text_edits: []const types.TextEdit,
) OOM![]types.TextDocumentContentChangeEvent {
    const content_changes = try allocator.alloc(types.TextDocumentContentChangeEvent, text_edits.len);
    for (text_edits, content_changes) |edit, *change| {
        change.* = .{ .text_document_content_change_partial = .{
            .range = edit.range,
            .text = edit.newText,
        } };
    }
    return content_changes;
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
    translateHover(&hover_result, map);
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
        map,
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

    try translateCompletionResult(arena_state.allocator(), &result, map);
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
