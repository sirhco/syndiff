//! Zig source parser. Wraps `std.zig.Ast` and projects the top-level decl list
//! onto SynDiff's flat AST. Each top-level decl becomes one node:
//!   - `zig_fn`     — function declarations / prototypes
//!   - `zig_struct` — comptime container decls bound to an identifier
//!                    (`const Foo = struct { ... };`)
//!   - `zig_decl`   — every other top-level binding (vars, tests, comptime
//!                    blocks, usingnamespace, etc.)
//!
//! Identity bytes = decl name (or "<anonymous>" for unnamed test blocks etc.).
//! Subtree hash   = full source bytes of the decl.
//!
//! Function bodies are NOT recursed: a body change shows up as MODIFIED on the
//! decl. Adding a new fn shows up as ADDED. Rename = ADDED+DELETED. Reorder =
//! MOVED. This matches the spec ("Function Signature in Rust").

const std = @import("std");
const ast_mod = @import("ast.zig");
const hash_mod = @import("hash.zig");

const NodeIndex = ast_mod.NodeIndex;
const Range = ast_mod.Range;
const Kind = ast_mod.Kind;
const ROOT_PARENT = ast_mod.ROOT_PARENT;

pub const ParseError = error{
    SyntaxError,
} || std.mem.Allocator.Error;

const ANONYMOUS = "<anonymous>";

/// Parse Zig source into a `Tree`. `source` must be null-terminated as
/// required by `std.zig.Ast.parse`. Caller owns returned tree.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8, path: []const u8) ParseError!ast_mod.Tree {
    var tree = ast_mod.Tree.init(gpa, source, path);
    errdefer tree.deinit();

    var zast = try std.zig.Ast.parse(gpa, source, .zig);
    defer zast.deinit(gpa);

    if (zast.errors.len > 0) return error.SyntaxError;

    const root_identity = hash_mod.identityHash(0, .file_root, "");

    var decl_indices: std.ArrayList(NodeIndex) = .empty;
    defer decl_indices.deinit(gpa);
    var decl_hashes: std.ArrayList(u64) = .empty;
    defer decl_hashes.deinit(gpa);

    var anon_counter: u32 = 0;
    var anon_buf: [16]u8 = undefined;
    for (zast.rootDecls()) |decl_node| {
        const info = classifyDecl(&zast, decl_node);
        const ident_bytes: []const u8 = if (std.mem.eql(u8, info.name, ANONYMOUS)) blk: {
            const idx_str = std.fmt.bufPrint(&anon_buf, "<anon:{d}>", .{anon_counter}) catch unreachable;
            anon_counter += 1;
            break :blk idx_str;
        } else info.name;
        const decl_identity = hash_mod.identityHash(root_identity, info.kind, ident_bytes);

        // For fn_decl nodes, walk the body block and emit stmt children FIRST
        // (post-order), then the fn node, then backpatch stmt parents.
        var stmt_indices: std.ArrayList(NodeIndex) = .empty;
        defer stmt_indices.deinit(gpa);
        var stmt_hashes: std.ArrayList(u64) = .empty;
        defer stmt_hashes.deinit(gpa);

        if (info.kind == .zig_fn and zast.nodeTag(decl_node) == .fn_decl) {
            const body_node = zast.nodeData(decl_node).node_and_node[1];
            try extractZigBlockStmts(
                gpa,
                &zast,
                body_node,
                decl_identity,
                &tree,
                &stmt_indices,
                &stmt_hashes,
            );
        }

        const decl_bytes = source[info.range.start..info.range.end];
        const decl_hash = hash_mod.subtreeHash(info.kind, stmt_hashes.items, decl_bytes);

        const idx = try tree.addNode(.{
            .hash = decl_hash,
            .identity_hash = decl_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, ident_bytes),
            .kind = info.kind,
            .depth = 1,
            .parent_idx = ROOT_PARENT,
            .content_range = info.range,
            .identity_range = info.name_range,
            .is_exported = startsWithVisibility(source, info.range.start, "pub"),
        });
        try decl_indices.append(gpa, idx);
        try decl_hashes.append(gpa, decl_hash);

        const parents_arr = tree.nodes.items(.parent_idx);
        for (stmt_indices.items) |s| parents_arr[s] = idx;
    }

    const root_hash = hash_mod.subtreeHash(.file_root, decl_hashes.items, "");
    const root_idx = try tree.addNode(.{
        .hash = root_hash,
        .identity_hash = root_identity,
        .identity_range_hash = 0,
        .kind = .file_root,
        .depth = 0,
        .parent_idx = ROOT_PARENT,
        .content_range = .{ .start = 0, .end = @intCast(source.len) },
        .identity_range = Range.empty,
        .is_exported = false,
    });

    const parents = tree.nodes.items(.parent_idx);
    for (decl_indices.items) |d| parents[d] = root_idx;

    return tree;
}

