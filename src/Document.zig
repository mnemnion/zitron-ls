//! Live document state and document-local operations for Zitron sources.

source: []u8,
version: i32,
parsed: ParseSummary,
tree: *ts.Tree,
parser: *ts.Parser,
// Optimistically retained across edits; refreshed when generated Zig no longer contains it.
token_enum_name: ?[]u8,

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
    token_class_definition,
    token_class_reference,
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
    token_class,
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

/// Result of resolving the semantic type assigned to a grammar particle.
pub const TypeDefinitionResolution = union(enum) {
    no_match,
    unsupported_zig_code,
    target: ts.Node,
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
    const parser = ts.Parser.create();
    errdefer parser.destroy();

    try parser.setLanguage(zitronLanguage());

    const parsed = try parseDocument(parser, text);
    errdefer parsed.tree.destroy();

    const text_copy = try allocator.dupe(u8, text);
    errdefer comptime unreachable;

    return .{
        .source = text_copy,
        .version = version,
        .parsed = parsed.summary,
        .tree = parsed.tree,
        .parser = parser,
        .token_enum_name = null,
    };
}

/// Releases the source buffer and parse tree owned by the document.
pub fn deinit(document: *Document, allocator: std.mem.Allocator) void {
    allocator.free(document.source);
    if (document.token_enum_name) |name| allocator.free(name);
    document.tree.destroy();
    document.parser.destroy();
}

/// Replaces the document contents with a fresh parse of the given text.
pub fn replace(document: *Document, allocator: std.mem.Allocator, version: i32, text: []const u8) Error!void {
    const parsed = try parseDocument(document.parser, text);
    errdefer parsed.tree.destroy();

    const text_copy = try allocator.dupe(u8, text);
    errdefer comptime unreachable;

    allocator.free(document.source);
    document.tree.destroy();
    document.source = text_copy;
    document.version = version;
    document.parsed = parsed.summary;
    document.tree = parsed.tree;
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

    const parsed = try parseDocumentIncremental(document.parser, applied_change.text.?, edited_old_tree);
    errdefer parsed.tree.destroy();

    const new_source = applied_change.takeText();
    errdefer allocator.free(new_source);
    errdefer comptime unreachable;

    allocator.free(document.source);
    document.tree.destroy();
    const parser = document.parser;
    const token_enum_name = document.token_enum_name;
    document.* = .{
        .source = new_source,
        .version = version,
        .parsed = parsed.summary,
        .tree = parsed.tree,
        .parser = parser,
        .token_enum_name = token_enum_name,
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

    const selected_nonterminal_name = if (grammarParticleContainingIndex(node, source_index)) |particle|
        if (grammarParticleKind(particle) == .nonterminal)
            normalizeSymbolName(sliceForNode(document.source, particle))
        else
            null
    else
        null;
    var selected_name_is_token_class = false;
    var best: ?SemanticSymbol = null;
    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, match) orelse continue;
        if (candidate.kind == .token_class_definition) {
            if (selected_nonterminal_name) |selected_name| {
                if (std.mem.eql(u8, candidate.symbol_name, selected_name)) {
                    selected_name_is_token_class = true;
                }
            }
        }
        if (!nodeContainsIndex(candidate.name_node, source_index)) continue;
        if (best == null or isBetterMatch(candidate, best.?, source_index)) {
            best = candidate;
        }
    }

    if (best) |*symbol| {
        if (symbol.kind == .rule_reference and selected_name_is_token_class) {
            symbol.kind = .token_class_reference;
        }
    }

    return if (best) |symbol| .{ .symbol = symbol } else .no_match;
}

/// Finds the type or token-class directive to display when hovering a grammar symbol.
pub fn hoverDirectiveForSymbol(document: Document, symbol: SemanticSymbol) ?[]const u8 {
    switch (symbol.kind) {
        .action_definition, .action_implementation => return null,
        else => {},
    }

    var explicit_type_directive: ?[]const u8 = null;
    var default_type_directive: ?[]const u8 = null;
    var token_type_directive: ?[]const u8 = null;
    var token_class_directive: ?[]const u8 = null;

    const root = document.tree.rootNode();
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const directive = root.namedChild(index).?;
        if (!std.mem.eql(u8, directive.kind(), "directive")) continue;

        if (tokenClassNameNode(directive)) |name_node| {
            if (std.mem.eql(u8, symbol.symbol_name, sliceForNode(document.source, name_node))) {
                token_class_directive = sliceForNode(document.source, directive);
            }
        }

        const directive_kind = directiveTypeKind(document.source, directive) orelse continue;
        _ = directiveTypePayloadNode(directive) orelse continue;
        const directive_text = sliceForNode(document.source, directive);
        switch (directive_kind) {
            .symbol_type => {
                const target = directiveNonterminalTypeTarget(document.source, directive) orelse continue;
                if (std.mem.eql(u8, symbol.symbol_name, target)) explicit_type_directive = directive_text;
            },
            .default_type => default_type_directive = directive_text,
            .token_type => token_type_directive = directive_text,
        }
    }

    return switch (symbol.kind) {
        .rule_definition, .rule_reference => explicit_type_directive orelse default_type_directive,
        .token_class_definition, .token_class_reference => token_class_directive,
        .terminal_reference => token_type_directive,
        .action_definition, .action_implementation => unreachable,
    };
}

