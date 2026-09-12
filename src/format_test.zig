//! Contract tests for the reusable formatter, without an LSP server.

fn formatted(source: []const u8, options: formatter.Options) ![]u8 {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ts.Language.fromRaw(grammar.language()));
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();
    return formatter.format(std.testing.io, allocator, source, tree.rootNode(), options);
}

fn golden(source: []const u8, expected: []const u8) !void {
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
    try stable(output);
}

fn stable(source: []const u8) !void {
    const again = try formatted(source, .{});
    defer allocator.free(again);
    if (!std.mem.eql(u8, source, again)) {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ".zig-cache/format-first.zy", .data = source });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ".zig-cache/format-second.zy", .data = again });
        return error.FormatNotIdempotent;
    }
}

test "format atomic rules and action arities" {
    try golden(
        "  foo(A) ::=   BAR |BAZ (B) . @copy( A ; B )\nfoo(A)::= . @empty(A;)\n",
        "foo(A) ::= BAR|BAZ(B).   @copy(A;B)\nfoo(A) ::= .             @empty(A)\n",
    );
    try golden("foo ::= . @zero(;)\n", "foo ::= .   @zero()\n");
    try golden("foo ::= A(B) B(C). @two( ;B,C,)\n", "foo ::= A(B) B(C).   @two( ; B, C)\n");
}

test "format precedence extends the pattern" {
    try golden(
        "foo ::= MINUS foo. [ NOT ] @negate()\nfoo ::= X. @short()\n",
        "foo ::= MINUS foo. [NOT]   @negate()\nfoo ::= X.                 @short()\n",
    );
}

test "format ditto spelling and single versus double blanks" {
    try golden(
        "foo(A) ::= A. @a(A;)\n\n `` ::= BBB. @b(A;)\n\n\n `` C. @c(A;)\n",
        "foo(A) ::= A.     @a(A)\n ``        BBB.   @b(A)\n\n\n ``        C.     @c(A)\n",
    );
    try golden("longname(A) ::= A.\n `` ::= B.\n", "longname(A) ::= A.\n  ``            B.\n");
}

test "format directives comments and token class majority" {
    try golden(
        "% name   Parser\n//hello\nfoo ::= .\n%token_class op A |B| C .\n",
        "%name Parser\n\n// hello\nfoo ::= .\n\n%token_class op A | B | C.\n",
    );
}

test "format standalone comments restart ditto spelling as specified" {
    try golden(
        "foo ::= A.\n `` B.\n//one\n//two\n `` C.\n `` D.\n",
        "foo ::= A.\n ``     B.\n\n// one\n// two\nfoo ::= C.\n ``     D.\n",
    );
}

test "format Zig code line and declaration block" {
    try golden("foo(A) ::= B(B). {A=B+1;}\n", "foo(A) ::= B(B).   { A = B + 1; }\n");
    try golden("%include {const x=1;}\n", "%include {\nconst x = 1;\n}\n");
}

test "format code lines retain multiple statements after Zig formatting" {
    try golden("foo ::= A. {x=1;y=2;}\n", "foo ::= A.   { x = 1; y = 2; }\n");
    try golden("foo ::= A. {if(x){y=1;z=2;}}\n", "foo ::= A.   { if (x) { y = 1; z = 2; } }\n");
    try golden("foo ::= A. {const s=\"a  b\\n//\";_=s;}\n", "foo ::= A.   { const s = \"a  b\\n//\"; _ = s; }\n");
    try golden("%token_destructor { release($$); count+=1; }\n", "%token_destructor { release($$); count += 1; }\n");
}

test "format declaration blocks retain container scope and preprocessor directives" {
    inline for (.{ "%include", "%code" }) |directive| {
        try golden(
            directive ++ " {\n%ifdef FOO\npub fn answer() u32 {return 42;}\n%endif\n}\n",
            directive ++ " {\n%ifdef FOO\npub fn answer() u32 {\n    return 42;\n}\n%endif\n}\n",
        );
        try golden(directive ++ " {const x=$$;}\n", directive ++ " {const x=$$;}\n");
    }
}

