//! Shared helpers for the lsp_zitron smoke-test server and client.
const std = @import("std");

pub const ServerInfo = struct {
    name: []const u8 = "lsp_zitron",
    version: []const u8 = "0.0.1",
};

pub const LspError = error{
    MissingContentLength,
    InvalidContentLength,
    InvalidRequestId,
};

pub fn readMessageAlloc(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var reader = file.deprecatedReader();
    var content_length: ?usize = null;

    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024);
        const line = maybe_line orelse return error.EndOfStream;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) break;

        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch {
                return LspError.InvalidContentLength;
            };
        }
    }

    const body_len = content_length orelse return LspError.MissingContentLength;
    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);
    try reader.readNoEof(body);
    return body;
}

pub fn writeMessage(file: std.fs.File, json_payload: []const u8) !void {
    var writer = file.deprecatedWriter();
    try writer.print("Content-Length: {d}\r\n\r\n", .{json_payload.len});
    try writer.writeAll(json_payload);
}

pub fn parseRequestId(json_payload: []const u8) !i64 {
    const id_key_index = std.mem.indexOf(u8, json_payload, "\"id\"") orelse return LspError.InvalidRequestId;
    const colon_index = std.mem.indexOfScalarPos(u8, json_payload, id_key_index, ':') orelse return LspError.InvalidRequestId;
    const trimmed = std.mem.trimLeft(u8, json_payload[colon_index + 1 ..], " \t\r\n");
    if (trimmed.len == 0) return LspError.InvalidRequestId;

    var end_index: usize = 0;
    if (trimmed[0] == '-') end_index = 1;
    while (end_index < trimmed.len and std.ascii.isDigit(trimmed[end_index])) : (end_index += 1) {}

    if (end_index == 0 or (end_index == 1 and trimmed[0] == '-')) {
        return LspError.InvalidRequestId;
    }

    return std.fmt.parseInt(i64, trimmed[0..end_index], 10);
}

pub fn buildInitializeResponseAlloc(allocator: std.mem.Allocator, request_id: i64) ![]u8 {
    const server_info = ServerInfo{};
    return std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"capabilities":{{"textDocumentSync":1,"hoverProvider":false,"definitionProvider":false}},"serverInfo":{{"name":"{s}","version":"{s}"}}}}}}
    ,
        .{ request_id, server_info.name, server_info.version },
    );
}

test "round-trips an initialize response" {
    const allocator = std.testing.allocator;
    const response = try buildInitializeResponseAlloc(allocator, 7);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"serverInfo\"") != null);
}

test "parses integer request ids" {
    try std.testing.expectEqual(@as(i64, 42), try parseRequestId(
        \\{"jsonrpc":"2.0","id":42,"method":"initialize"}
    ));
}
