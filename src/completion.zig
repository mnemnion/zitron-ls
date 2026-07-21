//! Directive completion support for Zitron source files.

const DirectiveContext = struct {
    prefix: []const u8,
    replace_range: types.Range,
};

const ImplAliasContext = struct {
    action_name: []const u8,
    prefix: []const u8,
    replace_range: types.Range,
};

const RuleActionAliasContext = struct {
    prefix: []const u8,
    replace_range: types.Range,
    action_start: usize,
    action_row: u32,
};

const ParticleContext = struct {
    prefix: []const u8,
    replace_range: types.Range,
};

const ActionArgumentContext = struct {
    action_name: ts.Node,
    prefix: []const u8,
    replace_range: types.Range,
};

const ActionArgumentKind = enum {
    impl,
    rule_action,
};

const ParticleKind = enum {
    nonterminal,
    token_class,
    terminal,
    multiterminal,
};

const Particle = struct {
    label: []const u8,
    kind: ParticleKind,
};

const ActionSignatureContext = struct {
    action_name: []const u8,
    kind: ActionArgumentKind,
    action_start: usize,
    action_row: u32,
    open_end: usize,
    index: usize,
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

pub fn signatureHelp(
    allocator: Allocator,
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) OOM!?types.SignatureHelp {
    const context = actionSignatureContext(source, root, position, encoding) orelse return null;
    const aliases = switch (context.kind) {
        .impl => try actionAliasesForName(allocator, source, root, context.action_name),
        .rule_action => blk: {
            const rule = ruleNodeForAction(root, context.action_start, context.action_row) orelse return null;
            break :blk try aliasesForRuleAction(allocator, source, rule);
        },
    } orelse return null;

    var label: std.ArrayList(u8) = .empty;
    try label.appendSlice(allocator, context.action_name);
    try label.append(allocator, '(');
    try label.appendSlice(allocator, aliases);
    try label.append(allocator, ')');
    const signature_label = try label.toOwnedSlice(allocator);

    const parameters = try signatureParameters(allocator, aliases);
    const active_parameter = activeActionParameter(source[context.open_end..context.index], parameters.len);

    const signatures = try allocator.alloc(types.SignatureInformation, 1);
    signatures[0] = .{
        .label = signature_label,
        .parameters = parameters,
        .activeParameter = active_parameter,
    };

    return .{
        .signatures = signatures,
        .activeSignature = 0,
        .activeParameter = active_parameter,
    };
}

/// Returns named-action alias completions for `%impl @action(` contexts.
pub fn completeImplAliases(
    allocator: Allocator,
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) OOM!?[]const types.CompletionItem {
    const context = implAliasContext(source, root, position, encoding) orelse return null;
    const aliases = try actionAliasesForName(allocator, source, root, context.action_name) orelse return null;
    if (context.prefix.len != 0 and !std.mem.startsWith(u8, aliases, context.prefix)) return null;

    const items = try allocator.alloc(types.CompletionItem, 1);
    items[0] = .{
        .label = aliases,
        .kind = .Variable,
        .detail = "@impl aliases",
        .filterText = aliases,
        .textEdit = .{ .text_edit = .{
            .range = context.replace_range,
            .newText = aliases,
        } },
    };
    return items;
}

/// Returns named-action alias completions for `@action(` contexts after grammar rules.
pub fn completeRuleActionAliases(
    allocator: Allocator,
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) OOM!?[]const types.CompletionItem {
    const context = ruleActionAliasContext(source, root, position, encoding) orelse return null;
    const rule = ruleNodeForAction(root, context.action_start, context.action_row) orelse return null;
    const aliases = try aliasesForRuleAction(allocator, source, rule) orelse return null;
    if (context.prefix.len != 0 and !std.mem.startsWith(u8, aliases, context.prefix)) return null;

    const items = try allocator.alloc(types.CompletionItem, 1);
    items[0] = .{
        .label = aliases,
        .kind = .Variable,
        .detail = "@action aliases",
        .filterText = aliases,
        .textEdit = .{ .text_edit = .{
            .range = context.replace_range,
            .newText = aliases,
        } },
    };
    return items;
}

/// Returns grammar-particle completions for terminals, nonterminals, token classes, and multiterminals.
pub fn completeGrammarParticles(
    allocator: Allocator,
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) OOM!?[]const types.CompletionItem {
    const context = particleContext(source, root, position, encoding) orelse return null;

    var particles: std.ArrayList(Particle) = .empty;
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(allocator);

    try collectGrammarParticles(allocator, source, root, &particles, &seen);

    var match_count: usize = 0;
    for (particles.items) |particle| {
        if (filterTextForParticle(particle, context.prefix) != null) match_count += 1;
    }
    if (match_count == 0) return null;

    const items = try allocator.alloc(types.CompletionItem, match_count);
    var next: usize = 0;
    for (particles.items) |particle| {
        const filter_text = filterTextForParticle(particle, context.prefix) orelse continue;
        items[next] = .{
            .label = particle.label,
            .kind = completionKindForParticle(particle.kind),
            .detail = detailForParticle(particle.kind),
            .filterText = filter_text,
            .textEdit = .{ .text_edit = .{
                .range = context.replace_range,
                .newText = particle.label,
            } },
        };
        next += 1;
    }

    return items;
}

/// Returns directive completions for a line-leading `%...` token at `position`.
pub fn completeDirectives(
    allocator: Allocator,
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) OOM!?[]const types.CompletionItem {
    const context = directiveContext(source, root, position, encoding) orelse return null;

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

fn actionSignatureContext(
    source: []const u8,
    _: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) ?ActionSignatureContext {
    const index = lsp.offsets.positionToIndex(source, position, encoding);
    const open = actionOpenBefore(source, index) orelse return null;
    const action_start = actionNameStartBeforeOpen(source, open) orelse return null;
    const action_name = source[action_start..open];
    if (index < open + 1) return null;
    if (containsAnyByte(source[open + 1 .. index], &.{ ')', '{' })) return null;

    const line_start = lineStartBefore(source, action_start);
    const is_impl = linePrefixHasImplDirective(source[line_start..action_start]);
    return .{
        .action_name = action_name,
        .kind = if (is_impl) .impl else .rule_action,
        .action_start = action_start,
        .action_row = position.line,
        .open_end = open + 1,
        .index = index,
    };
}

fn actionOpenBefore(source: []const u8, index: usize) ?usize {
    var scan = index;
    while (scan > 0) {
        scan -= 1;
        switch (source[scan]) {
            '(' => return scan,
            '\n', '\r' => return null,
            else => {},
        }
    }
    return null;
}

fn actionNameStartBeforeOpen(source: []const u8, open: usize) ?usize {
    if (open == 0) return null;
    var scan = open;
    while (scan > 0 and isIdentifierByte(source[scan - 1])) {
        scan -= 1;
    }
    if (scan == 0 or source[scan - 1] != '@') return null;
    return scan - 1;
}

fn lineStartBefore(source: []const u8, index: usize) usize {
    var scan = index;
    while (scan > 0) {
        if (source[scan - 1] == '\n' or source[scan - 1] == '\r') break;
        scan -= 1;
    }
    return scan;
}

fn linePrefixHasImplDirective(prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, prefix, " \t");
    return std.mem.startsWith(u8, trimmed, "%impl");
}

fn containsAnyByte(haystack: []const u8, needles: []const u8) bool {
    for (haystack) |byte| {
        if (std.mem.indexOfScalar(u8, needles, byte) != null) return true;
    }
    return false;
}

fn ruleActionAliasContext(
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) ?RuleActionAliasContext {
    const action = actionArgumentContext(source, root, position, encoding, .rule_action) orelse return null;
    return .{
        .prefix = action.prefix,
        .replace_range = action.replace_range,
        .action_start = action.action_name.startByte(),
        .action_row = action.action_name.startPoint().row,
    };
}

fn implAliasContext(
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) ?ImplAliasContext {
    const action = actionArgumentContext(source, root, position, encoding, .impl) orelse return null;
    return .{
        .action_name = sliceForNode(source, action.action_name),
        .prefix = action.prefix,
        .replace_range = action.replace_range,
    };
}

fn actionArgumentContext(
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
    kind: ActionArgumentKind,
) ?ActionArgumentContext {
    const index = lsp.offsets.positionToIndex(source, position, encoding);
    const parent = actionArgumentParent(root, index) orelse return null;
    const action_name = firstNamedChildOfKind(parent, "action_name") orelse return null;
    if (index < action_name.endByte()) return null;

    const is_impl = isImplActionParent(parent);
    switch (kind) {
        .impl => if (!is_impl) {
            return null;
        },
        .rule_action => if (is_impl) return null,
    }

    const open = childOfKindAfter(parent, "(", action_name.endByte()) orelse return null;
    if (index < open.endByte()) return null;
    if (childOfKindAfter(parent, "{", open.endByte())) |brace| {
        if (!brace.isMissing() and brace.startByte() <= index) return null;
    }
    if (childOfKindAfter(parent, ")", open.endByte())) |close| {
        if (!close.isMissing() and close.endByte() <= index) return null;
    }

    const arg = actionArgumentTextRange(source, index, open.endByte(), kind) orelse return null;
    return .{
        .action_name = action_name,
        .prefix = source[arg.start..index],
        .replace_range = .{
            .start = lsp.offsets.indexToPosition(source, arg.start, encoding),
            .end = lsp.offsets.indexToPosition(source, arg.end, encoding),
        },
    };
}

fn actionArgumentParent(root: ts.Node, index: usize) ?ts.Node {
    var cursor = nodeNearByte(root, index);
    while (true) {
        if (isActionArgumentParent(cursor) and firstNamedChildOfKind(cursor, "action_name") != null) {
            return cursor;
        }
        cursor = cursor.parent() orelse break;
    }
    return null;
}

fn isActionArgumentParent(node: ts.Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "named_action") or std.mem.eql(u8, kind, "ERROR");
}