test "format statement blocks retain wrapper indentation" {
    try golden(
        "%token_destructor {\n%ifdef FOO\nif(ok){release($$);}\n%endif\n}\n",
        "%token_destructor {\n%ifdef FOO\n    if (ok) {\n        release($$);\n    }\n%endif\n}\n",
    );
    try golden(
        "%token_destructor {\n// zig fmt: off\n  release($$);\n// zig fmt: on\n}\n",
        "%token_destructor {\n    // zig fmt: off\n  release($$);\n// zig fmt: on\n}\n",
    );
}

test "format property code lines stay aligned while existing blocks stay blocks" {
    const source =
        \\// Properties with no argument
        \\boolproperty ::= CW.          { p.cur.cw = 1; }
        \\boolproperty ::= CCW.         { p.cur.cw = 0; }
        \\boolproperty ::= LARROW.      { p.cur.larrow = 1; p.cur.rarrow = 0; }
        \\boolproperty ::= RARROW.      { p.cur.larrow = 0; p.cur.rarrow = 1; }
        \\boolproperty ::= LRARROW.     { p.cur.larrow = 1; p.cur.rarrow = 1; }
        \\boolproperty ::= INVIS.       { p.cur.sw = -0.00001; }
        \\boolproperty ::= THICK.       { p.cur.sw *= 1.5; }
        \\boolproperty ::= THIN.        { p.cur.sw *= 0.67; }
        \\boolproperty ::= SOLID.       { p.cur.sw = pik_value(p, "thickness", null);
        \\                               p.cur.dotted = 0.0; p.cur.dashed = 0.0; }
        \\
    ;
    const output = try formatted(source, .{});
    defer allocator.free(output);
    var lines = std.mem.splitScalar(u8, output, '\n');
    var column: ?usize = null;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "boolproperty") or std.mem.indexOf(u8, line, "SOLID") != null) continue;
        const brace = std.mem.indexOfScalar(u8, line, '{') orelse return error.MissingCodeLine;
        try std.testing.expect(std.mem.endsWith(u8, line, " }"));
        if (column) |expected| try std.testing.expectEqual(expected, brace);
        column = brace;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expect(std.mem.indexOf(u8, output, "SOLID.  {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{ p.cur.larrow = 1; p.cur.rarrow = 0; }") != null);
    try stable(output);
}

test "format compacted code lines drop before expanding on overflow" {
    for ([_]usize{ 55, 85 }) |length| {
        const payload = try allocator.alloc(u8, length);
        defer allocator.free(payload);
        @memset(payload, 'x');
        const source = try std.fmt.allocPrint(allocator, "foo ::= AAAAAAAAAA. {{ first(\"{s}\"); second(); }}\n", .{payload});
        defer allocator.free(source);
        const output = try formatted(source, .{});
        defer allocator.free(output);
        if (length == 55) {
            try std.testing.expect(std.mem.indexOf(u8, output, "\n        { first(") != null);
            try std.testing.expect(std.mem.indexOf(u8, output, "); second(); }") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, output, "AAAAAAAAAA.  {\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, output, "\n    second();\n}") != null);
        }
        try stable(output);
    }
}

test "format substitutions restore aliases dollars and preprocessor directives" {
    const source = "%include {\n%ifdef FOO\nconst x=1;\n%endif\n}\n\nfoo(A) ::= B(B). {A=@B;}\n\n%token_destructor { _=$$; }\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "A = @B;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_ = $$;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\n%ifdef FOO\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ZITRON_FORMAT") == null);
    try stable(output);
}

test "format invalid Zig and missing executable preserve original fragments" {
    try golden("foo ::= A. { x = ; }\n", "foo ::= A.   { x = ; }\n");
    const output = try formatted("foo ::= A. { x=  1; }\n", .{ .zig_executable = "/nonexistent/zitron-format-zig" });
    defer allocator.free(output);
    try std.testing.expectEqualStrings("foo ::= A.   { x=  1; }\n", output);
}

