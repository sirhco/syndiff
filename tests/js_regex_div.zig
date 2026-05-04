//! ECMA-262 regex/division disambiguation tests for the JS parser.
//!
//! Each test feeds a minimal JS snippet to `js_parser.parse` and asserts
//! that the parser does NOT return an error (i.e., the `/` is classified
//! correctly and the parser does not misread a regex body as a comment or
//! vice versa). Function count is used as a proxy: if the function after
//! the `/` expression is counted, the slash was parsed correctly.

const std = @import("std");
const Io = std.Io;
const js_parser = @import("js_parser");

/// Parse source as x.js; return number of js_function nodes. Panics on error.
fn countFunctions(gpa: std.mem.Allocator, src: []const u8) !usize {
    var t = try js_parser.parse(gpa, src, "x.js");
    defer t.deinit();
    var n: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_function) n += 1;
    }
    return n;
}

/// Parse source and return true if parsing succeeds without error.
fn parsesOk(gpa: std.mem.Allocator, src: []const u8) bool {
    var t = js_parser.parse(gpa, src, "x.js") catch return false;
    t.deinit();
    return true;
}

/// Read a fixture from the project's testdata tree under cwd. Caller frees.
fn readFixture(gpa: std.mem.Allocator, io: Io, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "testdata/parse/js_regex_div/{s}", .{name});
    const cwd = Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, gpa, .limited(1 << 16));
}

// -- Smoke test (passes before Phase 9 changes) ---------------------------

test "smoke: simple regex in function body parses ok" {
    const gpa = std.testing.allocator;
    const src = "function f() { const r = /hello/g; return r; }";
    try std.testing.expectEqual(@as(usize, 1), try countFunctions(gpa, src));
}

// -- ECMA edge cases ------------------------------------------------------
// Each test wraps the snippet in a function + a trailing `sentinel` function.
// If the parser misclassifies `/`, it will either:
//   (a) return ParseError (parsesOk == false), or
//   (b) not find the sentinel function (countFunctions < 2).
// Both assertions are checked where applicable.

test "div_after_paren: (a)/b/g is division -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "div_after_paren.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_in_array: [/regex/] is regex -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_in_array.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_if: if (x) /re/ -- regex after control ) -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_if.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_comment: comment transparent, regex goal preserved -- two functions" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_comment.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_return: return /re/g is regex -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_return.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_throw: throw /re/ is regex -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_throw.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_block: {} /re/g at stmt level is regex -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_block.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "div_in_object: ({} / 2) is division -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "div_in_object.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_prefix_inc: ++/a/ is regex after prefix ++ -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_prefix_inc.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "div_after_postfix_inc: a++/2 is division after postfix++ -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "div_after_postfix_inc.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_fn_decl: function(){} /re/g is regex after fn decl -- two top-level functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_fn_decl.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    // Skim parser does not extract nested fn decls; expect outer + sentinel.
    // The key signal is that sentinel is found, meaning outer's body (containing
    // `function inner() {}; /re/g;`) was consumed without misparsing the regex.
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_arrow: x => /re/ is regex after arrow -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_arrow.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}

test "regex_after_ternary: x ? /re1/ : /re2/ is regex -- two functions parsed" {
    const gpa = std.testing.allocator;
    const src = try readFixture(gpa, std.testing.io, "regex_after_ternary.js");
    defer gpa.free(src);
    try std.testing.expect(parsesOk(gpa, src));
    try std.testing.expectEqual(@as(usize, 2), try countFunctions(gpa, src));
}
