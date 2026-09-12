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
    var queue: ZigCode.Queue = undefined;
    queue.init(io, options.zig_executable);
    defer queue.deinit();
    var document = Document{ .allocator = arena.allocator(), .source = source, .queue = &queue };
    try document.collect(root);
    try queue.finish();
    try document.prepare();
    try document.layout();
    const rendered = try document.render();
    return allocator.dupe(u8, rendered);
}

const Kind = enum { rule, directive, comment, raw };
const Break = enum { none, soft, hard };
const Tail = enum { none, action, code_line, code_block, comment };
const Particle = struct { text: []const u8, line: bool = false };
const Pattern = struct {
    lines: []const []const u8,
    width: usize,
    last_width: usize,
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

    fn collect(document: *Document, root: Node) OOM!void {
        try document.findDisabled();
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
            var item = Item{
                .kind = .raw,
                .start = start,
                .end = end,
                .gap = gap,
                .blanks = blankCount(gap),
                .text = document.source[start..end],
            };
            const kind = node.kind();
            if (!node.hasError() and !node.isMissing() and !document.protected(start, end)) {
                if (eql(kind, "comment")) {
                    item.kind = .comment;
                    item.text = try normalizeComment(document.allocator, item.text);
                    item.long_comment = hasNewline(item.text);
                    if (!hasNewline(gap) and document.items.items.len != 0) {
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
                    if (firstChild(node, "lhs")) |lhs_node| {
                        lhs = try normalize(document.allocator, slice(document.source, lhs_node), false);
                        if (firstChild(lhs_node, "nonterminal")) |name| name_length = width(slice(document.source, name));
                        lhs_alias = if (firstChild(lhs_node, "rule_alias")) |alias| slice(document.source, alias) else null;
                    }
                    if (lhs.len != 0 and !hasSyntaxComment(node)) {
                        item.kind = .rule;
                        item.rule = try document.collectRule(node, lhs, name_length, lhs_alias);
                    }
                } else if (eql(kind, "directive")) {
                    if (!hasSyntaxComment(node)) try document.collectDirective(&item, node);
                }
            }
            if (item.kind == .raw) lhs = "";
            try document.items.append(document.allocator, item);
            previous_end = end;
            if (!cursor.gotoNextSibling()) break;
        }
    }

    fn collectRule(document: *Document, node: Node, lhs: []const u8, name_length: usize, lhs_alias: ?[]const u8) OOM!Rule {
        var particles: std.ArrayList(Particle) = .empty;
        var aliases: std.ArrayList([]const u8) = .empty;
        if (lhs_alias) |alias| try aliases.append(document.allocator, alias);
        if (firstChild(node, "rhs")) |rhs| {
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
            .precedence = if (firstChild(node, "precedence_mark")) |mark| try normalize(document.allocator, slice(document.source, mark), false) else "",
            .aliases = aliases.items,
        };
        const tail = firstChild(node, "named_action") orelse firstChild(node, "code_block");
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

    fn collectDirective(document: *Document, item: *Item, node: Node) OOM!void {
        item.kind = .directive;
        const name_node = directiveName(node) orelse return;
        const name = slice(document.source, name_node);
        const block = firstChild(node, "code_block");
        const prefix_end = if (block) |code| code.startByte() else node.endByte();
        const prefix = document.source[node.startByte()..prefix_end];
        item.text = try normalize(document.allocator, prefix, eql(name, "token_class") and spacedPipes(prefix));
        if (firstChild(node, "named_action")) |action| {
            item.text = try std.fmt.allocPrint(document.allocator, "%impl {s}", .{try normalizeAction(document.allocator, slice(document.source, action))});
        }
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
                if (firstChild(node, "named_action")) |action| {
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
            } else if (item.job) |work| {
                if (work.result) |text| {
                    const body = std.mem.trim(u8, text, " \t\r\n");
                    const line = if (item.block) null else try compactCode(document.allocator, body);
                    item.block = line == null or width(item.text) + 5 + width(line.?) > 100;
                    item.raw_code = if (item.block) text else try std.fmt.allocPrint(document.allocator, "{{ {s} }}", .{line.?});
                }
            }
            if (item.kind == .comment and index + 1 < document.items.items.len and document.items.items[index + 1].kind == .comment) {
                item.long_comment = true;
                document.items.items[index + 1].long_comment = true;
            }
        }
        try document.dittosAndBoundaries();
        for (document.items.items) |*item| {
            if (item.rule) |*rule| {
                rule.pattern = try document.makePattern(rule.*, null, false);
                if (rule.tail == .none and item.comment.len != 0) rule.tail = .comment;
            }
        }
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

    fn makePattern(document: Document, rule: Rule, split: ?usize, short_indent: bool) OOM!Pattern {
        var lines: std.ArrayList([]const u8) = .empty;
        var line: std.ArrayList(u8) = .empty;
        if (rule.ditto) {
            try spaces(document.allocator, &line, if (rule.name_length >= 8) 2 else 1);
            try line.appendSlice(document.allocator, "``");
            try spaces(document.allocator, &line, rule.rhs_column - width(line.items));
        } else {
            try line.appendSlice(document.allocator, rule.lhs);
            try line.appendSlice(document.allocator, " ::= ");
        }
        for (rule.particles, 0..) |particle, i| {
            const newline = if (split) |cut| i == cut else particle.line and i != 0;
            if (newline) {
                try lines.append(document.allocator, try line.toOwnedSlice(document.allocator));
                line = .empty;
                try spaces(document.allocator, &line, if (short_indent) 4 else rule.rhs_column);
            } else if (i != 0) try line.append(document.allocator, ' ');
            try line.appendSlice(document.allocator, particle.text);
        }
        try line.append(document.allocator, '.');
        if (rule.precedence.len != 0) {
            try line.append(document.allocator, ' ');
            try line.appendSlice(document.allocator, rule.precedence);
        }
        try lines.append(document.allocator, try line.toOwnedSlice(document.allocator));
        var maximum: usize = 0;
        for (lines.items) |text| maximum = @max(maximum, width(text));
        return .{ .lines = lines.items, .width = maximum, .last_width = width(lines.items[lines.items.len - 1]) };
    }

    fn layout(document: *Document) OOM!void {
        try document.collectRuns();
        while (true) {
            const before = document.blockCount();
            for (document.runs.items) |*run| try document.fit(run);
            if (document.blockCount() == before) break;
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
                if (rule.pattern.last_width + 2 > run.column or run.column + width(rule.action) > 90) continue;
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

    fn blockCount(document: Document) usize {
        var count: usize = 0;
        for (document.items.items) |item| {
            if (item.rule) |rule| count += @intFromBool(rule.block);
        }
        return count;
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

    fn fit(document: *Document, run: *Run) OOM!void {
        document.pullComments(run.*);
        var attempts: usize = 0;
        while (attempts < (run.end - run.first) * 4) : (attempts += 1) {
            const column = document.columnFor(run.*, null, null);
            const current_score = document.score(run.*, column, null, null);
            if (current_score.overflow == 0 and current_score.marginal == 0) break;
            var best: ?Candidate = null;
            for (run.first..run.end) |index| {
                const rule = if (document.items.items[index].rule) |r| r else continue;
                if (rule.particles.len >= 2 and rule.stage < 2) {
                    for (rule.stage + 1..3) |stage| {
                        var candidate = rule;
                        candidate.stage = @intCast(stage);
                        candidate.pattern = try document.balancedPattern(rule, stage == 2);
                        document.consider(run.*, index, candidate, current_score, &best);
                    }
                }
                if ((rule.tail == .code_line or rule.tail == .action) and !rule.dropped) {
                    var candidate = rule;
                    candidate.dropped = true;
                    candidate.newly_dropped = true;
                    if (candidate.tail == .code_line and 4 + width(candidate.action) > 100 and !candidate.code_failed) {
                        candidate.block = true;
                        candidate.tail = .code_block;
                        candidate.action = if (candidate.job) |work| work.result orelse candidate.action else candidate.action;
                        candidate.dropped = false;
                    }
                    document.consider(run.*, index, candidate, current_score, &best);
                }
            }
            if (best) |choice| {
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
                if (rule.tail == .comment and run.column + width(item.comment) > 100) rule.pulled_comment = true;
            }
        }
        run.fitted = document.requiresFitting(run.*);
    }

    fn pullComments(document: *Document, run: Run) void {
        const column = document.columnFor(run, null, null);
        for (run.first..run.end) |index| {
            const item = &document.items.items[index];
            if (item.rule) |*rule| {
                if (rule.tail == .comment and column + width(item.comment) > 100) rule.pulled_comment = true;
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
            var joined = rule.rhs_column + 1;
            for (rule.particles) |particle| joined += width(particle.text);
            joined += rule.particles.len -| 1;
            if (rule.precedence.len != 0) joined += 1 + width(rule.precedence);
            pattern_overflow = pattern_overflow or joined > 78;
            if (!rule.dropped and (rule.tail == .action or rule.tail == .code_line)) {
                maximum = @max(maximum, joined);
                tail = @max(tail, width(rule.action));
            }
            structural = structural or rule.pattern.lines.len > 1 or rule.dropped;
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
    const Candidate = struct { index: usize, rule: Rule, score: Score };

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

    fn balancedPattern(document: Document, rule: Rule, short_indent: bool) OOM!Pattern {
        var selected: ?Pattern = null;
        var best_difference: usize = std.math.maxInt(usize);
        for (1..rule.particles.len) |cut| {
            const pattern = try document.makePattern(rule, cut, short_indent);
            const first_width = width(pattern.lines[0]);
            const last_width = pattern.last_width;
            if (last_width < first_width) continue;
            const difference = last_width - first_width;
            if (difference < best_difference) {
                best_difference = difference;
                selected = pattern;
            }
        }
        return selected orelse try document.makePattern(rule, 1, short_indent);
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
            const tail_width = width(if (rule.tail == .comment) item.comment else rule.action);
            if (maximum + padding + tail_width > 90) padding = 2;
        }
        return maximum + padding;
    }

    fn score(document: Document, run: Run, column: usize, replacement_index: ?usize, replacement: ?Rule) Score {
        var result = Score{};
        const above = document.precedingTail(run);
        const opening = if (column == 0 and above != null) above.?.tail_column else column;
        var closing: ?usize = if (above) |rule| (if (rule.dropped) rule.drop_column else rule.tail_column) + width(rule.action) else null;
        for (run.first..run.end) |index| {
            const rule = (if (replacement_index == index) replacement else document.items.items[index].rule) orelse {
                if (document.items.items[index].kind != .comment) closing = null;
                continue;
            };
            const action_column = if (rule.dropped) dropColumn(rule, opening, closing) else column;
            closing = if (rule.tail == .action or rule.tail == .code_line) action_column + width(rule.action) else null;
            result.changes += rule.stage + @as(usize, if (rule.newly_dropped) 3 else 0);
            for (rule.pattern.lines) |line| {
                const count = width(line);
                if (count > 78) {
                    result.overflow += 1;
                    result.excess += count - 78;
                }
            }
            if (!rule.block and (rule.tail == .action or rule.tail == .code_line)) {
                const count = action_column + width(rule.action);
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
        var closing: ?usize = if (above) |rule| (if (rule.dropped) rule.drop_column else rule.tail_column) + width(rule.action) else null;
        for (run.first..run.end) |index| {
            const item = &document.items.items[index];
            const rule = if (item.rule) |*r| r else {
                if (item.kind != .comment) closing = null;
                continue;
            };
            if (rule.dropped) rule.drop_column = dropColumn(rule.*, opening, closing);
            const end = (if (rule.dropped) rule.drop_column else column) + width(rule.action);
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
            if (column + width(rule.action) > 90) return false;
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

    fn render(document: Document) OOM![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        const newline: []const u8 = if (std.mem.indexOf(u8, document.source, "\r\n") != null) "\r\n" else "\n";
        var previous_raw = false;
        for (document.items.items, 0..) |item, index| {
            if (item.kind == .raw or previous_raw) {
                try output.appendSlice(document.allocator, item.gap);
            } else if (index == 0) {
                for (0..std.mem.count(u8, item.gap, "\n")) |_| try output.appendSlice(document.allocator, newline);
            } else {
                for (0..item.blanks + 1) |_| try output.appendSlice(document.allocator, newline);
            }
            if (item.rule) |rule| {
                for (rule.pattern.lines, 0..) |line, i| {
                    if (i != 0) try output.appendSlice(document.allocator, newline);
                    try output.appendSlice(document.allocator, line);
                }
                if (rule.tail == .code_block) {
                    try output.appendSlice(document.allocator, "  ");
                    if (rule.code_failed) try output.appendSlice(document.allocator, rule.action) else try emitBlock(document.allocator, &output, rule.action, newline, rule.opening_comment);
                } else if (rule.tail == .action or rule.tail == .code_line) {
                    if (rule.dropped) {
                        try output.appendSlice(document.allocator, newline);
                        try spaces(document.allocator, &output, rule.drop_column);
                    } else try spaces(document.allocator, &output, @max(2, rule.tail_column -| rule.pattern.last_width));
                    try output.appendSlice(document.allocator, rule.action);
                }
                if (item.comment.len != 0) {
                    const action_end = (if (rule.dropped) rule.drop_column else rule.tail_column) + width(rule.action);
                    const padding = if (rule.tail == .comment and !rule.pulled_comment)
                        @max(2, rule.tail_column -| rule.pattern.last_width)
                    else if (!rule.block and rule.tail != .comment and rule.comment_column + width(item.comment) <= 100)
                        @max(2, rule.comment_column -| action_end)
                    else
                        2;
                    try spaces(document.allocator, &output, padding);
                    try output.appendSlice(document.allocator, item.comment);
                }
            } else if (item.kind == .directive) {
                try output.appendSlice(document.allocator, item.text);
                if (item.raw_code.len != 0) {
                    try output.append(document.allocator, ' ');
                    if (item.block and item.job != null and item.job.?.result != null) {
                        try emitBlock(document.allocator, &output, item.raw_code, newline, item.opening_comment);
                    } else try output.appendSlice(document.allocator, item.raw_code);
                }
                if (item.comment.len != 0) {
                    try output.appendSlice(document.allocator, "  ");
                    try output.appendSlice(document.allocator, item.comment);
                }
            } else if (item.kind == .raw) {
                try output.appendSlice(document.allocator, item.text);
            } else try appendNewlines(document.allocator, &output, item.text, newline);
            previous_raw = item.kind == .raw;
        }
        const end = if (document.items.items.len != 0) document.items.items[document.items.items.len - 1].end else 0;
        const suffix = document.source[end..];
        if (previous_raw or document.protected(end, document.source.len)) {
            try output.appendSlice(document.allocator, suffix);
        } else {
            for (0..std.mem.count(u8, suffix, "\n")) |_| try output.appendSlice(document.allocator, newline);
        }
        return output.items;
    }
};

fn firstChild(node: Node, kind: []const u8) ?Node {
    var cursor = node.walk();
    defer cursor.destroy();
    if (!cursor.gotoFirstChild()) return null;
    while (true) {
        const child = cursor.node();
        if (eql(child.kind(), kind)) return child;
        if (!cursor.gotoNextSibling()) return null;
    }
}

fn directiveName(node: Node) ?Node {
    var cursor = node.walk();
    defer cursor.destroy();
    if (!cursor.gotoFirstChild()) return null;
    while (true) {
        const child = cursor.node();
        const kind = child.kind();
        if (std.mem.endsWith(u8, kind, "_name")) return child;
        if (!cursor.gotoNextSibling()) return null;
    }
}

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
    const length = width(rule.action);
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

fn blankCount(text: []const u8) usize {
    return std.mem.count(u8, text, "\n") -| 1;
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
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const end = ZigCode.opaqueEnd(text, i);
        if (end != i) {
            if (std.mem.startsWith(u8, text[i..], "//") or
                std.mem.startsWith(u8, text[i..], "\\\\") or hasNewline(text[i..end])) return null;
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
    return output.items;
}

fn normalize(allocator: Allocator, text: []const u8, pipe_spaces: bool) OOM![]const u8 {
    var output: std.ArrayList(u8) = .empty;
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
        if (output.items.len != 0 and !close_before and !close_after) try output.append(allocator, ' ');
        try output.appendSlice(allocator, text[begin..i]);
        previous = text[i - 1];
    }
    return output.items;
}

fn normalizeAction(allocator: Allocator, text: []const u8) OOM![]const u8 {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return text;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return text;
    const arguments = text[open + 1 .. close];
    const semicolon = std.mem.indexOfScalar(u8, arguments, ';');
    const lhs = std.mem.trim(u8, arguments[0 .. semicolon orelse arguments.len], " \t\r\n");
    var rhs: std.ArrayList([]const u8) = .empty;
    if (semicolon) |semi| {
        var tokens = std.mem.tokenizeAny(u8, arguments[semi + 1 ..], " ,\t\r\n");
        while (tokens.next()) |alias| try rhs.append(allocator, alias);
    }
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(allocator, std.mem.trim(u8, text[0..open], " \t\r\n"));
    try output.append(allocator, '(');
    try output.appendSlice(allocator, lhs);
    if (rhs.items.len != 0) {
        if (lhs.len == 0 and rhs.items.len > 1) try output.append(allocator, ' ');
        try output.append(allocator, ';');
        if (rhs.items.len > 1) try output.append(allocator, ' ');
        for (rhs.items, 0..) |alias, index| {
            if (index != 0) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, alias);
        }
    }
    try output.append(allocator, ')');
    return output.items;
}

fn normalizeParameter(allocator: Allocator, text: []const u8) OOM![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var pending = false;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            pending = output.items.len != 0;
            i += 1;
            continue;
        }
        if (text[i] == ':') {
            while (output.items.len != 0 and output.items[output.items.len - 1] == ' ') _ = output.pop();
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
    return output.items;
}

fn normalizeComment(allocator: Allocator, text: []const u8) OOM![]const u8 {
    var output: std.ArrayList(u8) = .empty;
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
    return output.items;
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const ts = @import("tree-sitter");
const ZigCode = @import("format/ZigCode.zig");