/// Resolves the best renameable grammar-side symbol at the requested position.
pub fn renameSymbolAtPosition(
    document: Document,
    rename_query: *const ts.Query,
    tags_query: *const ts.Query,
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
    var kind = renameKindForNode(name_node) orelse return null;
    const symbol_name = normalizeSymbolName(sliceForNode(document.source, name_node));
    if (kind == .nonterminal and document.findTokenClassDefinition(tags_query, symbol_name) != null) {
        kind = .token_class;
    }
    return .{
        .kind = kind,
        .symbol_name = symbol_name,
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

/// Finds the directive that assigns the semantic type of the grammar particle at a position.
pub fn typeDefinitionAtPosition(
    document: Document,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) TypeDefinitionResolution {
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
    const raw_node = root.descendantForPointRange(point, point) orelse return .no_match;
    if (containsUnsupportedCode(raw_node)) return .unsupported_zig_code;
    const node = root.namedDescendantForPointRange(point, point) orelse return .no_match;
    if (containsUnsupportedCode(node)) return .unsupported_zig_code;

    const particle = grammarParticleContainingIndex(node, source_index) orelse return .no_match;
    const particle_kind = grammarParticleKind(particle).?;
    const particle_name = sliceForNode(document.source, particle);
    var token_class = false;
    var explicit_type: ?ts.Node = null;
    var default_type: ?ts.Node = null;
    var token_type: ?ts.Node = null;

    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const directive = root.namedChild(index).?;
        if (!std.mem.eql(u8, directive.kind(), "directive")) continue;

        if (particle_kind == .nonterminal) {
            if (tokenClassNameNode(directive)) |name_node| {
                if (std.mem.eql(u8, particle_name, sliceForNode(document.source, name_node))) {
                    token_class = true;
                }
            }
        }

        const payload = directiveTypePayloadNode(directive) orelse continue;

        switch (directiveTypeKind(document.source, directive) orelse continue) {
            .symbol_type => if (particle_kind == .nonterminal and !token_class) {
                const target = directiveNonterminalTypeTargetNode(directive) orelse continue;
                if (std.mem.eql(u8, particle_name, sliceForNode(document.source, target))) {
                    explicit_type = target;
                }
            },
            .default_type => default_type = payload,
            .token_type => token_type = payload,
        }
    }

    return switch (particle_kind) {
        .nonterminal => if (if (token_class) token_type else explicit_type orelse default_type) |directive|
            .{ .target = directive }
        else
            .no_match,
        .terminal, .multiterminal => if (token_type) |directive|
            .{ .target = directive }
        else
            .no_match,
    };
}

/// Shows alias types and named-action signatures using Zig Markdown highlighting.
pub fn typedHoverAtPosition(
    document: Document,
    arena: std.mem.Allocator,
    offset_encoding: lsp.offsets.Encoding,
    position: types.Position,
) OOM!?types.Hover {
    const source = document.source;
    const source_index = lsp.offsets.positionToIndex(source, position, offset_encoding);
    const point = tsPointFromIndex(source, source_index);
    const root = document.tree.rootNode();
    const node = root.namedDescendantForPointRange(point, point) orelse return null;
    const code = if (std.mem.eql(u8, node.kind(), "zig_code")) node else ancestorOfKind(node, "zig_code");
    if (code != null and containingRule(node) == null) {
        const directive = ancestorOfKind(node, "directive") orelse return null;
        if (!hasDirectChildOfKind(directive, "impl_name")) return null;
    }
    const code_alias = if (code) |body| try codeIdentifierAt(source, body, source_index, arena) else null;
    const is_alias = std.mem.eql(u8, node.kind(), "rule_alias");
    if (!is_alias and code_alias == null and !std.mem.eql(u8, node.kind(), "action_name")) return null;
    if (!nodeContainsIndex(node, source_index)) return null;

    var type_table: TypeTable = .empty;
    defer type_table.deinit(arena);
    try collectTypeFacts(source, root, arena, &type_table);
    var aliases: std.ArrayList(AliasTypeFact) = .empty;
    defer aliases.deinit(arena);
    var signatures: ActionSignatureTable = .empty;
    defer signatures.deinit(arena);
    const rule = containingRule(node);
    if (rule) |owner| {
        try collectRuleAliasTypes(source, owner, arena, &type_table, &aliases);
    } else {
        try collectActionSignatures(source, root, arena, &type_table, &signatures);
    }

    if (code_alias) |loc| {
        const name = source[loc.start..loc.end];
        const maybe_type = if (rule != null) blk: {
            for (aliases.items) |fact| {
                if (std.mem.eql(u8, name, fact.alias_name)) break :blk fact.type_value;
            }
            break :blk null;
        } else blk: {
            const directive = ancestorOfKind(node, "directive") orelse return null;
            if (!hasDirectChildOfKind(directive, "impl_name")) return null;
            const action = firstNamedChildOfKind(directive, "named_action") orelse return null;
            const action_name = actionNameForNamedAction(source, action) orelse return null;
            var slot: usize = 0;
            var index: u32 = 0;
            while (index < action.namedChildCount()) : (index += 1) {
                const child = action.namedChild(index).?;
                if (!std.mem.eql(u8, child.kind(), "rule_alias")) continue;
                defer slot += 1;
                if (!std.mem.eql(u8, name, sliceForNode(source, child))) continue;
                const fact = signatures.get(action_name, slot) orelse return null;
                break :blk if (std.mem.eql(u8, name, fact.alias_name)) fact.type_value else null;
            }
            break :blk null;
        };
        const type_value = maybe_type orelse return null;
        return .{
            .contents = .{ .markup_content = .{
                .kind = .markdown,
                .value = try std.fmt.allocPrint(arena, "```zig\n{s}: {s}\n```", .{ name, type_value }),
            } },
            .range = lsp.offsets.locToRange(source, loc, offset_encoding),
        };
    }

    var text: std.Io.Writer.Allocating = .init(arena);
    defer text.deinit();
    text.writer.writeAll("```zig\n") catch return error.OutOfMemory;
    if (ancestorOfKind(node, "named_action")) |action| {
        const action_name = actionNameForNamedAction(source, action) orelse return null;
        var slot: usize = 0;
        var index: u32 = 0;
        while (index < action.childCount()) : (index += 1) {
            const child = action.child(index).?;
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "rule_alias")) {
                const name = sliceForNode(source, child);
                const type_value = if (rule != null) blk: {
                    if (slot >= aliases.items.len) break :blk null;
                    const fact = aliases.items[slot];
                    break :blk if (std.mem.eql(u8, name, fact.alias_name)) fact.type_value else null;
                } else blk: {
                    const fact = signatures.get(action_name, slot) orelse break :blk null;
                    break :blk if (std.mem.eql(u8, name, fact.alias_name)) fact.type_value else null;
                };
                slot += 1;
                if (is_alias and !sameNode(node, child)) continue;
                if (is_alias and type_value == null) return null;
                text.writer.print("{s}: {s}", .{ name, type_value orelse "?" }) catch return error.OutOfMemory;
                if (is_alias) break;
            } else if (!is_alias) {
                if (std.mem.eql(u8, kind, "action_name") or
                    std.mem.eql(u8, kind, "(") or std.mem.eql(u8, kind, ")"))
                {
                    text.writer.writeAll(sliceForNode(source, child)) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, kind, ";") or std.mem.eql(u8, kind, ",")) {
                    text.writer.print("{s} ", .{sliceForNode(source, child)}) catch return error.OutOfMemory;
                }
            }
        }
    } else {
        var low: usize = 0;
        var high = aliases.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (aliases.items[mid].alias_node.startByte() < node.startByte()) low = mid + 1 else high = mid;
        }
        if (low == aliases.items.len or !sameNode(aliases.items[low].alias_node, node)) return null;
        const fact = aliases.items[low];
        text.writer.print("{s}: {s}", .{ fact.alias_name, fact.type_value orelse return null }) catch return error.OutOfMemory;
    }
    text.writer.writeAll("\n```") catch return error.OutOfMemory;
    return .{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = try text.toOwnedSlice() } },
        .range = lsp.offsets.locToRange(source, .{ .start = node.startByte(), .end = node.endByte() }, offset_encoding),
    };
}