fn isImplActionParent(node: ts.Node) bool {
    if (hasDirectChildOfKind(node, "impl_name")) return true;
    const parent = node.parent() orelse return false;
    return std.mem.eql(u8, parent.kind(), "directive") and hasDirectChildOfKind(parent, "impl_name");
}

const ByteRange = struct {
    start: usize,
    end: usize,
};

fn actionArgumentTextRange(
    source: []const u8,
    index: usize,
    open_end: usize,
    kind: ActionArgumentKind,
) ?ByteRange {
    var token_start = open_end;
    while (token_start < index and std.ascii.isWhitespace(source[token_start])) {
        token_start += 1;
    }

    var scan = token_start;
    while (scan < index) : (scan += 1) {
        if (!isActionArgumentByte(source[scan], kind)) return null;
    }

    var token_end = index;
    while (token_end < source.len and isActionArgumentByte(source[token_end], kind)) {
        token_end += 1;
    }

    return .{ .start = token_start, .end = token_end };
}

fn isActionArgumentByte(byte: u8, kind: ActionArgumentKind) bool {
    if (isAliasTokenByte(byte)) return true;
    return switch (kind) {
        .impl => false,
        .rule_action => byte == ';' or byte == ',',
    };
}

fn actionAliasesForName(
    allocator: Allocator,
    source: []const u8,
    root: ts.Node,
    action_name: []const u8,
) OOM!?[]const u8 {
    var aliases: std.ArrayList([]const u8) = .empty;
    try collectActionAliases(source, root, action_name, &aliases, allocator);
    if (aliases.items.len == 0) return null;

    var formatted: std.ArrayList(u8) = .empty;
    for (aliases.items, 0..) |alias, index| {
        if (index == 1) {
            try formatted.appendSlice(allocator, "; ");
        } else if (index > 1) {
            try formatted.appendSlice(allocator, ", ");
        }
        try formatted.appendSlice(allocator, alias);
    }
    return try formatted.toOwnedSlice(allocator);
}

