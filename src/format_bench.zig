//! Reproducible formatter timings, caller allocation probes, and worker retention.

/// Run from the repository root; optional arguments are repetitions and case filter.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const repetitions = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 11;
    if (repetitions == 0) return error.ZeroRepetitions;
    const filter = if (args.len > 2) args[2] else "";
    const allocator = std.heap.smp_allocator;
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print("# zig={s} mode={t} repetitions={d}; parse/input creation excluded\n", .{ builtin.zig_version_string, builtin.mode, repetitions });
    try writer.writeAll("case,mode,input_bytes,output_bytes,median_us,p90_us,min_us,allocs,resize_attempts,remap_attempts,granted_bytes,peak_live_bytes,output_hash\n");
    for ([_][]const u8{ "calc", "edn", "pikchr" }) |name| {
        const formatted_name = try std.fmt.allocPrint(allocator, "{s}_formatted", .{name});
        defer allocator.free(formatted_name);
        const original_matches = std.mem.indexOf(u8, name, filter) != null;
        const formatted_matches = std.mem.indexOf(u8, formatted_name, filter) != null;
        if (!original_matches and !formatted_matches) continue;
        const path = try std.fmt.allocPrint(allocator, "samples/{s}.zy", .{name});
        defer allocator.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(source);
        if (original_matches) try benchmark(init.io, allocator, writer, name, source, repetitions);
        if (formatted_matches) {
            const parser = ts.Parser.create();
            defer parser.destroy();
            try parser.setLanguage(ts.Language.fromRaw(grammar.language()));
            const tree = parser.parseString(source, null) orelse return error.ParseFailed;
            defer tree.destroy();
            const formatted = try formatter.format(init.io, allocator, source, tree.rootNode(), .{});
            defer allocator.free(formatted);
            try benchmark(init.io, allocator, writer, formatted_name, formatted, repetitions);
        }
    }
    const kinds = [_]CaseKind{ .rules, .disabled, .code, .drops, .wide_rhs, .macros };
    for (kinds) |kind| {
        const sizes: []const usize = switch (kind) {
            .rules, .disabled, .code => &.{ 128, 512, 2048 },
            .drops => &.{ 16, 32, 64, 128 },
            .wide_rhs => &.{ 16, 32, 64, 128, 256 },
            .macros => &.{ 16, 64, 256 },
        };
        for (sizes) |size| {
            const name = try std.fmt.allocPrint(allocator, "{t}_{d}", .{ kind, size });
            defer allocator.free(name);
            if (std.mem.indexOf(u8, name, filter) == null) continue;
            const source = try generated(allocator, kind, size);
            defer allocator.free(source);
            try benchmark(init.io, allocator, writer, name, source, repetitions);
        }
    }
    if (std.mem.startsWith(u8, filter, "aliases")) {
        inline for (.{ false, true }) |colliding| {
            const name = if (colliding) "aliases_colliding" else "aliases_sparse";
            const source = try aliasSource(allocator, colliding);
            defer allocator.free(source);
            try benchmark(init.io, allocator, writer, name, source, repetitions);
        }
    }
    if (filter.len == 0 or std.mem.indexOf(u8, "worker", filter) != null) {
        try writer.writeAll("# worker queue retained arena capacity after finish; result bytes are a subset\n");
        try writer.writeAll("jobs,result_capacity,scratch_capacity,total_capacity,result_bytes\n");
        for ([_]usize{ 1, 64, 256, 1024 }) |count| {
            const jobs = try allocator.alloc(ZigCode.Job, count);
            defer allocator.free(jobs);
            var queue: ZigCode.Queue = undefined;
            queue.init(init.io, null);
            defer queue.deinit();
            for (jobs) |*job| {
                job.* = .{ .original = "x=1;", .context = .statements, .aliases = &.{} };
                queue.submit(job);
            }
            try queue.finish();
            var result_bytes: usize = 0;
            for (jobs) |job| result_bytes += (job.result orelse return error.WorkerFormatFailed).len;
            try writer.print("{d},{d},{d},{d},{d}\n", .{ count, queue.results.queryCapacity(), queue.scratch.queryCapacity(), queue.results.queryCapacity() + queue.scratch.queryCapacity(), result_bytes });
        }
    }
    try writer.flush();
}

const CaseKind = enum { rules, disabled, code, drops, wide_rhs, macros };

fn generated(allocator: Allocator, kind: CaseKind, count: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    switch (kind) {
        .rules => for (0..count) |_| try writer.writeAll("expr(A) ::= TERM(B). @copy(A; B)\n"),
        .disabled => for (0..count) |_| try writer.writeAll("// zitron fmt: off\nraw ::= A.\n// zitron fmt: on\nexpr ::= B.\n"),
        .code => for (0..count) |_| try writer.writeAll("expr(A) ::= TERM(B). {A=B+1;}\n"),
        .drops => for (0..count) |_| try writer.writeAll("expr(A) ::= FIRST_LONG_SYMBOL SECOND_LONG_SYMBOL THIRD_LONG_SYMBOL FOURTH_LONG_SYMBOL. @extremely_long_action_name(A;)\n"),
        .wide_rhs => {
            try writer.writeAll("expr ::= ");
            for (0..count) |_| try writer.writeAll("TOKEN ");
            try writer.writeAll(". @done()\n");
        },
        .macros => {
            try writer.writeAll("%include {\n");
            for (0..count) |index| try writer.print("%ifdef FLAG_{d}\nconst value_{d}=1;\n%endif\n", .{ index, index });
            try writer.writeAll("}\n");
        },
    }
    return output.toOwnedSlice();
}

