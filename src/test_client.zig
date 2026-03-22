//! Tiny subprocess client for the smoke-test server.
const std = @import("std");
const module = @import("lsp_zitron");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const server_path = if (args.len > 1) args[1] else "zig-out/bin/lsp_zitron";
    const initialize_payload =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"lsp_zitron_test_client"}}}
    ;

    var child = std.process.Child.init(&.{server_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    try module.writeMessage(child.stdin.?, initialize_payload);
    child.stdin.?.close();
    child.stdin = null;

    const response = try module.readMessageAlloc(allocator, child.stdout.?);
    defer allocator.free(response);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{s}\n", .{response});

    try std.testing.expectEqual(@as(i64, 1), try module.parseRequestId(response));
    try std.testing.expect(std.mem.indexOf(u8, response, "\"capabilities\"") != null);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}