test "format linked Zig renderer matches external zig fmt" {
    const sources = [_][]const u8{
        "%include {\n%ifdef FOO\nconst x=1;\n%endif\n}\nfoo(A) ::= B(B). {A=@B;}\n%token_destructor { _=$$; }\n",
        "%include {\n// zig fmt: off\nconst x=  1;\n// zig fmt: on\n}\n",
        "foo(A) ::= B(B). {\nconst s=\"@B $$ AB\";\n// @B $$\nA=@B;\n_=s;\n}\n",
        "%include {\nconst text=\n\\\\trailing spaces  \n;\n}\n",
        "foo ::= A. { x = ; }\nbar ::= B. {x=1;}\n",
        "%include {\r\n\tconst x=1;\r\n}\r\nfoo ::= A. {\r\nx=2;\r\n}\r\n",
    };
    for (sources) |source| try matchesExternal(source);
    for ([_][]const u8{ "samples/calc.zy", "samples/edn.zy", "samples/pikchr.zy" }) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
        defer allocator.free(source);
        try matchesExternal(source);
    }
}

fn matchesExternal(source: []const u8) !void {
    const linked = try formatted(source, .{});
    defer allocator.free(linked);
    const external = try formatted(source, .{ .zig_executable = "zig" });
    defer allocator.free(external);
    try std.testing.expectEqualStrings(external, linked);
}

test "format linked wrapper boundaries ignore lexical braces" {
    try matchesExternal(
        "foo(A) ::= B(B). {\nconst s = \"} {\";\nconst c = '}';\nconst @\"}\" = struct { x: u8 = '{' };\nconst text =\n\\\\} { trailing  \n;\n// } {\nif (true) { A = @B; }\n_ = .{s, c, @\"}\", text};\n}\n",
    );
    try matchesExternal(
        "foo ::= B. {\n// zig fmt: off\nif (true) { x=  1; } // }\n// zig fmt: on\n}\n",
    );
}

test "format substitutions avoid embedded substring and marker-prefix collisions" {
    const source = "%include {\n%ifdef FOO\nconst text = \"prefixZITRON_FORMAT_0_012suffix\";\n%endif\n}\nfoo(A) ::= B(B). {\nconst s=\"prefixABsuffix prefixBBsuffix yY AA\";\nA=@B; _=$$; _=s;\n}\n";
    try matchesExternal(source);
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "prefixZITRON_FORMAT_0_012suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "prefixABsuffix prefixBBsuffix yY AA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "A = @B;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_ = $$;") != null);
    try stable(output);
}

test "format controls preserve disabled bytes" {
    const source = "//|zitron fmt: off\n  foo ::=   A .\t\n/******* zitron fmt: on ******/\nbar::= B .\n";
    try golden(source, "//|zitron fmt: off\n  foo ::=   A .\t\n/******* zitron fmt: on ******/\nbar ::= B.\n");
}

test "format layout code blocks preserve dittos and soft break tails" {
    const output = try formatted("foo(A) ::= LONG(B). @a(A;B)\n `` X(B). {\n A=B;\n}\n\n `` Y(B). @b(A;B)\n", .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\n\n ``        Y(B).") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "X(B).  {\n    A = B;\n}") != null);
    try stable(output);
}

test "format layout patterns split without separating precedence or multiterminals" {
    const source = "expression(A) ::= AAAAAAAAAAAAA(B) BBBBBBBBBBBBB(C) CCCCCCCCCCCCC(D) DDDDDDDDDDDDD(E). [NOT] @reduce(A;B,C,D,E)\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.count(u8, output, "\n") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, output, ". [NOT]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\n[NOT]") == null);
    try stable(output);
    const multi = try formatted("expression ::= AAAAAAAAAAAAA|BBBBBBBBBBBBB|CCCCCCCCCCCCC|DDDDDDDDDDDDD EEEEEEEEEEEEE FFFFFFFFFFFFF. @a()\n", .{});
    defer allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "AAAAAAAAAAAAA|BBBBBBBBBBBBB|CCCCCCCCCCCCC|DDDDDDDDDDDDD") != null);
    try stable(multi);
}

test "format layout long code lines drop or become blocks" {
    const source = "foo ::= A. { someLongFunctionName(aaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccccccccccccccc); }\nfoo ::= B. @b()\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "foo ::= A.  {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\n}\n\nfoo ::= B.") != null);
    try stable(output);
    const middle = try formatted("foo ::= AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA. @a()\n" ++ source, .{});
    defer allocator.free(middle);
    try stable(middle);
}

test "format layout comments never cause pattern wrapping" {
    const source = "foo ::= AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA. @a()\nfoo ::= B. // This is a fairly long trailing comment which cannot share the aligned action column.\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "foo ::= B.  // This") != null);
    try stable(output);
}