/// Builds grammar-side inlay hints for aliases with known Zitron value types.
pub fn inlayHints(
    document: Document,
    arena: std.mem.Allocator,
    range: types.Range,
    offset_encoding: lsp.offsets.Encoding,
) OOM![]const types.InlayHint {
    var type_table: TypeTable = .empty;
    defer type_table.deinit(arena);
    var action_signatures: ActionSignatureTable = .empty;
    defer action_signatures.deinit(arena);

    const root = document.tree.rootNode();
    try collectTypeFacts(document.source, root, arena, &type_table);
    try collectActionSignatures(document.source, root, arena, &type_table, &action_signatures);

    var hints: std.ArrayList(types.InlayHint) = .empty;
    try collectAliasInlayHints(
        document.source,
        root,
        range,
        offset_encoding,
        arena,
        &type_table,
        &action_signatures,
        &hints,
    );
    return try hints.toOwnedSlice(arena);
}

/// Finds the definition symbol for a named rule in this document.
pub fn findRuleDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .rule_definition);
}

/// Finds the defining `%token_class` directive name for a token class.
pub fn findTokenClassDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .token_class_definition);
}

/// Finds the definition symbol for a named action in this document.
pub fn findActionDefinition(document: Document, tags_query: *const ts.Query, symbol_name: []const u8) ?SemanticSymbol {
    return document.findDefinition(tags_query, symbol_name, .action_definition);
}

/// Returns the generated token enum name selected by `%token_enum`.
pub fn tokenEnumName(
    document: *Document,
    allocator: std.mem.Allocator,
    token_enum_query: *const ts.Query,
) OOM![]const u8 {
    return document.token_enum_name orelse try document.refreshTokenEnumName(allocator, token_enum_query);
}

pub fn refreshTokenEnumName(
    document: *Document,
    allocator: std.mem.Allocator,
    token_enum_query: *const ts.Query,
) OOM![]const u8 {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(token_enum_query, document.tree.rootNode());

    var enum_name: []const u8 = "TokenKind";
    while (cursor.nextMatch()) |match| {
        var directive_name: ?[]const u8 = null;
        var candidate_name: ?[]const u8 = null;
        for (match.captures) |capture| {
            const capture_name = token_enum_query.captureNameForId(capture.index) orelse continue;
            if (std.mem.eql(u8, capture_name, "directive"))
                directive_name = sliceForNode(document.source, capture.node)
            else if (std.mem.eql(u8, capture_name, "name"))
                candidate_name = sliceForNode(document.source, capture.node);
        }
        if (directive_name) |directive| {
            if (std.mem.eql(u8, directive, "token_enum")) {
                enum_name = candidate_name orelse continue;
                break;
            }
        }
    }

    const owned_name = try allocator.dupe(u8, enum_name);
    if (document.token_enum_name) |name| allocator.free(name);
    document.token_enum_name = owned_name;
    return owned_name;
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
        if (!renameKindsMatch(symbol.kind, candidate.kind)) continue;
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

    var scope: AliasRenameScope = .empty;
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

    var scope: AliasRenameScope = .empty;
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
    return document.findReferencesForSymbol(
        tags_query,
        arena,
        uri,
        symbol.kind,
        symbol.symbol_name,
        include_declaration,
        offset_encoding,
    );
}

