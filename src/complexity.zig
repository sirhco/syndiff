//! Cyclomatic complexity counter.
//!
//! `count(tree, idx)` returns the cyclomatic complexity of the function/method
//! body rooted at node `idx`. The result is: (number of decision points) + 1.
//!
//! Decision points counted per language:
//!   Go:   if, for, case, select, &&, ||, goto
//!   Rust: if, match (each arm `=>` after the first), while, for, loop, &&, ||, ?
//!   Zig:  if, else if, switch (each prong `=>` after the first), while, for,
//!         orelse, catch, ||, and, or
//!   Dart: if, else if, for, while, do, case, &&, ||, ??
//!   JS/TS: if, else if, for, while, do, case, &&, ||, ??, ?.
//!   (Bare `?` ternary is not counted — too ambiguous against Dart nullable
//!   type markers and JS/TS generic syntax. `??` and `?.` are explicit.)
//!
//! All counters scan `tree.contentSlice(idx)` — the raw source bytes already
//! stored in the tree — using `lex` helpers to skip strings and comments.
//! This is an O(body_bytes) token walk with no allocations.

const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lex.zig");

/// Return the cyclomatic complexity of the node at `idx` in `tree`.
/// If `idx` is itself a function-level node, count its body directly. If it
/// is nested inside a function (e.g. a `*_stmt` row produced by cascade
/// suppression), climb to the enclosing function and count that. For
/// languages/kinds with no enclosing function, returns 1 (base).
/// Never returns 0.
pub fn count(tree: *ast.Tree, idx: ast.NodeIndex) u32 {
    const fn_idx = enclosingFn(tree, idx) orelse return 1;
    const kind = tree.nodes.items(.kind)[fn_idx];
    const src = tree.contentSlice(fn_idx);
    return switch (kind) {
        .go_fn, .go_method => countGo(src),
        .rust_fn => countRust(src),
        .zig_fn => countZig(src),
        .dart_fn, .dart_method => countDart(src),
        .js_function, .js_method => countJs(src),
        .java_method, .java_constructor => countJava(src),
        .cs_method => countCsharp(src),
        .cs_property => countCsharp(src),
        else => 1,
    };
}

/// Walk up `parent_idx` to find the nearest function-level node. Returns
/// `idx` itself if it is already function-level. Returns `null` if no
/// enclosing function is reachable.
pub fn enclosingFn(tree: *ast.Tree, idx: ast.NodeIndex) ?ast.NodeIndex {
    const kinds = tree.nodes.items(.kind);
    const parents = tree.nodes.items(.parent_idx);
    var cur = idx;
    while (true) {
        switch (kinds[cur]) {
            .go_fn, .go_method, .rust_fn, .zig_fn, .dart_fn, .dart_method, .js_function, .js_method, .java_method, .java_constructor, .cs_method, .cs_property => return cur,
            else => {},
        }
        const p = parents[cur];
        if (p == ast.ROOT_PARENT or p == cur) return null;
        cur = p;
    }
}

// ---------------------------------------------------------------------------
// Stubs — filled in Tasks 2–7
// ---------------------------------------------------------------------------

