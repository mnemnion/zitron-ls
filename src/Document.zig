//! Live document state and document-local operations for Zitron sources.

source: []u8,
version: i32,
parsed: ParseSummary,
tree: *ts.Tree,

const Document = @This();

/// Summary information derived from the current tree-sitter parse.
pub const ParseSummary = struct {
    root_kind: []const u8,
    has_error: bool,
};

/// Semantic categories resolved from the Zitron tags query.
pub const SemanticKind = enum {
    rule_definition,
    rule_reference,
    terminal_reference,
    action_definition,
    action_implementation,
};

/// Semantic information for a resolved grammar or named-action symbol.
pub const SemanticSymbol = struct {
    kind: SemanticKind,
    capture_name: []const u8,
    symbol_name: []const u8,
    name_node: ts.Node,
    semantic_node: ts.Node,
    enclosing_kind: []const u8,
};

/// Symbol categories that can be renamed within Zitron grammar syntax.
pub const RenameKind = enum {
    action,
    alias,
    nonterminal,
    terminal,
};

/// A renameable grammar-side symbol captured from the rename query.
pub const RenameSymbol = struct {
    kind: RenameKind,
    symbol_name: []const u8,
    name_node: ts.Node,
};

/// Result of resolving a symbol lookup at a document position.
pub const Resolution = union(enum) {
    no_match,
    unsupported_zig_code,
    symbol: SemanticSymbol,
};

/// Errors that can occur while parsing or updating a document.
pub const Error = OOM || ts.Query.Error || error{
    IncompatibleLanguage,
    InvalidParams,
    ParseFailed,
    TooManySegments,
};

/// Creates a live document from source text and parses it immediately.
pub fn init(allocator: std.mem.Allocator, version: i32, text: []const u8) Error!Document {
    const parsed = try parseDocument(text);
    errdefer parsed.tree.destroy();

    const text_copy = try allocator.dupe(u8, text);
    errdefer allocator.free(text_copy);

    return .{
        .source = text_copy,
        .version = version,
        .parsed = parsed.summary,
        .tree = parsed.tree,
    };
}

/// Releases the source buffer and parse tree owned by the document.
pub fn deinit(document: *Document, allocator: std.mem.Allocator) void {
    allocator.free(document.source);
    document.tree.destroy();
}

/// Replaces the document contents with a fresh parse of the given text.
pub fn replace(document: *Document, allocator: std.mem.Allocator, version: i32, text: []const u8) Error!void {
    var replacement = try init(allocator, version, text);
    errdefer replacement.deinit(allocator);

    document.deinit(allocator);
    document.* = replacement;
}

/// Applies incremental content changes and reparses against the edited tree.
pub fn updateIncremental(
    document: *Document,
    allocator: std.mem.Allocator,
    version: i32,
    content_changes: []const types.TextDocumentContentChangeEvent,
    offset_encoding: lsp.offsets.Encoding,
) Error!void {
    var applied_change = try diff.applyContentChangesWithEdits(
        allocator,
        document.source,
        content_changes,
        offset_encoding,
    );
    defer applied_change.deinit(allocator);

    const edited_old_tree = document.tree.dupe();
    defer edited_old_tree.destroy();
    for (applied_change.input_edits.items) |input_edit| {
        edited_old_tree.edit(input_edit);
    }

    const parsed = try parseDocumentIncremental(applied_change.text, edited_old_tree);
    errdefer parsed.tree.destroy();

    const text_copy = try allocator.dupe(u8, applied_change.text);
    errdefer allocator.free(text_copy);

    allocator.free(document.source);
    document.tree.destroy();
    document.* = .{
        .source = text_copy,
        .version = version,
        .parsed = parsed.summary,
        .tree = parsed.tree,
    };
}

/// Resolves the best semantic symbol match at the requested position.
pub fn resolveAtPosition(
    document: Document,
    tags_query: *const ts.Query,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) Resolution {
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
    const raw_node = root.descendantForPointRange(point, point) orelse return .no_match;
    if (containsUnsupportedCode(raw_node)) {
        return .unsupported_zig_code;
    }
    const node = root.namedDescendantForPointRange(point, point) orelse return .no_match;
    if (containsUnsupportedCode(node)) {
        return .unsupported_zig_code;
    }

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, root);

    var best: ?SemanticSymbol = null;
    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, source_index, match) orelse continue;
        if (best == null or isBetterMatch(candidate, best.?, source_index)) {
            best = candidate;
        }
    }

    return if (best) |symbol| .{ .symbol = symbol } else .no_match;
}

/// Resolves the best renameable grammar-side symbol at the requested position.
pub fn renameSymbolAtPosition(
    document: Document,
    rename_query: *const ts.Query,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) ?RenameSymbol {
    _ = rename_query;
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
    const raw_node = root.descendantForPointRange(point, point) orelse return null;
    if (containsUnsupportedCode(raw_node)) return null;
    const node = root.namedDescendantForPointRange(point, point) orelse return null;
    if (containsUnsupportedCode(node)) return null;

    const name_node = renameNodeContainingIndex(node, source_index) orelse return null;
    return .{
        .kind = renameKindForNode(name_node) orelse return null,
        .symbol_name = normalizeSymbolName(sliceForNode(document.source, name_node)),
        .name_node = name_node,
    };
}

