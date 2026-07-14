//! Applies LSP document change events.

const AppliedChange = struct {
    text: ?[]u8,
    input_edits: ArrayList(ts.InputEdit),

    pub fn takeText(applied_change: *AppliedChange) []u8 {
        const text = applied_change.text orelse unreachable;
        applied_change.text = null;
        return text;
    }

    /// Releases the owned text buffer and collected tree-sitter edits.
    pub fn deinit(applied_change: *AppliedChange, allocator: Allocator) void {
        if (applied_change.text) |text| allocator.free(text);
        applied_change.input_edits.deinit(allocator);
    }
};

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
                // Whole-document changes replace prior ranged edits.
                .text_document_content_change_whole_document => |whole| break :blk .{ index, whole.text },
                .text_document_content_change_partial => continue,
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
            .text_document_content_change_partial => |change| change,
            .text_document_content_change_whole_document => unreachable,
        };
        const loc = lsp.offsets.rangeToLoc(text_array.items, partial.range, encoding);
        const input_edit = inputEditForPartialChange(text_array.items, partial.text, loc.start, loc.end);
        try input_edits.append(allocator, input_edit);
        try text_array.replaceRange(allocator, loc.start, loc.end - loc.start, partial.text);
    }

    return .{
        .text = try text_array.toOwnedSlice(allocator),
        .input_edits = input_edits,
    };
}

fn inputEditForPartialChange(
    text: []const u8,
    replacement: []const u8,
    start: usize,
    old_end: usize,
) ts.InputEdit {
    const start_point = pointFromByteIndex(text, start);
    const old_end_point = advancePoint(start_point, text[start..old_end]);

    return .{
        .start_byte = @intCast(start),
        .old_end_byte = @intCast(old_end),
        .new_end_byte = @intCast(start + replacement.len),
        .start_point = start_point,
        .old_end_point = old_end_point,
        .new_end_point = advancePoint(start_point, replacement),
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
    var saw_newline = false;
    for (text, 0..) |char, index| {
        if (char == '\n') {
            saw_newline = true;
            point.row += 1;
            line_start = index + 1;
        }
    }
    point.column = @intCast(if (saw_newline)
        text.len - line_start
    else
        start_point.column + text.len);
    return point;
}

//| Tests

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualDeep = testing.expectEqualDeep;
const expectEqualStrings = testing.expectEqualStrings;

test "apply content changes handles whole document replacement" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "old", &.{
        .{ .text_document_content_change_whole_document = .{ .text = "new" } },
    }, .@"utf-8");
    defer applied_change.deinit(testing.allocator);

    try expectEqualStrings("new", applied_change.text.?);
}

test "apply content changes handles ordered partial edits" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "calc ::= expr\n", &.{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 4 },
            },
            .rangeLength = 4,
            .text = "start",
        } },
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 10 },
                .end = .{ .line = 0, .character = 14 },
            },
            .rangeLength = 4,
            .text = "term",
        } },
    }, .@"utf-8");
    defer applied_change.deinit(testing.allocator);

    try expectEqualStrings("start ::= term\n", applied_change.text.?);
}

test "apply content changes uses last full text before trailing partial edits" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "ignored", &.{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 7 },
            },
            .rangeLength = 7,
            .text = "discard",
        } },
        .{ .text_document_content_change_whole_document = .{ .text = "calc ::= expr" } },
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 9 },
                .end = .{ .line = 0, .character = 13 },
            },
            .rangeLength = 4,
            .text = "term",
        } },
    }, .@"utf-8");
    defer applied_change.deinit(testing.allocator);

    try expectEqualStrings("calc ::= term", applied_change.text.?);
}

test "apply content changes handles utf-16 ranges" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "a¶↉🠁", &.{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 2 },
                .end = .{ .line = 0, .character = 3 },
            },
            .rangeLength = 1,
            .text = "!",
        } },
    }, .@"utf-16");
    defer applied_change.deinit(testing.allocator);

    try expectEqualStrings("a¶!🠁", applied_change.text.?);
}

test "input edit handles single-line replacement" {
    const partial = types.TextDocumentContentChangeEvent{ .text_document_content_change_partial = .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 4 },
        },
        .rangeLength = 4,
        .text = "start",
    } };
    const change = partial.text_document_content_change_partial;
    const loc = lsp.offsets.rangeToLoc("calc ::= expr\n", change.range, .@"utf-8");
    const input_edit = inputEditForPartialChange("calc ::= expr\n", change.text, loc.start, loc.end);

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
    const partial = types.TextDocumentContentChangeEvent{ .text_document_content_change_partial = .{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 4 },
        },
        .rangeLength = 0,
        .text = "\n",
    } };
    const change = partial.text_document_content_change_partial;
    const loc = lsp.offsets.rangeToLoc("calc", change.range, .@"utf-8");
    const input_edit = inputEditForPartialChange("calc", change.text, loc.start, loc.end);

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
    const partial = types.TextDocumentContentChangeEvent{ .text_document_content_change_partial = .{
        .range = .{
            .start = .{ .line = 0, .character = 2 },
            .end = .{ .line = 0, .character = 3 },
        },
        .rangeLength = 1,
        .text = "!",
    } };
    const change = partial.text_document_content_change_partial;
    const loc = lsp.offsets.rangeToLoc("a¶↉🠁", change.range, .@"utf-16");
    const input_edit = inputEditForPartialChange("a¶↉🠁", change.text, loc.start, loc.end);

    try expectEqualDeep(ts.InputEdit{
        .start_byte = 3,
        .old_end_byte = 6,
        .new_end_byte = 4,
        .start_point = .{ .row = 0, .column = 3 },
        .old_end_point = .{ .row = 0, .column = 6 },
        .new_end_point = .{ .row = 0, .column = 4 },
    }, input_edit);
}

test "input edit keeps same-line new end after nonzero column insert" {
    const partial = types.TextDocumentContentChangeEvent{ .text_document_content_change_partial = .{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 4 },
        },
        .rangeLength = 0,
        .text = " ::= TOKEN",
    } };
    const change = partial.text_document_content_change_partial;
    const loc = lsp.offsets.rangeToLoc("rule.", change.range, .@"utf-8");
    const input_edit = inputEditForPartialChange("rule.", change.text, loc.start, loc.end);

    try expectEqualDeep(ts.InputEdit{
        .start_byte = 4,
        .old_end_byte = 4,
        .new_end_byte = 14,
        .start_point = .{ .row = 0, .column = 4 },
        .old_end_point = .{ .row = 0, .column = 4 },
        .new_end_point = .{ .row = 0, .column = 14 },
    }, input_edit);
}

test "apply content changes with edits handles multiple ordered partial edits" {
    var applied_change = try applyContentChangesWithEdits(testing.allocator, "calc ::= expr\n", &.{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 4 },
            },
            .rangeLength = 4,
            .text = "start",
        } },
        .{ .text_document_content_change_partial = .{
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
    try expectEqualStrings("start ::= term\n", applied_change.text.?);
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
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 7 },
            },
            .rangeLength = 7,
            .text = "discard",
        } },
        .{ .text_document_content_change_whole_document = .{ .text = "calc ::= expr" } },
        .{ .text_document_content_change_partial = .{
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
    try expectEqualStrings("calc ::= term", applied_change.text.?);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const OOM = std.mem.Allocator.Error || error{TooManySegments};
const lsp = @import("lsp");
const types = lsp.types.flat;
const ts = @import("tree-sitter");
