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
    results: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    started: bool = false,
    oom: bool = false,

    /// Initialize in its final address before submitting borrowed jobs.
    pub fn init(queue: *Queue, io: std.Io, executable: ?[]const u8) void {
        queue.* = .{ .io = io, .executable = executable, .results = .init(std.heap.smp_allocator), .scratch = .init(std.heap.smp_allocator) };
        queue.queue = .init(&queue.buffer);
    }

    /// Submit a job; synchronous execution is the fallback if threads are unavailable.
    pub fn submit(queue: *Queue, job: *Job) void {
        if (!queue.started) {
            queue.started = true;
            queue.worker = std.Io.concurrent(queue.io, run, .{queue}) catch null;
        }
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
        queue.results.deinit();
        queue.scratch.deinit();
    }

    fn run(queue: *Queue) void {
        while (true) {
            const job = queue.queue.getOneUncancelable(queue.io) catch return;
            queue.process(job);
        }
    }

    fn process(queue: *Queue, job: *Job) void {
        defer _ = queue.scratch.reset(.{ .retain_with_limit = 256 * 1024 });
        if (queue.scratch.queryCapacity() == 0) {
            const warm = queue.scratch.allocator().alloc(u8, @min(256 * 1024, @max(4096, job.original.len *| 2))) catch {
                queue.oom = true;
                job.failed = true;
                return;
            };
            queue.scratch.allocator().free(warm);
        }
        const text = formatCode(queue.scratch.allocator(), queue.io, queue.executable, job.*) catch |err| {
            if (err == error.OutOfMemory) queue.oom = true;
            job.failed = true;
            return;
        };
        job.result = queue.results.allocator().dupe(u8, text) catch {
            queue.oom = true;
            job.failed = true;
            return;
        };
    }
};

fn formatCode(allocator: Allocator, io: std.Io, executable: ?[]const u8, job: Job) ![]const u8 {
    const source = try dedent(allocator, job.original);
    var aliases: std.StringHashMapUnmanaged(void) = .empty;
    for (job.aliases) |alias| try aliases.put(allocator, alias, {});
    var forward: std.StringHashMapUnmanaged([]const u8) = .empty;
    var reverse: std.StringHashMapUnmanaged([]const u8) = .empty;
    var macro_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var collisions = Collisions{ .source = source };
    var prepared: std.ArrayList(u8) = .empty;
    var copied_until: usize = 0;
    var offset: usize = 0;
    while (offset < source.len) {
        const start = offset;
        if (offset == 0 or source[offset - 1] == '\n') {
            const end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
            const line = source[offset..end];
            if (isMacro(std.mem.trim(u8, line, " \t\r"))) {
                const marker = try collisions.uniqueMarker(allocator, macro_map.count());
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
                const name = try collisions.substituteName(allocator, from, reverse);
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
    const modified = forward.count() != 0 or macro_map.count() != 0;
    if (modified) try prepared.appendSlice(allocator, source[copied_until..]);
    const code = if (modified) prepared.items else source;
    const wrapper: ?[:0]const u8 = if (job.context == .statements)
        try std.fmt.allocPrintSentinel(allocator, "fn zitron_format_body() void {{\n{s}\n}}\n", .{code}, 0)
    else
        null;
    const input = wrapper orelse code;
    const formatted = if (executable) |path|
        try runFmt(allocator, io, path, input)
    else
        try renderCode(allocator, wrapper orelse if (modified) try prepared.toOwnedSliceSentinel(allocator, 0) else try allocator.dupeZ(u8, input));
    var body = formatted;
    if (job.context == .statements) {
        if (executable == null) {
            body = try statementBody(formatted);
        } else {
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
    }
    if (!modified) return std.mem.trim(u8, body, "\r\n");
    var restored: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const line_start = @intFromPtr(line.ptr) - @intFromPtr(body.ptr);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "// ")) {
            if (macro_map.get(trimmed[3..])) |original| {
                try restored.appendSlice(allocator, body[copied..line_start]);
                try restored.appendSlice(allocator, original);
                copied = line_start + line.len;
                continue;
            }
        }
        var i: usize = 0;
        while (i < line.len) {
            const end = opaqueEnd(line, i);
            if (end != i) {
                i = end;
            } else if (identifierByte(line[i])) {
                const begin = i;
                while (i < line.len and identifierByte(line[i])) : (i += 1) {}
                if (reverse.get(line[begin..i])) |spelling| {
                    try restored.appendSlice(allocator, body[copied .. line_start + begin]);
                    try restored.appendSlice(allocator, spelling);
                    copied = line_start + i;
                }
            } else i += 1;
        }
    }
    try restored.appendSlice(allocator, body[copied..]);
    if (containsMarker(restored.items, macro_map)) return error.InvalidOutput;
    return std.mem.trim(u8, restored.items, "\r\n");
}

fn statementBody(formatted: []const u8) ![]const u8 {
    const header = "fn zitron_format_body() void {";
    if (!std.mem.startsWith(u8, formatted, header)) return error.InvalidOutput;
    var depth: usize = 1;
    var i = header.len;
    while (i < formatted.len) {
        const end = opaqueEnd(formatted, i);
        if (end != i) {
            i = end;
            continue;
        }
        switch (formatted[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    if (std.mem.trim(u8, formatted[i + 1 ..], " \t\r\n").len != 0) return error.InvalidOutput;
                    return formatted[header.len..i];
                }
            },
            else => {},
        }
        i += 1;
    }
    return error.InvalidOutput;
}