/// Collects same-document terminal references for a terminal identified by Zig analysis.
pub fn findTerminalReferences(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    uri: []const u8,
    terminal_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!lsp.ResultType("textDocument/references") {
    return document.findReferencesForSymbol(
        tags_query,
        arena,
        uri,
        .terminal_reference,
        terminal_name,
        false,
        offset_encoding,
    );
}

fn findReferencesForSymbol(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    uri: []const u8,
    symbol_kind: SemanticKind,
    symbol_name: []const u8,
    include_declaration: bool,
    offset_encoding: lsp.offsets.Encoding,
) OOM!lsp.ResultType("textDocument/references") {
    var references: std.ArrayList(types.Location) = .empty;

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, match) orelse continue;
        if (!std.mem.eql(u8, candidate.symbol_name, symbol_name)) continue;

        switch (symbol_kind) {
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
            .token_class_definition, .token_class_reference => {
                if (candidate.kind == .rule_reference) {
                    try references.append(arena, document.locationForNode(
                        uri,
                        candidate.name_node,
                        offset_encoding,
                    ));
                    continue;
                }

                if (include_declaration and candidate.kind == .token_class_definition) {
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

/// Collects same-document highlights for directive names, grammar symbols, and named actions.
pub fn documentHighlights(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    position: types.Position,
    offset_encoding: lsp.offsets.Encoding,
) OOM!?[]const types.DocumentHighlight {
    const source_index = lsp.offsets.positionToIndex(document.source, position, offset_encoding);
    const point = tsPointFromIndex(document.source, source_index);
    const root = document.tree.rootNode();
    const raw_node = root.descendantForPointRange(point, point) orelse return null;
    if (containsUnsupportedCode(raw_node)) return null;

    if (directiveNameAtIndex(document.source, raw_node, source_index)) |directive_name| {
        return try document.directiveHighlights(arena, directive_name, offset_encoding);
    }

    return switch (document.resolveAtPosition(tags_query, offset_encoding, position)) {
        .no_match, .unsupported_zig_code => null,
        .symbol => |symbol| try document.symbolHighlights(tags_query, arena, symbol, offset_encoding),
    };
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
        const candidate = semanticSymbolForMatch(tags_query, document.source, match) orelse continue;
        if (candidate.kind == .rule_reference or candidate.kind == .token_class_reference or candidate.kind == .terminal_reference) continue;

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

fn directiveHighlights(
    document: Document,
    arena: std.mem.Allocator,
    directive_name: []const u8,
    offset_encoding: lsp.offsets.Encoding,
) OOM!?[]const types.DocumentHighlight {
    var highlights: std.ArrayList(types.DocumentHighlight) = .empty;

    const root = document.tree.rootNode();
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = root.namedChild(index).?;
        if (!std.mem.eql(u8, child.kind(), "directive")) continue;
        const name_node = directiveNameChild(child) orelse continue;
        if (!std.mem.eql(u8, sliceForNode(document.source, name_node), directive_name)) continue;
        try highlights.append(arena, .{
            .range = directiveNameRange(document.source, name_node, offset_encoding),
        });
    }

    return if (highlights.items.len == 0) null else try highlights.toOwnedSlice(arena);
}

fn symbolHighlights(
    document: Document,
    tags_query: *const ts.Query,
    arena: std.mem.Allocator,
    symbol: SemanticSymbol,
    offset_encoding: lsp.offsets.Encoding,
) OOM!?[]const types.DocumentHighlight {
    var highlights: std.ArrayList(types.DocumentHighlight) = .empty;
    var seen_starts: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_starts.deinit(arena);

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(tags_query, document.tree.rootNode());

    while (cursor.nextMatch()) |match| {
        const candidate = semanticSymbolForMatch(tags_query, document.source, match) orelse continue;
        if (!std.mem.eql(u8, candidate.symbol_name, symbol.symbol_name)) continue;
        if (!highlightKindsMatch(symbol.kind, candidate.kind)) continue;

        const start = candidate.name_node.startByte();
        const gop = try seen_starts.getOrPut(arena, start);
        if (gop.found_existing) continue;

        try highlights.append(arena, .{
            .range = rangeFromNode(document.source, candidate.name_node, offset_encoding),
            .kind = highlightKindForSemanticKind(candidate.kind),
        });
    }

    return if (highlights.items.len == 0) null else try highlights.toOwnedSlice(arena);
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
        const candidate = semanticSymbolForMatch(tags_query, document.source, match) orelse continue;
        if (candidate.kind != kind) continue;
        if (std.mem.eql(u8, candidate.symbol_name, symbol_name)) return candidate;
    }

    return null;
}

fn documentSymbolKind(kind: SemanticKind) types.SymbolKind {
    return switch (kind) {
        .rule_definition => .Class,
        .rule_reference => .Class,
        .token_class_definition => .Constant,
        .token_class_reference => .Constant,
        .terminal_reference => .EnumMember,
        .action_definition => .Interface,
        .action_implementation => .Function,
    };
}

fn documentSymbolDetail(kind: SemanticKind) []const u8 {
    return switch (kind) {
        .rule_definition => "rule",
        .rule_reference => "rule reference",
        .token_class_definition => "token class",
        .token_class_reference => "token class reference",
        .terminal_reference => "terminal reference",
        .action_definition => "named action",
        .action_implementation => "named action implementation",
    };
}

fn codeIdentifierAt(source: []const u8, code: ts.Node, index: usize, allocator: std.mem.Allocator) OOM!?lsp.offsets.Loc {
    const text = try allocator.dupeZ(u8, sliceForNode(source, code));
    defer allocator.free(text);
    var tokenizer = std.zig.Tokenizer.init(text);
    const offset = index - code.startByte();
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof or token.loc.start > offset) return null;
        if (token.loc.start <= offset and offset < token.loc.end) {
            if (token.tag != .identifier) return null;
            return .{ .start = code.startByte() + token.loc.start, .end = code.startByte() + token.loc.end };
        }
    }
}

const TypeTable = struct {
    const empty: TypeTable = .{
        .symbol_types = .empty,
        .token_type = null,
        .default_type = "void",
    };

    symbol_types: std.StringHashMapUnmanaged(?[]const u8),
    token_type: ?[]const u8,
    default_type: ?[]const u8,

    fn deinit(table: *TypeTable, allocator: std.mem.Allocator) void {
        table.symbol_types.deinit(allocator);
    }

    fn putSymbolType(table: *TypeTable, allocator: std.mem.Allocator, symbol: []const u8, type_value: ?[]const u8) OOM!void {
        try table.symbol_types.put(allocator, symbol, type_value);
    }

    fn typeForParticle(table: *const TypeTable, source: []const u8, particle: ts.Node) ?[]const u8 {
        if (table.symbol_types.get(sliceForNode(source, particle))) |type_value| return type_value;
        return switch (grammarParticleKind(particle) orelse return null) {
            .nonterminal => table.default_type,
            .terminal, .multiterminal => table.token_type,
        };
    }
};

const GrammarParticleKind = enum {
    nonterminal,
    terminal,
    multiterminal,
};

const DirectiveTypeKind = enum {
    symbol_type,
    token_type,
    default_type,
};

const AliasTypeFact = struct {
    alias_name: []const u8,
    alias_node: ts.Node,
    type_value: ?[]const u8,
};

const ActionAliasType = struct {
    action_name: []const u8,
    slot_index: usize,
    alias_name: []const u8,
    type_value: []const u8,
};

const ActionSignatureTable = struct {
    const empty: ActionSignatureTable = .{ .items = .empty };

    items: std.StringHashMapUnmanaged(std.ArrayList(?ActionAliasType)),

    fn deinit(table: *ActionSignatureTable, allocator: std.mem.Allocator) void {
        var iterator = table.items.valueIterator();
        while (iterator.next()) |slots| slots.deinit(allocator);
        table.items.deinit(allocator);
    }

    fn put(
        table: *ActionSignatureTable,
        allocator: std.mem.Allocator,
        action_name: []const u8,
        slot_index: usize,
        alias_name: []const u8,
        type_value: []const u8,
    ) OOM!void {
        const entry = try table.items.getOrPut(allocator, action_name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const slots = entry.value_ptr;
        if (slots.items.len <= slot_index) {
            const old_len = slots.items.len;
            try slots.resize(allocator, slot_index + 1);
            @memset(slots.items[old_len..], null);
        }
        slots.items[slot_index] = .{
            .action_name = action_name,
            .slot_index = slot_index,
            .alias_name = alias_name,
            .type_value = type_value,
        };
    }

    fn get(table: *const ActionSignatureTable, action_name: []const u8, slot_index: usize) ?ActionAliasType {
        const slots = table.items.get(action_name) orelse return null;
        return if (slot_index < slots.items.len) slots.items[slot_index] else null;
    }
};

fn collectTypeFacts(
    source: []const u8,
    root: ts.Node,
    allocator: std.mem.Allocator,
    type_table: *TypeTable,
) OOM!void {
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const directive = root.namedChild(index).?;
        if (!std.mem.eql(u8, directive.kind(), "directive")) continue;

        const directive_kind = directiveTypeKind(source, directive) orelse continue;
        const type_value = directiveTypePayload(source, directive) orelse continue;
        switch (directive_kind) {
            .symbol_type => {
                const symbol = directiveNonterminalTypeTarget(source, directive) orelse continue;
                try type_table.putSymbolType(allocator, symbol, type_value);
            },
            .token_type => type_table.token_type = type_value,
            .default_type => type_table.default_type = type_value,
        }
    }

    index = 0;
    while (index < child_count) : (index += 1) {
        const directive = root.namedChild(index).?;
        const name_node = tokenClassNameNode(directive) orelse continue;
        try type_table.putSymbolType(allocator, sliceForNode(source, name_node), type_table.token_type);
    }
}

fn collectActionSignatures(
    source: []const u8,
    root: ts.Node,
    allocator: std.mem.Allocator,
    type_table: *const TypeTable,
    action_signatures: *ActionSignatureTable,
) OOM!void {
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const rule = root.namedChild(index).?;
        if (!isRuleNode(rule)) continue;

        var rule_alias_types: std.ArrayList(AliasTypeFact) = .empty;
        defer rule_alias_types.deinit(allocator);
        try collectRuleAliasTypes(source, rule, allocator, type_table, &rule_alias_types);

        const action = firstNamedChildOfKind(rule, "named_action") orelse continue;
        const action_name = actionNameForNamedAction(source, action) orelse continue;

        var slot_index: usize = 0;
        const child_count_action = action.namedChildCount();
        var child_index: u32 = 0;
        while (child_index < child_count_action) : (child_index += 1) {
            const child = action.namedChild(child_index).?;
            if (!std.mem.eql(u8, child.kind(), "rule_alias")) continue;
            defer slot_index += 1;

            if (slot_index >= rule_alias_types.items.len) continue;
            const rule_alias = rule_alias_types.items[slot_index];
            const action_alias = sliceForNode(source, child);
            if (!std.mem.eql(u8, action_alias, rule_alias.alias_name)) continue;

            try action_signatures.put(
                allocator,
                action_name,
                slot_index,
                action_alias,
                rule_alias.type_value orelse continue,
            );
        }
    }
}