const DeclInfo = struct {
    kind: Kind,
    name: []const u8,
    name_range: Range,
    range: Range,
};

fn nodeRange(zast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) Range {
    const first = zast.firstToken(node);
    const last = zast.lastToken(node);
    const start = zast.tokenStart(first);
    const last_slice = zast.tokenSlice(last);
    const last_start = zast.tokenStart(last);
    const end: u32 = last_start + @as(u32, @intCast(last_slice.len));
    return .{ .start = start, .end = end };
}

fn tokenRange(zast: *const std.zig.Ast, token_idx: std.zig.Ast.TokenIndex) Range {
    const start = zast.tokenStart(token_idx);
    const slice = zast.tokenSlice(token_idx);
    return .{ .start = start, .end = start + @as(u32, @intCast(slice.len)) };
}

fn extractZigBlockStmts(
    gpa: std.mem.Allocator,
    zast: *const std.zig.Ast,
    body_node: std.zig.Ast.Node.Index,
    fn_identity: u64,
    tree: *ast_mod.Tree,
    out_indices: *std.ArrayList(NodeIndex),
    out_hashes: *std.ArrayList(u64),
) ParseError!void {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const stmts = zast.blockStatements(&buf, body_node) orelse return;
    var idx_buf: [16]u8 = undefined;
    for (stmts, 0..) |s, i| {
        const range = nodeRange(zast, s);
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        const stmt_id = hash_mod.identityHash(fn_identity, .zig_stmt, idx_str);
        const stmt_bytes = zast.source[range.start..range.end];
        const stmt_h = hash_mod.subtreeHash(.zig_stmt, &.{}, stmt_bytes);
        const idx = try tree.addNode(.{
            .hash = stmt_h,
            .identity_hash = stmt_id,
            .identity_range_hash = 0,
            .kind = .zig_stmt,
            .depth = 2,
            .parent_idx = ROOT_PARENT,
            .content_range = range,
            .identity_range = Range.empty,
            .is_exported = false,
        });
        try out_indices.append(gpa, idx);
        try out_hashes.append(gpa, stmt_h);
    }
}

fn classifyDecl(zast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) DeclInfo {
    const range = nodeRange(zast, node);

    var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
    if (zast.fullFnProto(&fn_buf, node)) |fn_proto| {
        if (fn_proto.name_token) |name_tok| {
            const slice = zast.tokenSlice(name_tok);
            return .{
                .kind = .zig_fn,
                .name = slice,
                .name_range = tokenRange(zast, name_tok),
                .range = range,
            };
        }
        return .{ .kind = .zig_fn, .name = ANONYMOUS, .name_range = Range.empty, .range = range };
    }

    if (zast.fullVarDecl(node)) |var_decl| {
        const name_tok = var_decl.ast.mut_token + 1; // identifier follows `const`/`var`
        const slice = zast.tokenSlice(name_tok);
        const init_node = var_decl.ast.init_node.unwrap();
        const kind: Kind = if (init_node) |init_idx| switch (zast.nodeTag(init_idx)) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => .zig_struct,
            else => .zig_decl,
        } else .zig_decl;

        return .{
            .kind = kind,
            .name = slice,
            .name_range = tokenRange(zast, name_tok),
            .range = range,
        };
    }

    // Test decl, comptime block, usingnamespace, etc.
    return .{
        .kind = .zig_decl,
        .name = ANONYMOUS,
        .name_range = Range.empty,
        .range = range,
    };
}

/// True when, after skipping whitespace and `#[...]` attributes starting at
/// `start`, the next non-trivia bytes are exactly `keyword`.
fn startsWithVisibility(src: []const u8, start: u32, keyword: []const u8) bool {
    var i: usize = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '#' and i + 1 < src.len and src[i + 1] == '[') {
            while (i < src.len and src[i] != ']') i += 1;
            if (i < src.len) i += 1;
            continue;
        }
        break;
    }
    return std.mem.startsWith(u8, src[i..], keyword);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty file" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "", "empty.zig");
    defer t.deinit();
    // Just file_root.
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.file_root, t.nodes.items(.kind)[0]);
}