const Collisions = struct {
    source: []const u8,
    pairs: ?std.DynamicBitSetUnmanaged = null,
    markers: ?std.StringHashMapUnmanaged(void) = null,

    fn substituteName(collisions: *Collisions, allocator: Allocator, spelling: []const u8, used: std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
        if (std.mem.eql(u8, spelling, "$$")) {
            if (collisions.pairs == null) {
                collisions.pairs = try .initEmpty(allocator, 1 << 16);
                if (collisions.source.len >= 2) for (collisions.source[0 .. collisions.source.len - 1], collisions.source[1..]) |a, b| {
                    collisions.pairs.?.set(@as(usize, a) * 256 + b);
                };
            }
            const present = collisions.pairs.?;
            if (!present.isSet('y' * 256 + 'Y') and !used.contains("yY")) return "yY";
            for (alphabet) |a| {
                for (alphabet) |b| {
                    const name = [_]u8{ a, b };
                    if (!present.isSet(@as(usize, a) * 256 + b) and !used.contains(&name)) return allocator.dupe(u8, &name);
                }
            }
        } else {
            const name = try allocator.dupe(u8, spelling);
            name[0] = alphabet[0];
            if (std.mem.indexOf(u8, collisions.source, name) == null and !used.contains(name)) return name;
            var prefixes = std.StaticBitSet(256).initEmpty();
            var offset: usize = 1;
            while (std.mem.indexOfPos(u8, collisions.source, offset, spelling[1..])) |start| {
                prefixes.set(collisions.source[start - 1]);
                offset = start + 1;
            }
            for (alphabet[1..]) |prefix| {
                name[0] = prefix;
                if (!prefixes.isSet(prefix) and !used.contains(name)) return name;
            }
        }
        return error.NoSubstitution;
    }

    fn uniqueMarker(collisions: *Collisions, allocator: Allocator, number: usize) OOM![]const u8 {
        if (collisions.markers == null) {
            collisions.markers = .empty;
            var offset: usize = 0;
            while (markerStart(collisions.source, offset)) |start| {
                const digits = markerDigits(collisions.source, start) orelse {
                    offset = start + 1;
                    continue;
                };
                var end = digits;
                while (end < collisions.source.len and std.ascii.isDigit(collisions.source[end])) {
                    end += 1;
                    if (end - digits <= MAX_DECIMAL_DIGITS and (end - digits == 1 or collisions.source[digits] != '0'))
                        try collisions.markers.?.put(allocator, collisions.source[start..end], {});
                }
                offset = end;
            }
        }
        var buffer: [64]u8 = undefined;
        var salt: usize = 0;
        while (true) : (salt += 1) {
            const marker = std.fmt.bufPrint(&buffer, "ZITRON_FORMAT_{d}_{d}", .{ number, salt }) catch unreachable;
            if (!collisions.markers.?.contains(marker)) return allocator.dupe(u8, marker);
        }
    }
};