fn collectAliasInlayHints(
    source: []const u8,
    root: ts.Node,
    range: types.Range,
    offset_encoding: lsp.offsets.Encoding,
    allocator: std.mem.Allocator,
    type_table: *const TypeTable,
    action_signatures: *const ActionSignatureTable,
    hints: *std.ArrayList(types.InlayHint),
) OOM!void {
    const child_count = root.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = root.namedChild(index).?;
        if (isRuleNode(child)) {
            try appendRuleInlayHints(source, child, range, offset_encoding, allocator, type_table, hints);
        } else if (std.mem.eql(u8, child.kind(), "directive")) {
            try appendImplInlayHints(source, child, range, offset_encoding, allocator, action_signatures, hints);
        }
    }
}

fn appendRuleInlayHints(
    source: []const u8,
    rule: ts.Node,
    range: types.Range,
    offset_encoding: lsp.offsets.Encoding,
    allocator: std.mem.Allocator,
    type_table: *const TypeTable,
    hints: *std.ArrayList(types.InlayHint),
) OOM!void {
    var rule_alias_types: std.ArrayList(AliasTypeFact) = .empty;
    defer rule_alias_types.deinit(allocator);
    try collectRuleAliasTypes(source, rule, allocator, type_table, &rule_alias_types);

    for (rule_alias_types.items) |alias_type| {
        if (alias_type.alias_node.startByte() < rule.startByte()) continue;
        try appendInlayHint(source, alias_type.alias_node, alias_type.type_value orelse continue, range, offset_encoding, allocator, hints);
    }

    const action = firstNamedChildOfKind(rule, "named_action") orelse return;
    var slot_index: usize = 0;
    const child_count = action.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = action.namedChild(index).?;
        if (!std.mem.eql(u8, child.kind(), "rule_alias")) continue;
        defer slot_index += 1;

        if (slot_index >= rule_alias_types.items.len) continue;
        const rule_alias = rule_alias_types.items[slot_index];
        if (!std.mem.eql(u8, sliceForNode(source, child), rule_alias.alias_name)) continue;

        try appendInlayHint(source, child, rule_alias.type_value orelse continue, range, offset_encoding, allocator, hints);
    }
}

fn appendImplInlayHints(
    source: []const u8,
    directive: ts.Node,
    range: types.Range,
    offset_encoding: lsp.offsets.Encoding,
    allocator: std.mem.Allocator,
    action_signatures: *const ActionSignatureTable,
    hints: *std.ArrayList(types.InlayHint),
) OOM!void {
    if (!hasDirectChildOfKind(directive, "impl_name")) return;
    const action = firstNamedChildOfKind(directive, "named_action") orelse return;
    const action_name = actionNameForNamedAction(source, action) orelse return;

    var slot_index: usize = 0;
    const child_count = action.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = action.namedChild(index).?;
        if (!std.mem.eql(u8, child.kind(), "rule_alias")) continue;
        defer slot_index += 1;

        const action_type = action_signatures.get(action_name, slot_index) orelse continue;
        if (!std.mem.eql(u8, sliceForNode(source, child), action_type.alias_name)) continue;

        try appendInlayHint(source, child, action_type.type_value, range, offset_encoding, allocator, hints);
    }
}

fn collectRuleAliasTypes(
    source: []const u8,
    rule: ts.Node,
    allocator: std.mem.Allocator,
    type_table: *const TypeTable,
    alias_types: *std.ArrayList(AliasTypeFact),
) OOM!void {
    if (std.mem.eql(u8, rule.kind(), "ditto_rule")) {
        if (masterRuleForDittoRun(rule)) |master| {
            if (firstNamedChildOfKind(master, "lhs")) |lhs| {
                try collectParticleAliasTypes(source, lhs, allocator, type_table, alias_types);
            }
        }
    }
    const child_count = rule.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = rule.namedChild(index).?;
        const kind = child.kind();
        if (!std.mem.eql(u8, kind, "lhs") and !std.mem.eql(u8, kind, "rhs")) continue;
        try collectParticleAliasTypes(source, child, allocator, type_table, alias_types);
    }
}

