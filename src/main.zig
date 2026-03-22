//! Main executable of lsp_zitron.
const std = @import("std");
const zitron = @import("lsp_zitron");

test "exe mentioned" {
    var server = try zitron.Server.init(std.testing.allocator);
    defer server.deinit();

    const result = server.initialize(std.testing.allocator, .{
        .capabilities = .{},
    });

    try std.testing.expectEqualStrings(zitron.server_name, result.serverInfo.?.name);
}

pub fn main() !void {
    var server = try zitron.Server.init(std.heap.page_allocator);
    defer server.deinit();

    var read_buffer: [4096]u8 = undefined;
    var transport = zitron.lsp.Transport.Stdio.init(
        &read_buffer,
        std.fs.File.stdin(),
        std.fs.File.stdout(),
    );

    try zitron.lsp.basic_server.run(
        std.heap.page_allocator,
        &transport.transport,
        &server,
        std.log.err,
    );
}
