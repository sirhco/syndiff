//! Per-parse anchor table for YAML `&name` definitions.
//!
//! When the parser encounters `&name <node>`, it records the resulting node's
//! identity_hash + subtree_hash + content_range under `name`. When it later
//! encounters `*name`, it copies those values into the alias node so the
//! differ projects both occurrences to the same identity — guaranteeing one
//! MODIFIED record on the anchor when the content changes, not two.
//!
//! Lifetime: one Table per `parse(...)` call, freed on parser exit. Anchor
//! names live as borrowed slices into the source buffer (zero-copy).

const std = @import("std");
const ast = @import("ast.zig");

pub const AnchorEntry = struct {
    /// identity_hash of the anchor's target node (the node that follows `&name`).
    identity_hash: u64,
    /// subtree_hash of the anchor's target node — copied into the alias so
    /// the alias and the original hash-match exactly.
    subtree_hash: u64,
    /// Byte range of the anchor target's content in the source buffer.
    /// Aliases reuse this for `content_range` so any byte-range tooling
    /// downstream (e.g. line_diff overlays) sees the original location.
    content_range: ast.Range,
    /// Kind of the anchor target. Aliases inherit this so the differ
    /// pairs them at the same Kind level.
    kind: ast.Kind,
};

pub const Table = struct {
    map: std.StringHashMap(AnchorEntry),

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{ .map = std.StringHashMap(AnchorEntry).init(gpa) };
    }

    pub fn deinit(self: *Table) void {
        self.map.deinit();
    }

    /// Insert or overwrite. YAML allows redefining an anchor name; the most
    /// recent definition wins (matches PyYAML / libyaml behavior).
    pub fn put(self: *Table, name: []const u8, entry: AnchorEntry) !void {
        try self.map.put(name, entry);
    }

    pub fn get(self: *const Table, name: []const u8) ?AnchorEntry {
        return self.map.get(name);
    }
};

test "Table.put then get round-trips" {
    const gpa = std.testing.allocator;
    var t = Table.init(gpa);
    defer t.deinit();
    try t.put("base", .{
        .identity_hash = 0xDEAD_BEEF,
        .subtree_hash = 0xCAFE_F00D,
        .content_range = .{ .start = 10, .end = 20 },
        .kind = .yaml_mapping,
    });
    const got = t.get("base") orelse return error.AnchorMissing;
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF), got.identity_hash);
    try std.testing.expectEqual(@as(u64, 0xCAFE_F00D), got.subtree_hash);
    try std.testing.expectEqual(@as(u32, 10), got.content_range.start);
    try std.testing.expectEqual(@as(u32, 20), got.content_range.end);
    try std.testing.expectEqual(ast.Kind.yaml_mapping, got.kind);
}

test "Table.put overrides earlier definition for same name" {
    const gpa = std.testing.allocator;
    var t = Table.init(gpa);
    defer t.deinit();
    try t.put("x", .{
        .identity_hash = 1,
        .subtree_hash = 2,
        .content_range = .{ .start = 0, .end = 1 },
        .kind = .yaml_scalar,
    });
    try t.put("x", .{
        .identity_hash = 100,
        .subtree_hash = 200,
        .content_range = .{ .start = 5, .end = 6 },
        .kind = .yaml_scalar,
    });
    const got = t.get("x") orelse return error.AnchorMissing;
    try std.testing.expectEqual(@as(u64, 100), got.identity_hash);
    try std.testing.expectEqual(@as(u64, 200), got.subtree_hash);
}

test "Table.get returns null for unknown name" {
    const gpa = std.testing.allocator;
    var t = Table.init(gpa);
    defer t.deinit();
    try std.testing.expect(t.get("nope") == null);
}
