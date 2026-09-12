//! Tree-sitter-directed formatting of Zitron source, independent of LSP.

/// The tree type accepted by the formatter.
pub const Tree = ts.Tree;
/// The syntax-node type accepted by the formatter.
pub const Node = ts.Node;
/// Formatting failures. Unformattable source fragments are preserved locally.
pub const Error = OOM;
/// Runtime configuration; layout follows the Zitron house style.
pub const Options = struct {
    /// Use this external formatter instead of the linked Zig formatter.
    zig_executable: ?[]const u8 = null,
};

/// Format a complete document. Source and root must describe the same parse and
/// remain alive until return. The caller owns the returned text.
pub fn format(io: std.Io, allocator: Allocator, source: []const u8, root: Node, options: Options) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const warm = try arena.allocator().alloc(u8, @min(source.len *| 4, 256 * 1024));
    arena.allocator().free(warm);
    var queue: ZigCode.Queue = undefined;
    queue.init(io, options.zig_executable);
    defer queue.deinit();
    var document = Document{ .allocator = arena.allocator(), .source = source, .queue = &queue };
    try document.collect(root);
    try queue.finish();
    try document.prepare();
    try document.layout();
    return document.render(allocator);
}

const Kind = enum { rule, directive, comment, raw };
const Break = enum { none, soft, hard };
const Tail = enum { none, action, code_line, code_block, comment };
const Particle = struct { text: []const u8, line: bool = false, end_width: usize = 0 };
const Pattern = struct {
    split: ?usize = null,
    short_indent: bool = false,
    line_count: usize = 0,
    width: usize = 0,
    last_width: usize = 0,
    overflow: usize = 0,
    excess: usize = 0,

    fn addLine(pattern: *Pattern, count: usize) void {
        pattern.line_count += 1;
        pattern.width = @max(pattern.width, count);
        pattern.last_width = count;
        pattern.overflow += @intFromBool(count > 78);
        pattern.excess += count -| 78;
    }
};
const Rule = struct {
    lhs: []const u8,
    name_length: usize,
    input_ditto: bool,
    ditto: bool = false,
    rhs_column: usize = 0,
    particles: []Particle,
    precedence: []const u8,
    aliases: []const []const u8,
    tail: Tail = .none,
    action: []const u8 = "",
    action_width: usize = 0,
    suffix_width: usize = 1,
    joined_width: usize = 0,
    balanced_cuts: [2]usize = undefined,
    job: ?*ZigCode.Job = null,
    block: bool = false,
    code_failed: bool = false,
    opening_comment: bool = false,
    pattern: Pattern = undefined,
    dropped: bool = false,
    drop_column: usize = 0,
    newly_dropped: bool = false,
    input_dropped: bool = false,
    tail_column: usize = 0,
    comment_column: usize = 0,
    pulled_comment: bool = false,
    stage: u8 = 0,
};
const Item = struct {
    kind: Kind,
    start: usize,
    end: usize,
    gap: []const u8,
    blanks: usize,
    text: []const u8 = "",
    comment: []const u8 = "",
    comment_width: usize = 0,
    rule: ?Rule = null,
    job: ?*ZigCode.Job = null,
    block: bool = false,
    raw_code: []const u8 = "",
    boundary: Break = .none,
    long_comment: bool = false,
    opening_comment: bool = false,
    connected: bool = false,
};
const Disabled = struct { start: usize, end: usize };
const Run = struct {
    first: usize,
    end: usize,
    boundary: Break,
    column: usize = 0,
    bumped: bool = false,
    fitted: bool = false,
    connected: bool = false,
};