/// Returns whether the requested position is within embedded Zig source.
pub fn containsZigCodeAtPosition(
    document: Document,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) bool {
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
    const raw_node = root.descendantForPointRange(point, point) orelse return false;
    if (containsUnsupportedCode(raw_node)) return true;
    const node = root.namedDescendantForPointRange(point, point) orelse return false;
    return containsUnsupportedCode(node);
}

/// Finds the definition symbol for a named rule in this document.
pub fn findRuleDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .rule_definition);
}

/// Finds the definition symbol for a named action in this document.
pub fn findActionDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .action_definition);
}

/// Builds same-document text edits for a grammar-side rename.
pub fn renameEdits(
    document: Document,
    rename_query: *const ts.Query,
    arena: std.mem.Allocator,
    symbol: RenameSymbol,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM![]const types.TextEdit {
    if (symbol.kind == .alias) {
        return try aliasRenameEdits(document, arena, symbol, new_name, offset_encoding);
    }

    var edits: std.ArrayList(types.TextEdit) = .empty;
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(rename_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = renameSymbolForMatch(rename_query, document.source, null, match) orelse continue;
        if (candidate.kind != symbol.kind) continue;
        if (!std.mem.eql(u8, candidate.symbol_name, symbol.symbol_name)) continue;

        const start = candidate.name_node.startByte();
        const gop = try seen_starts.getOrPut(arena, start);
        if (gop.found_existing) continue;

        try edits.append(arena, .{
            .range = renameRangeFromNode(document.source, candidate.name_node, offset_encoding),
            .newText = new_name,
        });
    }

    return try edits.toOwnedSlice(arena);
}

/// Returns the embedded Zig code ranges that belong to the selected alias rename.
pub fn aliasCodeBlockRangesForRename(
    document: Document,
    arena: std.mem.Allocator,
    symbol: RenameSymbol,
) OOM![]const ts.Range {
    if (symbol.kind != .alias) return &.{};

    var scope = AliasRenameScope{};
    defer scope.deinit(arena);
    try scope.initForSymbol(arena, document.source, symbol.name_node);

    var ranges: std.ArrayList(ts.Range) = .empty;
    errdefer ranges.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);

    try collectAliasCodeBlockRanges(document.source, &scope, arena, &ranges, &seen_starts);
    return try ranges.toOwnedSlice(arena);
}

/// Builds text edits for alias-overwrite marker comments in scoped code blocks.
pub fn aliasMagicCommentEditsForRename(
    document: Document,
    arena: std.mem.Allocator,
    symbol: RenameSymbol,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM![]const types.TextEdit {
    if (symbol.kind != .alias) return &.{};

    var scope = AliasRenameScope{};
    defer scope.deinit(arena);
    try scope.initForSymbol(arena, document.source, symbol.name_node);

    var pairs: std.ArrayList(MagicCommentPair) = .empty;
    errdefer pairs.deinit(arena);
    try collectMagicCommentPairs(document.source, &scope, symbol.symbol_name, arena, &pairs);
    if (pairs.items.len == 0) return &.{};

    const code_ranges = try document.aliasCodeBlockRangesForRename(arena, symbol);
    var edits: std.ArrayList(types.TextEdit) = .empty;
    errdefer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);

    for (pairs.items) |pair| {
        const old_comment = try std.fmt.allocPrint(arena, "// {s}-overwrites-{s}\n", .{
            pair.lhs_alias,
            pair.rhs_alias,
        });
        const new_comment = try std.fmt.allocPrint(arena, "// {s}-overwrites-{s}\n", .{
            if (std.mem.eql(u8, pair.lhs_alias, symbol.symbol_name)) new_name else pair.lhs_alias,
            if (std.mem.eql(u8, pair.rhs_alias, symbol.symbol_name)) new_name else pair.rhs_alias,
        });

        for (code_ranges) |range| {
            var cursor: usize = range.start_byte;
            while (std.mem.indexOf(u8, document.source[cursor..range.end_byte], old_comment)) |relative| {
                const start = cursor + relative;
                const end = start + old_comment.len;
                const gop = try seen_starts.getOrPut(arena, start);
                if (!gop.found_existing) {
                    try edits.append(arena, .{
                        .range = lsp.offsets.locToRange(document.source, .{
                            .start = start,
                            .end = end,
                        }, offset_encoding),
                        .newText = new_comment,
                    });
                }
                cursor = end;
            }
        }
    }

    return try edits.toOwnedSlice(arena);
}

/// Collects same-document references for the resolved semantic symbol.
pub fn findReferences(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    uri: []const u8,
    symbol: SemanticSymbol,
    include_declaration: bool,
    offset_encoding: lsp.offsets.Encoding,
) OOM!lsp.ResultType("textDocument/references") {
    var references: std.ArrayList(types.Location) = .empty;

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, null, match) orelse continue;
        if (!std.mem.eql(u8, candidate.symbol_name, symbol.symbol_name)) continue;

        switch (symbol.kind) {
            .rule_definition, .rule_reference => {
                if (candidate.kind == .rule_reference) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                    continue;
                }

                if (include_declaration and candidate.kind == .rule_definition) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                }
            },
            .terminal_reference => {
                if (candidate.kind == .terminal_reference) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                }
            },
            .action_definition, .action_implementation => {
                if (candidate.kind == .action_definition or candidate.kind == .action_implementation) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                }
            },
        }
    }

    return if (references.items.len == 0) null else try references.toOwnedSlice(arena);
}

