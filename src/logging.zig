//! Runtime logging setup for the lsp_zitron executable.

const log_file_name = "lsp_zitron.log";
const app_dir_name = "lsp_zitron";

pub const Options = struct {
    log_file_path: ?[]const u8 = null,
    log_level: ?std.log.Level = null,
    enable_stderr_logs: bool = false,
};

pub const State = struct {
    io: std.Io,
    path: ?[]const u8,
    level: std.log.Level,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        if (log_file) |file| {
            file.close(state.io);
            log_file = null;
        }
        if (state.path) |path| allocator.free(path);
        state.* = undefined;
    }
};

var log_file: ?std.Io.File = null;
var runtime_log_level: std.log.Level = if (builtin.mode == .Debug) .debug else .info;
var log_stderr: bool = true;

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: std.process.Environ.Map,
    options: Options,
) error{ Canceled, OutOfMemory }!State {
    const created = try createLogFile(io, allocator, environ_map, options.log_file_path);
    log_file = if (created) |payload| payload.file else null;
    runtime_log_level = options.log_level orelse runtime_log_level;
    log_stderr = options.enable_stderr_logs;

    return .{
        .io = io,
        .path = if (created) |payload| payload.path else null,
        .level = runtime_log_level,
    };
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;
    if (!log_stderr and log_file == null) return;

    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const no_space_left = blk: {
        writer.print("{s:<5} ({s}): ", .{ levelText(level), @tagName(scope) }) catch break :blk true;
        writer.print(format, args) catch break :blk true;
        writer.writeByte('\n') catch break :blk true;
        break :blk false;
    };
    if (no_space_left) {
        const trailing = "...\n".*;
        writer.undo(trailing.len -| writer.unusedCapacityLen());
        (writer.writableArray(trailing.len) catch unreachable).* = trailing;
    }

    if (log_stderr) {
        const stderr = io.lockStderr(&.{}, null) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
        defer io.unlockStderr();
        stderr.file_writer.interface.writeAll(writer.buffered()) catch {};
    }

    if (log_file) |file| {
        const is_locked = if (file.lock(io, .exclusive)) |_| true else |_| false;
        defer if (is_locked) file.unlock(io);
        if (file.length(io)) |length| {
            file.writePositionalAll(io, writer.buffered(), length) catch {};
        } else |_| {
            file.writeStreamingAll(io, writer.buffered()) catch {};
        }
    }
}

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    recordPanic(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn recordPanic(msg: []const u8, first_trace_addr: ?usize) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    const stack_trace_addr = first_trace_addr orelse @returnAddress();
    const stderr = std.debug.lockStderr(&.{}).terminal();
    defer std.debug.unlockStderr();
    writePanicReport(stderr, msg, first_trace_addr, stack_trace_addr) catch {};

    if (log_file) |file| {
        writePanicReportToFile(io, file, msg, first_trace_addr, stack_trace_addr);
    }
}

fn writePanicReportToFile(
    io: std.Io,
    file: std.Io.File,
    msg: []const u8,
    first_trace_addr: ?usize,
    stack_trace_addr: usize,
) void {
    const is_locked = if (file.lock(io, .exclusive)) |_| true else |_| false;
    defer if (is_locked) file.unlock(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    if (file.length(io)) |length| {
        file_writer.seekTo(length) catch {};
    } else |_| {}

    writePanicReport(.{
        .writer = &file_writer.interface,
        .mode = .no_color,
    }, msg, first_trace_addr, stack_trace_addr) catch {};
    file_writer.flush() catch {};
}

fn writePanicReport(
    terminal: std.Io.Terminal,
    msg: []const u8,
    first_trace_addr: ?usize,
    stack_trace_addr: usize,
) std.Io.Writer.Error!void {
    const writer = terminal.writer;
    try writePanicRecord(writer, msg, first_trace_addr);
    try writer.writeAll("stack trace:\n");
    try std.debug.writeCurrentStackTrace(.{
        .first_address = stack_trace_addr,
        .allow_unsafe_unwind = true,
    }, terminal);
}

fn writePanicRecord(writer: *std.Io.Writer, msg: []const u8, first_trace_addr: ?usize) std.Io.Writer.Error!void {
    try writer.print("panic (panic): {s}", .{msg});
    if (first_trace_addr) |addr| try writer.print(" at 0x{x}", .{addr});
    try writer.writeByte('\n');
}

pub fn parseLevel(name: []const u8) ?std.log.Level {
    return std.meta.stringToEnum(std.log.Level, name);
}

pub fn defaultLogFilePath(allocator: std.mem.Allocator, environ_map: std.process.Environ.Map) OOM!?[]const u8 {
    if (builtin.os.tag == .wasi) return null;

    const cache_dir = environ_map.get("XDG_CACHE_HOME") orelse switch (builtin.os.tag) {
        .macos => if (environ_map.get("HOME")) |home|
            return try std.fs.path.join(allocator, &.{ home, "Library", "Caches", app_dir_name, log_file_name })
        else
            return null,
        else => if (environ_map.get("HOME")) |home|
            return try std.fs.path.join(allocator, &.{ home, ".cache", app_dir_name, log_file_name })
        else
            return null,
    };
    return try std.fs.path.join(allocator, &.{ cache_dir, app_dir_name, log_file_name });
}

fn createLogFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: std.process.Environ.Map,
    override_log_file_path: ?[]const u8,
) error{ Canceled, OutOfMemory }!?struct {
    file: std.Io.File,
    path: []const u8,
} {
    const path = if (override_log_file_path) |override|
        try allocator.dupe(u8, override)
    else
        try defaultLogFilePath(allocator, environ_map) orelse return null;
    errdefer allocator.free(path);

    if (std.fs.path.dirname(path)) |dirname| {
        std.Io.Dir.cwd().createDirPath(io, dirname) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }

    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            allocator.free(path);
            return null;
        },
    };
    errdefer file.close(io);

    return .{ .file = file, .path = path };
}

fn levelText(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

const OOM = error{OutOfMemory};

test "default log path uses macOS cache directory" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var env = std.process.Environ.Map.init(testing_allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/em");

    const path = try defaultLogFilePath(testing_allocator, env);
    defer if (path) |owned| testing_allocator.free(owned);

    try expectEqualStrings("/Users/em/Library/Caches/lsp_zitron/lsp_zitron.log", path.?);
}

test "XDG_CACHE_HOME overrides default cache directory" {
    var env = std.process.Environ.Map.init(testing_allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/em");
    try env.put("XDG_CACHE_HOME", "/tmp/cache");

    const path = try defaultLogFilePath(testing_allocator, env);
    defer if (path) |owned| testing_allocator.free(owned);

    try expectEqualStrings("/tmp/cache/lsp_zitron/lsp_zitron.log", path.?);
}

test "log level names parse like ZLS flags" {
    try expectEqual(std.log.Level.err, parseLevel("err").?);
    try expectEqual(std.log.Level.warn, parseLevel("warn").?);
    try expectEqual(std.log.Level.info, parseLevel("info").?);
    try expectEqual(std.log.Level.debug, parseLevel("debug").?);
    try expect(parseLevel("trace") == null);
}

test "panic records are formatted outside normal log filtering" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writePanicRecord(&writer, "smoke panic", 0x1234);

    try expectEqualStrings("panic (panic): smoke panic at 0x1234\n", writer.buffered());
}

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