fn collectParticleAliasTypes(
    source: []const u8,
    node: ts.Node,
    allocator: std.mem.Allocator,
    type_table: *const TypeTable,
    alias_types: *std.ArrayList(AliasTypeFact),
) OOM!void {
    var pending_type: ?[]const u8 = null;
    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = node.namedChild(index).?;
        if (grammarParticleKind(child) != null) {
            pending_type = type_table.typeForParticle(source, child);
            continue;
        }

        if (!std.mem.eql(u8, child.kind(), "rule_alias")) continue;
        try alias_types.append(allocator, .{
            .alias_name = sliceForNode(source, child),
            .alias_node = child,
            .type_value = pending_type,
        });
        pending_type = null;
    }
}

fn appendInlayHint(
    source: []const u8,
    alias_node: ts.Node,
    type_value: []const u8,
    range: types.Range,
    offset_encoding: lsp.offsets.Encoding,
    allocator: std.mem.Allocator,
    hints: *std.ArrayList(types.InlayHint),
) OOM!void {
    const position = lsp.offsets.indexToPosition(source, alias_node.endByte(), offset_encoding);
    if (!positionInRange(position, range)) return;

    try hints.append(allocator, .{
        .position = position,
        .label = .{ .string = try std.fmt.allocPrint(allocator, ": {s}", .{type_value}) },
        .kind = .Type,
    });
}

fn directiveTypeKind(source: []const u8, directive: ts.Node) ?DirectiveTypeKind {
    const child_count = directive.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = directive.namedChild(index).?;
        if (!isDirectiveNameNode(child)) continue;
        const name = sliceForNode(source, child);
        if (std.mem.eql(u8, name, "type")) return .symbol_type;
        if (std.mem.eql(u8, name, "token_type")) return .token_type;
        if (std.mem.eql(u8, name, "default_type")) return .default_type;
        return null;
    }
    return null;
}

fn directiveNonterminalTypeTarget(source: []const u8, directive: ts.Node) ?[]const u8 {
    return sliceForNode(source, directiveNonterminalTypeTargetNode(directive) orelse return null);
}

fn directiveNonterminalTypeTargetNode(directive: ts.Node) ?ts.Node {
    const child_count = directive.namedChildCount();
    var seen_name = false;
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = directive.namedChild(index).?;
        if (!seen_name) {
            if (isDirectiveNameNode(child)) seen_name = true;
            continue;
        }
        if (grammarParticleKind(child) == .nonterminal) return child;
    }
    return null;
}

fn tokenClassNameNode(directive: ts.Node) ?ts.Node {
    if (!std.mem.eql(u8, directive.kind(), "directive")) return null;
    _ = firstNamedChildOfKind(directive, "arg_directive_name") orelse return null;
    _ = firstNamedChildOfKind(directive, "multiterminal") orelse return null;
    return firstNamedChildOfKind(directive, "nonterminal");
}

fn directiveTypePayload(source: []const u8, directive: ts.Node) ?[]const u8 {
    const leaf = directiveTypePayloadNode(directive) orelse return null;
    const value = sliceForNode(source, leaf);
    if (std.mem.eql(u8, leaf.kind(), "string")) {
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

fn directiveTypePayloadNode(directive: ts.Node) ?ts.Node {
    var maybe_payload: ?ts.Node = null;
    const child_count = directive.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        maybe_payload = directive.namedChild(index).?;
    }

    const payload = maybe_payload orelse return null;
    const leaf = if (std.mem.eql(u8, payload.kind(), "code_block"))
        firstNamedChildOfKind(payload, "zig_code") orelse return null
    else
        payload;

    if (std.mem.eql(u8, leaf.kind(), "zig_code") or
        std.mem.eql(u8, leaf.kind(), "identifier") or
        std.mem.eql(u8, leaf.kind(), "string"))
    {
        return leaf;
    }
    return null;
}

fn isDirectiveNameNode(node: ts.Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "arg_directive_name") or
        std.mem.eql(u8, kind, "directive_name") or
        std.mem.eql(u8, kind, "token_directive_name") or
        std.mem.eql(u8, kind, "bad_directive_name");
}

fn grammarParticleKind(node: ts.Node) ?GrammarParticleKind {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "nonterminal")) return .nonterminal;
    if (std.mem.eql(u8, kind, "terminal")) return .terminal;
    if (std.mem.eql(u8, kind, "multiterminal")) return .multiterminal;
    return null;
}

fn grammarParticleContainingIndex(node: ts.Node, source_index: usize) ?ts.Node {
    var cursor = node;
    while (true) {
        if (nodeContainsIndex(cursor, source_index) and grammarParticleKind(cursor) != null) {
            return cursor;
        }
        cursor = cursor.parent() orelse return null;
    }
}

fn positionInRange(position: types.Position, range: types.Range) bool {
    return !positionLessThan(position, range.start) and positionLessThan(position, range.end);
}

fn positionLessThan(lhs: types.Position, rhs: types.Position) bool {
    return lhs.line < rhs.line or
        (lhs.line == rhs.line and lhs.character < rhs.character);
}

fn parseDocument(parser: *ts.Parser, source: []const u8) Error!ParsedDocument {
    return parseDocumentIncremental(parser, source, null);
}

