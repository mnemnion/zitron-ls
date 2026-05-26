const std = @import("std");

pub const Zig = @import("woodward").adapter("zig");

pub const Point = extern struct {
    row: u32,
    column: u32,
};

pub const Range = extern struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

pub const Language = opaque {
    pub fn fromRaw(raw: *const anyopaque) *const Language {
        return @ptrCast(raw);
    }
};

pub const Parser = opaque {
    pub fn create() *Parser {
        return externs.ts_parser_new().?;
    }

    pub fn destroy(parser: *Parser) void {
        externs.ts_parser_delete(parser);
    }

    pub fn setLanguage(parser: *Parser, language: *const Language) error{IncompatibleLanguage}!void {
        if (!externs.ts_parser_set_language(parser, language)) return error.IncompatibleLanguage;
    }

    pub fn parseString(parser: *Parser, string: []const u8, old_tree: ?*const Tree) ?*Tree {
        return externs.ts_parser_parse_string(parser, old_tree, string.ptr, @intCast(string.len));
    }

    const externs = struct {
        extern fn ts_parser_new() ?*Parser;
        extern fn ts_parser_delete(?*Parser) void;
        extern fn ts_parser_set_language(?*Parser, ?*const Language) bool;
        extern fn ts_parser_parse_string(?*Parser, ?*const Tree, [*]const u8, u32) ?*Tree;
    };
};

pub const Tree = opaque {
    pub fn dupe(tree: *const Tree) *Tree {
        return externs.ts_tree_copy(tree).?;
    }

    pub fn destroy(tree: *Tree) void {
        externs.ts_tree_delete(tree);
    }

    pub fn rootNode(tree: *const Tree) Node {
        return externs.ts_tree_root_node(tree);
    }

    pub fn edit(tree: *Tree, input_edit: anytype) void {
        const InputEditType = @TypeOf(input_edit);
        const input_edit_ptr = if (@typeInfo(InputEditType) == .pointer)
            input_edit
        else
            &input_edit;
        externs.ts_tree_edit(tree, input_edit_ptr);
    }

    const externs = struct {
        extern fn ts_tree_copy(?*const Tree) ?*Tree;
        extern fn ts_tree_delete(?*Tree) void;
        extern fn ts_tree_root_node(?*const Tree) Node;
        extern fn ts_tree_edit(?*Tree, *const InputEdit) void;
    };
};

pub const Node = extern struct {
    context: [4]u32,
    id: *const anyopaque,
    tree: *const Tree,

    pub fn eql(a: Node, b: Node) bool {
        return externs.ts_node_eq(a, b);
    }

    pub fn kind(node: Node) []const u8 {
        return std.mem.span(externs.ts_node_type(node));
    }

    pub fn startByte(node: Node) u32 {
        return externs.ts_node_start_byte(node);
    }

    pub fn endByte(node: Node) u32 {
        return externs.ts_node_end_byte(node);
    }

    pub fn startPoint(node: Node) Point {
        return externs.ts_node_start_point(node);
    }

    pub fn endPoint(node: Node) Point {
        return externs.ts_node_end_point(node);
    }

    pub fn range(node: Node) Range {
        return .{
            .start_point = node.startPoint(),
            .end_point = node.endPoint(),
            .start_byte = node.startByte(),
            .end_byte = node.endByte(),
        };
    }

    pub fn isMissing(node: Node) bool {
        return externs.ts_node_is_missing(node);
    }

    pub fn hasError(node: Node) bool {
        return externs.ts_node_has_error(node);
    }

    pub fn walk(node: Node) TreeCursor {
        return TreeCursor.create(node);
    }

    pub fn child(node: Node, index: u32) ?Node {
        return optionalNode(externs.ts_node_child(node, index));
    }

    pub fn childCount(node: Node) u32 {
        return externs.ts_node_child_count(node);
    }

    pub fn namedChild(node: Node, index: u32) ?Node {
        return optionalNode(externs.ts_node_named_child(node, index));
    }

    pub fn namedChildCount(node: Node) u32 {
        return externs.ts_node_named_child_count(node);
    }

    pub fn parent(node: Node) ?Node {
        return optionalNode(externs.ts_node_parent(node));
    }

    pub fn descendantForByteRange(node: Node, start: u32, end: u32) ?Node {
        return optionalNode(externs.ts_node_descendant_for_byte_range(node, start, end));
    }

    pub fn namedDescendantForByteRange(node: Node, start: u32, end: u32) ?Node {
        return optionalNode(externs.ts_node_named_descendant_for_byte_range(node, start, end));
    }

    pub fn descendantForPointRange(node: Node, start: Point, end: Point) ?Node {
        return optionalNode(externs.ts_node_descendant_for_point_range(node, start, end));
    }

    pub fn namedDescendantForPointRange(node: Node, start: Point, end: Point) ?Node {
        return optionalNode(externs.ts_node_named_descendant_for_point_range(node, start, end));
    }

    pub fn nextNamedSibling(node: Node) ?Node {
        return optionalNode(externs.ts_node_next_named_sibling(node));
    }

    pub fn prevNamedSibling(node: Node) ?Node {
        return optionalNode(externs.ts_node_prev_named_sibling(node));
    }

    fn optionalNode(node: Node) ?Node {
        return if (externs.ts_node_is_null(node)) null else node;
    }

    const externs = struct {
        extern fn ts_node_eq(Node, Node) bool;
        extern fn ts_node_type(Node) [*:0]const u8;
        extern fn ts_node_start_byte(Node) u32;
        extern fn ts_node_end_byte(Node) u32;
        extern fn ts_node_start_point(Node) Point;
        extern fn ts_node_end_point(Node) Point;
        extern fn ts_node_is_null(Node) bool;
        extern fn ts_node_is_missing(Node) bool;
        extern fn ts_node_has_error(Node) bool;
        extern fn ts_node_child(Node, u32) Node;
        extern fn ts_node_child_count(Node) u32;
        extern fn ts_node_named_child(Node, u32) Node;
        extern fn ts_node_named_child_count(Node) u32;
        extern fn ts_node_parent(Node) Node;
        extern fn ts_node_descendant_for_byte_range(Node, u32, u32) Node;
        extern fn ts_node_named_descendant_for_byte_range(Node, u32, u32) Node;
        extern fn ts_node_descendant_for_point_range(Node, Point, Point) Node;
        extern fn ts_node_named_descendant_for_point_range(Node, Point, Point) Node;
        extern fn ts_node_next_named_sibling(Node) Node;
        extern fn ts_node_prev_named_sibling(Node) Node;
    };
};

