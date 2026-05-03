//! Minimal symbol table for callsite discovery.
//!
//! Used by review-mode enrichment to surface a list of `(path, line)` for
//! each `signature_change` record — i.e. "where do callers of this symbol
//! live?". Walks `*_stmt` nodes in a tree and scans their content slices
//! for whole-word occurrences of the symbol name. No scope-aware
//! resolution; false positives are tolerated.

const std = @import("std");
const ast = @import("ast.zig");

pub const Callsite = struct {
    path: []const u8,
    line: u32,
};

/// Scan all `*_stmt` content slices in `tree` for occurrences of `name` as
/// a word (i.e. surrounded by non-identifier characters). Append one
/// `Callsite` per matching statement.
///
/// `Callsite.path` borrows from `tree.path` — caller must NOT free those
/// strings; they live as long as the `tree` does.
pub fn findCallsites(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    name: []const u8,
    out: *std.ArrayList(Callsite),
) !void {
    if (name.len == 0) return;
    const kinds = tree.nodes.items(.kind);
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const k = kinds[i];
        const is_stmt = k == .rust_stmt or k == .go_stmt or k == .zig_stmt or
            k == .dart_stmt or k == .js_stmt or k == .ts_stmt;
        if (!is_stmt) continue;
        const slice = tree.contentSlice(i);
        if (containsWord(slice, name)) {
            const lc = tree.lineCol(i);
            try out.append(gpa, .{ .path = tree.path, .line = lc.line });
        }
    }
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + needle.len], needle)) continue;
        const left_ok = i == 0 or !isIdent(haystack[i - 1]);
        const right_ok = i + needle.len == haystack.len or !isIdent(haystack[i + needle.len]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const go_parser = @import("go_parser.zig");

test "findCallsites: finds Add() inside another fn body" {
    const gpa = std.testing.allocator;
    var tree = try go_parser.parse(
        gpa,
        "package main\nfunc Add(a, b int) int { return a + b }\nfunc Run() { x := Add(1,2); _ = x }\n",
        "x.go",
    );
    defer tree.deinit();

    var sites: std.ArrayList(Callsite) = .empty;
    defer sites.deinit(gpa);
    try findCallsites(gpa, &tree, "Add", &sites);
    try std.testing.expect(sites.items.len >= 1);
}

test "containsWord respects identifier boundaries" {
    try std.testing.expect(containsWord("Add(1,2)", "Add"));
    try std.testing.expect(containsWord(" Add(", "Add"));
    try std.testing.expect(containsWord("x = Add", "Add"));
    try std.testing.expect(!containsWord("Adder()", "Add"));
    try std.testing.expect(!containsWord("preAdd()", "Add"));
    try std.testing.expect(!containsWord("Add_x", "Add"));
    try std.testing.expect(!containsWord("", "Add"));
}