fn parseDocumentIncremental(parser: *ts.Parser, source: []const u8, old_tree: ?*const ts.Tree) Error!ParsedDocument {
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
    match: ts.Query.Match,
) ?SemanticSymbol {
    var semantic_capture_name: ?[]const u8 = null;
    var semantic_node: ?ts.Node = null;
    var name_node: ?ts.Node = null;

    for (match.captures) |capture| {
        const capture_name = query.captureNameForId(capture.index) orelse continue;
        if (std.mem.eql(u8, capture_name, "name")) {
            if (name_node == null) name_node = capture.node;
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
    if (std.mem.eql(u8, capture_name, "definition.constant")) return .token_class_definition;
    if (std.mem.eql(u8, capture_name, "reference.class")) return .rule_reference;
    if (std.mem.eql(u8, capture_name, "reference.enum")) return .terminal_reference;
    if (std.mem.eql(u8, capture_name, "definition.interface")) return .action_definition;
    if (std.mem.eql(u8, capture_name, "reference.implementation")) return .action_implementation;
    return null;
}

fn highlightKindsMatch(selected: SemanticKind, candidate: SemanticKind) bool {
    return switch (selected) {
        .rule_definition, .rule_reference => candidate == .rule_definition or candidate == .rule_reference,
        .token_class_definition, .token_class_reference => candidate == .token_class_definition or candidate == .rule_reference,
        .terminal_reference => candidate == .terminal_reference,
        .action_definition, .action_implementation => candidate == .action_definition or candidate == .action_implementation,
    };
}

fn highlightKindForSemanticKind(kind: SemanticKind) ?types.DocumentHighlight.Kind {
    return switch (kind) {
        .rule_definition => .Write,
        .rule_reference => .Read,
        .token_class_definition => .Write,
        .token_class_reference => .Read,
        .terminal_reference, .action_definition, .action_implementation => null,
    };
}

fn renameKindForNode(node: ts.Node) ?RenameKind {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "action_name")) return .action;
    if (std.mem.eql(u8, kind, "rule_alias")) return .alias;
    if (std.mem.eql(u8, kind, "nonterminal")) return .nonterminal;
    if (std.mem.eql(u8, kind, "terminal")) return .terminal;
    return null;
}

fn renameKindsMatch(selected: RenameKind, candidate: RenameKind) bool {
    return selected == candidate or
        (selected == .token_class and candidate == .nonterminal);
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
    const empty: AliasRenameScope = .{
        .rule_starts = .empty,
        .directive_starts = .empty,
        .rules = .empty,
        .impl_directives = .empty,
        .action_names = .empty,
    };

    rule_starts: std.AutoHashMapUnmanaged(usize, void),
    directive_starts: std.AutoHashMapUnmanaged(usize, void),
    rules: std.ArrayList(ts.Node),
    impl_directives: std.ArrayList(ts.Node),
    action_names: std.ArrayList([]const u8),

    fn deinit(scope: *AliasRenameScope, allocator: std.mem.Allocator) void {
        scope.rule_starts.deinit(allocator);
        scope.directive_starts.deinit(allocator);
        scope.rules.deinit(allocator);
        scope.impl_directives.deinit(allocator);
        scope.action_names.deinit(allocator);
        scope.* = .empty;
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
    var scope: AliasRenameScope = .empty;
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

fn directiveNameAtIndex(source: []const u8, node: ts.Node, index: usize) ?[]const u8 {
    const directive = nodeOrAncestorOfKind(node, "directive") orelse return null;
    const name_node = directiveNameChild(directive) orelse return null;
    if (!rangeContainsIndex(directiveNameByteRange(source, name_node), index)) return null;
    return sliceForNode(source, name_node);
}

fn directiveNameChild(directive: ts.Node) ?ts.Node {
    const child_count = directive.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = directive.namedChild(index).?;
        if (isDirectiveNameNode(child)) return child;
    }
    return null;
}

fn directiveNameRange(source: []const u8, node: ts.Node, offset_encoding: lsp.offsets.Encoding) types.Range {
    const range = directiveNameByteRange(source, node);
    return lsp.offsets.locToRange(source, .{
        .start = range.start,
        .end = range.end,
    }, offset_encoding);
}

fn directiveNameByteRange(source: []const u8, node: ts.Node) struct { start: usize, end: usize } {
    var start: usize = node.startByte();
    if (start > 0 and source[start - 1] == '%') start -= 1;
    return .{
        .start = start,
        .end = node.endByte(),
    };
}

fn nodeOrAncestorOfKind(node: ts.Node, kind: []const u8) ?ts.Node {
    var cursor = node;
    while (true) {
        if (std.mem.eql(u8, cursor.kind(), kind)) return cursor;
        cursor = cursor.parent() orelse return null;
    }
}

fn nodeContainsIndex(node: ts.Node, index: usize) bool {
    const start: usize = node.startByte();
    const end: usize = node.endByte();
    return start <= index and index < end;
}

fn rangeContainsIndex(range: anytype, index: usize) bool {
    return range.start <= index and index < range.end;
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

fn expectInlayHintAfter(
    source: []const u8,
    hints: []const types.InlayHint,
    start_index: usize,
    alias_name: []const u8,
    label: []const u8,
) !void {
    const alias_index = std.mem.indexOf(u8, source[start_index..], alias_name) orelse return error.NeedleNotFound;
    const position = lsp.offsets.indexToPosition(source, start_index + alias_index + alias_name.len, .@"utf-8");
    for (hints) |hint| {
        if (!std.meta.eql(hint.position, position)) continue;
        switch (hint.label) {
            .string => |hint_label| {
                if (std.mem.eql(u8, hint_label, label)) return;
            },
            else => return error.UnexpectedInlayHint,
        }
    }
    return error.MissingInlayHint;
}

fn expectNoInlayHintAfter(
    source: []const u8,
    hints: []const types.InlayHint,
    start_index: usize,
    alias_name: []const u8,
) !void {
    const alias_index = std.mem.indexOf(u8, source[start_index..], alias_name) orelse return error.NeedleNotFound;
    const position = lsp.offsets.indexToPosition(source, start_index + alias_index + alias_name.len, .@"utf-8");
    for (hints) |hint| {
        try expect(!std.meta.eql(hint.position, position));
    }
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

test "updateIncremental applies multiple edits in notification order" {
    var document = try Document.init(testing_allocator, 1, "rule ::= TOKEN.");
    defer document.deinit(testing_allocator);

    const first_position = lsp.offsets.indexToPosition(document.source, 4, .@"utf-8");
    const second_position: types.Position = .{ .line = 0, .character = 8 };
    try document.updateIncremental(
        testing_allocator,
        2,
        &.{
            .{ .text_document_content_change_partial = .{
                .range = .{
                    .start = first_position,
                    .end = first_position,
                },
                .rangeLength = 0,
                .text = "_a",
            } },
            .{ .text_document_content_change_partial = .{
                .range = .{
                    .start = second_position,
                    .end = second_position,
                },
                .rangeLength = 0,
                .text = "_b",
            } },
        },
        .@"utf-8",
    );

    try expectEqualStrings("rule_a :_b:= TOKEN.", document.source);
}

test "document keeps one parser across reparses" {
    var document = try Document.init(testing_allocator, 1, "rule ::= TOKEN.");
    defer document.deinit(testing_allocator);

    const parser = document.parser;
    const insert_position = lsp.offsets.indexToPosition(document.source, document.source.len, .@"utf-8");
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
                .text = "\n",
            } },
        },
        .@"utf-8",
    );

    try expectEqual(parser, document.parser);

    try document.replace(testing_allocator, 3, "other ::= TOKEN.");
    try expectEqual(parser, document.parser);
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