/// Collects document-local symbols for editor outlines and symbol pickers.
pub fn documentSymbols(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    offset_encoding: lsp.offsets.Encoding,
) OOM![]const types.DocumentSymbol {
    var symbols: std.ArrayList(types.DocumentSymbol) = .empty;

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, null, match) orelse continue;
        if (candidate.kind == .rule_reference or candidate.kind == .terminal_reference) continue;

        try symbols.append(arena, .{
            .name = candidate.symbol_name,
            .detail = documentSymbolDetail(candidate.kind),
            .kind = documentSymbolKind(candidate.kind),
            .range = rangeFromNode(document.source, candidate.semantic_node, offset_encoding),
            .selectionRange = rangeFromNode(document.source, candidate.name_node, offset_encoding),
        });
    }

    return try symbols.toOwnedSlice(arena);
}

/// Builds an LSP location for the given syntax node in this document.
pub fn locationForNode(
    document: Document,
    uri: []const u8,
    node: ts.Node,
    offset_encoding: lsp.offsets.Encoding,
) types.Location {
    return .{
        .uri = uri,
        .range = rangeFromNode(document.source, node, offset_encoding),
    };
}

fn findDefinition(
    document: Document,
    tags_query: *const ts.Query,
    symbol_name: []const u8,
    kind: SemanticKind,
) ?SemanticSymbol {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, null, match) orelse continue;
        if (candidate.kind != kind) continue;
        if (std.mem.eql(u8, candidate.symbol_name, symbol_name)) return candidate;
    }

    return null;
}

fn documentSymbolKind(kind: SemanticKind) types.SymbolKind {
    return switch (kind) {
        .rule_definition => .Class,
        .rule_reference => .Class,
        .terminal_reference => .EnumMember,
        .action_definition => .Interface,
        .action_implementation => .Function,
    };
}

fn documentSymbolDetail(kind: SemanticKind) []const u8 {
    return switch (kind) {
        .rule_definition => "rule",
        .rule_reference => "rule reference",
        .terminal_reference => "terminal reference",
        .action_definition => "named action",
        .action_implementation => "named action implementation",
    };
}

fn parseDocument(source: []const u8) Error!ParsedDocument {
    return parseDocumentIncremental(source, null);
}

fn parseDocumentIncremental(source: []const u8, old_tree: ?*const ts.Tree) Error!ParsedDocument {
    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(zitronLanguage());

    const tree = parser.parseString(source, old_tree) orelse return error.ParseFailed;
    const root = tree.rootNode();
    return .{
        .summary = .{
            .root_kind = root.kind(),
            .has_error = root.hasError(),
        },
        .tree = tree,
    };
}

fn semanticSymbolForMatch(
    query: *const ts.Query,
    source: []const u8,
    source_index: ?usize,
    match: ts.Query.Match,
) ?SemanticSymbol {
    var semantic_capture_name: ?[]const u8 = null;
    var semantic_node: ?ts.Node = null;
    var name_node: ?ts.Node = null;

    for (match.captures) |capture| {
        const capture_name = query.captureNameForId(capture.index) orelse continue;
        if (std.mem.eql(u8, capture_name, "name")) {
            if (source_index) |index| {
                if (nodeContainsIndex(capture.node, index)) {
                    name_node = capture.node;
                }
            } else if (name_node == null) {
                name_node = capture.node;
            }
            continue;
        }

        if (semanticKindForCaptureName(capture_name)) |_| {
            semantic_capture_name = capture_name;
            semantic_node = capture.node;
        }
    }

    const resolved_name_node = name_node orelse return null;
    const resolved_semantic_name = semantic_capture_name orelse return null;
    const resolved_semantic_node = semantic_node orelse return null;

    return .{
        .kind = semanticKindForCaptureName(resolved_semantic_name).?,
        .capture_name = resolved_semantic_name,
        .symbol_name = normalizeSymbolName(sliceForNode(source, resolved_name_node)),
        .name_node = resolved_name_node,
        .semantic_node = resolved_semantic_node,
        .enclosing_kind = resolved_semantic_node.kind(),
    };
}

fn renameSymbolForMatch(
    query: *const ts.Query,
    source: []const u8,
    source_index: ?usize,
    match: ts.Query.Match,
) ?RenameSymbol {
    for (match.captures) |capture| {
        const capture_name = query.captureNameForId(capture.index) orelse continue;
        if (!std.mem.eql(u8, capture_name, "name")) continue;
        if (source_index) |index| {
            if (!nodeContainsIndex(capture.node, index)) continue;
        }
        return .{
            .kind = renameKindForNode(capture.node) orelse return null,
            .symbol_name = normalizeSymbolName(sliceForNode(source, capture.node)),
            .name_node = capture.node,
        };
    }

    return null;
}

fn semanticKindForCaptureName(capture_name: []const u8) ?SemanticKind {
    if (std.mem.eql(u8, capture_name, "definition.class")) return .rule_definition;
    if (std.mem.eql(u8, capture_name, "reference.class")) return .rule_reference;
    if (std.mem.eql(u8, capture_name, "reference.enum")) return .terminal_reference;
    if (std.mem.eql(u8, capture_name, "definition.interface")) return .action_definition;
    if (std.mem.eql(u8, capture_name, "reference.implementation")) return .action_implementation;
    return null;
}

fn renameKindForNode(node: ts.Node) ?RenameKind {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "action_name")) return .action;
    if (std.mem.eql(u8, kind, "rule_alias")) return .alias;
    if (std.mem.eql(u8, kind, "nonterminal")) return .nonterminal;
    if (std.mem.eql(u8, kind, "terminal")) return .terminal;
    return null;
}

