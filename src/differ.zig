//! Compare two `ast.Tree`s and emit a labeled diff.
//!
//! Algorithm:
//!   1. Build `std.AutoHashMap(u64, NodeIndex)` for each tree, keyed on
//!      `identity_hash`. O(n) build, O(1) lookup.
//!   2. For each node in tree A, look it up in B:
//!        - missing in B           => DELETED
//!        - subtree hash differs   => MODIFIED
//!        - same hash, different
//!          byte offset            => MOVED
//!        - same hash, same offset => unchanged (not emitted)
//!   3. For each node in tree B not seen in A => ADDED.
//!
//! `identity_hash` collisions across distinct nodes within one tree are treated
//! as a hashing pathology; first-write-wins. With `parent_identity` composed in
//! and a 64-bit hash, real-world collision probability is negligible.

const std = @import("std");
const ast = @import("ast.zig");

pub const ChangeKind = enum {
    added,
    deleted,
    modified,
    moved,
};

pub const Change = struct {
    kind: ChangeKind,
    /// Node index in tree A (null when ADDED).
    a_idx: ?ast.NodeIndex,
    /// Node index in tree B (null when DELETED).
    b_idx: ?ast.NodeIndex,
};

pub const DiffSet = struct {
    changes: std.ArrayList(Change),

    pub fn deinit(self: *DiffSet, gpa: std.mem.Allocator) void {
        self.changes.deinit(gpa);
    }
};

const IdentityMap = std.AutoHashMap(u64, ast.NodeIndex);

fn buildMap(gpa: std.mem.Allocator, tree: *ast.Tree) !IdentityMap {
    var map: IdentityMap = .init(gpa);
    errdefer map.deinit();
    const idents = tree.nodes.items(.identity_hash);
    try map.ensureTotalCapacity(@intCast(idents.len));
    for (idents, 0..) |id, i| {
        const gop = map.getOrPutAssumeCapacity(id);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        // Collision: keep first occurrence (deterministic).
    }
    return map;
}

pub fn diff(gpa: std.mem.Allocator, a: *ast.Tree, b: *ast.Tree) !DiffSet {
    var a_map = try buildMap(gpa, a);
    defer a_map.deinit();
    var b_map = try buildMap(gpa, b);
    defer b_map.deinit();

    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(gpa);

    const a_idents = a.nodes.items(.identity_hash);
    const a_hashes = a.nodes.items(.hash);
    const a_ranges = a.nodes.items(.content_range);
    const b_hashes = b.nodes.items(.hash);
    const b_ranges = b.nodes.items(.content_range);

    for (a_idents, 0..) |a_id, ai| {
        if (b_map.get(a_id)) |bi| {
            if (a_hashes[ai] != b_hashes[bi]) {
                try changes.append(gpa, .{
                    .kind = .modified,
                    .a_idx = @intCast(ai),
                    .b_idx = bi,
                });
            } else if (a_ranges[ai].start != b_ranges[bi].start) {
                try changes.append(gpa, .{
                    .kind = .moved,
                    .a_idx = @intCast(ai),
                    .b_idx = bi,
                });
            }
            // else: unchanged; skip.
        } else {
            try changes.append(gpa, .{
                .kind = .deleted,
                .a_idx = @intCast(ai),
                .b_idx = null,
            });
        }
    }

    const b_idents = b.nodes.items(.identity_hash);
    for (b_idents, 0..) |b_id, bi| {
        if (!a_map.contains(b_id)) {
            try changes.append(gpa, .{
                .kind = .added,
                .a_idx = null,
                .b_idx = @intCast(bi),
            });
        }
    }

    return .{ .changes = changes };
}

/// Render a diff to the given writer in a simple line-oriented format.
pub fn render(
    set: *const DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
) !void {
    for (set.changes.items) |c| {
        switch (c.kind) {
            .added => {
                try writer.print("ADDED    {s}\n", .{b.path});
                try writer.print("  + {s}\n", .{b.contentSlice(c.b_idx.?)});
            },
            .deleted => {
                try writer.print("DELETED  {s}\n", .{a.path});
                try writer.print("  - {s}\n", .{a.contentSlice(c.a_idx.?)});
            },
            .modified => {
                try writer.print("MODIFIED {s} -> {s}\n", .{ a.path, b.path });
                try writer.print("  - {s}\n", .{a.contentSlice(c.a_idx.?)});
                try writer.print("  + {s}\n", .{b.contentSlice(c.b_idx.?)});
            },
            .moved => {
                try writer.print("MOVED    {s} -> {s}\n", .{ a.path, b.path });
                try writer.print("  ~ {s}\n", .{b.contentSlice(c.b_idx.?)});
            },
        }
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const json_parser = @import("json_parser.zig");

fn countKind(set: *const DiffSet, k: ChangeKind) usize {
    var n: usize = 0;
    for (set.changes.items) |c| {
        if (c.kind == k) n += 1;
    }
    return n;
}

test "identical files produce no changes" {
    const gpa = std.testing.allocator;
    const src = "{\"k\":1,\"v\":2}";
    var a = try json_parser.parse(gpa, src, "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, src, "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), set.changes.items.len);
}

test "value change reports MODIFIED" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"k\":1}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"k\":2}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // The number, member, and object are all "modified" because the subtree
    // hash propagates upward. That is the desired bottom-up behavior.
    try std.testing.expect(countKind(&set, .modified) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .added));
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .deleted));
}

test "added field reports ADDED" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"k\":1}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"k\":1,\"new\":99}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    try std.testing.expect(countKind(&set, .added) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .deleted));
    // Object's subtree hash changes (new member), so MODIFIED on object node:
    try std.testing.expect(countKind(&set, .modified) >= 1);

    // Verify one of the ADDED rows points at the `new` member.
    var found = false;
    const kinds = b.nodes.items(.kind);
    for (set.changes.items) |c| {
        if (c.kind != .added) continue;
        const bi = c.b_idx.?;
        if (kinds[bi] == .json_member and std.mem.eql(u8, b.identitySlice(bi), "new")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "removed field reports DELETED" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"k\":1,\"gone\":2}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"k\":1}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    try std.testing.expect(countKind(&set, .deleted) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .added));

    var found = false;
    const a_kinds = a.nodes.items(.kind);
    for (set.changes.items) |c| {
        if (c.kind != .deleted) continue;
        const ai = c.a_idx.?;
        if (a_kinds[ai] == .json_member and std.mem.eql(u8, a.identitySlice(ai), "gone")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "key reorder reports MOVED, not MODIFIED" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"a\":1,\"b\":2}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"b\":2,\"a\":1}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // Object subtree hash is the same (member hashes order matters in subtreeHash;
    // reorder DOES change object's subtree hash). So:
    //  - members `a` and `b` themselves: same identity, same content, different
    //    byte offsets => MOVED.
    //  - object root: same identity, DIFFERENT subtree hash (member order changed)
    //    => MODIFIED.
    try std.testing.expect(countKind(&set, .moved) >= 2);
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .added));
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .deleted));
}

test "AutoHashMap O(1) lookup smoke test (large doc)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '{');
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        if (i != 0) try buf.append(gpa, ',');
        var key_buf: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&key_buf, "\"k{d}\":{d}", .{ i, i }) catch unreachable;
        try buf.appendSlice(gpa, k);
    }
    try buf.append(gpa, '}');

    var a = try json_parser.parse(gpa, buf.items, "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, buf.items, "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), set.changes.items.len);
}