fn signatureParameters(allocator: Allocator, aliases: []const u8) OOM![]const types.ParameterInformation {
    var count: usize = 0;
    var start: usize = 0;
    while (start <= aliases.len) {
        const end = aliasParameterEnd(aliases, start);
        const parameter = std.mem.trim(u8, aliases[start..end], " \t\r\n");
        if (parameter.len != 0) count += 1;
        if (end == aliases.len) break;
        start = end + 1;
    }

    const parameters = try allocator.alloc(types.ParameterInformation, count);
    var next: usize = 0;
    start = 0;
    while (start <= aliases.len) {
        const end = aliasParameterEnd(aliases, start);
        const parameter = std.mem.trim(u8, aliases[start..end], " \t\r\n");
        if (parameter.len != 0) {
            parameters[next] = .{ .label = .{ .string = parameter } };
            next += 1;
        }
        if (end == aliases.len) break;
        start = end + 1;
    }
    return parameters;
}

fn aliasParameterEnd(aliases: []const u8, start: usize) usize {
    var index = start;
    while (index < aliases.len) : (index += 1) {
        if (aliases[index] == ';' or aliases[index] == ',') break;
    }
    return index;
}

fn activeActionParameter(argument_text: []const u8, parameter_count: usize) ?u32 {
    if (parameter_count == 0) return null;

    var index: usize = 0;
    for (argument_text) |byte| {
        if (byte == ';' or byte == ',') index += 1;
    }
    return @intCast(@min(index, parameter_count - 1));
}