fn markerStart(source: []const u8, offset: usize) ?usize {
    return std.mem.indexOfPos(u8, source, offset, "ZITRON_FORMAT_");
}

const MAX_DECIMAL_DIGITS = std.fmt.count("{d}", .{std.math.maxInt(usize)});

fn markerDigits(source: []const u8, start: usize) ?usize {
    var i = start + "ZITRON_FORMAT_".len;
    const first = i;
    while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
    if (i == first or i - first > MAX_DECIMAL_DIGITS or (i - first > 1 and source[first] == '0') or i == source.len or source[i] != '_') return null;
    return i + 1;
}

fn containsMarker(source: []const u8, markers: std.StringHashMapUnmanaged([]const u8)) bool {
    if (markers.count() == 0) return false;
    var offset: usize = 0;
    while (markerStart(source, offset)) |start| {
        const digits = markerDigits(source, start) orelse {
            offset = start + 1;
            continue;
        };
        var end = digits;
        while (end < source.len and std.ascii.isDigit(source[end])) {
            end += 1;
            if (end - digits <= MAX_DECIMAL_DIGITS and (end - digits == 1 or source[digits] != '0') and markers.contains(source[start..end])) return true;
        }
        offset = end;
    }
    return false;
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

fn renderCode(allocator: Allocator, input: [:0]const u8) ![]const u8 {
    var ast = try std.zig.Ast.parse(allocator, input, .zig);
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

//| Tests

test "format worker results survive scratch release and failed neighboring jobs" {
    var queue: Queue = undefined;
    queue.init(std.testing.io, null);
    defer queue.deinit();
    try std.testing.expect(queue.worker == null);
    try std.testing.expectEqual(0, queue.scratch.queryCapacity());
    var jobs: [128]Job = undefined;
    for (&jobs, 0..) |*job, index| {
        job.* = .{ .original = switch (index % 3) {
            0 => "x=1;",
            1 => "y=2;",
            else => "z=;",
        }, .context = .statements, .aliases = &.{} };
        queue.submit(job);
    }
    try queue.finish();
    _ = queue.scratch.reset(.free_all);
    for (jobs, 0..) |job, index| {
        if (index % 3 == 2) {
            try std.testing.expect(job.failed);
            try std.testing.expect(job.result == null);
        } else {
            try std.testing.expect(!job.failed);
            try std.testing.expectEqualStrings(if (index % 3 == 0) "    x = 1;" else "    y = 2;", job.result.?);
        }
    }
}

test "format marker collision index bounds long decimal lookalikes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prefix = "ZITRON_FORMAT_0_";
    const source = try allocator.alloc(u8, prefix.len + 64 * 1024);
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len..], '1');
    var collisions = Collisions{ .source = source };
    const marker = try collisions.uniqueMarker(allocator, 0);
    try std.testing.expectEqualStrings("ZITRON_FORMAT_0_0", marker);
    try std.testing.expectEqual(MAX_DECIMAL_DIGITS, collisions.markers.?.count());
    var markers: std.StringHashMapUnmanaged([]const u8) = .empty;
    try markers.put(allocator, marker, "");
    try std.testing.expect(!containsMarker(source, markers));
    try markers.put(allocator, "ZITRON_FORMAT_0_1", "");
    try std.testing.expect(containsMarker(source, markers));
    source[prefix.len] = '0';
    var zero = Collisions{ .source = source };
    try std.testing.expectEqualStrings("ZITRON_FORMAT_0_1", try zero.uniqueMarker(allocator, 0));
    try std.testing.expectEqual(1, zero.markers.?.count());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