fn renameNodeContainingIndex(node: ts.Node, source_index: usize) ?ts.Node {
    var cursor = node;
    while (true) {
        if (nodeContainsIndex(cursor, source_index) and renameKindForNode(cursor) != null) {
            return cursor;
        }
        cursor = cursor.parent() orelse return null;
    }
}

const AliasRenameScope = struct {
    rule_starts: std.AutoHashMapUnmanaged(usize, void) = .empty,
    directive_starts: std.AutoHashMapUnmanaged(usize, void) = .empty,
    rules: std.ArrayList(ts.Node) = .empty,
    impl_directives: std.ArrayList(ts.Node) = .empty,
    action_names: std.ArrayList([]const u8) = .empty,

    fn deinit(scope: *AliasRenameScope, allocator: std.mem.Allocator) void {
        scope.rule_starts.deinit(allocator);
        scope.directive_starts.deinit(allocator);
        scope.rules.deinit(allocator);
        scope.impl_directives.deinit(allocator);
        scope.action_names.deinit(allocator);
        scope.* = .{};
    }

    fn initForSymbol(
        scope: *AliasRenameScope,
        allocator: std.mem.Allocator,
        source: []const u8,
        alias_node: ts.Node,
    ) OOM!void {
        const root = alias_node.tree.rootNode();
        if (ancestorOfKind(alias_node, "named_action")) |action| {
            if (actionNameForNamedAction(source, action)) |action_name| {
                try scope.addActionName(allocator, action_name);
                try collectRulesForAction(source, root, action_name, allocator, scope);
                if (isFirstActionAlias(action, alias_node)) {
                    try collectDittoRunsForAction(allocator, source, root, action_name, scope);
                }
            }
        } else if (containingRule(alias_node)) |rule| {
            try scope.addRule(allocator, rule);
            try collectActionNamesInNode(rule, source, allocator, scope);
            if (std.mem.eql(u8, rule.kind(), "grammar_rule") and isLhsAlias(rule, alias_node)) {
                try collectDittoRunAliases(allocator, source, rule, scope);
            }
        }

        var index: usize = 0;
        while (index < scope.action_names.items.len) : (index += 1) {
            try collectRulesForAction(source, root, scope.action_names.items[index], allocator, scope);
        }
        index = 0;
        while (index < scope.action_names.items.len) : (index += 1) {
            try collectImplDirectivesForAction(root, source, scope.action_names.items[index], allocator, scope);
        }
    }

    fn addRule(scope: *AliasRenameScope, allocator: std.mem.Allocator, rule: ts.Node) OOM!void {
        const gop = try scope.rule_starts.getOrPut(allocator, rule.startByte());
        if (!gop.found_existing) try scope.rules.append(allocator, rule);
    }

    fn addImplDirective(scope: *AliasRenameScope, allocator: std.mem.Allocator, directive: ts.Node) OOM!void {
        const gop = try scope.directive_starts.getOrPut(allocator, directive.startByte());
        if (!gop.found_existing) try scope.impl_directives.append(allocator, directive);
    }

    fn addActionName(scope: *AliasRenameScope, allocator: std.mem.Allocator, action_name: []const u8) OOM!void {
        if (containsSlice(scope.action_names.items, action_name)) return;
        try scope.action_names.append(allocator, action_name);
    }

    fn hasRule(scope: *const AliasRenameScope, rule: ts.Node) bool {
        return scope.rule_starts.contains(rule.startByte());
    }

    fn hasActionName(scope: *const AliasRenameScope, action_name: []const u8) bool {
        return containsSlice(scope.action_names.items, action_name);
    }
};

fn aliasRenameEdits(
    document: Document,
    arena: std.mem.Allocator,
    symbol: RenameSymbol,
    new_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM![]const types.TextEdit {
    var scope = AliasRenameScope{};
    defer scope.deinit(arena);
    try scope.initForSymbol(arena, document.source, symbol.name_node);

    var edits: std.ArrayList(types.TextEdit) = .empty;
    errdefer edits.deinit(arena);
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);

    for (scope.rules.items) |rule| {
        try collectAliasRenameEdits(
            rule,
            document.source,
            symbol.symbol_name,
            new_name,
            arena,
            &edits,
            &seen_starts,
            offset_encoding,
        );
    }
    for (scope.impl_directives.items) |directive| {
        try collectAliasRenameEdits(
            directive,
            document.source,
            symbol.symbol_name,
            new_name,
            arena,
            &edits,
            &seen_starts,
            offset_encoding,
        );
    }
    return try edits.toOwnedSlice(arena);
}

fn collectAliasRenameEdits(
    node: ts.Node,
    source: []const u8,
    alias_name: []const u8,
    new_name: []const u8,
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    if (std.mem.eql(u8, node.kind(), "rule_alias") and
        std.mem.eql(u8, sliceForNode(source, node), alias_name))
    {
        try appendRenameEdit(source, node, new_name, arena, edits, seen_starts, offset_encoding);
    }

    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        try collectAliasRenameEdits(
            node.namedChild(index).?,
            source,
            alias_name,
            new_name,
            arena,
            edits,
            seen_starts,
            offset_encoding,
        );
    }
}