const Document = struct {
    allocator: Allocator,
    source: []const u8,
    queue: *ZigCode.Queue,
    items: std.ArrayList(Item) = .empty,
    disabled: std.ArrayList(Disabled) = .empty,
    runs: std.ArrayList(Run) = .empty,
    crlf: bool = false,

    fn collect(document: *Document, root: Node) OOM!void {
        try document.findDisabled();
        try document.items.ensureTotalCapacity(document.allocator, root.childCount());
        var cursor = root.walk();
        defer cursor.destroy();
        if (!cursor.gotoFirstChild()) return;
        var previous_end: usize = 0;
        var lhs: []const u8 = "";
        var name_length: usize = 0;
        var lhs_alias: ?[]const u8 = null;
        while (true) {
            const node = cursor.node();
            const start = node.startByte();
            const end = node.endByte();
            const gap = document.source[previous_end..start];
            const gap_lines = std.mem.count(u8, gap, "\n");
            var item = Item{
                .kind = .raw,
                .start = start,
                .end = end,
                .gap = gap,
                .blanks = gap_lines -| 1,
                .text = document.source[start..end],
            };
            const kind = node.kind();
            if (!node.hasError() and !node.isMissing() and !document.protected(start, end)) {
                if (eql(kind, "comment")) {
                    item.kind = .comment;
                    item.text = try normalizeComment(document.allocator, item.text);
                    item.long_comment = hasNewline(item.text);
                    if (gap_lines == 0 and document.items.items.len != 0) {
                        const last = &document.items.items[document.items.items.len - 1];
                        if ((last.kind == .rule or last.kind == .directive) and !item.long_comment) {
                            last.comment = item.text;
                            last.end = end;
                            previous_end = end;
                            if (!cursor.gotoNextSibling()) break;
                            continue;
                        }
                    }
                } else if (eql(kind, "grammar_rule") or eql(kind, "ditto_rule")) {
                    const children = Children.init(node);
                    if (children.lhs) |lhs_node| {
                        const left = Children.init(lhs_node);
                        lhs = try normalize(document.allocator, slice(document.source, lhs_node), false);
                        if (left.nonterminal) |name| name_length = width(slice(document.source, name));
                        lhs_alias = if (left.rule_alias) |alias| slice(document.source, alias) else null;
                    }
                    if (lhs.len != 0 and !children.commented) {
                        item.kind = .rule;
                        item.rule = try document.collectRule(node, children, lhs, name_length, lhs_alias);
                    }
                } else if (eql(kind, "directive")) {
                    const children = Children.init(node);
                    if (!children.commented) try document.collectDirective(&item, node, children);
                }
            }
            if (item.kind == .raw) lhs = "";
            try document.items.append(document.allocator, item);
            previous_end = end;
            if (!cursor.gotoNextSibling()) break;
        }
    }

    fn collectRule(document: *Document, node: Node, children: Children, lhs: []const u8, name_length: usize, lhs_alias: ?[]const u8) OOM!Rule {
        var particles: std.ArrayList(Particle) = .empty;
        var aliases: std.ArrayList([]const u8) = .empty;
        if (lhs_alias) |alias| try aliases.append(document.allocator, alias);
        if (children.rhs) |rhs| {
            var cursor = rhs.walk();
            defer cursor.destroy();
            var begin: ?usize = null;
            var previous: usize = rhs.startByte();
            if (cursor.gotoFirstChild()) while (true) {
                const child = cursor.node();
                if (particleKind(child.kind())) {
                    if (begin) |start| {
                        const text = std.mem.trimEnd(u8, document.source[start..child.startByte()], " \t\r\n");
                        try particles.append(document.allocator, .{
                            .text = try normalize(document.allocator, text, false),
                            .line = hasNewline(document.source[previous..start]),
                        });
                        previous = start + text.len;
                    }
                    begin = child.startByte();
                } else if (eql(child.kind(), "rule_alias")) {
                    try aliases.append(document.allocator, slice(document.source, child));
                }
                if (!cursor.gotoNextSibling()) break;
            };
            if (begin) |start| try particles.append(document.allocator, .{
                .text = try normalize(document.allocator, document.source[start..rhs.endByte()], false),
                .line = hasNewline(document.source[previous..start]),
            });
        }
        var rule = Rule{
            .lhs = lhs,
            .name_length = name_length,
            .input_ditto = eql(node.kind(), "ditto_rule"),
            .particles = particles.items,
            .precedence = if (children.precedence_mark) |mark| try normalize(document.allocator, slice(document.source, mark), false) else "",
            .aliases = aliases.items,
        };
        const tail = children.named_action orelse children.code_block;
        if (tail) |action| {
            const before = document.source[node.startByte()..action.startByte()];
            const trimmed = std.mem.trimEnd(u8, before, " \t\r\n");
            rule.input_dropped = hasNewline(before[trimmed.len..]);
            rule.dropped = rule.input_dropped;
            if (eql(action.kind(), "named_action")) {
                rule.tail = .action;
                rule.action = try normalizeAction(document.allocator, slice(document.source, action));
            } else {
                rule.block = hasNewline(slice(document.source, action));
                rule.tail = if (rule.block) .code_block else .code_line;
                const text = slice(document.source, action);
                rule.opening_comment = openingComment(text);
                rule.action = text;
                rule.job = try document.job(text[1 .. text.len - 1], .statements, aliases.items);
            }
        }
        return rule;
    }

    fn collectDirective(document: *Document, item: *Item, node: Node, children: Children) OOM!void {
        item.kind = .directive;
        const name_node = children.directive_name orelse return;
        const name = slice(document.source, name_node);
        const block = children.code_block;
        const prefix_end = if (block) |code| code.startByte() else node.endByte();
        const prefix = document.source[node.startByte()..prefix_end];
        if (children.named_action) |action| {
            item.text = try std.fmt.allocPrint(document.allocator, "%impl {s}", .{try normalizeAction(document.allocator, slice(document.source, action))});
        } else item.text = try normalize(document.allocator, prefix, eql(name, "token_class") and spacedPipes(prefix));
        if (block) |code| {
            const code_text = slice(document.source, code);
            item.opening_comment = openingComment(code_text);
            const body = code_text[1 .. code_text.len - 1];
            item.raw_code = code_text;
            if (localCode(name)) {
                const content = try normalizeParameter(document.allocator, body);
                item.raw_code = if (typeCode(name))
                    try std.fmt.allocPrint(document.allocator, "{{{s}}}", .{content})
                else
                    try std.fmt.allocPrint(document.allocator, "{{ {s} }}", .{content});
            } else {
                item.block = hasNewline(code_text) or eql(name, "include") or eql(name, "code");
                var aliases: std.ArrayList([]const u8) = .empty;
                if (children.named_action) |action| {
                    var cursor = action.walk();
                    defer cursor.destroy();
                    if (cursor.gotoFirstChild()) while (true) {
                        const child = cursor.node();
                        if (eql(child.kind(), "rule_alias")) try aliases.append(document.allocator, slice(document.source, child));
                        if (!cursor.gotoNextSibling()) break;
                    };
                }
                item.job = try document.job(body, if (eql(name, "include") or eql(name, "code")) .declarations else .statements, aliases.items);
            }
        }
    }

    fn job(document: *Document, text: []const u8, context: ZigCode.Context, aliases: []const []const u8) OOM!*ZigCode.Job {
        const work = try document.allocator.create(ZigCode.Job);
        work.* = .{ .original = text, .context = context, .aliases = aliases };
        document.queue.submit(work);
        return work;
    }

    fn findDisabled(document: *Document) OOM!void {
        var start: ?usize = null;
        var i: usize = 0;
        while (i < document.source.len) {
            const end = ZigCode.opaqueEnd(document.source, i);
            if (!document.crlf) {
                document.crlf = if (end != i) std.mem.indexOf(u8, document.source[i..@min(end + 1, document.source.len)], "\r\n") != null else std.mem.startsWith(u8, document.source[i..], "\r\n");
            }
            if (end != i) {
                if (std.mem.startsWith(u8, document.source[i..], "//") or std.mem.startsWith(u8, document.source[i..], "/*")) {
                    if (control(document.source[i..end])) |enabled| {
                        if (!enabled and start == null) start = i;
                        if (enabled) if (start) |begin| {
                            try document.disabled.append(document.allocator, .{ .start = begin, .end = end });
                            start = null;
                        };
                    }
                }
                i = end;
            } else i += 1;
        }
        if (start) |begin| try document.disabled.append(document.allocator, .{ .start = begin, .end = document.source.len });
    }

    fn protected(document: Document, start: usize, end: usize) bool {
        var lo: usize = 0;
        var hi = document.disabled.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (document.disabled.items[mid].end <= start) lo = mid + 1 else hi = mid;
        }
        return lo < document.disabled.items.len and document.disabled.items[lo].start < end;
    }

    fn prepare(document: *Document) OOM!void {
        for (document.items.items, 0..) |*item, index| {
            if (item.rule) |*rule| {
                if (rule.job) |work| {
                    if (work.result) |text| {
                        const body = std.mem.trim(u8, text, " \t\r\n");
                        const line = if (rule.block) null else try compactCode(document.allocator, body);
                        rule.block = line == null;
                        rule.tail = if (rule.block) .code_block else .code_line;
                        rule.action = if (line) |code| try std.fmt.allocPrint(document.allocator, "{{ {s} }}", .{code}) else text;
                    } else rule.code_failed = true;
                }
                if (rule.block) rule.dropped = false;
                rule.action_width = width(rule.action);
                rule.suffix_width = 1 + if (rule.precedence.len != 0) 1 + width(rule.precedence) else @as(usize, 0);
                var end_width: usize = 0;
                for (rule.particles) |*particle| {
                    end_width += width(particle.text) + 1;
                    particle.end_width = end_width;
                }
            } else if (item.job) |work| {
                if (work.result) |text| {
                    const body = std.mem.trim(u8, text, " \t\r\n");
                    const line = if (item.block) null else try compactCode(document.allocator, body);
                    item.block = line == null or width(item.text) + 5 + width(line.?) > 100;
                    item.raw_code = if (item.block) text else try std.fmt.allocPrint(document.allocator, "{{ {s} }}", .{line.?});
                }
            }
            item.comment_width = width(item.comment);
            if (item.kind == .comment and index + 1 < document.items.items.len and document.items.items[index + 1].kind == .comment) {
                item.long_comment = true;
                document.items.items[index + 1].long_comment = true;
            }
        }
        try document.dittosAndBoundaries();
    }

    fn dittosAndBoundaries(document: *Document) OOM!void {
        var previous_rule: ?usize = null;
        var head: ?usize = null;
        var ditto_mode: ?bool = null;
        var pending: Break = .none;
        var restart = false;
        var saw_comment = false;
        var saw_long_comment = false;
        var comment_blank_before = false;
        var last_category: ?Kind = null;
        var comment_start: ?usize = null;
        for (document.items.items, 0..) |*item, index| {
            if (item.kind == .comment) {
                if (comment_start == null) comment_start = index;
                saw_comment = true;
                saw_long_comment = saw_long_comment or item.long_comment;
                comment_blank_before = comment_blank_before or item.blanks != 0;
                if (item.long_comment) {
                    if (index == 0 or document.items.items[index - 1].kind != .comment) item.blanks = @max(item.blanks, 1);
                    restart = true;
                }
                pending = stronger(pending, .soft);
                continue;
            }
            const rule = if (item.rule) |*r| r else null;
            if (last_category) |last| {
                if ((last == .rule and item.kind == .directive) or (last == .directive and item.kind == .rule)) {
                    const target = if (comment_start) |c| &document.items.items[c] else item;
                    target.blanks = @max(target.blanks, 1);
                }
            }
            if (rule) |r| {
                const previous = if (previous_rule) |p| &document.items.items[p].rule.? else null;
                const same = if (previous) |p| eql(p.lhs, r.lhs) else false;
                var boundary = pending;
                if (!same) {
                    boundary = stronger(boundary, if (item.blanks >= 2 or saw_long_comment or (saw_comment and (comment_blank_before or item.blanks != 0))) .hard else .soft);
                    restart = true;
                } else if (item.blanks >= 2) boundary = stronger(boundary, .soft);
                if (saw_comment and item.blanks != 0) {
                    restart = true;
                    if (comment_start) |c| document.items.items[c].blanks = @max(document.items.items[c].blanks, 1);
                }
                if (head == null or restart) {
                    head = index;
                    ditto_mode = null;
                    r.ditto = false;
                } else {
                    if (ditto_mode == null) ditto_mode = r.input_ditto;
                    r.ditto = ditto_mode.?;
                }
                r.rhs_column = width(r.lhs) + 5;
                if (r.ditto) {
                    r.rhs_column = document.items.items[head.?].rule.?.rhs_column;
                    if (item.blanks == 1 and !saw_comment and !(if (previous) |p| p.block else false)) item.blanks = 0;
                }
                r.pattern = makePattern(r.*, null, false);
                r.joined_width = r.rhs_column + particleWidth(r.*, 0, r.particles.len) + r.suffix_width;
                if (r.particles.len >= 2) {
                    r.balanced_cuts = .{ balancedPattern(r.*, false).split.?, balancedPattern(r.*, true).split.? };
                }
                if (r.tail == .none and item.comment.len != 0) r.tail = .comment;
                item.boundary = if (previous_rule == null) .hard else boundary;
                item.connected = previous != null and !same and boundary == .soft and !previous.?.block;
                previous_rule = index;
                pending = if (r.block) .soft else .none;
                if (r.block and index + 1 < document.items.items.len) document.items.items[index + 1].blanks = @max(document.items.items[index + 1].blanks, 1);
                restart = false;
            } else {
                pending = .hard;
                restart = true;
                head = null;
                if (item.block and index + 1 < document.items.items.len) document.items.items[index + 1].blanks = @max(document.items.items[index + 1].blanks, 1);
            }
            last_category = item.kind;
            saw_comment = false;
            saw_long_comment = false;
            comment_blank_before = false;
            comment_start = null;
        }
    }

    fn particleWidth(rule: Rule, first: usize, end: usize) usize {
        if (first == end) return 0;
        return rule.particles[end - 1].end_width - (if (first == 0) 0 else rule.particles[first - 1].end_width) - 1;
    }

    fn makePattern(rule: Rule, split: ?usize, short_indent: bool) Pattern {
        var pattern = Pattern{ .split = split, .short_indent = short_indent };
        const indent = if (short_indent) 4 else rule.rhs_column;
        if (split) |cut| {
            pattern.addLine(rule.rhs_column + particleWidth(rule, 0, cut));
            pattern.addLine(indent + particleWidth(rule, cut, rule.particles.len) + rule.suffix_width);
        } else {
            var first: usize = 0;
            for (rule.particles, 0..) |particle, i| {
                if (particle.line and i != 0) {
                    pattern.addLine(rule.rhs_column + particleWidth(rule, first, i));
                    first = i;
                }
            }
            pattern.addLine(rule.rhs_column + particleWidth(rule, first, rule.particles.len) + rule.suffix_width);
        }
        if (builtin.is_test) verifyPattern(rule, pattern);
        return pattern;
    }

    fn layout(document: *Document) OOM!void {
        var scratch = FitScratch{};
        defer scratch.deinit(document.allocator);
        try document.collectRuns();
        while (true) {
            var new_blocks = false;
            for (document.runs.items) |*run| new_blocks = try document.fit(run, &scratch) or new_blocks;
            if (!new_blocks) break;
            try document.collectRuns();
        }
        var previous: ?usize = null;
        for (document.runs.items, 0..) |*run, index| {
            if (run.column == 0) {
                previous = null;
                continue;
            }
            if (previous) |p| {
                const upper = &document.runs.items[p];
                const difference = (upper.column -| run.column) + (run.column -| upper.column);
                const target = @max(upper.column, run.column);
                const sparse = run.connected and (document.minimumAfterSpace(run.*, target) >= 12 or document.minimumAfterSpace(upper.*, target) >= 12);
                const limit: usize = if (run.boundary == .hard or run.fitted or upper.fitted or sparse) 4 else 12;
                if (difference > 0 and difference < limit) {
                    if (upper.column < target and !upper.bumped and document.canBump(upper.*, target)) {
                        document.setColumn(upper, target);
                        run.bumped = true;
                    } else if (run.column < target and document.canBump(run.*, target)) {
                        document.setColumn(run, target);
                        run.bumped = true;
                    }
                }
                if (run.boundary == .soft and run.column != upper.column) {
                    const item = &document.items.items[run.first];
                    if (!eql(item.rule.?.lhs, document.items.items[upper.first].rule.?.lhs)) item.blanks = @max(item.blanks, 1);
                }
            }
            previous = index;
        }
        for (document.runs.items) |*run| {
            document.undrop(run);
            document.setColumn(run, run.column);
        }
    }

    fn undrop(document: *Document, run: *Run) void {
        if (run.column == 0) return;
        while (true) {
            var changed = false;
            for (run.first..run.end) |index| {
                const rule = if (document.items.items[index].rule) |*r| r else continue;
                if (!rule.dropped or (rule.tail != .code_line and rule.tail != .action)) continue;
                if (rule.pattern.last_width + 2 > run.column or run.column + rule.action_width > 90) continue;
                var candidate = rule.*;
                candidate.dropped = false;
                if (document.columnFor(run.*, index, candidate) > run.column) continue;
                rule.dropped = false;
                changed = true;
            }
            if (!changed) break;
        }
    }

    fn precedingTail(document: Document, run: Run) ?Rule {
        const first = document.items.items[run.first];
        if (first.boundary == .hard or first.blanks >= 2) return null;
        var index = run.first;
        while (index > 0) {
            index -= 1;
            const item = document.items.items[index];
            if (item.kind == .comment) {
                if (item.long_comment or item.blanks >= 2) return null;
                continue;
            }
            const rule = item.rule orelse return null;
            if (!eql(rule.lhs, first.rule.?.lhs)) return null;
            return if (rule.tail == .action or rule.tail == .code_line) rule else null;
        }
        return null;
    }

    fn collectRuns(document: *Document) OOM!void {
        document.runs.clearRetainingCapacity();
        var start: ?usize = null;
        var after_block = false;
        for (document.items.items, 0..) |*item, index| {
            if (item.rule != null) {
                if (after_block) item.boundary = stronger(item.boundary, .soft);
                after_block = item.rule.?.block;
                if (start != null and (item.boundary != .none or item.rule.?.block)) {
                    try document.runs.append(document.allocator, document.newRun(start.?, index));
                    start = null;
                }
                if (start == null) start = index;
                if (item.rule.?.block) {
                    try document.runs.append(document.allocator, document.newRun(start.?, index + 1));
                    start = null;
                }
            } else if (item.kind != .comment and start != null) {
                try document.runs.append(document.allocator, document.newRun(start.?, index));
                start = null;
            }
        }
        if (start) |first| try document.runs.append(document.allocator, document.newRun(first, document.items.items.len));
    }

    fn newRun(document: Document, first: usize, end: usize) Run {
        return .{ .first = first, .end = end, .boundary = document.items.items[first].boundary, .connected = document.items.items[first].connected };
    }

    fn fit(document: *Document, run: *Run, scratch: *FitScratch) OOM!bool {
        var new_blocks = false;
        document.pullComments(run.*);
        var attempts: usize = 0;
        while (attempts < (run.end - run.first) * 4) : (attempts += 1) {
            const column = document.columnFor(run.*, null, null);
            const current_score = document.score(run.*, column, null, null);
            if (current_score.overflow == 0 and current_score.marginal == 0) break;
            try scratch.reset(document, run.*);
            var reference: ?Candidate = null;
            for (run.first..run.end) |index| {
                const rule = if (document.items.items[index].rule) |r| r else continue;
                if (rule.particles.len >= 2 and rule.stage < 2) {
                    for (rule.stage + 1..3) |stage| {
                        var candidate = rule;
                        candidate.stage = @intCast(stage);
                        candidate.pattern = makePattern(rule, rule.balanced_cuts[stage - 1], stage == 2);
                        try scratch.submit(index, candidate);
                        if (builtin.is_test) document.consider(run.*, index, candidate, current_score, &reference);
                    }
                }
                if ((rule.tail == .code_line or rule.tail == .action) and !rule.dropped) {
                    var candidate = rule;
                    candidate.dropped = true;
                    candidate.newly_dropped = true;
                    if (candidate.tail == .code_line and 4 + candidate.action_width > 100 and !candidate.code_failed) {
                        candidate.block = true;
                        candidate.tail = .code_block;
                        candidate.action = if (candidate.job) |work| work.result orelse candidate.action else candidate.action;
                        candidate.action_width = width(candidate.action);
                        candidate.dropped = false;
                    }
                    try scratch.submit(index, candidate);
                    if (builtin.is_test) document.consider(run.*, index, candidate, current_score, &reference);
                }
            }
            const best = scratch.best(current_score);
            if (builtin.is_test) {
                std.debug.assert((best == null) == (reference == null));
                if (best) |choice| {
                    const expected = reference.?;
                    std.debug.assert(choice.index == expected.index);
                    std.debug.assert(choice.rule.stage == expected.rule.stage);
                    std.debug.assert(choice.rule.dropped == expected.rule.dropped);
                    std.debug.assert(choice.rule.block == expected.rule.block);
                    std.debug.assert(std.meta.eql(choice.score, expected.score));
                }
            }
            if (best) |choice| {
                new_blocks = new_blocks or (choice.rule.block and !document.items.items[choice.index].rule.?.block);
                document.items.items[choice.index].rule = choice.rule;
                document.pullComments(run.*);
                if ((choice.rule.newly_dropped or choice.rule.block) and choice.index + 1 < document.items.items.len) {
                    const next = &document.items.items[choice.index + 1];
                    const ditto = if (next.rule) |r| r.ditto else false;
                    if (choice.rule.block or !ditto) next.blanks = @max(next.blanks, 1);
                }
            } else break;
        }
        document.setColumn(run, document.columnFor(run.*, null, null));
        for (run.first..run.end) |index| {
            const item = &document.items.items[index];
            if (item.rule) |*rule| {
                if (rule.tail == .comment and run.column + item.comment_width > 100) rule.pulled_comment = true;
            }
        }
        run.fitted = document.requiresFitting(run.*);
        return new_blocks;
    }

    fn pullComments(document: *Document, run: Run) void {
        const column = document.columnFor(run, null, null);
        for (run.first..run.end) |index| {
            const item = &document.items.items[index];
            if (item.rule) |*rule| {
                if (rule.tail == .comment and column + item.comment_width > 100) rule.pulled_comment = true;
            }
        }
    }

    fn requiresFitting(document: Document, run: Run) bool {
        var maximum: usize = 0;
        var tail: usize = 0;
        var structural = false;
        var pattern_overflow = false;
        for (run.first..run.end) |index| {
            const rule = document.items.items[index].rule orelse continue;
            if (rule.block) continue;
            const joined = rule.joined_width;
            pattern_overflow = pattern_overflow or joined > 78;
            if (!rule.dropped and (rule.tail == .action or rule.tail == .code_line)) {
                maximum = @max(maximum, joined);
                tail = @max(tail, rule.action_width);
            }
            structural = structural or rule.pattern.line_count > 1 or rule.dropped;
        }
        return structural and (pattern_overflow or (tail != 0 and maximum + 2 + tail > 90));
    }

    const Score = struct {
        overflow: usize = 0,
        excess: usize = 0,
        marginal: usize = 0,
        changes: usize = 0,

        fn less(a: Score, b: Score) bool {
            inline for (.{ "overflow", "excess", "marginal", "changes" }) |field| {
                if (@field(a, field) != @field(b, field)) return @field(a, field) < @field(b, field);
            }
            return false;
        }
    };
    const Candidate = struct {
        index: usize,
        rule: Rule,
        score: Score = .{},
        order: usize = 0,
        column: usize = 0,
        next: ?usize = null,
    };

    const ColumnSummary = struct {
        maximum: usize = 0,
        tail_width: usize = 0,
        any_tail: bool = false,
        pulled: bool = false,

        fn from(item: Item, rule: ?Rule) ColumnSummary {
            const r = rule orelse return .{};
            const tail = !r.block and !r.dropped and r.tail != .none;
            return .{
                .maximum = if (tail and !r.pulled_comment) r.pattern.width else 0,
                .tail_width = if (tail) (if (r.tail == .comment) item.comment_width else r.action_width) else 0,
                .any_tail = tail and !r.pulled_comment,
                .pulled = r.pulled_comment,
            };
        }

        fn combine(a: ColumnSummary, b: ColumnSummary) ColumnSummary {
            return .{
                .maximum = @max(a.maximum, b.maximum),
                .tail_width = @max(a.tail_width, b.tail_width),
                .any_tail = a.any_tail or b.any_tail,
                .pulled = a.pulled or b.pulled,
            };
        }

        fn column(summary: ColumnSummary) usize {
            if (!summary.any_tail) return 0;
            const padding: usize = if (summary.maximum <= 35 and !summary.pulled and summary.maximum + 3 + summary.tail_width <= 90) 3 else 2;
            return summary.maximum + padding;
        }
    };

    const FitScratch = struct {
        const STATE_COUNT = 102;
        const NO_CLOSING = 101;
        const Total = struct {
            score: Score = .{},
            linear: usize = 0,

            fn add(a: Total, b: Total) Total {
                var result = Total{ .linear = a.linear + b.linear };
                inline for (.{ "overflow", "excess", "marginal", "changes" }) |field| {
                    @field(result.score, field) = @field(a.score, field) + @field(b.score, field);
                }
                return result;
            }
        };
        const Prefix = struct { total: Total = .{}, closing: usize = NO_CLOSING };
        const Memo = struct { generation: usize = 0, total: Total = undefined };
        const Path = struct { key: usize, total: Total };

        document: *Document = undefined,
        run: Run = undefined,
        rows: []const Item = &.{},
        above: ?Rule = null,
        before: std.ArrayList(ColumnSummary) = .empty,
        after: std.ArrayList(ColumnSummary) = .empty,
        prefix: std.ArrayList(Prefix) = .empty,
        memo: std.ArrayList(Memo) = .empty,
        memo_offsets: std.ArrayList(usize) = .empty,
        path: std.ArrayList(Path) = .empty,
        candidates: std.ArrayList(Candidate) = .empty,
        heads: [STATE_COUNT]?usize = @splat(null),
        generation: usize = 0,
        column: usize = 0,
        opening: usize = 0,

        fn deinit(scratch: *FitScratch, allocator: Allocator) void {
            scratch.before.deinit(allocator);
            scratch.after.deinit(allocator);
            scratch.prefix.deinit(allocator);
            scratch.memo.deinit(allocator);
            scratch.memo_offsets.deinit(allocator);
            scratch.path.deinit(allocator);
            scratch.candidates.deinit(allocator);
        }

        fn reset(scratch: *FitScratch, document: *Document, run: Run) OOM!void {
            scratch.document = document;
            scratch.run = run;
            scratch.rows = document.items.items[run.first..run.end];
            scratch.above = document.precedingTail(run);
            const count = scratch.rows.len;
            const allocator = document.allocator;
            try scratch.before.resize(allocator, count + 1);
            try scratch.after.resize(allocator, count + 1);
            try scratch.prefix.resize(allocator, count + 1);
            try scratch.memo_offsets.resize(allocator, count + 1);
            scratch.memo_offsets.items[0] = 0;
            for (scratch.rows, 0..) |item, i| {
                const slots: usize = if (item.rule) |rule|
                    (if (rule.dropped and (rule.tail == .action or rule.tail == .code_line) and rule.action_width <= 96) 98 - rule.action_width else 1)
                else if (item.kind == .comment) 0 else 1;
                scratch.memo_offsets.items[i + 1] = scratch.memo_offsets.items[i] + slots;
            }
            const previous = scratch.memo.items.len;
            try scratch.memo.resize(allocator, scratch.memo_offsets.items[count]);
            if (scratch.memo.items.len > previous) for (scratch.memo.items[previous..]) |*entry| {
                entry.generation = 0;
            };
            try scratch.path.ensureTotalCapacity(allocator, count);
            scratch.candidates.clearRetainingCapacity();
            scratch.heads = @splat(null);
            scratch.before.items[0] = .{};
            for (scratch.rows, 0..) |item, i| scratch.before.items[i + 1] = scratch.before.items[i].combine(ColumnSummary.from(item, item.rule));
            scratch.after.items[count] = .{};
            var i = count;
            while (i != 0) {
                i -= 1;
                scratch.after.items[i] = ColumnSummary.from(scratch.rows[i], scratch.rows[i].rule).combine(scratch.after.items[i + 1]);
            }
        }

        fn submit(scratch: *FitScratch, index: usize, rule: Rule) OOM!void {
            const local = index - scratch.run.first;
            const column = scratch.before.items[local].combine(ColumnSummary.from(scratch.rows[local], rule)).combine(scratch.after.items[local + 1]).column();
            if (builtin.is_test) std.debug.assert(column == scratch.document.columnFor(scratch.run, index, rule));
            const bucket = @min(column, NO_CLOSING);
            const order = scratch.candidates.items.len;
            try scratch.candidates.append(scratch.document.allocator, .{
                .index = index,
                .rule = rule,
                .order = order,
                .column = column,
                .next = scratch.heads[bucket],
            });
            scratch.heads[bucket] = order;
        }

        fn beginColumn(scratch: *FitScratch, column: usize) void {
            scratch.generation += 1;
            scratch.column = column;
            scratch.opening = if (column == 0 and scratch.above != null) scratch.above.?.tail_column else column;
            scratch.prefix.items[0] = .{ .closing = if (scratch.above) |rule| @min(NO_CLOSING, (if (rule.dropped) rule.drop_column else rule.tail_column) + rule.action_width) else NO_CLOSING };
            for (scratch.rows, 0..) |item, i| {
                const previous = scratch.prefix.items[i];
                var next = scratch.step(item, item.rule, previous.closing);
                next.total = previous.total.add(next.total);
                scratch.prefix.items[i + 1] = next;
            }
        }

        fn step(scratch: *const FitScratch, item: Item, replacement: ?Rule, closing: usize) Prefix {
            const rule = replacement orelse return .{ .closing = if (item.kind == .comment) closing else NO_CLOSING };
            const action_column = if (rule.dropped) dropColumn(rule, scratch.opening, if (closing == NO_CLOSING) null else closing) else scratch.column;
            const has_action = rule.tail == .action or rule.tail == .code_line;
            const end = action_column + rule.action_width;
            var result = Prefix{
                .closing = if (has_action) @min(NO_CLOSING, end) else NO_CLOSING,
                .total = .{ .score = .{
                    .overflow = rule.pattern.overflow,
                    .excess = rule.pattern.excess,
                    .changes = rule.stage + @as(usize, if (rule.newly_dropped) 3 else 0),
                } },
            };
            if (!rule.block and has_action) {
                if (end > 100) {
                    result.total.score.overflow += 1;
                    result.total.score.excess += end - 100;
                } else if (end > 90) result.total.score.marginal += 1;
                result.total.linear = @intFromBool(!rule.dropped);
            }
            return result;
        }

        fn suffix(scratch: *FitScratch, start: usize, incoming: usize) Total {
            scratch.path.clearRetainingCapacity();
            var index = start;
            var closing = incoming;
            var total = Total{};
            while (index < scratch.rows.len) : (index += 1) {
                const base = scratch.memo_offsets.items[index];
                const slots = scratch.memo_offsets.items[index + 1] - base;
                if (slots == 0) continue;
                const first = STATE_COUNT - slots;
                const key = base + if (slots > 1 and closing >= first and closing < NO_CLOSING) 1 + closing - first else @as(usize, 0);
                const entry = scratch.memo.items[key];
                if (entry.generation == scratch.generation) {
                    total = entry.total;
                    break;
                }
                const next = scratch.step(scratch.rows[index], scratch.rows[index].rule, closing);
                scratch.path.appendAssumeCapacity(.{ .key = key, .total = next.total });
                closing = next.closing;
            }
            var i = scratch.path.items.len;
            while (i != 0) {
                i -= 1;
                const part = scratch.path.items[i];
                total = part.total.add(total);
                scratch.memo.items[part.key] = .{ .generation = scratch.generation, .total = total };
            }
            return total;
        }

        fn best(scratch: *FitScratch, current: Score) ?Candidate {
            var selected: ?Candidate = null;
            for (scratch.heads, 0..) |head, column| {
                if (head == null) continue;
                scratch.beginColumn(column);
                var next = head;
                while (next) |at| {
                    var candidate = scratch.candidates.items[at];
                    next = candidate.next;
                    const local = candidate.index - scratch.run.first;
                    const before = scratch.prefix.items[local];
                    const middle = scratch.step(scratch.rows[local], candidate.rule, before.closing);
                    var total = before.total.add(middle.total).add(scratch.suffix(local + 1, middle.closing));
                    total.score.excess += total.linear * (candidate.column - column);
                    candidate.score = total.score;
                    if (builtin.is_test) std.debug.assert(std.meta.eql(candidate.score, scratch.document.score(scratch.run, candidate.column, candidate.index, candidate.rule)));
                    if (!candidate.score.less(current)) continue;
                    if (selected) |old| {
                        if (old.score.less(candidate.score)) continue;
                        if (!candidate.score.less(old.score)) {
                            if (ruleLess(old.rule, candidate.rule)) continue;
                            if (!ruleLess(candidate.rule, old.rule) and candidate.order > old.order) continue;
                        }
                    }
                    selected = candidate;
                }
            }
            return selected;
        }
    };

    fn consider(document: Document, run: Run, index: usize, rule: Rule, current: Score, best: *?Candidate) void {
        const column = document.columnFor(run, index, rule);
        const candidate_score = document.score(run, column, index, rule);
        if (!candidate_score.less(current)) return;
        if (best.*) |old| {
            if (!candidate_score.less(old.score)) {
                if (old.score.less(candidate_score) or !ruleLess(rule, old.rule)) return;
            }
        }
        best.* = .{ .index = index, .rule = rule, .score = candidate_score };
    }

    fn balancedPattern(rule: Rule, short_indent: bool) Pattern {
        var lo: usize = 1;
        var hi = rule.particles.len;
        while (lo < hi) {
            const cut = lo + (hi - lo) / 2;
            const first = rule.rhs_column + particleWidth(rule, 0, cut);
            const last = (if (short_indent) 4 else rule.rhs_column) + particleWidth(rule, cut, rule.particles.len) + rule.suffix_width;
            if (last >= first) lo = cut + 1 else hi = cut;
        }
        const cut = @max(1, lo - 1);
        if (builtin.is_test) {
            var selected: usize = 1;
            var difference: usize = std.math.maxInt(usize);
            for (1..rule.particles.len) |candidate| {
                const first = rule.rhs_column + particleWidth(rule, 0, candidate);
                const last = (if (short_indent) 4 else rule.rhs_column) + particleWidth(rule, candidate, rule.particles.len) + rule.suffix_width;
                if (last >= first and last - first < difference) {
                    selected = candidate;
                    difference = last - first;
                }
            }
            std.debug.assert(cut == selected);
        }
        return makePattern(rule, cut, short_indent);
    }

    fn columnFor(document: Document, run: Run, replacement_index: ?usize, replacement: ?Rule) usize {
        var maximum: usize = 0;
        var any_tail = false;
        for (run.first..run.end) |index| {
            const rule = (if (replacement_index == index) replacement else document.items.items[index].rule) orelse continue;
            if (rule.block or rule.pulled_comment or rule.dropped or rule.tail == .none) continue;
            maximum = @max(maximum, rule.pattern.width);
            any_tail = true;
        }
        if (!any_tail) return 0;
        var padding: usize = if (maximum <= 35) 3 else 2;
        for (run.first..run.end) |index| {
            const item = document.items.items[index];
            const rule = (if (replacement_index == index) replacement else item.rule) orelse continue;
            if (rule.pulled_comment) padding = 2;
            if (rule.block or rule.dropped or rule.tail == .none) continue;
            const tail_width = (if (rule.tail == .comment) item.comment_width else rule.action_width);
            if (maximum + padding + tail_width > 90) padding = 2;
        }
        return maximum + padding;
    }

    fn score(document: Document, run: Run, column: usize, replacement_index: ?usize, replacement: ?Rule) Score {
        var result = Score{};
        const above = document.precedingTail(run);
        const opening = if (column == 0 and above != null) above.?.tail_column else column;
        var closing: ?usize = if (above) |rule| (if (rule.dropped) rule.drop_column else rule.tail_column) + rule.action_width else null;
        for (run.first..run.end) |index| {
            const rule = (if (replacement_index == index) replacement else document.items.items[index].rule) orelse {
                if (document.items.items[index].kind != .comment) closing = null;
                continue;
            };
            const action_column = if (rule.dropped) dropColumn(rule, opening, closing) else column;
            closing = if (rule.tail == .action or rule.tail == .code_line) action_column + rule.action_width else null;
            result.changes += rule.stage + @as(usize, if (rule.newly_dropped) 3 else 0);
            result.overflow += rule.pattern.overflow;
            result.excess += rule.pattern.excess;
            if (!rule.block and (rule.tail == .action or rule.tail == .code_line)) {
                const count = action_column + rule.action_width;
                if (count > 100) {
                    result.overflow += 1;
                    result.excess += count - 100;
                } else if (count > 90) result.marginal += 1;
            }
        }
        return result;
    }

    fn setColumn(document: *Document, run: *Run, column: usize) void {
        run.column = column;
        var comment_column: usize = 0;
        const above = document.precedingTail(run.*);
        const opening = if (column == 0 and above != null) above.?.tail_column else column;
        var closing: ?usize = if (above) |rule| (if (rule.dropped) rule.drop_column else rule.tail_column) + rule.action_width else null;
        for (run.first..run.end) |index| {
            const item = &document.items.items[index];
            const rule = if (item.rule) |*r| r else {
                if (item.kind != .comment) closing = null;
                continue;
            };
            if (rule.dropped) rule.drop_column = dropColumn(rule.*, opening, closing);
            const end = (if (rule.dropped) rule.drop_column else column) + rule.action_width;
            closing = if (rule.tail == .action or rule.tail == .code_line) end else null;
            if (item.comment.len == 0 or rule.tail == .comment or rule.block) continue;
            comment_column = @max(comment_column, end + 2);
        }
        for (run.first..run.end) |index| {
            if (document.items.items[index].rule) |*rule| {
                rule.tail_column = opening;
                rule.comment_column = comment_column;
            }
        }
    }

    fn canBump(document: Document, run: Run, column: usize) bool {
        for (run.first..run.end) |index| {
            const item = document.items.items[index];
            const rule = item.rule orelse continue;
            if (rule.block or rule.dropped or rule.tail == .none or rule.tail == .comment) continue;
            if (column + rule.action_width > 90) return false;
        }
        return true;
    }

    fn minimumAfterSpace(document: Document, run: Run, column: usize) usize {
        var minimum: usize = std.math.maxInt(usize);
        for (run.first..run.end) |index| {
            const rule = document.items.items[index].rule orelse continue;
            if (rule.block or rule.dropped or rule.tail == .none or rule.pulled_comment) continue;
            minimum = @min(minimum, column -| rule.pattern.width);
        }
        return minimum;
    }

    fn render(document: Document, allocator: Allocator) OOM![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, document.source.len);
        const newline: []const u8 = if (document.crlf) "\r\n" else "\n";
        var previous_raw = false;
        for (document.items.items, 0..) |item, index| {
            if (item.kind == .raw or previous_raw) {
                try output.appendSlice(allocator, item.gap);
            } else if (index == 0) {
                for (0..std.mem.count(u8, item.gap, "\n")) |_| try output.appendSlice(allocator, newline);
            } else {
                for (0..item.blanks + 1) |_| try output.appendSlice(allocator, newline);
            }
            if (item.rule) |rule| {
                try emitPattern(allocator, &output, rule, newline);
                if (rule.tail == .code_block) {
                    try output.appendSlice(allocator, "  ");
                    if (rule.code_failed) try output.appendSlice(allocator, rule.action) else try emitBlock(allocator, &output, rule.action, newline, rule.opening_comment);
                } else if (rule.tail == .action or rule.tail == .code_line) {
                    if (rule.dropped) {
                        try output.appendSlice(allocator, newline);
                        try spaces(allocator, &output, rule.drop_column);
                    } else try spaces(allocator, &output, @max(2, rule.tail_column -| rule.pattern.last_width));
                    try output.appendSlice(allocator, rule.action);
                }
                if (item.comment.len != 0) {
                    const action_end = (if (rule.dropped) rule.drop_column else rule.tail_column) + rule.action_width;
                    const padding = if (rule.tail == .comment and !rule.pulled_comment)
                        @max(2, rule.tail_column -| rule.pattern.last_width)
                    else if (!rule.block and rule.tail != .comment and rule.comment_column + item.comment_width <= 100)
                        @max(2, rule.comment_column -| action_end)
                    else
                        2;
                    try spaces(allocator, &output, padding);
                    try output.appendSlice(allocator, item.comment);
                }
            } else if (item.kind == .directive) {
                try output.appendSlice(allocator, item.text);
                if (item.raw_code.len != 0) {
                    try output.append(allocator, ' ');
                    if (item.block and item.job != null and item.job.?.result != null) {
                        try emitBlock(allocator, &output, item.raw_code, newline, item.opening_comment);
                    } else try output.appendSlice(allocator, item.raw_code);
                }
                if (item.comment.len != 0) {
                    try output.appendSlice(allocator, "  ");
                    try output.appendSlice(allocator, item.comment);
                }
            } else if (item.kind == .raw) {
                try output.appendSlice(allocator, item.text);
            } else try appendNewlines(allocator, &output, item.text, newline);
            previous_raw = item.kind == .raw;
        }
        const end = if (document.items.items.len != 0) document.items.items[document.items.items.len - 1].end else 0;
        const suffix = document.source[end..];
        if (previous_raw or document.protected(end, document.source.len)) {
            try output.appendSlice(allocator, suffix);
        } else {
            for (0..std.mem.count(u8, suffix, "\n")) |_| try output.appendSlice(allocator, newline);
        }
        return output.toOwnedSlice(allocator);
    }
};