test "token enum name defaults and follows token_enum" {
    var query_error_offset: u32 = 0;
    const token_enum_query = try ts.Query.create(
        zitronLanguage(),
        "(directive (directive_name) @directive (identifier) @name)",
        &query_error_offset,
    );
    defer token_enum_query.destroy();

    var default_document = try Document.init(testing_allocator, 1, "start ::= FOO.");
    defer default_document.deinit(testing_allocator);
    try expectEqualStrings("TokenKind", try default_document.tokenEnumName(testing_allocator, token_enum_query));

    var custom_document = try Document.init(
        testing_allocator,
        1,
        "%token_enum MySpecialEnumType\nstart ::= FOO.",
    );
    defer custom_document.deinit(testing_allocator);
    try expectEqualStrings("MySpecialEnumType", try custom_document.tokenEnumName(testing_allocator, token_enum_query));

    const name_start = "%token_enum ".len;
    const name_end = name_start + "MySpecialEnumType".len;
    try custom_document.updateIncremental(
        testing_allocator,
        2,
        &.{.{ .text_document_content_change_partial = .{
            .range = .{
                .start = lsp.offsets.indexToPosition(custom_document.source, name_start, .@"utf-8"),
                .end = lsp.offsets.indexToPosition(custom_document.source, name_end, .@"utf-8"),
            },
            .rangeLength = "MySpecialEnumType".len,
            .text = "RenamedEnumType",
        } }},
        .@"utf-8",
    );
    try expectEqualStrings("MySpecialEnumType", try custom_document.tokenEnumName(testing_allocator, token_enum_query));
    try expectEqualStrings("RenamedEnumType", try custom_document.refreshTokenEnumName(testing_allocator, token_enum_query));
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

test "inlay hints type grammar aliases from type directives" {
    const sample =
        \\%token_type "Token"
        \\%default_type {*Default}
        \\%type expr f64
        \\%type expr i64
        \\start ::= expr(A) PLUS|MINUS(O) fallback(F).
        \\expr(E) ::= NUMBER(N).
        \\fallback(D) ::= .
    ;
    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const hints = try document.inlayHints(arena_state.allocator(), .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 100, .character = 0 },
    }, .@"utf-8");

    const start_rule = try byteIndexOf(sample, "start ::=");
    try expectInlayHintAfter(sample, hints, start_rule, "A", ": i64");
    try expectInlayHintAfter(sample, hints, start_rule, "O", ": Token");
    try expectInlayHintAfter(sample, hints, start_rule, "F", ": *Default");

    const expr_rule = try byteIndexOf(sample, "expr(E)");
    try expectInlayHintAfter(sample, hints, expr_rule, "E", ": i64");
    const number_alias = try byteIndexOf(sample, "NUMBER(N)");
    try expectInlayHintAfter(sample, hints, number_alias + "NUMBER(".len, "N", ": Token");
}

test "inlay hints use the implicit void default type" {
    const sample = "start ::= fallback(F).";
    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const hints = try document.inlayHints(arena_state.allocator(), .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 1, .character = 0 },
    }, .@"utf-8");

    try expectEqual(@as(usize, 1), hints.len);
    try expectInlayHintAfter(sample, hints, 0, "F", ": void");
}

test "inlay hints type named action and impl aliases by name and position" {
    const sample =
        \\%token_type f64
        \\%type expr f64
        \\expr(A) ::= NUMBER(N). @on_expr(A; N)
        \\%impl @on_expr(A; N) { _ = .{ A, N }; }
        \\%impl @on_expr(N; A) { _ = .{ N, A }; }
        \\%impl @on_expr(A; Bad) { _ = Bad; }
    ;
    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const hints = try document.inlayHints(arena_state.allocator(), .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 100, .character = 0 },
    }, .@"utf-8");

    const rule = try byteIndexOf(sample, "expr(A)");
    try expectInlayHintAfter(sample, hints, rule, "A", ": f64");
    const number_alias = try byteIndexOf(sample, "NUMBER(N)");
    try expectInlayHintAfter(sample, hints, number_alias + "NUMBER(".len, "N", ": f64");

    const rule_action = try byteIndexOf(sample, "@on_expr(A; N)");
    try expectInlayHintAfter(sample, hints, rule_action, "A", ": f64");
    try expectInlayHintAfter(sample, hints, rule_action, "N", ": f64");

    const impl_action = try byteIndexOf(sample, "%impl @on_expr(A; N)");
    try expectInlayHintAfter(sample, hints, impl_action, "A", ": f64");
    try expectInlayHintAfter(sample, hints, impl_action, "N", ": f64");

    const swapped_impl = try byteIndexOf(sample, "%impl @on_expr(N; A)");
    try expectNoInlayHintAfter(sample, hints, swapped_impl, "N");
    try expectNoInlayHintAfter(sample, hints, swapped_impl, "A");

    const mismatched_impl = try byteIndexOf(sample, "%impl @on_expr(A; Bad)");
    try expectInlayHintAfter(sample, hints, mismatched_impl, "A", ": f64");
    try expectNoInlayHintAfter(sample, hints, mismatched_impl, "Bad");
}

test "inlay hints filter by request range" {
    const sample =
        \\%type expr f64
        \\expr(A) ::= expr(B). @on_expr(A; B)
        \\%impl @on_expr(A; B) { _ = .{ A, B }; }
    ;
    var document = try Document.init(testing_allocator, 1, sample);
    defer document.deinit(testing_allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena_state.deinit();

    const hints = try document.inlayHints(arena_state.allocator(), .{
        .start = .{ .line = 2, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    }, .@"utf-8");

    try expectEqual(@as(usize, 2), hints.len);
    const impl_action = try byteIndexOf(sample, "%impl @on_expr(A; B)");
    try expectInlayHintAfter(sample, hints, impl_action, "A", ": f64");
    try expectInlayHintAfter(sample, hints, impl_action, "B", ": f64");
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