pub const TreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,

    pub fn create(root: Node) TreeCursor {
        return externs.ts_tree_cursor_new(root);
    }

    pub fn destroy(cursor: *TreeCursor) void {
        externs.ts_tree_cursor_delete(cursor);
    }

    pub fn node(cursor: *const TreeCursor) Node {
        return externs.ts_tree_cursor_current_node(cursor);
    }

    pub fn gotoParent(cursor: *TreeCursor) bool {
        return externs.ts_tree_cursor_goto_parent(cursor);
    }

    pub fn gotoNextSibling(cursor: *TreeCursor) bool {
        return externs.ts_tree_cursor_goto_next_sibling(cursor);
    }

    pub fn gotoFirstChild(cursor: *TreeCursor) bool {
        return externs.ts_tree_cursor_goto_first_child(cursor);
    }

    const externs = struct {
        extern fn ts_tree_cursor_new(Node) TreeCursor;
        extern fn ts_tree_cursor_delete(*TreeCursor) void;
        extern fn ts_tree_cursor_current_node(*const TreeCursor) Node;
        extern fn ts_tree_cursor_goto_parent(*TreeCursor) bool;
        extern fn ts_tree_cursor_goto_next_sibling(*TreeCursor) bool;
        extern fn ts_tree_cursor_goto_first_child(*TreeCursor) bool;
    };
};

pub const Query = opaque {
    pub const Error = error{
        InvalidSyntax,
        InvalidNodeType,
        InvalidField,
        InvalidCapture,
        InvalidStructure,
        InvalidLanguage,
    };

    const ErrorValue = enum(c_uint) {
        none,
        syntax,
        node_type,
        field,
        capture,
        structure,
        language,
    };

    pub const Capture = extern struct {
        node: Node,
        index: u32,
    };

    const RawMatch = extern struct {
        id: u32,
        pattern_index: u16,
        capture_count: u16,
        captures: [*]const Capture,

        fn into(raw: RawMatch) Match {
            return .{
                .id = raw.id,
                .pattern_index = raw.pattern_index,
                .captures = raw.captures[0..raw.capture_count],
            };
        }
    };

    pub const Match = struct {
        id: u32,
        pattern_index: u16,
        captures: []const Capture,
    };

    pub fn create(language: *const Language, source: []const u8, error_offset: *u32) Error!*Query {
        var error_value: ErrorValue = .none;
        return externs.ts_query_new(
            language,
            source.ptr,
            @intCast(source.len),
            error_offset,
            &error_value,
        ) orelse switch (error_value) {
            .none => unreachable,
            .syntax => error.InvalidSyntax,
            .node_type => error.InvalidNodeType,
            .field => error.InvalidField,
            .capture => error.InvalidCapture,
            .structure => error.InvalidStructure,
            .language => error.InvalidLanguage,
        };
    }

    pub fn destroy(query: *Query) void {
        externs.ts_query_delete(query);
    }

    pub fn patternCount(query: *const Query) u32 {
        return externs.ts_query_pattern_count(query);
    }

    pub fn captureCount(query: *const Query) u32 {
        return externs.ts_query_capture_count(query);
    }

    pub fn getCaptureNameForId(query: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const name = externs.ts_query_capture_name_for_id(query, id, &len);
        return name[0..len];
    }

    pub fn captureNameForId(query: *const Query, id: u32) ?[]const u8 {
        if (id >= query.captureCount()) return null;
        return query.getCaptureNameForId(id);
    }

    const externs = struct {
        extern fn ts_query_new(?*const Language, [*]const u8, u32, *u32, *ErrorValue) ?*Query;
        extern fn ts_query_delete(?*Query) void;
        extern fn ts_query_pattern_count(?*const Query) u32;
        extern fn ts_query_capture_count(?*const Query) u32;
        extern fn ts_query_capture_name_for_id(?*const Query, u32, *u32) [*]const u8;
    };

    pub const Cursor = opaque {
        pub fn create() *Cursor {
            return CursorExterns.ts_query_cursor_new().?;
        }

        pub fn destroy(cursor: *Cursor) void {
            CursorExterns.ts_query_cursor_delete(cursor);
        }

        pub fn exec(cursor: *Cursor, query: *const Query, node: Node) void {
            CursorExterns.ts_query_cursor_exec(cursor, query, node);
        }

        pub fn nextMatch(cursor: *Cursor) ?Match {
            var raw: RawMatch = undefined;
            return if (CursorExterns.ts_query_cursor_next_match(cursor, &raw)) raw.into() else null;
        }

        const CursorExterns = struct {
            extern fn ts_query_cursor_new() ?*Cursor;
            extern fn ts_query_cursor_delete(?*Cursor) void;
            extern fn ts_query_cursor_exec(?*Cursor, ?*const Query, Node) void;
            extern fn ts_query_cursor_next_match(?*Cursor, *RawMatch) bool;
        };
    };
};

pub const QueryCursor = Query.Cursor;