const Children = struct {
    lhs: ?Node = null,
    rhs: ?Node = null,
    nonterminal: ?Node = null,
    rule_alias: ?Node = null,
    precedence_mark: ?Node = null,
    named_action: ?Node = null,
    code_block: ?Node = null,
    directive_name: ?Node = null,
    commented: bool = false,

    fn init(node: Node) Children {
        var children: Children = .{};
        var cursor = node.walk();
        defer cursor.destroy();
        if (!cursor.gotoFirstChild()) return children;
        while (true) {
            const child = cursor.node();
            const kind = child.kind();
            inline for (.{ "lhs", "rhs", "nonterminal", "rule_alias", "precedence_mark", "named_action", "code_block" }) |name| {
                if (@field(children, name) == null and eql(kind, name)) @field(children, name) = child;
            }
            if (children.directive_name == null and std.mem.endsWith(u8, kind, "_name")) children.directive_name = child;
            children.commented = children.commented or hasSyntaxComment(child);
            if (!cursor.gotoNextSibling()) return children;
        }
    }
};

fn hasSyntaxComment(node: Node) bool {
    if (eql(node.kind(), "code_block")) return false;
    if (eql(node.kind(), "comment")) return true;
    var cursor = node.walk();
    defer cursor.destroy();
    if (cursor.gotoFirstChild()) while (true) {
        if (hasSyntaxComment(cursor.node())) return true;
        if (!cursor.gotoNextSibling()) break;
    };
    return false;
}

