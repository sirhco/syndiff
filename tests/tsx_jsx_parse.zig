//! Parser-level tests for `.tsx` JSX vs generic disambiguation. Each test
//! reads a fixture from `testdata/parse/tsx_jsx/`, runs `ts_parser.parse`,
//! and asserts the parse succeeds and produces the expected node-kind set.
const std = @import("std");
const Io = std.Io;
const syndiff = @import("syndiff");
const ts_parser = syndiff.ts_parser;
const ast = syndiff.ast;

fn readFixture(gpa: std.mem.Allocator, io: Io, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "testdata/parse/tsx_jsx/{s}", .{name});
    const cwd = Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, gpa, .limited(1 << 16));
}

fn parseFixture(gpa: std.mem.Allocator, io: Io, name: []const u8) !ast.Tree {
    const src = try readFixture(gpa, io, name);
    defer gpa.free(src);
    // Path argument must end in `.tsx` so the parser sets is_tsx=true.
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "testdata/parse/tsx_jsx/{s}", .{name});
    return try ts_parser.parse(gpa, src, path);
}

fn countKind(t: ast.Tree, kind: ast.Kind) usize {
    var n: usize = 0;
    for (t.nodes.items(.kind)) |k| if (k == kind) {
        n += 1;
    };
    return n;
}

test "tsx_jsx: mixed generics and jsx produce expected nodes" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "mixed_generics_and_jsx.tsx");
    defer t.deinit();
    // 2 functions + 1 const arrow.
    try std.testing.expect(countKind(t, ast.Kind.js_function) >= 2);
    try std.testing.expect(countKind(t, ast.Kind.js_const) >= 1);
}

test "tsx_jsx: intrinsic_lower" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "intrinsic_lower.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_const) >= 1);
}

test "tsx_jsx: component_self_close" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "component_self_close.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_const) >= 1);
}

test "tsx_jsx: component_with_children" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "component_with_children.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_function) >= 1);
}

test "tsx_jsx: nested_generic_in_jsx" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "nested_generic_in_jsx.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_const) >= 1);
}

test "tsx_jsx: fragment" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "fragment.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_function) >= 1);
}

test "tsx_jsx: jsx_then_paren_child" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "jsx_then_paren_child.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_function) >= 1);
}

test "tsx_jsx: typed_arrow_with_comma" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "typed_arrow_with_comma.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_const) >= 1);
}

test "tsx_jsx: typed_arrow_extends" {
    const gpa = std.testing.allocator;
    var t = try parseFixture(gpa, std.testing.io, "typed_arrow_extends.tsx");
    defer t.deinit();
    try std.testing.expect(countKind(t, ast.Kind.js_const) >= 1);
}