test "format layout literal indentation respects zig fmt off" {
    try golden("%include {\n// zig fmt: off\nconst x=  1;\n// zig fmt: on\n}\n", "%include {\n// zig fmt: off\nconst x=  1;\n// zig fmt: on\n}\n");
}

test "format layout comment slugs and parameters" {
    try golden("///hello\n//!world\n//|text\nfoo ::= .\n", "/// hello\n//! world\n//| text\nfoo ::= .\n");
    try golden("%extra_argument { b :[]const   u8 }\n", "%extra_argument { b: []const u8 }\n");
    try golden(
        "%type expr { ?*Expr }\n%token_type { Token }\n%default_type { Value }\n%parse_error_type { Error }\n%extra_context { ctx: *Context }\n",
        "%type expr {?*Expr}\n%token_type {Token}\n%default_type {Value}\n%parse_error_type {Error}\n%extra_context { ctx: *Context }\n",
    );
}

test "format layout preserves malformed declarations and CRLF" {
    try golden("//comment\r\n", "// comment\r\n");
    const output = try formatted("foo ::= A.\n%type ???\n%name Parser\nbar ::= B .\n", .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "%type ???") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "bar ::= B.") != null);
    try stable(output);
    try golden("foo::= A .\r\n", "foo ::= A.\r\n");
}

test "format layout substitutions do not touch lexical lookalikes" {
    const source = "foo(A) ::= B(B). {\n const s=\"@B $$ AB\";\n // @B $$\n A=@B;\n _=s;\n}\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"@B $$ AB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "// @B $$") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "A = @B;") != null);
    try stable(output);
}

test "format layout fitting is idempotent across width thresholds" {
    for ([_]usize{ 8, 18, 29 }) |length| {
        for ([_]usize{ 2, 4, 6 }) |count| {
            for ([_]usize{ 8, 35, 72 }) |tail_length| {
                var source: std.ArrayList(u8) = .empty;
                defer source.deinit(allocator);
                try source.appendSlice(allocator, "expression(A) ::= ");
                for (0..count) |i| {
                    if (i != 0) try source.append(allocator, ' ');
                    try source.appendNTimes(allocator, 'A' + @as(u8, @intCast(i)), length);
                }
                try source.appendSlice(allocator, ". [NOT] @");
                try source.appendNTimes(allocator, 'a', tail_length);
                try source.appendSlice(allocator, "(A;)\nexpression(A) ::= X. @x(A;)\n");
                const output = try formatted(source.items, .{});
                defer allocator.free(output);
                try stable(output);
            }
        }
    }
}

test "format layout user pattern breaks survive ordinary formatting" {
    try golden("foo ::= A\n B C. @a()\n", "foo ::= A\n        B C.   @a()\n");
}

test "format layout alias changes and directives restart ditto spelling" {
    try golden("foo(A) ::= A.\n `` B.\nfoo(B) ::= C.\n `` D.\n", "foo(A) ::= A.\n ``        B.\nfoo(B) ::= C.\n ``        D.\n");
    try golden("foo ::= A.\n `` B.\n%name Parser\n `` C.\n `` D.\n", "foo ::= A.\n ``     B.\n\n%name Parser\n\nfoo ::= C.\n ``     D.\n");
}

test "format layout action comments align without affecting margins" {
    try golden("foo ::= A. @a() //a\nfoo ::= B. @longer() //b\n", "foo ::= A.   @a()       // a\nfoo ::= B.   @longer()  // b\n");
}

test "format layout soft and hard bump thresholds" {
    for ([_]usize{ 3, 4, 11, 12 }) |difference| {
        for ([_]bool{ false, true }) |hard| {
            const particle = try allocator.alloc(u8, 1 + difference);
            defer allocator.free(particle);
            @memset(particle, 'A');
            const source = try std.fmt.allocPrint(allocator, "foo ::= {s}. @a()\n{s}foo ::= B. @b()\n", .{ particle, if (hard) "%name Parser\n" else "\n\n" });
            defer allocator.free(source);
            const output = try formatted(source, .{});
            defer allocator.free(output);
            const a = actionColumn(output, "@a()");
            const b = actionColumn(output, "@b()");
            try std.testing.expectEqual(difference < (if (hard) @as(usize, 4) else 12), a == b);
            try stable(output);
        }
    }
}