fn particleKind(kind: []const u8) bool {
    return eql(kind, "nonterminal") or eql(kind, "terminal") or eql(kind, "multiterminal");
}

fn localCode(name: []const u8) bool {
    return eql(name, "extra_argument") or eql(name, "extra_context") or typeCode(name);
}

fn typeCode(name: []const u8) bool {
    return eql(name, "type") or eql(name, "token_type") or
        eql(name, "default_type") or eql(name, "parse_error_type");
}

fn dropColumn(rule: Rule, column: usize, closing: ?usize) usize {
    const length = rule.action_width;
    if (column != 0 and column + length <= 90) return column;
    if (closing) |end| {
        if (end >= length + 4 and end <= 100) return end - length;
    }
    return if (rule.rhs_column + length <= 100) rule.rhs_column else 4;
}

fn ruleLess(a: Rule, b: Rule) bool {
    const lhs_order = std.mem.order(u8, a.lhs, b.lhs);
    if (lhs_order != .eq) return lhs_order == .lt;
    for (a.particles[0..@min(a.particles.len, b.particles.len)], b.particles[0..@min(a.particles.len, b.particles.len)]) |left, right| {
        const order = std.mem.order(u8, left.text, right.text);
        if (order != .eq) return order == .lt;
    }
    if (a.particles.len != b.particles.len) return a.particles.len < b.particles.len;
    return std.mem.order(u8, a.action, b.action) == .lt;
}

