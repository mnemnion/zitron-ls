//! Text diffing between document revisions and LSP change events.

fn edits(
    allocator: Allocator,
    before: []const u8,
    after: []const u8,
    encoding: lsp.offsets.Encoding,
) OOM!ArrayList(types.TextEdit) {
    var dmp = DiffMatchPatch.Diff.init(.default);
    defer dmp.deinit(allocator);
    _ = try dmp.diff(allocator, before, after);

    var edit_count: usize = 0;
    for (dmp.edits.items) |item| {
        switch (item.operation) {
            .equal => {},
            .insert, .delete => edit_count += 1,
        }
    }

    var text_edits: ArrayList(types.TextEdit) = try .initCapacity(allocator, edit_count);
    errdefer deinitTextEdits(allocator, &text_edits);

    var offset: usize = 0;
    for (dmp.edits.items) |item| {
        const start = offset;
        switch (item.operation) {
            .equal => offset += item.text.len,
            .delete => {
                offset += item.text.len;
                text_edits.appendAssumeCapacity(.{
                    .range = lsp.offsets.locToRange(before, .{ .start = start, .end = offset }, encoding),
                    .newText = "",
                });
            },
            .insert => {
                text_edits.appendAssumeCapacity(.{
                    .range = lsp.offsets.locToRange(before, .{ .start = start, .end = start }, encoding),
                    .newText = try allocator.dupe(u8, item.text),
                });
            },
        }
    }

    return text_edits;
}

const AppliedChange = struct {
    text: [:0]const u8,
    input_edits: ArrayList(ts.InputEdit),

    /// Releases the owned text buffer and collected tree-sitter edits.
    pub fn deinit(applied_change: *AppliedChange, allocator: Allocator) void {
        allocator.free(applied_change.text);
        applied_change.input_edits.deinit(allocator);
    }
};

/// Applies a sequence of LSP content changes to `text` in notification order.
pub fn applyContentChanges(
    allocator: Allocator,
    text: []const u8,
    content_changes: []const types.TextDocumentContentChangeEvent,
    encoding: lsp.offsets.Encoding,
) OOM![:0]const u8 {
    var applied_change = try applyContentChangesWithEdits(
        allocator,
        text,
        content_changes,
        encoding,
    );
    defer applied_change.deinit(allocator);
    return try allocator.dupeZ(u8, applied_change.text);
}

/// Applies content changes and returns both the updated text and tree-sitter edits.
pub fn applyContentChangesWithEdits(
    allocator: Allocator,
    text: []const u8,
    content_changes: []const types.TextDocumentContentChangeEvent,
    encoding: lsp.offsets.Encoding,
) OOM!AppliedChange {
    const last_full_text_index, const last_full_text = blk: {
        var index = content_changes.len;
        while (index != 0) {
            index -= 1;
            switch (content_changes[index]) {
                // literal_1 is the whole-document form; literal_0 is ranged change form.
                .literal_1 => |whole| break :blk .{ index, whole.text },
                .literal_0 => continue,
            }
        }
        break :blk .{ null, text };
    };

    var text_array: ArrayList(u8) = .empty;
    errdefer text_array.deinit(allocator);
    try text_array.appendSlice(allocator, last_full_text);

    var input_edits: ArrayList(ts.InputEdit) = .empty;
    errdefer input_edits.deinit(allocator);

    const changes = content_changes[if (last_full_text_index) |index| index + 1 else 0..];
    for (changes) |item| {
        const partial = switch (item) {
            .literal_0 => |change| change,
            .literal_1 => unreachable,
        };
        const input_edit = inputEditForPartialChange(
            text_array.items,
            partial,
            encoding,
        );
        const loc = lsp.offsets.rangeToLoc(text_array.items, partial.range, encoding);
        try input_edits.append(allocator, input_edit);
        try text_array.replaceRange(allocator, loc.start, loc.end - loc.start, partial.text);
    }

    return .{
        .text = try text_array.toOwnedSliceSentinel(allocator, 0),
        .input_edits = input_edits,
    };
}

fn inputEditForPartialChange(
    text: []const u8,
    partial: anytype,
    encoding: lsp.offsets.Encoding,
) ts.InputEdit {
    const loc = lsp.offsets.rangeToLoc(text, partial.range, encoding);
    const start_point = pointFromByteIndex(text, loc.start);
    const old_end_point = pointFromByteIndex(text, loc.end);

    return .{
        .start_byte = @intCast(loc.start),
        .old_end_byte = @intCast(loc.end),
        .new_end_byte = @intCast(loc.start + partial.text.len),
        .start_point = start_point,
        .old_end_point = old_end_point,
        .new_end_point = advancePoint(start_point, partial.text),
    };
}

fn pointFromByteIndex(text: []const u8, index: usize) ts.Point {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..index], '\n')) |line| line + 1 else 0;
    return .{
        .row = @intCast(std.mem.count(u8, text[0..line_start], "\n")),
        .column = @intCast(index - line_start),
    };
}

