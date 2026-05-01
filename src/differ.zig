//! Step 3 placeholder. Compares two `ast.Tree`s and emits a diff.
//!
//! Will key on `identity_hash` via `std.AutoHashMap(u64, ast.NodeIndex)` for
//! O(1) cross-file lookup. Output labels: MOVED, MODIFIED, ADDED, DELETED.

const std = @import("std");
const ast = @import("ast.zig");

pub const ChangeKind = enum {
    added,
    deleted,
    modified,
    moved,
};

pub const DiffError = error{
    NotImplemented,
};

pub fn diff(a: *ast.Tree, b: *ast.Tree) DiffError!void {
    _ = a;
    _ = b;
    return error.NotImplemented;
}