fn emitPattern(allocator: Allocator, output: *std.ArrayList(u8), rule: Rule, newline: []const u8) OOM!void {
    if (rule.ditto) {
        const indent: usize = if (rule.name_length >= 8) 2 else 1;
        try spaces(allocator, output, indent);
        try output.appendSlice(allocator, "``");
        try spaces(allocator, output, rule.rhs_column - indent - 2);
    } else {
        try output.appendSlice(allocator, rule.lhs);
        try output.appendSlice(allocator, " ::= ");
    }
    for (rule.particles, 0..) |particle, i| {
        const line = if (rule.pattern.split) |cut| i == cut else particle.line and i != 0;
        if (line) {
            try output.appendSlice(allocator, newline);
            try spaces(allocator, output, if (rule.pattern.short_indent) 4 else rule.rhs_column);
        } else if (i != 0) try output.append(allocator, ' ');
        try output.appendSlice(allocator, particle.text);
    }
    try output.append(allocator, '.');
    if (rule.precedence.len != 0) {
        try output.append(allocator, ' ');
        try output.appendSlice(allocator, rule.precedence);
    }
}

fn stronger(a: Break, b: Break) Break {
    return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
}

fn slice(source: []const u8, node: Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn hasNewline(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '\n') != null;
}

fn width(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) count += if (byte == '\t') @as(usize, 4) else 1;
    }
    return count;
}

