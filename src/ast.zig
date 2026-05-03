//! Data-Oriented Design AST for SynDiff.
//!
//! Nodes live in a `std.MultiArrayList(Node)` so each field is a contiguous
//! column. Diff scans (e.g. `slice().items(.identity_hash)`) walk a packed
//! `[]u64` — sequential, prefetcher-friendly.

const std = @import("std");

pub const NodeIndex = u32;

/// Sentinel parent index for the root node of a Tree.
pub const ROOT_PARENT: NodeIndex = std.math.maxInt(u32);

/// Half-open byte range into the source buffer: [start, end).
pub const Range = struct {
    start: u32,
    end: u32,

    pub const empty: Range = .{ .start = 0, .end = 0 };

    pub fn len(self: Range) u32 {
        return self.end - self.start;
    }
};

/// Node kind. Multi-language variants are pre-shaped now to avoid a future
/// ABI break across every match exhaustiveness check.
pub const Kind = enum(u8) {
    // JSON (Step 2)
    json_object,
    json_array,
    json_member,
    json_string,
    json_number,
    json_bool,
    json_null,
    // YAML
    yaml_mapping,
    yaml_sequence,
    yaml_pair,
    yaml_scalar,
    // Rust
    rust_fn,
    rust_struct,    // struct, enum, union
    rust_impl,
    rust_trait,
    rust_mod,
    rust_use,
    rust_const,     // const, static, type alias
    rust_macro,     // macro_rules! and macro invocations at top level
    // Go
    go_package,
    go_import,
    go_fn,
    go_method,
    go_type,        // type X struct/interface/alias
    go_var,
    go_const,
    // Zig (Step 4+)
    zig_fn,
    zig_decl,
    zig_struct,
    // Statement-level (per-language fn body children)
    rust_stmt,
    go_stmt,
    zig_stmt,
    // Dart
    dart_class,
    dart_mixin,
    dart_enum,
    dart_extension,
    dart_typedef,
    dart_fn,
    dart_method,
    dart_field,
    dart_const,
    dart_import,
    dart_stmt,
    // JavaScript
    js_function,
    js_class,
    js_method,
    js_const,
    js_let,
    js_var,
    js_import,
    js_export,
    js_stmt,
    // TypeScript (superset of JS)
    ts_interface,
    ts_type,
    ts_enum,
    ts_namespace,
    ts_declare,
    ts_stmt,
    // Generic
    file_root,
};

pub const Node = struct {
    hash: u64,
    identity_hash: u64,
    identity_range_hash: u64,
    kind: Kind,
    depth: u16,
    parent_idx: NodeIndex,
    content_range: Range,
    identity_range: Range,
    is_exported: bool,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.MultiArrayList(Node),
    source: []const u8,
    path: []const u8,

    pub fn init(gpa: std.mem.Allocator, source: []const u8, path: []const u8) Tree {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .nodes = .{},
            .source = source,
            .path = path,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn addNode(self: *Tree, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.len);
        try self.nodes.append(self.arena.allocator(), node);
        return idx;
    }

    pub fn slice(self: *Tree) std.MultiArrayList(Node).Slice {
        return self.nodes.slice();
    }

    pub fn get(self: *Tree, idx: NodeIndex) Node {
        return self.nodes.get(idx);
    }

    pub fn contentSlice(self: *Tree, idx: NodeIndex) []const u8 {
        const r = self.nodes.items(.content_range)[idx];
        return self.source[r.start..r.end];
    }

    pub fn identitySlice(self: *Tree, idx: NodeIndex) []const u8 {
        const r = self.nodes.items(.identity_range)[idx];
        return self.source[r.start..r.end];
    }

    /// Linear scan over `parent_idx` column. Result appended to `out`.
    pub fn childrenOf(
        self: *Tree,
        gpa: std.mem.Allocator,
        parent: NodeIndex,
        out: *std.ArrayList(NodeIndex),
    ) !void {
        const parents = self.nodes.items(.parent_idx);
        for (parents, 0..) |p, i| {
            if (p == parent) {
                try out.append(gpa, @intCast(i));
            }
        }
    }

    pub const LineCol = struct { line: u32, col: u32 };

    /// Convert a node's `content_range.start` byte offset into 1-indexed
    /// (line, col). O(start) — fine for diff output, not hot paths.
    pub fn lineCol(self: *Tree, idx: NodeIndex) LineCol {
        const range = self.nodes.items(.content_range)[idx];
        var line: u32 = 1;
        var col: u32 = 1;
        var i: u32 = 0;
        while (i < range.start and i < self.source.len) : (i += 1) {
            if (self.source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn makeNode(kind: Kind, parent: NodeIndex) Node {
    return .{
        .hash = 0,
        .identity_hash = 0,
        .identity_range_hash = 0,
        .kind = kind,
        .depth = 0,
        .parent_idx = parent,
        .content_range = Range.empty,
        .identity_range = Range.empty,
        .is_exported = false,
    };
}

test "Tree.addNode preserves insertion order" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "test.json");
    defer tree.deinit();

    const kinds = [_]Kind{ .json_string, .json_number, .json_bool, .json_null, .json_array };
    for (kinds) |k| {
        _ = try tree.addNode(makeNode(k, ROOT_PARENT));
    }

    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);

    const stored: []Kind = tree.nodes.items(.kind);
    for (stored, kinds) |s, expected| {
        try std.testing.expectEqual(expected, s);
    }
}

test "post-order layout: root last, children before parent" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "");
    defer tree.deinit();

    // Topology: root has 2 children (A, B); A has 1 child (G).
    // Post-order push: G(0), A(1), B(2), root(3)
    const g_idx = try tree.addNode(makeNode(.json_string, 1));
    const a_idx = try tree.addNode(makeNode(.json_array, 3));
    const b_idx = try tree.addNode(makeNode(.json_string, 3));
    const root_idx = try tree.addNode(makeNode(.file_root, ROOT_PARENT));

    try std.testing.expectEqual(@as(NodeIndex, 0), g_idx);
    try std.testing.expectEqual(@as(NodeIndex, 1), a_idx);
    try std.testing.expectEqual(@as(NodeIndex, 2), b_idx);
    try std.testing.expectEqual(@as(NodeIndex, 3), root_idx);

    const parents = tree.nodes.items(.parent_idx);
    try std.testing.expectEqual(@as(NodeIndex, 1), parents[g_idx]);
    try std.testing.expectEqual(@as(NodeIndex, 3), parents[a_idx]);
    try std.testing.expectEqual(@as(NodeIndex, 3), parents[b_idx]);
    try std.testing.expectEqual(ROOT_PARENT, parents[root_idx]);
}

