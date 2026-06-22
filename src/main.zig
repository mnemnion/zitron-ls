//! Main executable of lsp_zitron.

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub const panic = std.debug.FullPanic(logging.panic);

pub fn main(init: std.process.Init) Error!void {
    const args = try parseArgs(init.gpa, init.minimal.args);
    defer args.deinit(init.gpa);

    var logging_state = try logging.init(init.io, init.gpa, init.environ_map.*, args.logging);
    defer logging_state.deinit(init.gpa);

    log.info("Starting {s} @ '{s}'", .{ zitron.server_name, args.exe_path });
    if (logging_state.path) |path| {
        log.info("Log File: {s} ({t})", .{ path, logging_state.level });
    } else {
        log.info("Log File: none", .{});
    }
    if (args.panic_smoke_test) @panic("panic-smoke-test");

    var server = try zitron.Server.initProduction(init.io, init.gpa, init.environ_map);
    defer server.deinit();

    var read_buffer: [4096]u8 = undefined;
    var transport = lsp.Transport.Stdio.init(
        &read_buffer,
        std.Io.File.stdin(),
        std.Io.File.stdout(),
    );
    var safe_transport = lsp.ThreadSafeTransport(.{
        .thread_safe_read = false,
        .thread_safe_write = true,
        .MutexType = SpinMutex,
    }).init(&transport.transport);
    server.setClientTransport(&safe_transport.transport);

    try handleServerRunResult(lsp.basic_server.run(
        init.io,
        init.gpa,
        &safe_transport.transport,
        &server,
        log.err,
    ));
}

const SpinMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub const init: SpinMutex = .{};

    pub fn lock(mutex: *SpinMutex, _: std.Io) !void {
        while (mutex.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(mutex: *SpinMutex, _: std.Io) void {
        mutex.locked.store(false, .release);
    }
};

const usage =
    \\lsp_zitron
    \\
    \\Options:
    \\  --log-file [path]       Set path to the lsp_zitron log file
    \\  --log-level [level]     err, warn, info, or debug
    \\  --enable-stderr-logs    Also write logs to stderr
    \\  -h, --help              Print this help and exit
    \\
;

const Args = struct {
    logging: logging.Options = .{},
    exe_path: []const u8 = "",
    panic_smoke_test: bool = false,

    fn deinit(args: Args, allocator: std.mem.Allocator) void {
        if (args.logging.log_file_path) |path| allocator.free(path);
        allocator.free(args.exe_path);
    }
};

fn parseArgs(allocator: std.mem.Allocator, process_args: std.process.Args) !Args {
    var result: Args = .{};
    errdefer result.deinit(allocator);

    var args_it = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args_it.deinit();

    const exe_path = args_it.next() orelse "";
    result.exe_path = try allocator.dupe(u8, exe_path);

    var arg_index: usize = 0;
    while (args_it.next()) |arg| : (arg_index += 1) {
        if ((arg_index == 0 and std.mem.eql(u8, arg, "help")) or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            try std.Io.File.stderr().writeStreamingAll(std.Options.debug_io, usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            const path = args_it.next() orelse {
                std.log.err("Expected log file path after --log-file.", .{});
                std.process.exit(1);
            };
            if (result.logging.log_file_path) |old_path| allocator.free(old_path);
            result.logging.log_file_path = try allocator.dupe(u8, path);
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            const level_name = args_it.next() orelse {
                std.log.err("Expected level after --log-level.", .{});
                std.process.exit(1);
            };
            result.logging.log_level = logging.parseLevel(level_name) orelse {
                std.log.err(
                    "Invalid --log-level argument. Expected one of {{'debug', 'info', 'warn', 'err'}} but got '{s}'.",
                    .{level_name},
                );
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--enable-stderr-logs")) {
            result.logging.enable_stderr_logs = true;
        } else if (std.mem.eql(u8, arg, "--panic-smoke-test")) {
            result.panic_smoke_test = true;
        } else {
            std.log.err("Unrecognized argument: '{s}'.", .{arg});
            std.process.exit(1);
        }
    }

    return result;
}

fn handleServerRunResult(result: Error!void) Error!void {
    result catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
}

test "exe mentioned" {
    var server = try zitron.Server.init(testing_allocator);
    defer server.deinit();

    const result = server.initialize(testing_allocator, .{
        .capabilities = .{},
    });

    try expectEqualStrings(zitron.server_name, result.serverInfo.?.name);
}

test "server loop treats stream end as expected shutdown" {
    try handleServerRunResult(error.EndOfStream);
    try std.testing.expectError(error.OutOfMemory, handleServerRunResult(error.OutOfMemory));
}

comptime {
    std.testing.refAllDecls(logging);
}

const std = @import("std");
const logging = @import("logging.zig");
const log = std.log.scoped(.main);
const Error =
    zitron.Server.Error ||
    lsp.Transport.ReadError ||
    lsp.Transport.WriteError ||
    error{ Canceled, OutOfMemory };
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const lsp = @import("lsp");
const zitron = @import("lsp_zitron");