fn collectActionAliases(
    source: []const u8,
    node: ts.Node,
    action_name: []const u8,
    aliases: *std.ArrayList([]const u8),
    allocator: Allocator,
) OOM!void {
    if (std.mem.eql(u8, node.kind(), "named_action") and isActionDefinition(node)) {
        const maybe_name = firstNamedChildOfKind(node, "action_name");
        if (maybe_name) |name_node| {
            if (std.mem.eql(u8, sliceForNode(source, name_node), action_name)) {
                try collectRuleAliases(source, node, aliases, allocator);
                return;
            }
        }
    }

    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        try collectActionAliases(source, node.namedChild(index).?, action_name, aliases, allocator);
        if (aliases.items.len != 0) return;
    }
}

fn isActionDefinition(node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    const kind = parent.kind();
    return std.mem.eql(u8, kind, "grammar_rule") or std.mem.eql(u8, kind, "ditto_rule");
}

fn collectRuleAliases(
    source: []const u8,
    node: ts.Node,
    aliases: *std.ArrayList([]const u8),
    allocator: Allocator,
) OOM!void {
    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = node.namedChild(index).?;
        if (std.mem.eql(u8, child.kind(), "rule_alias")) {
            try aliases.append(allocator, sliceForNode(source, child));
        }
    }
}

fn ruleNodeForAction(root: ts.Node, action_start: usize, action_row: u32) ?ts.Node {
    const direct = root.namedDescendantForByteRange(@intCast(action_start), @intCast(action_start)) orelse root;
    if (containingRuleNode(direct)) |rule| return rule;

    var best: ?ts.Node = null;
    findBestRuleBeforeAction(root, action_start, action_row, &best);
    return best;
}

fn containingRuleNode(node: ts.Node) ?ts.Node {
    var cursor = node;
    while (true) {
        if (isRuleNode(cursor)) return cursor;
        cursor = cursor.parent() orelse return null;
    }
}

fn findBestRuleBeforeAction(node: ts.Node, action_start: usize, action_row: u32, best: *?ts.Node) void {
    if (isRuleNode(node)) {
        const start: usize = node.startByte();
        if (node.startPoint().row == action_row and start <= action_start) {
            if (best.* == null or best.*.?.startByte() < node.startByte()) {
                best.* = node;
            }
        }
    }

    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        findBestRuleBeforeAction(node.namedChild(index).?, action_start, action_row, best);
    }
}

