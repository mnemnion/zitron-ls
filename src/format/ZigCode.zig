//! Independent, reversible formatting jobs for embedded Zig.

/// Syntax context required by `zig fmt`.
pub const Context = enum { declarations, statements };

/// One code fragment. Inputs remain borrowed until the queue is drained.
pub const Job = struct {
    original: []const u8,
    context: Context,
    aliases: []const []const u8,
    result: ?[]const u8 = null,
    failed: bool = false,
};

/// A bounded worker queue with storage independent of the caller's allocator.
pub const Queue = struct {
    io: std.Io,
    executable: ?[]const u8,
    buffer: [16]*Job = undefined,
    queue: std.Io.Queue(*Job) = undefined,
    worker: ?std.Io.Future(void) = null,
    arena: std.heap.ArenaAllocator,
    oom: bool = false,

    /// Initialize in its final address before submitting borrowed jobs.
    pub fn init(queue: *Queue, io: std.Io, executable: ?[]const u8) void {
        queue.* = .{ .io = io, .executable = executable, .arena = .init(std.heap.page_allocator) };
        queue.queue = .init(&queue.buffer);
        queue.worker = std.Io.concurrent(io, run, .{queue}) catch null;
    }

    /// Submit a job; synchronous execution is the fallback if threads are unavailable.
    pub fn submit(queue: *Queue, job: *Job) void {
        if (queue.worker != null) {
            queue.queue.putOneUncancelable(queue.io, job) catch unreachable;
        } else queue.process(job);
    }

    /// Wait until every result is safe to read.
    pub fn finish(queue: *Queue) OOM!void {
        if (queue.worker) |*worker| {
            queue.queue.close(queue.io);
            worker.await(queue.io);
            queue.worker = null;
        }
        if (queue.oom) return error.OutOfMemory;
    }

    /// Drain outstanding work and release all result storage.
    pub fn deinit(queue: *Queue) void {
        queue.finish() catch {};
        queue.arena.deinit();
    }

    fn run(queue: *Queue) void {
        while (true) {
            const job = queue.queue.getOneUncancelable(queue.io) catch return;
            queue.process(job);
        }
    }

    fn process(queue: *Queue, job: *Job) void {
        job.result = formatCode(queue.arena.allocator(), queue.io, queue.executable, job.*) catch |err| blk: {
            if (err == error.OutOfMemory) queue.oom = true;
            job.failed = true;
            break :blk null;
        };
    }
};

const Macro = struct { marker: []const u8, original: []const u8 };

fn formatCode(allocator: Allocator, io: std.Io, executable: ?[]const u8, job: Job) ![]const u8 {
    const source = try dedent(allocator, job.original);
    var aliases: std.StringHashMapUnmanaged(void) = .empty;
    for (job.aliases) |alias| try aliases.put(allocator, alias, {});
    var forward: std.StringHashMapUnmanaged([]const u8) = .empty;
    var reverse: std.StringHashMapUnmanaged([]const u8) = .empty;
    var macro_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var macros: std.ArrayList(Macro) = .empty;
    var prepared: std.ArrayList(u8) = .empty;
    var copied_until: usize = 0;
    var offset: usize = 0;
    while (offset < source.len) {
        const start = offset;
        if (offset == 0 or source[offset - 1] == '\n') {
            const end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
            const line = source[offset..end];
            if (isMacro(std.mem.trim(u8, line, " \t\r"))) {
                const marker = try uniqueMarker(allocator, source, macros.items.len);
                try macros.append(allocator, .{ .marker = marker, .original = line });
                try macro_map.put(allocator, marker, line);
                try prepared.appendSlice(allocator, source[copied_until..offset]);
                try prepared.appendSlice(allocator, "// ");
                try prepared.appendSlice(allocator, marker);
                copied_until = end;
                offset = end;
                continue;
            }
        }
        const end = opaqueEnd(source, offset);
        if (end != offset) {
            offset = end;
            continue;
        }
        var special_end: usize = offset;
        if (job.context == .statements and std.mem.startsWith(u8, source[offset..], "$$")) {
            special_end = offset + 2;
        } else if (job.context == .statements and source[offset] == '@') {
            var name_end = offset + 1;
            while (name_end < source.len and identifierByte(source[name_end])) : (name_end += 1) {}
            if (aliases.contains(source[offset + 1 .. name_end])) special_end = name_end;
        }
        if (special_end > offset) {
            const from = source[start..special_end];
            const replacement = replacement: {
                if (forward.get(from)) |name| break :replacement name;
                const name = try substituteName(allocator, source, from, reverse);
                try forward.put(allocator, from, name);
                try reverse.put(allocator, name, from);
                break :replacement name;
            };
            try prepared.appendSlice(allocator, source[copied_until..offset]);
            try prepared.appendSlice(allocator, replacement);
            copied_until = special_end;
            offset = special_end;
        } else {
            offset += 1;
        }
    }
    const modified = forward.count() != 0 or macros.items.len != 0;
    if (modified) try prepared.appendSlice(allocator, source[copied_until..]);
    const code = if (modified) prepared.items else source;
    const input = if (job.context == .statements)
        try std.fmt.allocPrint(allocator, "fn zitron_format_body() void {{\n{s}\n}}\n", .{code})
    else
        code;
    const formatted = if (executable) |path|
        try runFmt(allocator, io, path, input)
    else
        try renderCode(allocator, input);
    var body = formatted;
    if (job.context == .statements) {
        const terminated = try allocator.dupeZ(u8, formatted);
        var ast = try std.zig.Ast.parse(allocator, terminated, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0 or ast.rootDecls().len != 1) return error.InvalidOutput;
        const declaration = ast.rootDecls()[0];
        if (ast.nodeTag(declaration) != .fn_decl) return error.InvalidOutput;
        const block = ast.nodeData(declaration).node_and_node[1];
        const first = ast.tokenStart(ast.firstToken(block));
        const last = ast.tokenStart(ast.lastToken(block));
        body = formatted[first + 1 .. last];
    }
    var restored: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try restored.append(allocator, '\n');
        first_line = false;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "// ")) {
            if (macro_map.get(trimmed[3..])) |original| {
                try restored.appendSlice(allocator, original);
                continue;
            }
        }
        var i: usize = 0;
        while (i < line.len) {
            const end = opaqueEnd(line, i);
            if (end != i) {
                try restored.appendSlice(allocator, line[i..end]);
                i = end;
            } else if (identifierByte(line[i])) {
                const begin = i;
                while (i < line.len and identifierByte(line[i])) : (i += 1) {}
                const token = line[begin..i];
                const spelling = reverse.get(token) orelse token;
                try restored.appendSlice(allocator, spelling);
            } else {
                try restored.append(allocator, line[i]);
                i += 1;
            }
        }
    }
    for (macros.items) |macro| {
        if (std.mem.indexOf(u8, restored.items, macro.marker) != null) return error.InvalidOutput;
    }
    return std.mem.trim(u8, restored.items, "\r\n");
}