fn countGo(src: []const u8) u32 {
    var n: u32 = 1; // base
    var pos: u32 = 0;
    while (pos < src.len) {
        const c = src[pos];
        // Skip line comment
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '/') {
            pos = lex.skipLineComment(src, pos);
            continue;
        }
        // Skip block comment
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '*') {
            pos = lex.skipBlockComment(src, pos, false);
            continue;
        }
        // Skip double-quoted string
        if (c == '"') {
            pos = lex.skipDoubleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Skip raw string (backtick)
        if (c == '`') {
            pos = lex.skipBacktickRaw(src, pos) catch pos + 1;
            continue;
        }
        // Skip single-quoted rune literal
        if (c == '\'') {
            pos = lex.skipSingleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Two-char operators
        if (pos + 1 < src.len) {
            const two = src[pos .. pos + 2];
            if (std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "||")) {
                n += 1;
                pos += 2;
                continue;
            }
        }
        // Keywords (word-boundary checked)
        if (lex.matchKeyword(src, pos, "if") or
            lex.matchKeyword(src, pos, "for") or
            lex.matchKeyword(src, pos, "case") or
            lex.matchKeyword(src, pos, "select") or
            lex.matchKeyword(src, pos, "goto"))
        {
            n += 1;
        }
        pos += 1;
    }
    return n;
}
fn countRust(src: []const u8) u32 {
    var n: u32 = 1; // base
    var pos: u32 = 0;
    while (pos < src.len) {
        const c = src[pos];
        // Skip line comment
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '/') {
            pos = lex.skipLineComment(src, pos);
            continue;
        }
        // Skip block comment (Rust supports nested /* */)
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '*') {
            pos = lex.skipBlockComment(src, pos, true);
            continue;
        }
        // Skip double-quoted string (covers most string literals)
        if (c == '"') {
            pos = lex.skipDoubleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // ? propagation operator — only counts when followed by ; , ) } or whitespace
        // (avoids counting ? in type positions like Option<?> generics)
        if (c == '?' and pos + 1 < src.len) {
            const next = src[pos + 1];
            if (next == ';' or next == ',' or next == ')' or next == '}' or
                next == ' ' or next == '\n' or next == '\t')
            {
                n += 1;
            }
        }
        // Two-char operators
        if (pos + 1 < src.len) {
            const two = src[pos .. pos + 2];
            if (std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "||")) {
                n += 1;
                pos += 2;
                continue;
            }
            // match arm: =>
            if (std.mem.eql(u8, two, "=>")) {
                n += 1;
                pos += 2;
                continue;
            }
        }
        // Keywords
        if (lex.matchKeyword(src, pos, "if") or
            lex.matchKeyword(src, pos, "while") or
            lex.matchKeyword(src, pos, "for") or
            lex.matchKeyword(src, pos, "loop"))
        {
            n += 1;
        }
        pos += 1;
    }
    return n;
}
fn countZig(src: []const u8) u32 {
    var n: u32 = 1;
    var pos: u32 = 0;
    while (pos < src.len) {
        const c = src[pos];
        // Skip line comment //
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '/') {
            pos = lex.skipLineComment(src, pos);
            continue;
        }
        // Skip double-quoted string
        if (c == '"') {
            pos = lex.skipDoubleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Skip Zig multiline string literal \\ ... (consume to end of line)
        if (c == '\\' and pos + 1 < src.len and src[pos + 1] == '\\') {
            pos = lex.skipLineComment(src, pos); // same: consume to \n
            continue;
        }
        // Two-char operators: ||, =>
        if (pos + 1 < src.len) {
            const two = src[pos .. pos + 2];
            if (std.mem.eql(u8, two, "||") or std.mem.eql(u8, two, "=>")) {
                n += 1;
                pos += 2;
                continue;
            }
        }
        // Keywords (Zig uses `and`/`or` as operators, not `&&`/`||`)
        if (lex.matchKeyword(src, pos, "if") or
            lex.matchKeyword(src, pos, "while") or
            lex.matchKeyword(src, pos, "for") or
            lex.matchKeyword(src, pos, "orelse") or
            lex.matchKeyword(src, pos, "catch") or
            lex.matchKeyword(src, pos, "and") or
            lex.matchKeyword(src, pos, "or"))
        {
            n += 1;
        }
        pos += 1;
    }
    return n;
}
fn countDart(src: []const u8) u32 {
    return countCStyle(src, false);
}

fn countJs(src: []const u8) u32 {
    return countCStyle(src, true);
}

