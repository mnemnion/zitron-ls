//! Main executable of lsp_zitron.

pub fn main() Error!void {
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

test "exe mentioned" {
    var server = try zitron.Server.init(testing_allocator);
    defer server.deinit();

    const result = server.initialize(testing_allocator, .{
        .capabilities = .{},
    });

    try expectEqualStrings(zitron.server_name, result.serverInfo.?.name);
}

const std = @import("std");
const Error = zitron.Error || zitron.lsp.Transport.ReadError || zitron.lsp.Transport.WriteError;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const zitron = @import("lsp_zitron");