fn spaces(allocator: Allocator, output: *std.ArrayList(u8), count: usize) OOM!void {
    try output.appendNTimes(allocator, ' ', count);
}

fn control(comment: []const u8) ?bool {
    var index: usize = 0;
    while (index < comment.len and (std.ascii.isWhitespace(comment[index]) or std.ascii.isPunctuation(comment[index]))) : (index += 1) {}
    const text = comment[index..];
    if (std.mem.startsWith(u8, text, "zitron fmt: off")) return false;
    if (std.mem.startsWith(u8, text, "zitron fmt: on")) return true;
    return null;
}

fn spacedPipes(text: []const u8) bool {
    var slots: usize = 0;
    var spaced: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const end = ZigCode.opaqueEnd(text, i);
        if (end != i) {
            i = end;
            continue;
        }
        if (text[i] == '|') {
            slots += 2;
            spaced += @intFromBool(i != 0 and std.ascii.isWhitespace(text[i - 1]));
            spaced += @intFromBool(i + 1 < text.len and std.ascii.isWhitespace(text[i + 1]));
        }
        i += 1;
    }
    return spaced * 2 >= slots;
}

fn compactCode(allocator: Allocator, text: []const u8) OOM!?[]const u8 {
    if (!hasNewline(text)) return text;
    var output = Normalized{ .source = text };
    var i: usize = 0;
    while (i < text.len) {
        const end = ZigCode.opaqueEnd(text, i);
        if (end != i) {
            if (std.mem.startsWith(u8, text[i..], "//") or
                std.mem.startsWith(u8, text[i..], "\\\\") or hasNewline(text[i..end]))
            {
                output.output.deinit(allocator);
                return null;
            }
            try output.appendSlice(allocator, text[i..end]);
            i = end;
        } else if (text[i] == '\n' or text[i] == '\r') {
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            try output.append(allocator, ' ');
        } else {
            try output.append(allocator, text[i]);
            i += 1;
        }
    }
    return output.text();
}