fn isRuleNode(node: ts.Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "grammar_rule") or std.mem.eql(u8, kind, "ditto_rule");
}

fn aliasesForRuleAction(allocator: Allocator, source: []const u8, rule: ts.Node) OOM!?[]const u8 {
    var lhs_aliases: std.ArrayList([]const u8) = .empty;
    var rhs_aliases: std.ArrayList([]const u8) = .empty;

    const child_count = rule.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = rule.namedChild(index).?;
        if (std.mem.eql(u8, child.kind(), "lhs")) {
            try collectRuleAliases(source, child, &lhs_aliases, allocator);
        } else if (std.mem.eql(u8, child.kind(), "rhs")) {
            try collectRuleAliases(source, child, &rhs_aliases, allocator);
        }
    }

    if (lhs_aliases.items.len == 0 and rhs_aliases.items.len == 0) return null;

    var formatted: std.ArrayList(u8) = .empty;
    try appendAliasList(allocator, &formatted, lhs_aliases.items);
    if (rhs_aliases.items.len != 0) {
        if (lhs_aliases.items.len != 0) {
            try formatted.append(allocator, ';');
            if (rhs_aliases.items.len > 1) try formatted.append(allocator, ' ');
        } else if (rhs_aliases.items.len == 1) {
            try formatted.append(allocator, ';');
        } else {
            try formatted.appendSlice(allocator, " ; ");
        }
        try appendAliasList(allocator, &formatted, rhs_aliases.items);
    }

    return try formatted.toOwnedSlice(allocator);
}

fn appendAliasList(allocator: Allocator, formatted: *std.ArrayList(u8), aliases: []const []const u8) OOM!void {
    for (aliases, 0..) |alias, index| {
        if (index != 0) try formatted.appendSlice(allocator, ", ");
        try formatted.appendSlice(allocator, alias);
    }
}

fn directiveContext(
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) ?DirectiveContext {
    const index = lsp.offsets.positionToIndex(source, position, encoding);
    const node = directiveNameNode(source, root, index) orelse return null;
    const token_start = directiveTokenStart(source, node);
    const token_end = node.endByte();
    if (index < token_start or index > token_end) return null;

    return .{
        .prefix = source[token_start..@min(index, token_end)],
        .replace_range = .{
            .start = lsp.offsets.indexToPosition(source, token_start, encoding),
            .end = lsp.offsets.indexToPosition(source, token_end, encoding),
        },
    };
}

fn particleContext(
    source: []const u8,
    root: ts.Node,
    position: types.Position,
    encoding: lsp.offsets.Encoding,
) ?ParticleContext {
    const index = lsp.offsets.positionToIndex(source, position, encoding);
    const node = particleNodeAt(root, index) orelse return null;
    const token_start = node.startByte();
    const token_end = node.endByte();
    if (index <= token_start or index > token_end) return null;
    return .{
        .prefix = source[token_start..index],
        .replace_range = .{
            .start = lsp.offsets.indexToPosition(source, token_start, encoding),
            .end = lsp.offsets.indexToPosition(source, token_end, encoding),
        },
    };
}

fn collectGrammarParticles(
    allocator: Allocator,
    source: []const u8,
    node: ts.Node,
    particles: *std.ArrayList(Particle),
    seen: *std.StringHashMapUnmanaged(usize),
) OOM!void {
    if (tokenClassNameNode(node)) |name_node| {
        try appendOrRefineParticle(
            allocator,
            particles,
            seen,
            sliceForNode(source, name_node),
            .token_class,
        );
    }

    if (particleKindForNode(node)) |kind| {
        try appendOrRefineParticle(
            allocator,
            particles,
            seen,
            sliceForNode(source, node),
            kind,
        );
    }

    const child_count = node.namedChildCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        try collectGrammarParticles(allocator, source, node.namedChild(index).?, particles, seen);
    }
}