fn appendRenameEdit(
    source: []const u8,
    node: ts.Node,
    new_name: []const u8,
    arena: std.mem.Allocator,
    edits: *std.ArrayList(types.TextEdit),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    offset_encoding: lsp.offsets.Encoding,
) OOM!void {
    const start = node.startByte();
    const gop = try seen_starts.getOrPut(arena, start);
    if (gop.found_existing) return;

    try edits.append(arena, .{
        .range = rangeFromNode(source, node, offset_encoding),
        .newText = new_name,
    });
}

fn collectAliasCodeBlockRanges(
    source: []const u8,
    scope: *const AliasRenameScope,
    arena: std.mem.Allocator,
    ranges: *std.ArrayList(ts.Range),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
) OOM!void {
    for (scope.rules.items) |rule| {
        if (zigCodeRangeInNode(rule)) |range| {
            try appendCodeRange(arena, ranges, seen_starts, range);
        }
    }
    for (scope.impl_directives.items) |directive| {
        if (implActionNameInDirective(source, directive)) |action| {
            if (!scope.hasActionName(action)) continue;
        } else continue;
        if (zigCodeRangeInNode(directive)) |range| {
            try appendCodeRange(arena, ranges, seen_starts, range);
        }
    }
}

fn appendCodeRange(
    arena: std.mem.Allocator,
    ranges: *std.ArrayList(ts.Range),
    seen_starts: *std.AutoHashMapUnmanaged(usize, void),
    range: ts.Range,
) OOM!void {
    const gop = try seen_starts.getOrPut(arena, range.start_byte);
    if (gop.found_existing) return;
    try ranges.append(arena, range);
}

fn collectRulesForAction(
    source: []const u8,
    root: ts.Node,
    action_name: []const u8,
    allocator: std.mem.Allocator,
    scope: *AliasRenameScope,
) OOM!void {
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = root.namedChild(index).?;
        if (isRuleNode(child) and ruleContainsActionName(child, source, action_name)) {
            try scope.addRule(allocator, child);
        }
    }
}

fn collectImplDirectivesForAction(
    root: ts.Node,
    source: []const u8,
    action_name: []const u8,
    allocator: std.mem.Allocator,
    scope: *AliasRenameScope,
) OOM!void {
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = root.namedChild(index).?;
        if (!std.mem.eql(u8, child.kind(), "directive")) continue;
        const impl_action_name = implActionNameInDirective(source, child) orelse continue;
        if (std.mem.eql(u8, impl_action_name, action_name)) {
            try scope.addImplDirective(allocator, child);
        }
    }
}

fn collectDittoRunAliases(
    allocator: std.mem.Allocator,
    source: []const u8,
    master_rule: ts.Node,
    scope: *AliasRenameScope,
) OOM!void {
    try scope.addRule(allocator, master_rule);
    try collectActionNamesInNode(master_rule, source, allocator, scope);

    var maybe_sibling = master_rule.nextNamedSibling();
    while (maybe_sibling) |sibling| : (maybe_sibling = sibling.nextNamedSibling()) {
        const kind = sibling.kind();
        if (std.mem.eql(u8, kind, "ditto_rule")) {
            try scope.addRule(allocator, sibling);
            try collectActionNamesInNode(sibling, source, allocator, scope);
            continue;
        }
        if (std.mem.eql(u8, kind, "grammar_rule")) return;
    }
}

fn collectDittoRunsForAction(
    allocator: std.mem.Allocator,
    source: []const u8,
    root: ts.Node,
    action_name: []const u8,
    scope: *AliasRenameScope,
) OOM!void {
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = root.namedChild(index).?;
        if (isRuleNode(child) and ruleContainsActionName(child, source, action_name)) {
            const master = masterRuleForDittoRun(child) orelse continue;
            try collectDittoRunAliases(allocator, source, master, scope);
        }
    }
}

fn collectActionNamesInNode(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    scope: *AliasRenameScope,
) OOM!void {
    if (std.mem.eql(u8, node.kind(), "named_action")) {
        if (actionNameForNamedAction(source, node)) |action_name| {
            try scope.addActionName(allocator, action_name);
        }
    }

    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        try collectActionNamesInNode(node.namedChild(index).?, source, allocator, scope);
    }
}

fn ruleContainsActionName(node: ts.Node, source: []const u8, action_name: []const u8) bool {
    if (std.mem.eql(u8, node.kind(), "named_action")) {
        if (actionNameForNamedAction(source, node)) |candidate| {
            return std.mem.eql(u8, candidate, action_name);
        }
    }

    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        if (ruleContainsActionName(node.namedChild(index).?, source, action_name)) return true;
    }
    return false;
}

fn implActionNameInDirective(source: []const u8, node: ts.Node) ?[]const u8 {
    if (!hasDirectChildOfKind(node, "impl_name")) return null;
    const action = firstNamedChildOfKind(node, "named_action") orelse return null;
    return actionNameForNamedAction(source, action);
}

const MagicCommentPair = struct {
    lhs_alias: []const u8,
    rhs_alias: []const u8,
};