fn countJava(src: []const u8) u32 {
    var n: u32 = 1;
    var pos: u32 = 0;
    while (pos < src.len) {
        const c = src[pos];
        // Skip line comment //
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '/') {
            pos = lex.skipLineComment(src, pos);
            continue;
        }
        // Skip block comment /* */
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '*') {
            pos = lex.skipBlockComment(src, pos, false);
            continue;
        }
        // Java text block: """..."""
        if (c == '"' and pos + 2 < src.len and src[pos + 1] == '"' and src[pos + 2] == '"') {
            pos += 3;
            while (pos + 2 < src.len) {
                if (src[pos] == '\\' and pos + 1 < src.len) {
                    pos += 2;
                    continue;
                }
                if (src[pos] == '"' and src[pos + 1] == '"' and src[pos + 2] == '"') {
                    pos += 3;
                    break;
                }
                pos += 1;
            }
            continue;
        }
        if (c == '"') {
            pos = lex.skipDoubleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        if (c == '\'') {
            pos = lex.skipSingleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Two-char operators &&, ||
        if (pos + 1 < src.len) {
            const two = src[pos .. pos + 2];
            if (std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "||")) {
                n += 1;
                pos += 2;
                continue;
            }
        }
        // Ternary `?` — count once. (Java has no nullable-type `?` syntax.)
        if (c == '?') {
            n += 1;
            pos += 1;
            continue;
        }
        // Keywords
        if (lex.matchKeyword(src, pos, "if") or
            lex.matchKeyword(src, pos, "for") or
            lex.matchKeyword(src, pos, "while") or
            lex.matchKeyword(src, pos, "do") or
            lex.matchKeyword(src, pos, "case") or
            lex.matchKeyword(src, pos, "catch"))
        {
            n += 1;
        }
        pos += 1;
    }
    return n;
}

fn countCsharp(src: []const u8) u32 {
    var n: u32 = 1;
    var pos: u32 = 0;
    while (pos < src.len) {
        const c = src[pos];
        // Line comment //
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '/') {
            pos = lex.skipLineComment(src, pos);
            continue;
        }
        // Block comment /* */
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '*') {
            pos = lex.skipBlockComment(src, pos, false);
            continue;
        }
        // Raw / verbatim / interpolated string prefixes. For complexity
        // counting, we approximate by skipping the literal contents bracket-
        // by-bracket — close enough since interpolation expressions can
        // legitimately contain branches but we err on the side of false
        // positives via simple skipping.
        // C# 11 raw triple-quoted: """...""" (must check before single ")
        if (c == '"' and pos + 2 < src.len and src[pos + 1] == '"' and src[pos + 2] == '"') {
            // Count opening run.
            var q_run: u32 = 0;
            while (pos < src.len and src[pos] == '"') : (pos += 1) q_run += 1;
            while (pos < src.len) {
                if (src[pos] == '"') {
                    var c_run: u32 = 0;
                    while (pos < src.len and src[pos] == '"') : (pos += 1) c_run += 1;
                    if (c_run >= q_run) break;
                    continue;
                }
                pos += 1;
            }
            continue;
        }
        // Verbatim string @"..." (doubled "" is escape).
        if (c == '@' and pos + 1 < src.len and src[pos + 1] == '"') {
            pos += 2;
            while (pos < src.len) {
                if (src[pos] == '"') {
                    if (pos + 1 < src.len and src[pos + 1] == '"') {
                        pos += 2;
                        continue;
                    }
                    pos += 1;
                    break;
                }
                pos += 1;
            }
            continue;
        }
        // Interpolated $"..." or $@"..." / @$"...".
        if (c == '$' and pos + 1 < src.len and (src[pos + 1] == '"' or src[pos + 1] == '@')) {
            pos += 1;
            // Possibly second `@`.
            if (pos < src.len and src[pos] == '@') pos += 1;
            if (pos < src.len and src[pos] == '"') {
                pos += 1;
                // Scan; treat `{` as start of interp body — decision points
                // inside interp count toward total.
                var brace: u32 = 0;
                while (pos < src.len) {
                    const cc = src[pos];
                    if (brace == 0 and cc == '"') {
                        pos += 1;
                        break;
                    }
                    if (cc == '\\') {
                        pos += 2;
                        continue;
                    }
                    if (cc == '{') {
                        if (pos + 1 < src.len and src[pos + 1] == '{') {
                            pos += 2;
                            continue;
                        }
                        brace += 1;
                        pos += 1;
                        continue;
                    }
                    if (cc == '}' and brace > 0) {
                        brace -= 1;
                        pos += 1;
                        continue;
                    }
                    pos += 1;
                }
                continue;
            }
            continue;
        }
        // Regular string.
        if (c == '"') {
            pos = lex.skipDoubleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Char literal.
        if (c == '\'') {
            pos = lex.skipSingleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Two-char operators.
        if (pos + 1 < src.len) {
            const two = src[pos .. pos + 2];
            if (std.mem.eql(u8, two, "??") or std.mem.eql(u8, two, "?.") or
                std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "||"))
            {
                n += 1;
                pos += 2;
                continue;
            }
        }
        // Bare `?` ternary — count once. C#'s nullable suffix `string?` does
        // not appear inside fn bodies as a standalone token; ternary `cond ?
        // a : b` is the dominant context.
        if (c == '?') {
            n += 1;
            pos += 1;
            continue;
        }
        // Keywords.
        if (lex.matchKeyword(src, pos, "if") or
            lex.matchKeyword(src, pos, "for") or
            lex.matchKeyword(src, pos, "foreach") or
            lex.matchKeyword(src, pos, "while") or
            lex.matchKeyword(src, pos, "do") or
            lex.matchKeyword(src, pos, "case") or
            lex.matchKeyword(src, pos, "catch") or
            lex.matchKeyword(src, pos, "when"))
        {
            n += 1;
        }
        pos += 1;
    }
    return n;
}

