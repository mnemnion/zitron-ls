//! Directive completion support for Zitron source files.

const DirectiveContext = struct {
    prefix: []const u8,
    replace_range: types.Range,
};

const directives = [_][]const u8{
    "%name",
    "%include",
    "%impl",
    "%code",
    "%token_destructor",
    "%default_destructor",
    "%token_enum",
    "%token_enum_integer",
    "%trace_writer",
    "%syntax_error",
    "%parse_accept",
    "%parse_error_type",
    "%parse_failure",
    "%stack_overflow",
    "%extra_argument",
    "%extra_context",
    "%token_type",
    "%default_type",
    "%stack_size",
    "%start_symbol",
    "%left",
    "%right",
    "%nonassoc",
    "%destructor",
    "%type",
    "%fallback",
    "%token",
    "%wildcard",
    "%token_class",
};

/// Returns directive completions for a line-leading `%...` token at `position`.
pub fn completeDirectives(
    allocator: Allocator,
    source: []const u8,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) OOM!?[]const types.CompletionItem {
    const context = directiveContext(source, position, encoding) orelse return null;

    var match_count: usize = 0;
    for (directives) |directive| {
        if (std.mem.startsWith(u8, directive, context.prefix)) match_count += 1;
    }
    if (match_count == 0) return null;

    const items = try allocator.alloc(types.CompletionItem, match_count);
    var next: usize = 0;
    for (directives) |directive| {
        if (!std.mem.startsWith(u8, directive, context.prefix)) continue;
        items[next] = .{
            .label = directive,
            .kind = .Keyword,
            .textEdit = .{ .text_edit = .{
                .range = context.replace_range,
                .newText = directive,
            } },
        };
        next += 1;
    }

    return items;
}

fn directiveContext(
    source: []const u8,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) ?DirectiveContext {
    const index = lsp.offsets.positionToIndex(source, position, encoding);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..index], '\n')) |newline| newline + 1 else 0;
    const line_end = line_start + (std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start);
    const line = source[line_start..line_end];

    const indent_end = std.mem.indexOfNone(u8, line, " \t") orelse return null;
    if (line[indent_end] != '%') return null;

    const token_start = line_start + indent_end;
    const token_end = directiveTokenEnd(source, token_start);
    if (index < token_start or index > token_end) return null;

    return .{
        .prefix = source[token_start..@min(index, token_end)],
        .replace_range = .{
            .start = lsp.offsets.indexToPosition(source, token_start, encoding),
            .end = lsp.offsets.indexToPosition(source, token_end, encoding),
        },
    };
}

fn directiveTokenEnd(source: []const u8, token_start: usize) usize {
    var index = token_start + 1;
    while (index < source.len and isDirectiveTokenByte(source[index])) : (index += 1) {}
    return index;
}

fn isDirectiveTokenByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

//| Tests

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const testing_allocator = testing.allocator;

fn completionLabels(
    allocator: Allocator,
    items: []const types.CompletionItem,
) OOM![]const []const u8 {
    const labels = try allocator.alloc([]const u8, items.len);
    for (items, labels) |item, *label| {
        label.* = item.label;
    }
    return labels;
}

fn hasCompletionLabel(items: []const types.CompletionItem, label: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.label, label)) return true;
    }
    return false;
}

test "directive completions match %t at the start of a directive line" {
    const items = (try completeDirectives(
        testing_allocator,
        "%t",
        .{ .line = 0, .character = 2 },
        .@"utf-8",
    )).?;
    defer testing_allocator.free(items);
    const labels = try completionLabels(testing_allocator, items);
    defer testing_allocator.free(labels);

    try expectEqual(@as(usize, 8), labels.len);
    try expectEqualStrings("%token_destructor", labels[0]);
    try expectEqualStrings("%token_enum", labels[1]);
    try expectEqualStrings("%token_enum_integer", labels[2]);
    try expectEqualStrings("%trace_writer", labels[3]);
    try expectEqualStrings("%token_type", labels[4]);
    try expectEqualStrings("%type", labels[5]);
    try expectEqualStrings("%token", labels[6]);
    try expectEqualStrings("%token_class", labels[7]);
}

test "directive completions match %incl" {
    const items = (try completeDirectives(
        testing_allocator,
        "%incl",
        .{ .line = 0, .character = 5 },
        .@"utf-8",
    )).?;
    defer testing_allocator.free(items);

    try expectEqual(@as(usize, 1), items.len);
    try expectEqualStrings("%include", items[0].label);
}

test "directive completions return null outside directive context" {
    const result = try completeDirectives(
        testing_allocator,
        "rule ::= TOKEN.\n",
        .{ .line = 0, .character = 4 },
        .@"utf-8",
    );

    try expect(result == null);
}

test "directive completions return null on commented directive text" {
    const result = try completeDirectives(
        testing_allocator,
        "// %token_type \"Token\"\n",
        .{ .line = 0, .character = 9 },
        .@"utf-8",
    );

    try expect(result == null);
}

test "directive completions only inspect the current line inside %code blocks" {
    const source =
        \\%code {
        \\    literal %tok
        \\    %tok
        \\}
    ;

    const non_directive_line = try completeDirectives(
        testing_allocator,
        source,
        .{ .line = 1, .character = 16 },
        .@"utf-8",
    );
    try expect(non_directive_line == null);

    const directive_line = (try completeDirectives(
        testing_allocator,
        source,
        .{ .line = 2, .character = 8 },
        .@"utf-8",
    )).?;
    defer testing_allocator.free(directive_line);
    try expect(directive_line.len >= 1);
    try expect(hasCompletionLabel(directive_line, "%token"));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const lsp = @import("lsp");
const types = lsp.types.flat;
