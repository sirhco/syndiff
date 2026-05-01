//! Hashing primitives for SynDiff.
//!
//! Two distinct hashes per Node:
//!   - `identity_hash` — semantic identity (kind + parent identity + identity bytes).
//!     Drives O(1) cross-file MOVED/MODIFIED detection via std.AutoHashMap.
//!   - `hash` (subtree) — full content (kind + recursive child hashes + leaf bytes).
//!     Detects MODIFIED when identity matches but subtree differs.
//!
//! Both use std.hash.Wyhash: matches std.AutoHashMap default, fast on short keys,
//! std-lib only.

const std = @import("std");
const ast = @import("ast.zig");

const SEED: u64 = 0;

/// Compose semantic identity. Parent identity is folded in so the same key
/// under different parents (`user.name` vs `org.name`) yields distinct hashes.
pub fn identityHash(parent_identity: u64, kind: ast.Kind, identity_bytes: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(SEED);
    hasher.update(std.mem.asBytes(&parent_identity));
    const k: u8 = @intFromEnum(kind);
    hasher.update(std.mem.asBytes(&k));
    hasher.update(identity_bytes);
    return hasher.final();
}

/// Compose subtree hash from this node's kind, all child subtree hashes (in
/// order), and any leaf bytes. Leaf bytes apply to primitives (numbers, strings,
/// bools, null literals); container nodes pass an empty slice.
pub fn subtreeHash(kind: ast.Kind, child_hashes: []const u64, leaf_bytes: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(SEED);
    const k: u8 = @intFromEnum(kind);
    hasher.update(std.mem.asBytes(&k));
    hasher.update(std.mem.sliceAsBytes(child_hashes));
    hasher.update(leaf_bytes);
    return hasher.final();
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "identityHash differs for same key under different parents" {
    const a = identityHash(0xAAAA_AAAA_AAAA_AAAA, .json_member, "name");
    const b = identityHash(0xBBBB_BBBB_BBBB_BBBB, .json_member, "name");
    try std.testing.expect(a != b);
}

test "identityHash deterministic" {
    const a = identityHash(0x1234_5678, .json_member, "key");
    const b = identityHash(0x1234_5678, .json_member, "key");
    try std.testing.expectEqual(a, b);
}

test "identityHash kind-sensitive" {
    const a = identityHash(0, .json_string, "x");
    const b = identityHash(0, .json_number, "x");
    try std.testing.expect(a != b);
}

test "subtreeHash equal for identical subtrees" {
    const children = [_]u64{ 0x1111, 0x2222, 0x3333 };
    const a = subtreeHash(.json_object, &children, "");
    const b = subtreeHash(.json_object, &children, "");
    try std.testing.expectEqual(a, b);
}

test "subtreeHash differs when leaf bytes change" {
    const a = subtreeHash(.json_number, &.{}, "42");
    const b = subtreeHash(.json_number, &.{}, "43");
    try std.testing.expect(a != b);
}

test "subtreeHash differs when child order changes" {
    const ab = [_]u64{ 0x1111, 0x2222 };
    const ba = [_]u64{ 0x2222, 0x1111 };
    const h1 = subtreeHash(.json_array, &ab, "");
    const h2 = subtreeHash(.json_array, &ba, "");
    try std.testing.expect(h1 != h2);
}
