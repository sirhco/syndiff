//! Maps source paths to expected test paths per language convention.
//!
//! Used by the multi-file driver to emit `test_not_updated` records when a
//! source file changes but its conventional test sibling does not.
//!
//! Conventions:
//!   Go:    `foo.go`            -> `foo_test.go`
//!   JS/TS: `foo.ts`            -> `foo.test.ts`, `foo.spec.ts`
//!   Dart:  `lib/foo.dart`      -> `test/foo_test.dart`
//!   Rust:  inline `#[cfg(test)]` — skipped here.

const std = @import("std");

/// Returns up to 3 candidate test paths for a given source path. Each entry
/// is an owned `[]const u8` allocated via `gpa`. The outer slice is also
/// owned by the caller. Caller MUST free both:
///   for (out) |o| if (o) |s| gpa.free(s);
///   gpa.free(out);
///
/// For unsupported extensions, returns an owned empty slice.
pub fn expectedTestPath(gpa: std.mem.Allocator, src: []const u8) ![]const ?[]const u8 {
    if (std.mem.endsWith(u8, src, ".go")) {
        const stem = src[0 .. src.len - ".go".len];
        const path = try std.fmt.allocPrint(gpa, "{s}_test.go", .{stem});
        return try makeList(gpa, &.{@as(?[]const u8, path)});
    }
    if (std.mem.endsWith(u8, src, ".ts") or std.mem.endsWith(u8, src, ".js") or
        std.mem.endsWith(u8, src, ".tsx") or std.mem.endsWith(u8, src, ".mjs"))
    {
        const dot = std.mem.lastIndexOfScalar(u8, src, '.').?;
        const stem = src[0..dot];
        const ext = src[dot..];
        const test_path = try std.fmt.allocPrint(gpa, "{s}.test{s}", .{ stem, ext });
        const spec_path = try std.fmt.allocPrint(gpa, "{s}.spec{s}", .{ stem, ext });
        return try makeList(gpa, &.{
            @as(?[]const u8, test_path),
            @as(?[]const u8, spec_path),
        });
    }
    if (std.mem.endsWith(u8, src, ".dart")) {
        // lib/foo.dart -> test/foo_test.dart
        if (std.mem.startsWith(u8, src, "lib/")) {
            const stem = src["lib/".len .. src.len - ".dart".len];
            const path = try std.fmt.allocPrint(gpa, "test/{s}_test.dart", .{stem});
            return try makeList(gpa, &.{@as(?[]const u8, path)});
        }
    }
    return try makeList(gpa, &.{});
}

fn makeList(gpa: std.mem.Allocator, items: []const ?[]const u8) ![]const ?[]const u8 {
    return try gpa.dupe(?[]const u8, items);
}

/// Heuristic: a path is a "test" path if it matches one of the common
/// conventions across supported languages. False positives are tolerated.
pub fn isTestPath(p: []const u8) bool {
    return std.mem.indexOf(u8, p, "_test.") != null or
        std.mem.indexOf(u8, p, ".test.") != null or
        std.mem.indexOf(u8, p, ".spec.") != null or
        std.mem.startsWith(u8, p, "test/") or
        std.mem.indexOf(u8, p, "/__tests__/") != null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "Go test pairing" {
    const gpa = std.testing.allocator;
    const out = try expectedTestPath(gpa, "src/auth.go");
    defer {
        for (out) |o| if (o) |s| gpa.free(s);
        gpa.free(out);
    }
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("src/auth_test.go", out[0].?);
}

test "TS test pairing" {
    const gpa = std.testing.allocator;
    const out = try expectedTestPath(gpa, "src/foo.ts");
    defer {
        for (out) |o| if (o) |s| gpa.free(s);
        gpa.free(out);
    }
    try std.testing.expect(out.len >= 1);
    try std.testing.expectEqualStrings("src/foo.test.ts", out[0].?);
    try std.testing.expectEqualStrings("src/foo.spec.ts", out[1].?);
}

test "isTestPath" {
    try std.testing.expect(isTestPath("foo_test.go"));
    try std.testing.expect(isTestPath("a/b/foo.test.ts"));
    try std.testing.expect(isTestPath("a/b/foo.spec.js"));
    try std.testing.expect(isTestPath("test/foo.dart"));
    try std.testing.expect(isTestPath("src/__tests__/foo.ts"));
    try std.testing.expect(!isTestPath("foo.go"));
    try std.testing.expect(!isTestPath("src/foo.ts"));
}