fn appendOrRefineParticle(
    allocator: Allocator,
    particles: *std.ArrayList(Particle),
    seen: *std.StringHashMapUnmanaged(usize),
    label: []const u8,
    kind: ParticleKind,
) OOM!void {
    const entry = try seen.getOrPut(allocator, label);
    if (entry.found_existing) {
        if (kind == .token_class) particles.items[entry.value_ptr.*].kind = .token_class;
        return;
    }

    entry.value_ptr.* = particles.items.len;
    try particles.append(allocator, .{ .label = label, .kind = kind });
}

fn particleKindForNode(node: ts.Node) ?ParticleKind {
    const parent = node.parent() orelse return null;
    const parent_kind = parent.kind();
    const node_kind = node.kind();

    if (std.mem.eql(u8, node_kind, "multiterminal")) return .multiterminal;

    if (!std.mem.eql(u8, parent_kind, "lhs") and
        !std.mem.eql(u8, parent_kind, "rhs") and
        !std.mem.eql(u8, parent_kind, "multiterminal"))
    {
        return null;
    }

    if (std.mem.eql(u8, node_kind, "nonterminal")) return .nonterminal;
    if (std.mem.eql(u8, node_kind, "terminal")) return .terminal;
    return null;
}

fn completionKindForParticle(kind: ParticleKind) types.CompletionItemKind {
    return switch (kind) {
        .nonterminal => .Class,
        .token_class => .Constant,
        .terminal => .EnumMember,
        .multiterminal => .Constant,
    };
}

fn detailForParticle(kind: ParticleKind) []const u8 {
    return switch (kind) {
        .nonterminal => "nonterminal",
        .token_class => "token class",
        .terminal => "terminal",
        .multiterminal => "multiterminal",
    };
}

fn filterTextForParticle(particle: Particle, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, particle.label, prefix)) return particle.label;
    if (particle.kind != .multiterminal) return null;

    var it = std.mem.tokenizeAny(u8, particle.label, "|/");
    while (it.next()) |terminal| {
        if (std.mem.startsWith(u8, terminal, prefix)) return terminal;
    }

    return null;
}

fn tokenClassNameNode(directive: ts.Node) ?ts.Node {
    if (!std.mem.eql(u8, directive.kind(), "directive")) return null;
    _ = firstNamedChildOfKind(directive, "arg_directive_name") orelse return null;
    _ = firstNamedChildOfKind(directive, "multiterminal") orelse return null;
    return firstNamedChildOfKind(directive, "nonterminal");
}

fn directiveNameNode(source: []const u8, root: ts.Node, index: usize) ?ts.Node {
    var node = nodeNearByte(root, index);
    while (true) {
        if (isDirectiveNameKind(node.kind())) return node;
        if (std.mem.eql(u8, node.kind(), "ERROR") and
            node.startByte() < source.len and
            source[node.startByte()] == '%' and
            index <= node.endByte())
        {
            return node;
        }
        node = node.parent() orelse return null;
    }
}

fn isDirectiveNameKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "directive_name") or
        std.mem.eql(u8, kind, "arg_directive_name") or
        std.mem.eql(u8, kind, "token_directive_name") or
        std.mem.eql(u8, kind, "bad_directive_name") or
        std.mem.eql(u8, kind, "impl_name");
}

fn directiveTokenStart(source: []const u8, node: ts.Node) usize {
    if (node.parent()) |parent| {
        const parent_kind = parent.kind();
        if ((std.mem.eql(u8, parent_kind, "directive") or std.mem.eql(u8, parent_kind, "bad_directive")) and
            parent.startByte() < source.len and
            source[parent.startByte()] == '%')
        {
            return parent.startByte();
        }
    }
    return node.startByte();
}