const Normalized = struct {
    source: []const u8,
    matched: usize = 0,
    changed: bool = false,
    output: std.ArrayList(u8) = .empty,

    fn text(output: Normalized) []const u8 {
        return if (output.changed) output.output.items else output.source[0..output.matched];
    }

    fn append(output: *Normalized, allocator: Allocator, byte: u8) OOM!void {
        try output.appendSlice(allocator, &.{byte});
    }

    fn appendSlice(output: *Normalized, allocator: Allocator, bytes: []const u8) OOM!void {
        if (!output.changed) {
            if (std.mem.startsWith(u8, output.source[output.matched..], bytes)) {
                output.matched += bytes.len;
                return;
            }
            try output.output.ensureTotalCapacity(allocator, output.source.len);
            try output.output.appendSlice(allocator, output.source[0..output.matched]);
            output.changed = true;
        }
        try output.output.appendSlice(allocator, bytes);
    }

    fn pop(output: *Normalized) ?u8 {
        if (output.changed) return output.output.pop();
        if (output.matched == 0) return null;
        output.matched -= 1;
        return output.source[output.matched];
    }
};

fn normalize(allocator: Allocator, text: []const u8, pipe_spaces: bool) OOM![]const u8 {
    var output = Normalized{ .source = text };
    var i: usize = 0;
    var previous: u8 = 0;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        const begin = i;
        const opaque_end = ZigCode.opaqueEnd(text, i);
        if (opaque_end != i) {
            i = opaque_end;
        } else if (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '@') {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
        } else if (i + 1 < text.len and ((text[i] == '&' and text[i + 1] == '&') or (text[i] == '|' and text[i + 1] == '|'))) {
            i += 2;
        } else i += 1;
        const current = text[begin];
        const close_before = current == ')' or current == ']' or current == '(' or current == ',' or current == ';' or current == '.' or (current == '|' and !pipe_spaces);
        const close_after = previous == '%' or previous == '(' or previous == '[' or (previous == '|' and !pipe_spaces);
        if (output.text().len != 0 and !close_before and !close_after) try output.append(allocator, ' ');
        try output.appendSlice(allocator, text[begin..i]);
        previous = text[i - 1];
    }
    return output.text();
}

fn normalizeAction(allocator: Allocator, text: []const u8) OOM![]const u8 {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return text;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return text;
    const arguments = text[open + 1 .. close];
    const semicolon = std.mem.indexOfScalar(u8, arguments, ';');
    const lhs = std.mem.trim(u8, arguments[0 .. semicolon orelse arguments.len], " \t\r\n");
    var tokens = std.mem.tokenizeAny(u8, if (semicolon) |semi| arguments[semi + 1 ..] else "", " ,\t\r\n");
    const first = tokens.next();
    const second = tokens.next();
    var output = Normalized{ .source = text };
    try output.appendSlice(allocator, std.mem.trim(u8, text[0..open], " \t\r\n"));
    try output.append(allocator, '(');
    try output.appendSlice(allocator, lhs);
    if (first) |alias| {
        if (lhs.len == 0 and second != null) try output.append(allocator, ' ');
        try output.append(allocator, ';');
        if (second != null) try output.append(allocator, ' ');
        try output.appendSlice(allocator, alias);
        var next = second;
        while (next) |more| : (next = tokens.next()) {
            try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, more);
        }
    }
    try output.append(allocator, ')');
    return output.text();
}

fn normalizeParameter(allocator: Allocator, text: []const u8) OOM![]const u8 {
    var output = Normalized{ .source = text };
    var i: usize = 0;
    var pending = false;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            pending = output.text().len != 0;
            i += 1;
            continue;
        }
        if (text[i] == ':') {
            while (output.text().len != 0 and output.text()[output.text().len - 1] == ' ') _ = output.pop();
            try output.append(allocator, ':');
            pending = true;
            i += 1;
            continue;
        }
        if (pending) try output.append(allocator, ' ');
        pending = false;
        const end = ZigCode.opaqueEnd(text, i);
        if (end != i) {
            try output.appendSlice(allocator, text[i..end]);
            i = end;
        } else {
            try output.append(allocator, text[i]);
            i += 1;
        }
    }
    return output.text();
}

fn normalizeComment(allocator: Allocator, text: []const u8) OOM![]const u8 {
    var output = Normalized{ .source = text };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    const block = std.mem.startsWith(u8, text, "/*");
    var starred = block;
    if (block) {
        var rest = std.mem.splitScalar(u8, text, '\n');
        _ = rest.next();
        while (rest.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0 and trimmed[0] != '*') starred = false;
        }
    }
    while (lines.next()) |raw| {
        if (!first) try output.append(allocator, '\n');
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        var slug: usize = 0;
        if (first) {
            slug = 2;
        } else if (starred) {
            while (slug < line.len and std.ascii.isWhitespace(line[slug])) : (slug += 1) {}
        }
        if (first or starred) {
            while (slug < line.len and std.ascii.isPunctuation(line[slug]) and !std.mem.startsWith(u8, line[slug..], "*/")) : (slug += 1) {}
            if (slug < line.len and !std.ascii.isWhitespace(line[slug]) and !(line[slug] == '/' and slug > 0 and line[slug - 1] == '*')) {
                try output.appendSlice(allocator, line[0..slug]);
                try output.append(allocator, ' ');
                try output.appendSlice(allocator, line[slug..]);
            } else try output.appendSlice(allocator, line);
        } else try output.appendSlice(allocator, line);
        first = false;
    }
    return output.text();
}

