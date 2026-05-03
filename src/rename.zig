//! Pairs (deleted, added) Change pairs into a single `.renamed` row.
//!
//! Rules: same parent scope + (Signature.hash match OR subtree hash match).
//! Mutates the DiffSet in place.
//!
//! Note: `Signature.hash` (per `signature.zig`) folds the function name into
//! the hash, so a pure rename (same params/return/visibility) won't satisfy
//! `sa.hash == sb.hash`. The `sig_match` branch instead compares the
//! structural fields (params, return type, visibility) directly while
//! ignoring the name — which is exactly what a rename is.

const std = @import("std");
const ast = @import("ast.zig");
const differ = @import("differ.zig");
const signature = @import("signature.zig");

pub fn pairRenames(
    gpa: std.mem.Allocator,
    set: *differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
) !void {
    const parents_a = a.nodes.items(.parent_idx);
    const parents_b = b.nodes.items(.parent_idx);
    const a_id = a.nodes.items(.identity_hash);
    const b_id = b.nodes.items(.identity_hash);
    const a_hash = a.nodes.items(.hash);
    const b_hash = b.nodes.items(.hash);

    var to_drop: std.AutoHashMap(usize, void) = .init(gpa);
    defer to_drop.deinit();

    for (set.changes.items, 0..) |ca, i| {
        if (ca.kind != .deleted) continue;
        if (to_drop.contains(i)) continue;
        const ai = ca.a_idx.?;
        const a_parent_id = if (parents_a[ai] == ast.ROOT_PARENT) 0 else a_id[parents_a[ai]];

        for (set.changes.items, 0..) |cb, j| {
            if (i == j) continue;
            if (cb.kind != .added) continue;
            if (to_drop.contains(j)) continue;
            const bi = cb.b_idx.?;
            const b_parent_id = if (parents_b[bi] == ast.ROOT_PARENT) 0 else b_id[parents_b[bi]];
            if (a_parent_id != b_parent_id) continue;

            const subtree_match = a_hash[ai] == b_hash[bi];
            const sig_match = blk: {
                const sa_opt = try signature.extract(gpa, a, ai);
                if (sa_opt == null) break :blk false;
                const sa = sa_opt.?;
                defer gpa.free(sa.params);

                const sb_opt = try signature.extract(gpa, b, bi);
                if (sb_opt == null) break :blk false;
                const sb = sb_opt.?;
                defer gpa.free(sb.params);

                // Compare structurally, ignoring name (which is exactly the
                // thing a rename changes). `Signature.hash` folds the name
                // into the hash, so we cannot use it directly.
                if (sa.params.len != sb.params.len) break :blk false;
                for (sa.params, sb.params) |pa, pb| {
                    if (!std.mem.eql(u8, pa.type_str, pb.type_str)) break :blk false;
                }
                const ra: []const u8 = sa.return_type orelse "";
                const rb: []const u8 = sb.return_type orelse "";
                if (!std.mem.eql(u8, ra, rb)) break :blk false;
                if (sa.visibility != sb.visibility) break :blk false;
                break :blk true;
            };
            if (!subtree_match and !sig_match) continue;

            // Convert `i` to renamed; drop `j`.
            set.changes.items[i] = .{ .kind = .renamed, .a_idx = ai, .b_idx = bi };
            try to_drop.put(j, {});
            break;
        }
    }

    // Compact.
    var w: usize = 0;
    for (set.changes.items, 0..) |c, idx| {
        if (to_drop.contains(idx)) continue;
        set.changes.items[w] = c;
        w += 1;
    }
    set.changes.shrinkRetainingCapacity(w);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const go_parser = @import("go_parser.zig");

test "pairRenames: same body, new name -> renamed" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc OldName() { x := 1; _ = x }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc NewName() { x := 1; _ = x }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    var added_before: u32 = 0;
    var deleted_before: u32 = 0;
    for (set.changes.items) |c| {
        if (c.kind == .added) added_before += 1;
        if (c.kind == .deleted) deleted_before += 1;
    }
    try std.testing.expect(added_before >= 1 and deleted_before >= 1);

    try pairRenames(gpa, &set, &a, &b);

    var renamed: u32 = 0;
    for (set.changes.items) |c| if (c.kind == .renamed) {
        renamed += 1;
    };
    try std.testing.expect(renamed >= 1);
}