test "parse single function" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "pub fn add(a: i32, b: i32) i32 { return a + b; }";
    var t = try parse(gpa, src, "x.zig");
    defer t.deinit();

    // 1 stmt (return) + 1 fn + 1 file_root
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.zig_stmt, kinds[0]);
    try std.testing.expectEqual(Kind.zig_fn, kinds[1]);
    try std.testing.expectEqual(Kind.file_root, kinds[2]);

    try std.testing.expectEqualStrings("add", t.identitySlice(1));
}

test "parse mixed decls" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn foo() void {}
        \\
        \\const Point = struct { x: i32, y: i32 };
        \\
        \\test "smoke" { _ = std; }
    ;
    var t = try parse(gpa, src, "x.zig");
    defer t.deinit();

    const kinds = t.nodes.items(.kind);
    // Expect: zig_decl (std), zig_fn (foo), zig_struct (Point), zig_decl (test), file_root
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    try std.testing.expectEqual(Kind.zig_decl, kinds[0]);
    try std.testing.expectEqual(Kind.zig_fn, kinds[1]);
    try std.testing.expectEqual(Kind.zig_struct, kinds[2]);
    try std.testing.expectEqual(Kind.zig_decl, kinds[3]);
    try std.testing.expectEqual(Kind.file_root, kinds[4]);

    try std.testing.expectEqualStrings("std", t.identitySlice(0));
    try std.testing.expectEqualStrings("foo", t.identitySlice(1));
    try std.testing.expectEqualStrings("Point", t.identitySlice(2));
}

test "syntax error rejected" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "pub fn { broken";
    try std.testing.expectError(error.SyntaxError, parse(gpa, src, "x.zig"));
}

test "subtree hash differs when fn body changes" {
    const gpa = std.testing.allocator;
    const a_src: [:0]const u8 = "pub fn add(a: i32, b: i32) i32 { return a + b; }";
    const b_src: [:0]const u8 = "pub fn add(a: i32, b: i32) i32 { return a - b; }";
    var a = try parse(gpa, a_src, "a.zig");
    defer a.deinit();
    var b = try parse(gpa, b_src, "b.zig");
    defer b.deinit();

    // Fn nodes are at index 0 in both.
    try std.testing.expect(a.nodes.items(.hash)[0] != b.nodes.items(.hash)[0]);
    // Identities match (same name).
    try std.testing.expectEqual(a.nodes.items(.identity_hash)[0], b.nodes.items(.identity_hash)[0]);
}

test "zig fn body extracts statement nodes" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    const x = a + b;
        \\    const y = x * 2;
        \\    return y;
        \\}
    ;
    var t = try parse(gpa, src, "x.zig");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var stmt_count: usize = 0;
    for (kinds) |k| {
        if (k == .zig_stmt) stmt_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), stmt_count);

    var fn_idx: ?NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .zig_fn) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);
    const parents = t.nodes.items(.parent_idx);
    for (kinds, 0..) |k, i| {
        if (k == .zig_stmt) {
            try std.testing.expectEqual(fn_idx.?, parents[i]);
        }
    }
}

test "identity differs across fn names" {
    const gpa = std.testing.allocator;
    var a = try parse(gpa, "fn add() void {}", "a.zig");
    defer a.deinit();
    var b = try parse(gpa, "fn sub() void {}", "b.zig");
    defer b.deinit();

    try std.testing.expect(a.nodes.items(.identity_hash)[0] != b.nodes.items(.identity_hash)[0]);
}

test "is_exported true for pub fn; false otherwise; identity_range_hash non-zero" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "pub fn foo() void {}\nfn bar() void {}\n";
    var tree = try parse(gpa, src, "x.zig");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exps = tree.nodes.items(.is_exported);
    const irhs = tree.nodes.items(.identity_range_hash);
    var saw_pub = false;
    var saw_priv = false;
    for (kinds, exps, irhs, 0..) |k, exp, h, i| {
        if (k != .zig_fn) continue;
        try std.testing.expect(h != 0);
        const name = tree.identitySlice(@intCast(i));
        if (std.mem.eql(u8, name, "foo")) {
            try std.testing.expect(exp);
            saw_pub = true;
        } else if (std.mem.eql(u8, name, "bar")) {
            try std.testing.expect(!exp);
            saw_priv = true;
        }
    }
    try std.testing.expect(saw_pub and saw_priv);
}