fn particleNodeAt(root: ts.Node, index: usize) ?ts.Node {
    var node = nodeNearByte(root, index);
    if (containingNodeOfKind(node, "multiterminal")) |multiterminal| {
        if (particleKindForNode(multiterminal) != null) return multiterminal;
    }

    while (true) {
        if (particleKindForNode(node) != null) return node;
        node = node.parent() orelse return null;
    }
}

fn containingNodeOfKind(node: ts.Node, kind: []const u8) ?ts.Node {
    var cursor = node;
    while (true) {
        if (std.mem.eql(u8, cursor.kind(), kind)) return cursor;
        cursor = cursor.parent() orelse return null;
    }
}

fn nodeNearByte(root: ts.Node, index: usize) ts.Node {
    const start = if (index == 0) 0 else index - 1;
    return root.descendantForByteRange(@intCast(start), @intCast(index)) orelse root;
}

fn childOfKindAfter(node: ts.Node, kind: []const u8, after: usize) ?ts.Node {
    const child_count = node.childCount();
    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        const child = node.child(index).?;
        if (child.startByte() >= after and std.mem.eql(u8, child.kind(), kind)) return child;
    }
    return null;
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

fn sliceForNode(source: []const u8, node: ts.Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn isAliasTokenByte(byte: u8) bool {
    return isIdentifierByte(byte);
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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

const ParsedTestSource = struct {
    tree: *ts.Tree,

    fn deinit(parsed: *ParsedTestSource) void {
        parsed.tree.destroy();
    }

    fn root(parsed: ParsedTestSource) ts.Node {
        return parsed.tree.rootNode();
    }
};

fn parseTestSource(source: []const u8) !ParsedTestSource {
    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(ts.Language.fromRaw(zitron_grammar.language()));
    return .{ .tree = parser.parseString(source, null) orelse return error.ParseFailed };
}

test "directive completions match %t at the start of a directive line" {
    var parsed = try parseTestSource("%t");
    defer parsed.deinit();
    const items = (try completeDirectives(
        testing_allocator,
        "%t",
        parsed.root(),
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
    var parsed = try parseTestSource("%incl");
    defer parsed.deinit();
    const items = (try completeDirectives(
        testing_allocator,
        "%incl",
        parsed.root(),
        .{ .line = 0, .character = 5 },
        .@"utf-8",
    )).?;
    defer testing_allocator.free(items);

    try expectEqual(@as(usize, 1), items.len);
    try expectEqualStrings("%include", items[0].label);
}

test "directive completions return null outside directive context" {
    var parsed = try parseTestSource("rule ::= TOKEN.\n");
    defer parsed.deinit();
    const result = try completeDirectives(
        testing_allocator,
        "rule ::= TOKEN.\n",
        parsed.root(),
        .{ .line = 0, .character = 4 },
        .@"utf-8",
    );

    try expect(result == null);
}

test "directive completions return null on commented directive text" {
    var parsed = try parseTestSource("// %token_type \"Token\"\n");
    defer parsed.deinit();
    const result = try completeDirectives(
        testing_allocator,
        "// %token_type \"Token\"\n",
        parsed.root(),
        .{ .line = 0, .character = 9 },
        .@"utf-8",
    );

    try expect(result == null);
}

test "directive completions ignore directive text inside %code blocks" {
    const source =
        \\%code {
        \\    literal %tok
        \\    %tok
        \\}
    ;

    var parsed = try parseTestSource(source);
    defer parsed.deinit();

    const non_directive_line = try completeDirectives(
        testing_allocator,
        source,
        parsed.root(),
        .{ .line = 1, .character = 16 },
        .@"utf-8",
    );
    try expect(non_directive_line == null);

    const directive_line = try completeDirectives(
        testing_allocator,
        source,
        parsed.root(),
        .{ .line = 2, .character = 8 },
        .@"utf-8",
    );
    try expect(directive_line == null);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const lsp = @import("lsp");
const ts = @import("tree-sitter");
const types = lsp.types.flat;
const zitron_grammar = @import("tree_sitter_zitron");
