//! Synthetic-tree unit tests for identity-hash collision counting.
//! Uses hand-crafted `ast.Tree` nodes so no parser is needed.

const std = @import("std");
const ast = @import("syndiff").ast;
const differ = @import("syndiff").differ;

/// 1 KiB of filler bytes so synthetic node ranges always have valid source
/// to slice when downstream passes (e.g. `annotateScope`) read the source.
const FILLER_SOURCE = "x" ** 1024;

/// Build a minimal tree: a `file_root` root node plus `n` child nodes,
/// all sharing `identity_hash = forced_id`.
fn treeWithCollisions(
    gpa: std.mem.Allocator,
    n: u32,
    forced_id: u64,
) !ast.Tree {
    var tree = ast.Tree.init(gpa, FILLER_SOURCE, "test.go");
    // Root node — unique hash so it never collides with the children.
    _ = try tree.addNode(.{
        .hash = 0,
        .identity_hash = 0xDEAD_BEEF_DEAD_BEEF,
        .identity_range_hash = 0,
        .kind = .file_root,
        .depth = 0,
        .parent_idx = ast.ROOT_PARENT,
        .content_range = .{ .start = 0, .end = 0 },
        .identity_range = .{ .start = 0, .end = 0 },
        .is_exported = false,
    });
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try tree.addNode(.{
            .hash = i,                  // distinct content hashes
            .identity_hash = forced_id, // ALL share the same identity_hash → collisions
            .identity_range_hash = 0,
            .kind = .go_fn,
            .depth = 1,
            .parent_idx = 0,
            .content_range = .{ .start = i * 10, .end = i * 10 + 5 },
            .identity_range = .{ .start = i * 10, .end = i * 10 + 5 },
            .is_exported = false,
        });
    }
    return tree;
}

test "two nodes with identical identity_hash: hash_collisions == 1" {
    const gpa = std.testing.allocator;

    var a = try treeWithCollisions(gpa, 2, 0xCAFE_BABE_CAFE_BABE);
    defer a.deinit();
    var b = try treeWithCollisions(gpa, 0, 0xCAFE_BABE_CAFE_BABE);
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // One collision in tree A (node 1 clobbers node 0's slot — first-write-wins).
    try std.testing.expectEqual(@as(u32, 1), set.hash_collisions);
}

test "no collisions in normal tree: hash_collisions == 0" {
    const gpa = std.testing.allocator;

    // Two nodes, each with a unique identity_hash.
    var a = ast.Tree.init(gpa, "", "test.go");
    defer a.deinit();
    _ = try a.addNode(.{
        .hash = 1, .identity_hash = 0x0000_0001,
        .identity_range_hash = 0, .kind = .go_fn, .depth = 1,
        .parent_idx = ast.ROOT_PARENT,
        .content_range = .{ .start = 0, .end = 5 },
        .identity_range = .{ .start = 0, .end = 5 },
        .is_exported = false,
    });
    _ = try a.addNode(.{
        .hash = 2, .identity_hash = 0x0000_0002,
        .identity_range_hash = 0, .kind = .go_fn, .depth = 1,
        .parent_idx = ast.ROOT_PARENT,
        .content_range = .{ .start = 10, .end = 15 },
        .identity_range = .{ .start = 10, .end = 15 },
        .is_exported = false,
    });

    var b = ast.Tree.init(gpa, "", "test.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 0), set.hash_collisions);
}

test "three nodes same hash: hash_collisions == 2" {
    const gpa = std.testing.allocator;

    var a = try treeWithCollisions(gpa, 3, 0x1111_2222_3333_4444);
    defer a.deinit();
    var b = try treeWithCollisions(gpa, 0, 0x1111_2222_3333_4444);
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // Nodes 1 and 2 both collide with node 0's slot → 2 collisions.
    try std.testing.expectEqual(@as(u32, 2), set.hash_collisions);
}

test "collisions on both sides are summed" {
    const gpa = std.testing.allocator;

    var a = try treeWithCollisions(gpa, 2, 0xAAAA_BBBB_CCCC_DDDD);
    defer a.deinit();
    var b = try treeWithCollisions(gpa, 2, 0xAAAA_BBBB_CCCC_DDDD);
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // 1 collision in A + 1 collision in B = 2 total.
    try std.testing.expectEqual(@as(u32, 2), set.hash_collisions);
}

test "review pipeline emits hash_collisions in summary" {
    const gpa = std.testing.allocator;
    const review = @import("syndiff").review;

    // Build two trees: A has a 2-node collision; B is empty.
    var a = try treeWithCollisions(gpa, 2, 0xFEED_FACE_FEED_FACE);
    defer a.deinit();
    var b = ast.Tree.init(gpa, FILLER_SOURCE, "test.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try review.renderReviewJson(gpa, &set, &a, &b, &aw.writer);

    const out = aw.writer.buffered();
    // The summary line must contain "hash_collisions":1
    const has_field = std.mem.indexOf(u8, out, "\"hash_collisions\":1") != null;
    try std.testing.expect(has_field);
}