fn openingComment(code: []const u8) bool {
    const first_line_end = std.mem.indexOfScalar(u8, code, '\n') orelse return false;
    const first_line = std.mem.trimStart(u8, code[1..first_line_end], " \t");
    return std.mem.startsWith(u8, first_line, "//");
}

fn emitBlock(allocator: Allocator, output: *std.ArrayList(u8), body: []const u8, newline: []const u8, opening_comment: bool) OOM!void {
    try output.append(allocator, '{');
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, body, "\r\n"), '\n');
    if (opening_comment) {
        if (lines.next()) |line| {
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, std.mem.trimStart(u8, line, " \t"));
        }
    }
    try output.appendSlice(allocator, newline);
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len != 0) {
            try output.appendSlice(allocator, line);
        }
        try output.appendSlice(allocator, newline);
    }
    try output.append(allocator, '}');
}

fn appendNewlines(allocator: Allocator, output: *std.ArrayList(u8), text: []const u8, newline: []const u8) OOM!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try output.appendSlice(allocator, newline);
        try output.appendSlice(allocator, std.mem.trimEnd(u8, line, "\r"));
        first = false;
    }
}

//| Tests

test "fitting summaries preserve columns scores and incoming closing states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var random_state = std.Random.DefaultPrng.init(0x465449545f53554d);
    const random = random_state.random();
    var items: [25]Item = undefined;
    var document = Document{ .allocator = allocator, .source = "", .queue = undefined };
    document.items = .{ .items = &items, .capacity = items.len };
    var scratch = Document.FitScratch{};
    defer scratch.deinit(allocator);
    const columns = [_]usize{ 0, 1, 35, 36, 78, 89, 90, 91, 99, 100, 101, 102, 256, 4096 };
    for (0..160) |round| {
        for (&items) |*item| {
            const action_width = random.intRangeAtMost(usize, 0, 140);
            const tail: Tail = switch (random.uintLessThan(u8, 5)) {
                0 => .none,
                1 => .comment,
                2 => .code_line,
                3 => .code_block,
                else => .action,
            };
            item.* = .{
                .kind = .rule,
                .start = 0,
                .end = 0,
                .gap = "",
                .blanks = 0,
                .comment_width = random.intRangeAtMost(usize, 0, 130),
                .rule = .{
                    .lhs = "expr",
                    .name_length = 4,
                    .input_ditto = false,
                    .particles = &.{},
                    .precedence = "",
                    .aliases = &.{},
                    .action_width = action_width,
                    .tail = tail,
                    .block = tail == .code_block,
                    .dropped = (tail == .action or tail == .code_line) and random.boolean(),
                    .pulled_comment = tail == .comment and random.boolean(),
                    .stage = random.uintLessThan(u8, 3),
                    .newly_dropped = random.boolean(),
                    .rhs_column = random.intRangeAtMost(usize, 4, 150),
                    .tail_column = random.intRangeAtMost(usize, 0, 140),
                    .drop_column = random.intRangeAtMost(usize, 4, 150),
                    .pattern = .{ .width = random.intRangeAtMost(usize, 0, 200), .overflow = random.uintLessThan(usize, 3), .excess = random.uintLessThan(usize, 200) },
                },
            };
            if (random.uintLessThan(u8, 6) == 0) {
                item.rule = null;
                item.kind = if (random.boolean()) .comment else .raw;
            }
        }
        // An earlier tail crosses the run boundary; intervening comments retain it.
        items[0].kind = .rule;
        items[0].rule = .{
            .lhs = "expr",
            .name_length = 4,
            .input_ditto = false,
            .particles = &.{},
            .precedence = "",
            .aliases = &.{},
            .tail = .action,
            .action_width = round % 141,
            .tail_column = columns[round % columns.len],
            .pattern = .{},
        };
        items[1].kind = .comment;
        items[1].rule = null;
        items[2] = items[0];
        items[2].boundary = if (round % 3 == 0) .hard else .soft;
        const run = Run{ .first = 2, .end = 3 + round % (items.len - 2), .boundary = .soft };
        try scratch.reset(&document, run);
        for (run.first..run.end) |index| {
            var replacement = items[index].rule orelse items[0].rule.?;
            replacement.pattern.width = random.intRangeAtMost(usize, 0, 200);
            replacement.dropped = !replacement.dropped;
            try scratch.submit(index, replacement);
        }
        for (columns) |column| {
            const canonical = @min(column, Document.FitScratch.NO_CLOSING);
            scratch.beginColumn(canonical);
            for (scratch.candidates.items) |candidate| {
                const local = candidate.index - run.first;
                const prefix = scratch.prefix.items[local];
                const middle = scratch.step(scratch.rows[local], candidate.rule, prefix.closing);
                var total = prefix.total.add(middle.total).add(scratch.suffix(local + 1, middle.closing));
                total.score.excess += total.linear * (column - canonical);
                try std.testing.expectEqual(document.score(run, column, candidate.index, candidate.rule), total.score);
            }
            if (round < 12 and items[2].boundary != .hard) {
                const saved = items[0].rule.?;
                items[0].rule.?.action_width = 0;
                items[0].rule.?.dropped = true;
                for (0..Document.FitScratch.STATE_COUNT) |closing| {
                    items[0].rule.?.drop_column = closing;
                    var total = scratch.suffix(0, closing);
                    total.score.excess += total.linear * (column - canonical);
                    try std.testing.expectEqual(document.score(run, column, null, null), total.score);
                }
                items[0].rule = saved;
            }
        }
    }
}

fn verifyPattern(rule: Rule, pattern: Pattern) void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var line: std.ArrayList(u8) = .empty;
    var expected: std.ArrayList(u8) = .empty;
    var measured = Pattern{ .split = pattern.split, .short_indent = pattern.short_indent };
    if (rule.ditto) {
        spaces(allocator, &line, if (rule.name_length >= 8) 2 else 1) catch @panic("OutOfMemory");
        line.appendSlice(allocator, "``") catch @panic("OutOfMemory");
        spaces(allocator, &line, rule.rhs_column - width(line.items)) catch @panic("OutOfMemory");
    } else {
        line.appendSlice(allocator, rule.lhs) catch @panic("OutOfMemory");
        line.appendSlice(allocator, " ::= ") catch @panic("OutOfMemory");
    }
    for (rule.particles, 0..) |particle, i| {
        const newline = if (pattern.split) |cut| i == cut else particle.line and i != 0;
        if (newline) {
            measured.addLine(width(line.items));
            expected.appendSlice(allocator, line.items) catch @panic("OutOfMemory");
            expected.append(allocator, '\n') catch @panic("OutOfMemory");
            line.clearRetainingCapacity();
            spaces(allocator, &line, if (pattern.short_indent) 4 else rule.rhs_column) catch @panic("OutOfMemory");
        } else if (i != 0) line.append(allocator, ' ') catch @panic("OutOfMemory");
        line.appendSlice(allocator, particle.text) catch @panic("OutOfMemory");
    }
    line.append(allocator, '.') catch @panic("OutOfMemory");
    if (rule.precedence.len != 0) {
        line.append(allocator, ' ') catch @panic("OutOfMemory");
        line.appendSlice(allocator, rule.precedence) catch @panic("OutOfMemory");
    }
    measured.addLine(width(line.items));
    expected.appendSlice(allocator, line.items) catch @panic("OutOfMemory");
    std.debug.assert(std.meta.eql(measured, pattern));
    var candidate = rule;
    candidate.pattern = pattern;
    var actual: std.ArrayList(u8) = .empty;
    emitPattern(allocator, &actual, candidate, "\n") catch @panic("OutOfMemory");
    std.debug.assert(eql(expected.items, actual.items));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const builtin = @import("builtin");
const ts = @import("tree-sitter");
const ZigCode = @import("format/ZigCode.zig");