/// Shared counter for Dart and JS/TS.
/// `count_optional_chain` — if true, count `?.` as a decision point (JS/TS only).
fn countCStyle(src: []const u8, count_optional_chain: bool) u32 {
    var n: u32 = 1;
    var pos: u32 = 0;
    while (pos < src.len) {
        const c = src[pos];
        // Skip line comment //
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '/') {
            pos = lex.skipLineComment(src, pos);
            continue;
        }
        // Skip block comment /* */
        if (c == '/' and pos + 1 < src.len and src[pos + 1] == '*') {
            pos = lex.skipBlockComment(src, pos, false);
            continue;
        }
        // Skip double-quoted string
        if (c == '"') {
            pos = lex.skipDoubleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Skip single-quoted string
        if (c == '\'') {
            pos = lex.skipSingleQuoteString(src, pos) catch pos + 1;
            continue;
        }
        // Skip template literal (backtick) — treat as raw string to EOT
        if (c == '`') {
            pos = lex.skipBacktickRaw(src, pos) catch pos + 1;
            continue;
        }
        // Three- and two-char operators (must check longer first)
        if (pos + 1 < src.len) {
            const two = src[pos .. pos + 2];
            // ?? null-coalescing
            if (std.mem.eql(u8, two, "??")) {
                n += 1;
                pos += 2;
                continue;
            }
            // ?. optional chaining (JS/TS only)
            if (count_optional_chain and std.mem.eql(u8, two, "?.")) {
                n += 1;
                pos += 2;
                continue;
            }
            // && and ||
            if (std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "||")) {
                n += 1;
                pos += 2;
                continue;
            }
        }
        // Bare ? is ambiguous (Dart nullable types, ternary, generics).
        // Skip without counting to avoid false positives. `??` and `?.` are
        // handled above as explicit two-char operators.
        if (c == '?') {
            pos += 1;
            continue;
        }
        // Keywords
        if (lex.matchKeyword(src, pos, "if") or
            lex.matchKeyword(src, pos, "for") or
            lex.matchKeyword(src, pos, "while") or
            lex.matchKeyword(src, pos, "do") or
            lex.matchKeyword(src, pos, "case"))
        {
            n += 1;
        }
        pos += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "count returns at least 1 for empty Go fn body" {
    const src =
        \\func Noop() {}
    ;
    try std.testing.expect(countGo(src) >= 1);
}

test "count returns at least 1 for empty Rust fn body" {
    const src =
        \\fn noop() {}
    ;
    try std.testing.expect(countRust(src) >= 1);
}

test "Go: straight-line function has complexity 1" {
    const src =
        \\func Add(a, b int) int {
        \\    x := a + b
        \\    return x
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), countGo(src));
}