fn actionColumn(source: []const u8, name: []const u8) usize {
    const index = std.mem.indexOf(u8, source, name).?;
    const start = if (std.mem.lastIndexOfScalar(u8, source[0..index], '\n')) |line| line + 1 else 0;
    return index - start;
}

test "format layout pleasant padding stops after column 35" {
    for ([_]usize{ 35, 36 }) |pattern_width| {
        const token = try allocator.alloc(u8, pattern_width - "foo ::= .".len);
        defer allocator.free(token);
        @memset(token, 'A');
        const source = try std.fmt.allocPrint(allocator, "foo ::= {s}. @a()\n", .{token});
        defer allocator.free(source);
        const output = try formatted(source, .{});
        defer allocator.free(output);
        try std.testing.expectEqual(pattern_width + (if (pattern_width == 35) @as(usize, 3) else 2), actionColumn(output, "@a()"));
        try stable(output);
    }
}

test "format layout exhausted alias substitutions retain the original code" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{ const s=\"");
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_") |prefix| {
        try body.append(allocator, prefix);
        try body.appendSlice(allocator, "B ");
    }
    try body.appendSlice(allocator, "\"; A=@B; _=s; }");
    const source = try std.fmt.allocPrint(allocator, "foo(A) ::= B(B). {s}\n", .{body.items});
    defer allocator.free(source);
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, body.items) != null);
    try stable(output);
}

test "format layout trailing spaces inside Zig multiline strings are data" {
    const source = "%include {\nconst s =\n    \\\\hello  \n;\n}\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\\hello  \n") != null);
    try stable(output);
}

test "format layout opening code comments remain beside the brace" {
    try golden("foo ::= A. { // comment\n x=1;\n}\n", "foo ::= A.  { // comment\n    x = 1;\n}\n");
}