fn collectMagicCommentPairs(
    source: []const u8,
    scope: *const AliasRenameScope,
    alias_name: []const u8,
    allocator: std.mem.Allocator,
    pairs: *std.ArrayList(MagicCommentPair),
) OOM!void {
    for (scope.rules.items) |rule| {
        if (std.mem.eql(u8, rule.kind(), "grammar_rule")) {
            if (magicCommentPairFromGrammarRule(source, rule, alias_name)) |pair| {
                try appendMagicCommentPair(allocator, pairs, pair);
            }
        }
        if (firstNamedChildOfKind(rule, "named_action")) |action| {
            if (magicCommentPairFromNamedAction(source, action, alias_name)) |pair| {
                try appendMagicCommentPair(allocator, pairs, pair);
            }
        }
    }
    for (scope.impl_directives.items) |directive| {
        if (implActionNameInDirective(source, directive)) |action_name| {
            if (!scope.hasActionName(action_name)) continue;
        } else continue;
        const action = firstNamedChildOfKind(directive, "named_action") orelse continue;
        if (magicCommentPairFromNamedAction(source, action, alias_name)) |pair| {
            try appendMagicCommentPair(allocator, pairs, pair);
        }
    }
}

fn magicCommentPairFromGrammarRule(
    source: []const u8,
    rule: ts.Node,
    alias_name: []const u8,
) ?MagicCommentPair {
    const lhs_alias = lhsAliasForRule(rule);
    const rhs_alias = firstRhsAliasForRule(rule);

    if (lhs_alias) |lhs| {
        if (rhs_alias) |rhs| {
            if (std.mem.eql(u8, sliceForNode(source, lhs), alias_name) or
                std.mem.eql(u8, sliceForNode(source, rhs), alias_name))
            {
                return .{
                    .lhs_alias = sliceForNode(source, lhs),
                    .rhs_alias = sliceForNode(source, rhs),
                };
            }
        }
    }
    return null;
}

fn magicCommentPairFromNamedAction(
    source: []const u8,
    action: ts.Node,
    alias_name: []const u8,
) ?MagicCommentPair {
    const lhs_alias = actionAliasNodeAt(action, 0) orelse return null;
    const rhs_alias = actionAliasNodeAt(action, 1) orelse return null;
    if (!std.mem.eql(u8, sliceForNode(source, lhs_alias), alias_name) and
        !std.mem.eql(u8, sliceForNode(source, rhs_alias), alias_name))
    {
        return null;
    }
    return .{
        .lhs_alias = sliceForNode(source, lhs_alias),
        .rhs_alias = sliceForNode(source, rhs_alias),
    };
}

fn appendMagicCommentPair(
    allocator: std.mem.Allocator,
    pairs: *std.ArrayList(MagicCommentPair),
    pair: MagicCommentPair,
) OOM!void {
    for (pairs.items) |item| {
        if (std.mem.eql(u8, item.lhs_alias, pair.lhs_alias) and
            std.mem.eql(u8, item.rhs_alias, pair.rhs_alias))
        {
            return;
        }
    }
    try pairs.append(allocator, pair);
}

fn lhsAliasForRule(rule: ts.Node) ?ts.Node {
    const lhs = firstNamedChildOfKind(rule, "lhs") orelse return null;
    return firstNamedChildOfKind(lhs, "rule_alias");
}

fn firstRhsAliasForRule(rule: ts.Node) ?ts.Node {
    const rhs = firstNamedChildOfKind(rule, "rhs") orelse return null;
    return firstNamedChildOfKind(rhs, "rule_alias");
}

fn actionAliasNodeAt(action: ts.Node, alias_index: usize) ?ts.Node {
    var found: usize = 0;
    const child_count = action.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = action.namedChild(index).?;
        if (!std.mem.eql(u8, child.kind(), "rule_alias")) continue;
        if (found == alias_index) return child;
        found += 1;
    }
    return null;
}

fn isFirstActionAlias(action: ts.Node, alias_node: ts.Node) bool {
    const first_alias = actionAliasNodeAt(action, 0) orelse return false;
    return sameNode(first_alias, alias_node);
}

fn isLhsAlias(rule: ts.Node, alias_node: ts.Node) bool {
    const lhs_alias = lhsAliasForRule(rule) orelse return false;
    return sameNode(lhs_alias, alias_node);
}

fn masterRuleForDittoRun(rule: ts.Node) ?ts.Node {
    const kind = rule.kind();
    if (std.mem.eql(u8, kind, "grammar_rule")) return rule;
    if (!std.mem.eql(u8, kind, "ditto_rule")) return null;

    var maybe_sibling = rule.prevNamedSibling();
    while (maybe_sibling) |sibling| : (maybe_sibling = sibling.prevNamedSibling()) {
        const sibling_kind = sibling.kind();
        if (std.mem.eql(u8, sibling_kind, "grammar_rule")) return sibling;
    }
    return null;
}

fn sameNode(a: ts.Node, b: ts.Node) bool {
    return a.startByte() == b.startByte() and a.endByte() == b.endByte();
}

fn containsSlice(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn actionNameForNamedAction(source: []const u8, node: ts.Node) ?[]const u8 {
    const action_name = firstNamedChildOfKind(node, "action_name") orelse return null;
    return sliceForNode(source, action_name);
}

fn containingRule(node: ts.Node) ?ts.Node {
    var cursor = node;
    while (true) {
        if (isRuleNode(cursor)) return cursor;
        cursor = cursor.parent() orelse return null;
    }
}

fn ancestorOfKind(node: ts.Node, kind: []const u8) ?ts.Node {
    var cursor = node.parent() orelse return null;
    while (true) {
        if (std.mem.eql(u8, cursor.kind(), kind)) return cursor;
        cursor = cursor.parent() orelse return null;
    }
}

fn isRuleNode(node: ts.Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "grammar_rule") or std.mem.eql(u8, kind, "ditto_rule");
}