test "Go: single if adds 1" {
    const src =
        \\func Abs(n int) int {
        \\    if n < 0 {
        \\        return -n
        \\    }
        \\    return n
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), countGo(src));
}

test "Go: if + for + case = 3 decision points, complexity 4" {
    const src =
        \\func F(s []string) int {
        \\    if len(s) == 0 { return 0 }
        \\    for _, v := range s {
        \\        switch v {
        \\        case "a": return 1
        \\        }
        \\    }
        \\    return 2
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 4), countGo(src));
}

test "Go: keyword inside string literal does not count" {
    const src =
        \\func F() string {
        \\    return "if for case"
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), countGo(src));
}

test "Go: && and || each add 1" {
    const src =
        \\func F(a, b, c bool) bool {
        \\    return a && b || c
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 3), countGo(src));
}

test "Rust: straight-line fn has complexity 1" {
    const src =
        \\fn add(a: i32, b: i32) -> i32 { a + b }
    ;
    try std.testing.expectEqual(@as(u32, 1), countRust(src));
}

test "Rust: if adds 1" {
    const src =
        \\fn abs(n: i32) -> i32 {
        \\    if n < 0 { -n } else { n }
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), countRust(src));
}

test "Rust: match with 3 arms adds 3 (each => is a branch)" {
    const src =
        \\fn label(n: u8) -> &'static str {
        \\    match n {
        \\        0 => "zero",
        \\        1 => "one",
        \\        _ => "many",
        \\    }
        \\}
    ;
    // 3 arms => 3 decision points => complexity 4
    try std.testing.expectEqual(@as(u32, 4), countRust(src));
}

test "Rust: ? operator adds 1" {
    const src =
        \\fn read() -> Result<String, Err> {
        \\    let s = std::fs::read_to_string("f")?;
        \\    Ok(s)
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), countRust(src));
}

test "Rust: keyword inside string does not count" {
    const src =
        \\fn msg() -> &'static str { "if while for loop" }
    ;
    try std.testing.expectEqual(@as(u32, 1), countRust(src));
}

test "Zig: straight-line fn has complexity 1" {
    const src =
        \\fn add(a: u32, b: u32) u32 { return a + b; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countZig(src));
}

test "Zig: if adds 1" {
    const src =
        \\fn abs(n: i32) i32 {
        \\    if (n < 0) return -n;
        \\    return n;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), countZig(src));
}

test "Zig: orelse and catch each add 1" {
    const src =
        \\fn f(opt: ?u32) u32 {
        \\    const x = opt orelse 0;
        \\    const y = parse() catch 0;
        \\    return x + y;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 3), countZig(src));
}

test "Zig: switch prongs via =>" {
    const src =
        \\fn label(n: u8) []const u8 {
        \\    return switch (n) {
        \\        0 => "zero",
        \\        1 => "one",
        \\        else => "many",
        \\    };
        \\}
    ;
    // 3 prongs => complexity 4
    try std.testing.expectEqual(@as(u32, 4), countZig(src));
}

test "Zig: keyword inside string does not count" {
    const src =
        \\fn msg() []const u8 { return "if while orelse catch"; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countZig(src));
}

test "Dart: straight-line fn has complexity 1" {
    const src =
        \\int add(int a, int b) { return a + b; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countDart(src));
}

test "Dart: if and for add 2" {
    const src =
        \\int sum(List<int> xs) {
        \\    if (xs.isEmpty) return 0;
        \\    int t = 0;
        \\    for (final x in xs) { t += x; }
        \\    return t;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 3), countDart(src));
}