test "format layout dropped actions do not leave ordinary single blanks in dittos" {
    const source = "foo ::= A. @aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa()\n `` B. @b()\n";
    const output = try formatted(source, .{});
    defer allocator.free(output);
    try stable(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\n\n ``") == null);
}

test "format dropped tails do not force pattern splitting or inline tail columns" {
    const source = "statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }\n" ++
        "statement_list(A) ::= statement_list(B) EOL statement(X).\n" ++
        "                      { A = pik_elist_append(p, B, X); }\n";
    try golden(source, "statement_list(A) ::= statement(X).   { A = pik_elist_append(p, null, X); }\n" ++
        "statement_list(A) ::= statement_list(B) EOL statement(X).\n" ++
        " " ** 38 ++ "{ A = pik_elist_append(p, B, X); }\n");
    try golden(
        "foo ::= A. @a()\nfoo ::= AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.\n",
        "foo ::= A.   @a()\nfoo ::= AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.\n",
    );
}

test "format dropped tails opportunistically join established alignment" {
    try golden(
        "foo ::= LONG. @a()\nfoo ::= A.\n @b()\n",
        "foo ::= LONG.   @a()\nfoo ::= A.      @b()\n",
    );
    try golden(
        "foo ::= LONG. {x=1;}\nfoo ::= A.\n {y=2;}\n",
        "foo ::= LONG.   { x = 1; }\nfoo ::= A.      { y = 2; }\n",
    );
    try golden(
        "foo ::= A.\n {x=1;}\nfoo ::= B.\n @b()\n",
        "foo ::= A.\n        { x = 1; }\nfoo ::= B.\n              @b()\n",
    );
    try golden(
        "foo ::= A. @a()\nfoo ::= AB.\n @b()\n",
        "foo ::= A.   @a()\nfoo ::= AB.\n             @b()\n",
    );
}

test "format dropped tails align closing delimiters when opening alignment is marginal" {
    const pattern = "foo ::= " ++ "A" ** 36 ++ ".";
    const action = "@" ++ "x" ** 41 ++ "()";
    const code = "{ p(" ++ "a" ** 36 ++ "); }";
    const comfortable = "{ p(" ++ "a" ** 35 ++ "); }";
    const long_pattern = "foo ::= " ++ "B" ** 45 ++ ".";
    try golden(
        pattern ++ " @short()\n" ++ long_pattern ++ "\n " ++ comfortable ++ "\n",
        pattern ++ "  @short()\n" ++ long_pattern ++ "\n" ++ " " ** 47 ++ comfortable ++ "\n",
    );
    try golden(
        pattern ++ " @short()\nfoo ::= B.\n " ++ code ++ "\n",
        pattern ++ "  @short()\nfoo ::= B.\n" ++ " " ** 11 ++ code ++ "\n",
    );
    try golden(
        pattern ++ " { x = 1; }\nfoo ::= B.\n " ++ action ++ "\n",
        pattern ++ "  { x = 1; }\nfoo ::= B.\n" ++ " " ** 13 ++ action ++ "\n",
    );
    try golden(
        pattern ++ " @short()\n// note\nfoo ::= B.\n " ++ code ++ "\n",
        pattern ++ "  @short()\n// note\nfoo ::= B.\n" ++ " " ** 11 ++ code ++ "\n",
    );
    try golden(
        pattern ++ " @short()\nfoo ::= X.\nfoo ::= B.\n " ++ code ++ "\n",
        pattern ++ "  @short()\nfoo ::= X.\nfoo ::= B.\n" ++ " " ** 8 ++ code ++ "\n",
    );
    try golden(
        pattern ++ " @short()\nbar ::= B.\n " ++ code ++ "\n",
        pattern ++ "  @short()\nbar ::= B.\n" ++ " " ** 8 ++ code ++ "\n",
    );
    try golden(
        pattern ++ " @short()\n\n\nfoo ::= B.\n " ++ code ++ "\n",
        pattern ++ "  @short()\n\n\nfoo ::= B.\n" ++ " " ** 8 ++ code ++ "\n",
    );
}

test "format undropping allows ninety columns but never marginal fit" {
    for ([_]usize{ 71, 72 }) |length| {
        const name = try allocator.alloc(u8, length);
        defer allocator.free(name);
        @memset(name, 'x');
        const source = try std.fmt.allocPrint(allocator, "foo ::= LONG. @a()\nfoo ::= A.\n @{s}()\n", .{name});
        defer allocator.free(source);
        const expected = try std.fmt.allocPrint(allocator, "foo ::= LONG.   @a()\nfoo ::= A.{s}@{s}()\n", .{
            if (length == 71) "      " else "\n        ", name,
        });
        defer allocator.free(expected);
        try golden(source, expected);
        if (length == 71) {
            const together = try std.fmt.allocPrint(allocator, "foo ::= LONG. @a()\nfoo ::= LONGG.\n @b()\nfoo ::= A.\n @{s}()\n", .{name});
            defer allocator.free(together);
            const joined = try std.fmt.allocPrint(allocator, "foo ::= LONG.   @a()\nfoo ::= LONGG.  @b()\nfoo ::= A.      @{s}()\n", .{name});
            defer allocator.free(joined);
            try golden(together, joined);
        }
    }
}

test "format layout connected runs separate at twelve spaces" {
    const output = try formatted("aaa ::= AAAAAAAAAA. @a()\nbbb ::= B. @b()\n", .{});
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\n\nbbb") != null);
    try std.testing.expect(actionColumn(output, "@a()") != actionColumn(output, "@b()"));
    try stable(output);
}

test "format bumping requires adjacent runs with inline tails" {
    try golden(
        "aaa ::= LONG. @a()\nbbb ::= B. @b()\n",
        "aaa ::= LONG.   @a()\nbbb ::= B.      @b()\n",
    );
    try golden(
        "aaa ::= LONG. @a()\nempty ::= X.\nbbb ::= B. @b()\n",
        "aaa ::= LONG.   @a()\nempty ::= X.\nbbb ::= B.   @b()\n",
    );
    try golden(
        "aaa ::= A. @a()\nempty ::= X.\nbbb ::= LONG. @b()\n",
        "aaa ::= A.   @a()\nempty ::= X.\nbbb ::= LONG.   @b()\n",
    );
    try golden(
        "rvalue(A) ::= PLACENAME(C). @color(A;C)\n\nprint ::= PRINT.\nprlist ::= pritem.\nprlist ::= prlist prsep pritem.\npritem ::= FILL(X). @fill( ; X)\npritem ::= THICKNESS(X). @thickness( ; X)\n",
        "rvalue(A) ::= PLACENAME(C).   @color(A;C)\n\nprint ::= PRINT.\nprlist ::= pritem.\nprlist ::= prlist prsep pritem.\npritem ::= FILL(X).        @fill(;X)\npritem ::= THICKNESS(X).   @thickness(;X)\n",
    );
}

test "format sample grammars are parseable and idempotent" {
    for ([_][]const u8{ "samples/calc.zy", "samples/edn.zy", "samples/pikchr.zy" }) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
        defer allocator.free(source);
        const output = try formatted(source, .{});
        defer allocator.free(output);
        const parser = ts.Parser.create();
        defer parser.destroy();
        try parser.setLanguage(ts.Language.fromRaw(grammar.language()));
        const tree = parser.parseString(output, null) orelse return error.ParseFailed;
        defer tree.destroy();
        if (tree.rootNode().hasError()) {
            std.debug.print("Unparseable formatted sample: {s}\n", .{path});
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ".zig-cache/format-failure.zy", .data = output });
            return error.FormattedSampleHasErrors;
        }
        try stable(output);
        const before = try semanticContent(source);
        defer allocator.free(before);
        const after = try semanticContent(output);
        defer allocator.free(after);
        if (!std.mem.eql(u8, before, after)) {
            var at: usize = 0;
            while (at < @min(before.len, after.len) and before[at] == after[at]) : (at += 1) {}
            std.debug.print("Semantic token difference in {s} at {d}\n", .{ path, at });
            try std.testing.expectEqualStrings(before[at -| 40..@min(before.len, at + 80)], after[at -| 40..@min(after.len, at + 80)]);
        }
    }
}