fn zigCodeRangeInNode(node: ts.Node) ?ts.Range {
    const code_block = firstNamedChildOfKind(node, "code_block") orelse return null;
    const zig_code = firstNamedChildOfKind(code_block, "zig_code") orelse return null;
    return zig_code.range();
}

fn hasDirectChildOfKind(node: ts.Node, kind: []const u8) bool {
    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = node.namedChild(index).?;
        if (std.mem.eql(u8, child.kind(), kind)) return true;
    }
    return false;
}

fn firstNamedChildOfKind(node: ts.Node, kind: []const u8) ?ts.Node {
    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = node.namedChild(index).?;
        if (std.mem.eql(u8, child.kind(), kind)) return child;
    }
    return null;
}

fn nodeContainsIndex(node: ts.Node, index: usize) bool {
    const start: usize = node.startByte();
    const end: usize = node.endByte();
    return start <= index and index < end;
}

fn isBetterMatch(candidate: SemanticSymbol, current: SemanticSymbol, source_index: usize) bool {
    const candidate_hits_name = nodeContainsIndex(candidate.name_node, source_index);
    const current_hits_name = nodeContainsIndex(current.name_node, source_index);
    if (candidate_hits_name != current_hits_name) return candidate_hits_name;

    const candidate_len = candidate.name_node.endByte() - candidate.name_node.startByte();
    const current_len = current.name_node.endByte() - current.name_node.startByte();
    if (candidate_len != current_len) return candidate_len < current_len;

    const candidate_span = candidate.semantic_node.endByte() - candidate.semantic_node.startByte();
    const current_span = current.semantic_node.endByte() - current.semantic_node.startByte();
    return candidate_span < current_span;
}

fn isBetterRenameMatch(candidate: RenameSymbol, current: RenameSymbol, source_index: usize) bool {
    const candidate_hits_name = nodeContainsIndex(candidate.name_node, source_index);
    const current_hits_name = nodeContainsIndex(current.name_node, source_index);
    if (candidate_hits_name != current_hits_name) return candidate_hits_name;

    const candidate_len = candidate.name_node.endByte() - candidate.name_node.startByte();
    const current_len = current.name_node.endByte() - current.name_node.startByte();
    return candidate_len < current_len;
}

fn containsUnsupportedCode(node: ts.Node) bool {
    var cursor = node;
    while (true) {
        const kind = cursor.kind();
        if (std.mem.eql(u8, kind, "zig_code") or std.mem.eql(u8, kind, "code_block")) {
            return true;
        }
        cursor = cursor.parent() orelse return false;
    }
}

fn sliceForNode(source: []const u8, node: ts.Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn normalizeSymbolName(symbol_name: []const u8) []const u8 {
    const open_paren = std.mem.indexOfScalar(u8, symbol_name, '(') orelse return symbol_name;
    return std.mem.trimEnd(u8, symbol_name[0..open_paren], " \t");
}

fn renameRangeFromNode(source: []const u8, node: ts.Node, offset_encoding: lsp.offsets.Encoding) types.Range {
    const slice = sliceForNode(source, node);
    const open_paren = std.mem.indexOfScalar(u8, slice, '(') orelse {
        return rangeFromNode(source, node, offset_encoding);
    };
    const start = node.startByte();
    return lsp.offsets.locToRange(source, .{
        .start = start,
        .end = start + std.mem.trimEnd(u8, slice[0..open_paren], " \t").len,
    }, offset_encoding);
}

fn tsPointFromIndex(source: []const u8, index: usize) ts.Point {
    const position = lsp.offsets.indexToPosition(source, index, .@"utf-8");
    return .{
        .row = position.line,
        .column = position.character,
    };
}

fn rangeFromNode(source: []const u8, node: ts.Node, offset_encoding: lsp.offsets.Encoding) types.Range {
    return lsp.offsets.locToRange(source, .{
        .start = node.startByte(),
        .end = node.endByte(),
    }, offset_encoding);
}

fn zitronLanguage() *const ts.Language {
    return ts.Language.fromRaw(zitron_grammar.language());
}

const ParsedDocument = struct {
    summary: ParseSummary,
    tree: *ts.Tree,
};

//| Tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

fn byteIndexOf(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!usize {
    return std.mem.indexOf(u8, haystack, needle) orelse error.NeedleNotFound;
}

fn positionOfText(haystack: []const u8, needle: []const u8) error{NeedleNotFound}!types.Position {
    const index = try byteIndexOf(haystack, needle);
    return lsp.offsets.indexToPosition(haystack, index, .@"utf-8");
}

fn compileTagsQuery() ts.Query.Error!*ts.Query {
    var error_offset: u32 = 0;
    return ts.Query.create(zitronLanguage(), tags_query_source, &error_offset);
}

test "init builds expected parse summary" {
    var document = try Document.init(testing_allocator, 1, "rule ::= TOKEN.");
    defer document.deinit(testing_allocator);

    try expectEqual(@as(i32, 1), document.version);
    try expectEqualStrings("source_file", document.parsed.root_kind);
    try expect(!document.parsed.has_error);
}

test "updateIncremental preserves parse correctness" {
    var document = try Document.init(testing_allocator, 1, "rule ::= TOKEN.");
    defer document.deinit(testing_allocator);

    const end_position = lsp.offsets.indexToPosition(document.source, document.source.len, .@"utf-8");
    try document.updateIncremental(
        testing_allocator,
        2,
        &.{
            .{ .text_document_content_change_partial = .{
                .range = .{
                    .start = end_position,
                    .end = end_position,
                },
                .rangeLength = 0,
                .text = "\n",
            } },
        },
        .@"utf-8",
    );

    try expectEqual(@as(i32, 2), document.version);
    try expectEqualStrings("\n", document.source[document.source.len - 1 ..]);
    try expectEqualStrings("source_file", document.parsed.root_kind);
    try expect(!document.parsed.has_error);
}

test "updateIncremental accepts same-line insert after nonzero column" {
    var document = try Document.init(testing_allocator, 1, "rule.");
    defer document.deinit(testing_allocator);

    const insert_position = lsp.offsets.indexToPosition(document.source, 4, .@"utf-8");
    try document.updateIncremental(
        testing_allocator,
        2,
        &.{
            .{ .text_document_content_change_partial = .{
                .range = .{
                    .start = insert_position,
                    .end = insert_position,
                },
                .rangeLength = 0,
                .text = " ::= TOKEN",
            } },
        },
        .@"utf-8",
    );

    try expectEqual(@as(i32, 2), document.version);
    try expectEqualStrings("rule ::= TOKEN.", document.source);
    try expectEqualStrings("source_file", document.parsed.root_kind);
    try expect(!document.parsed.has_error);
}

test "resolution and references work without server" {
    const sample =
        \\calc ::= expr.
        \\expr(A) ::= expr(B) PLUS term(C).
        \\expr(A) ::= term(A).
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    const resolution = document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "calc ::= expr"));
    switch (resolution) {
        .symbol => |symbol| try expectEqual(SemanticKind.rule_definition, symbol.kind),
        else => return error.UnexpectedResolution,
    }

    const symbol = switch (document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "expr(B)"))) {
        .symbol => |resolved| resolved,
        else => return error.UnexpectedResolution,
    };

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const references = (try document.findReferences(
        query,
        arena.allocator(),
        "file:///samples/doc.zy",
        symbol,
        true,
        .@"utf-8",
    )) orelse return error.UnexpectedReferences;
    try expect(references.len >= 2);
}