test "Dart: ?? adds 1" {
    const src =
        \\String name(String? n) => n ?? 'anon';
    ;
    try std.testing.expectEqual(@as(u32, 2), countDart(src));
}

test "Dart: keyword in string does not count" {
    const src =
        \\String msg() => 'if for while case';
    ;
    try std.testing.expectEqual(@as(u32, 1), countDart(src));
}

test "JS: straight-line fn has complexity 1" {
    const src =
        \\function add(a, b) { return a + b; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countJs(src));
}

test "JS: if, while, case add 3" {
    const src =
        \\function f(x) {
        \\    if (x > 0) {
        \\        while (x > 1) { x--; }
        \\        switch(x) { case 1: break; }
        \\    }
        \\    return x;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 4), countJs(src));
}

test "JS: ?. adds 1" {
    const src =
        \\function name(obj) { return obj?.name; }
    ;
    try std.testing.expectEqual(@as(u32, 2), countJs(src));
}

test "JS: keyword in string does not count" {
    const src =
        \\function msg() { return "if while for case"; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countJs(src));
}

test "Java: straight-line method has complexity 1" {
    const src =
        \\public int add(int a, int b) { return a + b; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countJava(src));
}

test "Java: if + for + case adds 3" {
    const src =
        \\public int f(int[] xs) {
        \\    if (xs.length == 0) return 0;
        \\    int t = 0;
        \\    for (int x : xs) {
        \\        switch (x) { case 1: t++; break; }
        \\    }
        \\    return t;
        \\}
    ;
    // 1 (base) + if + for + case = 4
    try std.testing.expectEqual(@as(u32, 4), countJava(src));
}

test "Java: && and || each add 1" {
    const src =
        \\public boolean f(boolean a, boolean b, boolean c) {
        \\    return a && b || c;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 3), countJava(src));
}

test "Java: try/catch — catch adds 1" {
    const src =
        \\public void f() {
        \\    try { x(); } catch (Exception e) { y(); }
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), countJava(src));
}

test "Java: keyword in string does not count" {
    const src =
        \\public String msg() { return "if while for case catch"; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countJava(src));
}

test "Java: ternary adds 1" {
    const src =
        \\public int sgn(int x) { return x < 0 ? -1 : 1; }
    ;
    // 1 (base) + ? (ternary) = 2  (`<` is not counted)
    try std.testing.expectEqual(@as(u32, 2), countJava(src));
}

test "C#: straight-line method has complexity 1" {
    const src =
        \\public int Add(int a, int b) { return a + b; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countCsharp(src));
}

test "C#: if + foreach + case adds 3" {
    const src =
        \\public int F(int[] xs) {
        \\    if (xs.Length == 0) return 0;
        \\    int t = 0;
        \\    foreach (var x in xs) {
        \\        switch (x) { case 1: t++; break; }
        \\    }
        \\    return t;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 4), countCsharp(src));
}

test "C#: ?? and ?. each add 1" {
    const src =
        \\public string Name(object o) { return o?.ToString() ?? "null"; }
    ;
    // 1 (base) + ?. + ?? = 3
    try std.testing.expectEqual(@as(u32, 3), countCsharp(src));
}

test "C#: when filter adds 1" {
    const src =
        \\public void F() {
        \\    try { x(); } catch (Exception e) when (e.Message != null) { y(); }
        \\}
    ;
    // 1 (base) + catch + when = 3
    try std.testing.expectEqual(@as(u32, 3), countCsharp(src));
}

test "C#: keyword in string does not count" {
    const src =
        \\public string Msg() { return "if while for foreach case catch when"; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countCsharp(src));
}

test "C#: keyword in verbatim string does not count" {
    const src =
        \\public string Msg() { return @"if while ""for"" case"; }
    ;
    try std.testing.expectEqual(@as(u32, 1), countCsharp(src));
}