fn semanticContent(source: []const u8) ![]u8 {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ts.Language.fromRaw(grammar.language()));
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(allocator);
    var lhs: ?ts.Node = null;
    var cursor = tree.rootNode().walk();
    defer cursor.destroy();
    if (cursor.gotoFirstChild()) while (true) {
        const node = cursor.node();
        const rule = std.mem.eql(u8, node.kind(), "grammar_rule") or std.mem.eql(u8, node.kind(), "ditto_rule");
        if (rule) {
            try content.appendSlice(allocator, "RULE\x00");
            for (0..node.namedChildCount()) |i| {
                const child = node.namedChild(@intCast(i)).?;
                if (std.mem.eql(u8, child.kind(), "lhs")) lhs = child;
            }
            if (lhs) |name| try semanticNode(&content, source, name);
            for (0..node.namedChildCount()) |i| {
                const child = node.namedChild(@intCast(i)).?;
                if (!std.mem.eql(u8, child.kind(), "lhs")) try semanticNode(&content, source, child);
            }
        } else try semanticNode(&content, source, node);
        if (!cursor.gotoNextSibling()) break;
    };
    return content.toOwnedSlice(allocator);
}

fn semanticNode(output: *std.ArrayList(u8), source: []const u8, node: ts.Node) !void {
    if (std.mem.eql(u8, node.kind(), "comment")) return;
    if (std.mem.eql(u8, node.kind(), "code_block")) {
        const code = try allocator.dupeZ(u8, source[node.startByte() + 1 .. node.endByte() - 1]);
        defer allocator.free(code);
        var tokenizer = std.zig.Tokenizer.init(code);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag == .doc_comment or token.tag == .container_doc_comment) continue;
            const token_text = code[token.loc.start..token.loc.end];
            try output.appendSlice(allocator, if (token.tag == .invalid) std.mem.trim(u8, token_text, " \t\r\n") else token_text);
            try output.append(allocator, 0);
        }
    } else if (std.mem.eql(u8, node.kind(), "named_action")) {
        for (0..node.namedChildCount()) |i| try semanticNode(output, source, node.namedChild(@intCast(i)).?);
    } else if (node.childCount() == 0) {
        try output.appendSlice(allocator, source[node.startByte()..node.endByte()]);
        try output.append(allocator, 0);
    } else {
        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) while (true) {
            try semanticNode(output, source, cursor.node());
            if (!cursor.gotoNextSibling()) break;
        };
    }
}

const std = @import("std");
const allocator = std.testing.allocator;
const formatter = @import("zitron-format");
const ts = @import("tree-sitter");
const grammar = @import("tree_sitter_zitron");