fn advancePoint(start_point: ts.Point, text: []const u8) ts.Point {
    var point = start_point;
    var line_start: usize = 0;
    for (text, 0..) |char, index| {
        if (char == '\n') {
            point.row += 1;
            line_start = index + 1;
        }
    }
    point.column = @intCast(text.len - line_start);
    return point;
}

fn textEditLessThan(_: void, lhs: types.TextEdit, rhs: types.TextEdit) bool {
    return lsp.offsets.orderPosition(lhs.range.start, rhs.range.start) == .lt or
        lsp.offsets.orderPosition(lhs.range.end, rhs.range.end) == .lt;
}

fn applyTextEdits(
    allocator: Allocator,
    text: []const u8,
    text_edits: []const types.TextEdit,
    encoding: lsp.offsets.Encoding,
) OOM![]const u8 {
    const sortable = try allocator.dupe(types.TextEdit, text_edits);
    defer allocator.free(sortable);
    std.mem.sort(types.TextEdit, sortable, {}, textEditLessThan);

    var final_text: ArrayList(u8) = .empty;
    errdefer final_text.deinit(allocator);

    var last: usize = 0;
    for (sortable) |item| {
        const start = lsp.offsets.positionToIndex(text, item.range.start, encoding);
        if (start > last) {
            try final_text.appendSlice(allocator, text[last..start]);
            last = start;
        }
        try final_text.appendSlice(allocator, item.newText);
        last = lsp.offsets.positionToIndex(text, item.range.end, encoding);
    }
    if (last < text.len) {
        try final_text.appendSlice(allocator, text[last..]);
    }

    return try final_text.toOwnedSlice(allocator);
}

fn deinitTextEdits(allocator: Allocator, text_edits: *ArrayList(types.TextEdit)) void {
    defer text_edits.deinit(allocator);
    for (text_edits.items) |item| {
        if (item.newText.len != 0) allocator.free(item.newText);
    }
}

//| Tests

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualDeep = testing.expectEqualDeep;
const expectEqualStrings = testing.expectEqualStrings;

test "edits round trip pure insert" {
    var text_edits = try edits(testing.allocator, "calc ::= expr", "calc ::= expr.", .@"utf-8");
    defer deinitTextEdits(testing.allocator, &text_edits);

    const applied = try applyTextEdits(testing.allocator, "calc ::= expr", text_edits.items, .@"utf-8");
    defer testing.allocator.free(applied);

    try expectEqual(@as(usize, 1), text_edits.items.len);
    try expectEqualStrings("calc ::= expr.", applied);
}

test "edits round trip pure delete" {
    var text_edits = try edits(testing.allocator, "calc ::= expr.\n", "calc ::= expr", .@"utf-8");
    defer deinitTextEdits(testing.allocator, &text_edits);

    const applied = try applyTextEdits(testing.allocator, "calc ::= expr.\n", text_edits.items, .@"utf-8");
    defer testing.allocator.free(applied);

    try expectEqual(@as(usize, 1), text_edits.items.len);
    try expectEqualStrings("calc ::= expr", applied);
}

test "edits round trip mixed replace with multiple edits" {
    const before = "calc ::= expr\nexpr ::= term\nterm ::= TOKEN\n";
    const after = "start ::= expr\nexpr ::= factor\nfactor ::= TOKEN\n";
    var text_edits = try edits(testing.allocator, before, after, .@"utf-8");
    defer deinitTextEdits(testing.allocator, &text_edits);

    const applied = try applyTextEdits(testing.allocator, before, text_edits.items, .@"utf-8");
    defer testing.allocator.free(applied);

    try expect(text_edits.items.len >= 2);
    try expectEqualStrings(after, applied);
}

test "edits preserve utf-16 positions" {
    const before = "a¶↉🠁";
    const after = "a¶🠁!";
    var text_edits = try edits(testing.allocator, before, after, .@"utf-16");
    defer deinitTextEdits(testing.allocator, &text_edits);

    const applied = try applyTextEdits(testing.allocator, before, text_edits.items, .@"utf-16");
    defer testing.allocator.free(applied);

    try expect(text_edits.items.len >= 1);
    try expectEqualStrings(after, applied);
}

test "apply content changes handles whole document replacement" {
    const updated = try applyContentChanges(testing.allocator, "old", &.{
        .{ .literal_1 = .{ .text = "new" } },
    }, .@"utf-8");
    defer testing.allocator.free(updated);

    try expectEqualStrings("new", updated);
}

test "apply content changes handles ordered partial edits" {
    const updated = try applyContentChanges(testing.allocator, "calc ::= expr\n", &.{
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 4 },
            },
            .rangeLength = 4,
            .text = "start",
        } },
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 10 },
                .end = .{ .line = 0, .character = 14 },
            },
            .rangeLength = 4,
            .text = "term",
        } },
    }, .@"utf-8");
    defer testing.allocator.free(updated);

    try expectEqualStrings("start ::= term\n", updated);
}