fn dedent(allocator: Allocator, source: []const u8) OOM![]const u8 {
    var indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or isMacro(text)) continue;
        var count: usize = 0;
        while (count < line.len and line[count] == ' ') : (count += 1) {}
        indent = @min(indent, count);
    }
    if (indent == 0 or indent == std.math.maxInt(usize)) return source;
    var output: std.ArrayList(u8) = .empty;
    lines.reset();
    var first = true;
    while (lines.next()) |line| {
        if (!first) try output.append(allocator, '\n');
        first = false;
        var count: usize = 0;
        while (count < @min(indent, line.len) and line[count] == ' ') : (count += 1) {}
        try output.appendSlice(allocator, line[count..]);
    }
    return output.items;
}

fn substituteName(allocator: Allocator, source: []const u8, spelling: []const u8, used: std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
    if (std.mem.eql(u8, spelling, "$$")) {
        if (std.mem.indexOf(u8, source, "yY") == null and !used.contains("yY")) return "yY";
        for (alphabet) |a| {
            for (alphabet) |b| {
                const name = [_]u8{ a, b };
                if (std.mem.indexOf(u8, source, &name) == null and !used.contains(&name)) return allocator.dupe(u8, &name);
            }
        }
    } else {
        for (alphabet) |prefix| {
            const name = try std.fmt.allocPrint(allocator, "{c}{s}", .{ prefix, spelling[1..] });
            if (std.mem.indexOf(u8, source, name) == null and !used.contains(name)) return name;
        }
    }
    return error.NoSubstitution;
}

fn uniqueMarker(allocator: Allocator, source: []const u8, number: usize) OOM![]const u8 {
    var salt: usize = 0;
    while (true) : (salt += 1) {
        const marker = try std.fmt.allocPrint(allocator, "ZITRON_FORMAT_{d}_{d}", .{ number, salt });
        if (std.mem.indexOf(u8, source, marker) == null) return marker;
    }
}

/// Return the end of a string, character, or comment, or `start` for ordinary code.
pub fn opaqueEnd(source: []const u8, start: usize) usize {
    const rest = source[start..];
    if (std.mem.startsWith(u8, rest, "//") or std.mem.startsWith(u8, rest, "\\\\")) {
        return std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    }
    if (std.mem.startsWith(u8, rest, "/*")) {
        return if (std.mem.indexOfPos(u8, source, start + 2, "*/")) |end| end + 2 else source.len;
    }
    if (source[start] == '"' or source[start] == '\'') {
        var i = start + 1;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\\') {
                i += @intFromBool(i + 1 < source.len);
            } else if (source[i] == source[start]) return i + 1;
        }
        return source.len;
    }
    return start;
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isMacro(line: []const u8) bool {
    if (line.len == 0 or line[0] != '%') return false;
    const body = std.mem.trimStart(u8, line[1..], " \t");
    const end = std.mem.indexOfAny(u8, body, " \t\r(") orelse body.len;
    const name = body[0..end];
    return std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "ifdef") or
        std.mem.eql(u8, name, "ifndef") or std.mem.eql(u8, name, "else") or std.mem.eql(u8, name, "endif");
}

fn renderCode(allocator: Allocator, input: []const u8) ![]const u8 {
    const terminated = try allocator.dupeZ(u8, input);
    defer allocator.free(terminated);
    var ast = try std.zig.Ast.parse(allocator, terminated, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) return error.InvalidCode;
    return ast.renderAlloc(allocator);
}

fn writeInput(io: std.Io, file: std.Io.File, input: []const u8) !void {
    defer file.close(io);
    try file.writeStreamingAll(io, input);
}

fn runFmt(allocator: Allocator, io: std.Io, executable: []const u8, input: []const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable, "fmt", "--stdin" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var writer = try std.Io.concurrent(io, writeInput, .{ io, child.stdin.?, input });
    child.stdin = null;
    defer writer.cancel(io) catch {};
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    try writer.await(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.InvalidCode;
    return reader.toOwnedSlice(0);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