test "documentSymbols returns local definitions and named action implementations" {
    const sample =
        \\calc ::= expr(A). @on_calc(A)
        \\expr(A) ::= NUMBER(A).
        \\%impl @on_calc(A) { _ = A; }
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const symbols = try document.documentSymbols(query, arena.allocator(), .@"utf-8");
    try expectEqual(@as(usize, 4), symbols.len);

    try expectEqualStrings("calc", symbols[0].name);
    try expectEqual(types.SymbolKind.Class, symbols[0].kind);
    try expectEqualStrings("rule", symbols[0].detail.?);
    try expectEqual(@as(u32, 0), symbols[0].selectionRange.start.line);
    try expectEqual(@as(u32, 0), symbols[0].selectionRange.start.character);

    try expectEqualStrings("@on_calc", symbols[1].name);
    try expectEqual(types.SymbolKind.Interface, symbols[1].kind);

    try expectEqualStrings("expr", symbols[2].name);
    try expectEqual(types.SymbolKind.Class, symbols[2].kind);

    try expectEqualStrings("@on_calc", symbols[3].name);
    try expectEqual(types.SymbolKind.Function, symbols[3].kind);
}

test "classifies zig code positions for middleware routing" {
    const sample =
        \\calc ::= expr(A). { answer = A; }
        \\%code {
        \\const parser_name = "calc";
        \\}
    ;

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    try expect(document.containsZigCodeAtPosition(.@"utf-8", try positionOfText(sample, "answer")));
    try expect(document.containsZigCodeAtPosition(.@"utf-8", try positionOfText(sample, "parser_name")));
    try expect(!document.containsZigCodeAtPosition(.@"utf-8", try positionOfText(sample, "calc ::= expr")));
}

test "resolution chooses discard rule reference instead of leftmost rule" {
    const sample =
        \\pair(P) ::= m_form(K) discard m_form(V).  @on_pair2(P; K, V)
        \\m_form(A) ::= FORM(A).
        \\discard ::= .
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    const resolution = document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "discard"));
    switch (resolution) {
        .symbol => |symbol| {
            try expectEqual(SemanticKind.rule_reference, symbol.kind);
            try expectEqualStrings("discard", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }
}

test "resolution chooses discard after terminal instead of neighbors" {
    const sample =
        \\tagged(F) ::= TAGGED(T) discard t_form(E).  @tagged_form2(F; T, E)
        \\t_form(A) ::= FORM(A).
        \\discard ::= .
    ;
    var query = try compileTagsQuery();
    defer query.destroy();

    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    const resolution = document.resolveAtPosition(query, .@"utf-8", try positionOfText(sample, "discard"));
    switch (resolution) {
        .symbol => |symbol| {
            try expectEqual(SemanticKind.rule_reference, symbol.kind);
            try expectEqualStrings("discard", symbol.symbol_name);
        },
        else => return error.UnexpectedResolution,
    }
}

const std = @import("std");
const OOM = std.mem.Allocator.Error;
const diff = @import("diff.zig");
const lsp = @import("lsp");
const types = lsp.types.flat;
const ts = @import("tree-sitter");
const tags_query_source = @embedFile("zitron-tags-query");
const zitron_grammar = @import("tree_sitter_zitron");