test "apply content changes uses last full text before trailing partial edits" {
    const updated = try applyContentChanges(testing.allocator, "ignored", &.{
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 7 },
            },
            .rangeLength = 7,
            .text = "discard",
        } },
        .{ .literal_1 = .{ .text = "calc ::= expr" } },
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 9 },
                .end = .{ .line = 0, .character = 13 },
            },
            .rangeLength = 4,
            .text = "term",
        } },
    }, .@"utf-8");
    defer testing.allocator.free(updated);

    try expectEqualStrings("calc ::= term", updated);
}

test "apply content changes handles utf-16 ranges" {
    const updated = try applyContentChanges(testing.allocator, "a¶↉🠁", &.{
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 2 },
                .end = .{ .line = 0, .character = 3 },
            },
            .rangeLength = 1,
            .text = "!",
        } },
    }, .@"utf-16");
    defer testing.allocator.free(updated);

    try expectEqualStrings("a¶!🠁", updated);
}

test "input edit handles single-line replacement" {
    const partial = types.TextDocumentContentChangeEvent{ .literal_0 = .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 4 },
        },
        .rangeLength = 4,
        .text = "start",
    } };
    const input_edit = inputEditForPartialChange("calc ::= expr\n", partial.literal_0, .@"utf-8");

    try expectEqualDeep(ts.InputEdit{
        .start_byte = 0,
        .old_end_byte = 4,
        .new_end_byte = 5,
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = .{ .row = 0, .column = 4 },
        .new_end_point = .{ .row = 0, .column = 5 },
    }, input_edit);
}

test "input edit handles insertion at end of file" {
    const partial = types.TextDocumentContentChangeEvent{ .literal_0 = .{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 4 },
        },
        .rangeLength = 0,
        .text = "\n",
    } };
    const input_edit = inputEditForPartialChange("calc", partial.literal_0, .@"utf-8");

    try expectEqualDeep(ts.InputEdit{
        .start_byte = 4,
        .old_end_byte = 4,
        .new_end_byte = 5,
        .start_point = .{ .row = 0, .column = 4 },
        .old_end_point = .{ .row = 0, .column = 4 },
        .new_end_point = .{ .row = 1, .column = 0 },
    }, input_edit);
}

test "input edit handles utf-16 positions over multibyte text" {
    const partial = types.TextDocumentContentChangeEvent{ .literal_0 = .{
        .range = .{
            .start = .{ .line = 0, .character = 2 },
            .end = .{ .line = 0, .character = 3 },
        },
        .rangeLength = 1,
        .text = "!",
    } };
    const input_edit = inputEditForPartialChange("a¶↉🠁", partial.literal_0, .@"utf-16");

    try expectEqualDeep(ts.InputEdit{
        .start_byte = 3,
        .old_end_byte = 6,
        .new_end_byte = 4,
        .start_point = .{ .row = 0, .column = 3 },
        .old_end_point = .{ .row = 0, .column = 6 },
        .new_end_point = .{ .row = 0, .column = 1 },
    }, input_edit);
}

test "apply content changes with edits handles multiple ordered partial edits" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "calc ::= expr\n", &.{
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 4 },
            },
            .rangeLength = 4,
            .text = "start",
        } },
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 10 },
                .end = .{ .line = 0, .character = 14 },
            },
            .rangeLength = 4,
            .text = "term",
        } },
    }, .@"utf-8");
    defer applied_change.deinit(testing.allocator);

    try expectEqual(@as(usize, 2), applied_change.input_edits.items.len);
    try expectEqualStrings("start ::= term\n", applied_change.text);
    try expectEqualDeep(ts.InputEdit{
        .start_byte = 0,
        .old_end_byte = 4,
        .new_end_byte = 5,
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = .{ .row = 0, .column = 4 },
        .new_end_point = .{ .row = 0, .column = 5 },
    }, applied_change.input_edits.items[0]);
}

test "apply content changes with edits handles last full text and trailing partial edits" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "ignored", &.{
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 7 },
            },
            .rangeLength = 7,
            .text = "discard",
        } },
        .{ .literal_1 = .{ .text = "calc ::= expr" } },
        .{ .literal_0 = .{
            .range = .{
                .start = .{ .line = 0, .character = 9 },
                .end = .{ .line = 0, .character = 13 },
            },
            .rangeLength = 4,
            .text = "term",
        } },
    }, .@"utf-8");
    defer applied_change.deinit(testing.allocator);

    try expectEqual(@as(usize, 1), applied_change.input_edits.items.len);
    try expectEqualStrings("calc ::= term", applied_change.text);
}

test "edits output matches expected utf-8 replace range" {
    const before = "calc ::= expr";
    const after = "start ::= expr";
    var text_edits = try edits(testing.allocator, before, after, .@"utf-8");
    defer deinitTextEdits(testing.allocator, &text_edits);

    const applied = try applyTextEdits(testing.allocator, before, text_edits.items, .@"utf-8");
    defer testing.allocator.free(applied);

    try expect(text_edits.items.len >= 2);
    try expectEqualDeep(types.Position{ .line = 0, .character = 0 }, text_edits.items[0].range.start);
    try expectEqualStrings(after, applied);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const OOM = std.mem.Allocator.Error;
const lsp = @import("lsp");
const types = lsp.types;
const DiffMatchPatch = @import("dmp");
const ts = @import("tree-sitter");
