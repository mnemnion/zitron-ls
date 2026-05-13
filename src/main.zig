//! Main executable of lsp_zitron.

pub fn main(init: std.process.Init) Error!void {
    var server = try zitron.Server.initProduction(init.io, init.gpa);
    defer server.deinit();

    var read_buffer: [4096]u8 = undefined;
    var transport = lsp.Transport.Stdio.init(
        &read_buffer,
        std.Io.File.stdin(),
        std.Io.File.stdout(),
    );

    try lsp.basic_server.run(
        init.io,
        init.gpa,
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
const Error = zitron.Server.Error || lsp.Transport.ReadError || lsp.Transport.WriteError;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const lsp = @import("lsp");
const zitron = @import("lsp_zitron");