fn aliasSource(allocator: Allocator, colliding: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const alias = "alias_with_a_deliberately_long_spelling";
    try writer.print("expr(A) ::= TERM({s}). {{\nconst text =\n\\\\", .{alias});
    for (0..128 * 1024) |_| try writer.writeByte('x');
    if (colliding) for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") |prefix| try writer.print(" {c}{s}", .{ prefix, alias });
    try writer.print("\n;\nA=@{s};\n_=text;\n}}\n", .{alias});
    return output.toOwnedSlice();
}

fn benchmark(io: std.Io, allocator: Allocator, writer: *std.Io.Writer, name: []const u8, source: []const u8, repetitions: usize) !void {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ts.Language.fromRaw(grammar.language()));
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();
    if (tree.rootNode().hasError()) return error.InvalidFixture;
    const reference = try formatter.format(io, allocator, source, tree.rootNode(), .{});
    defer allocator.free(reference);
    const reference_tree = parser.parseString(reference, null) orelse return error.ParseFailed;
    defer reference_tree.destroy();
    if (reference_tree.rootNode().hasError()) return error.InvalidFormattedOutput;
    if (std.mem.endsWith(u8, name, "_formatted") and !std.mem.eql(u8, source, reference)) return error.NotIdempotent;
    const hash = std.hash.Wyhash.hash(0, reference);
    const timings = try allocator.alloc(i96, repetitions);
    defer allocator.free(timings);
    inline for (.{ false, true }) |warmed| {
        var outer = std.heap.ArenaAllocator.init(allocator);
        defer outer.deinit();
        const backing = if (warmed) outer.allocator() else allocator;
        for (0..repetitions + 2) |index| {
            const start = std.Io.Clock.awake.now(io);
            const rendered = try formatter.format(io, backing, source, tree.rootNode(), .{});
            const ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
            if (!std.mem.eql(u8, reference, rendered)) return error.UnstableOutput;
            backing.free(rendered);
            if (warmed and !outer.reset(.retain_capacity)) return error.ArenaResetFailed;
            if (index >= 2) timings[index - 2] = ns;
        }
        var counter = Counter{ .backing = backing };
        const counted = counter.allocator();
        const rendered = try formatter.format(io, counted, source, tree.rootNode(), .{});
        counted.free(rendered);
        if (counter.live != 0) return error.CallerAllocationLeak;
        std.mem.sort(i96, timings, {}, std.sort.asc(i96));
        try writer.print("{s},{s},{d},{d},{d:.3},{d:.3},{d:.3},{d},{d},{d},{d},{d},{x}\n", .{
            name,                                                     if (warmed) "warm_caller_arena" else "direct_smp",                                    source.len,                                 reference.len,
            @as(f64, @floatFromInt(timings[repetitions / 2])) / 1000, @as(f64, @floatFromInt(timings[@min(repetitions - 1, repetitions * 9 / 10)])) / 1000, @as(f64, @floatFromInt(timings[0])) / 1000, counter.allocs,
            counter.resizes,                                          counter.remaps,                                                                       counter.granted,                            counter.peak,
            hash,
        });
        try writer.flush();
    }
}

const Counter = struct {
    backing: Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    granted: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(counter: *Counter) Allocator {
        return .{ .ptr = counter, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn change(counter: *Counter, old: usize, new: usize) void {
        counter.granted += new -| old;
        counter.live = counter.live - old + new;
        counter.peak = @max(counter.peak, counter.live);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const counter: *Counter = @ptrCast(@alignCast(context));
        const result = counter.backing.rawAlloc(len, alignment, address) orelse return null;
        counter.allocs += 1;
        counter.change(0, len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const counter: *Counter = @ptrCast(@alignCast(context));
        counter.resizes += 1;
        if (!counter.backing.rawResize(memory, alignment, len, address)) return false;
        counter.change(memory.len, len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const counter: *Counter = @ptrCast(@alignCast(context));
        counter.remaps += 1;
        const result = counter.backing.rawRemap(memory, alignment, len, address) orelse return null;
        counter.change(memory.len, len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const counter: *Counter = @ptrCast(@alignCast(context));
        counter.backing.rawFree(memory, alignment, address);
        counter.change(memory.len, 0);
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const formatter = @import("format.zig");
const ts = @import("tree-sitter");
const grammar = @import("tree_sitter_zitron");
const ZigCode = @import("format/ZigCode.zig");
