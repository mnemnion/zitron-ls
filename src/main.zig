//! Main executable of lsp_zitron.
const std = @import("std");
const module = @import("lsp_zitron");

test "exe mentioned" {
    const allocator = std.testing.allocator;
    const response = try module.buildInitializeResponseAlloc(allocator, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"jsonrpc\":\"2.0\"") != null);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const request = try module.readMessageAlloc(allocator, std.fs.File.stdin());
    defer allocator.free(request);

    const request_id = try module.parseRequestId(request);
    const response = try module.buildInitializeResponseAlloc(allocator, request_id);
    defer allocator.free(response);

    try module.writeMessage(std.fs.File.stdout(), response);
}