test "childrenOf returns direct children only" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "");
    defer tree.deinit();

    // Same topology as above: G(0) -> A(1); A(1), B(2) -> root(3).
    _ = try tree.addNode(makeNode(.json_string, 1));
    _ = try tree.addNode(makeNode(.json_array, 3));
    _ = try tree.addNode(makeNode(.json_string, 3));
    _ = try tree.addNode(makeNode(.file_root, ROOT_PARENT));

    var buf: std.ArrayList(NodeIndex) = .empty;
    defer buf.deinit(gpa);

    try tree.childrenOf(gpa, 3, &buf);
    try std.testing.expectEqual(@as(usize, 2), buf.items.len);
    try std.testing.expectEqual(@as(NodeIndex, 1), buf.items[0]);
    try std.testing.expectEqual(@as(NodeIndex, 2), buf.items[1]);

    buf.clearRetainingCapacity();
    try tree.childrenOf(gpa, 1, &buf);
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(NodeIndex, 0), buf.items[0]);

    buf.clearRetainingCapacity();
    try tree.childrenOf(gpa, 0, &buf);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "contentSlice and identitySlice return correct bytes" {
    const gpa = std.testing.allocator;
    const src = "{\"k\":1}";
    var tree = Tree.init(gpa, src, "test.json");
    defer tree.deinit();

    // member = `"k":1` spans bytes 1..6; identity = `k` spans bytes 2..3.
    var member = makeNode(.json_member, ROOT_PARENT);
    member.content_range = .{ .start = 1, .end = 6 };
    member.identity_range = .{ .start = 2, .end = 3 };
    const idx = try tree.addNode(member);

    try std.testing.expectEqualStrings("\"k\":1", tree.contentSlice(idx));
    try std.testing.expectEqualStrings("k", tree.identitySlice(idx));
}

test "Tree.deinit releases arena (no leaks)" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "");
    for (0..16) |_| {
        _ = try tree.addNode(makeNode(.json_string, ROOT_PARENT));
    }
    tree.deinit();
    // testing.allocator catches the leak on test exit.
}

test "lineCol converts byte offset to 1-indexed line and column" {
    const gpa = std.testing.allocator;
    const src = "abc\ndefg\nhi";
    var tree = Tree.init(gpa, src, "");
    defer tree.deinit();

    // Three nodes pointing at offsets 0, 4 (start of "defg"), 9 (start of "hi").
    var n = makeNode(.json_string, ROOT_PARENT);
    n.content_range = .{ .start = 0, .end = 1 };
    _ = try tree.addNode(n);
    n.content_range = .{ .start = 4, .end = 5 };
    _ = try tree.addNode(n);
    n.content_range = .{ .start = 9, .end = 10 };
    _ = try tree.addNode(n);

    const lc0 = tree.lineCol(0);
    try std.testing.expectEqual(@as(u32, 1), lc0.line);
    try std.testing.expectEqual(@as(u32, 1), lc0.col);

    const lc1 = tree.lineCol(1);
    try std.testing.expectEqual(@as(u32, 2), lc1.line);
    try std.testing.expectEqual(@as(u32, 1), lc1.col);

    const lc2 = tree.lineCol(2);
    try std.testing.expectEqual(@as(u32, 3), lc2.line);
    try std.testing.expectEqual(@as(u32, 1), lc2.col);
}

test "MultiArrayList SoA layout: hash column is []u64" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "");
    defer tree.deinit();

    var n = makeNode(.file_root, ROOT_PARENT);
    n.hash = 0xDEADBEEFCAFEBABE;
    _ = try tree.addNode(n);

    // Explicit type annotation: compile error if items(.hash) is not []u64.
    const hashes: []u64 = tree.nodes.items(.hash);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), hashes[0]);
}

test "Node carries identity_range_hash and is_exported columns" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "");
    defer tree.deinit();

    var n = makeNode(.go_fn, ROOT_PARENT);
    n.identity_range_hash = 0xCAFEF00DCAFEF00D;
    n.is_exported = true;
    _ = try tree.addNode(n);

    const irhs: []u64 = tree.nodes.items(.identity_range_hash);
    const exps: []bool = tree.nodes.items(.is_exported);
    try std.testing.expectEqual(@as(u64, 0xCAFEF00DCAFEF00D), irhs[0]);
    try std.testing.expectEqual(true, exps[0]);
}
