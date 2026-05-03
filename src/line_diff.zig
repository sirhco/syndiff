//! Line-level unified diff via classical LCS.
//!
//! Computes longest common subsequence between two line lists with an O(M*N)
//! DP table, then walks back to emit a `git diff`-style sequence of context,
//! delete, and add lines. Used by the differ's text renderer to give MODIFIED
//! decls a sub-statement view.
//!
//! For very large inputs the DP table size is bounded; callers fall back to a
//! whole-block render when `writeUnified` returns `false`.

const std = @import("std");
const syntax = @import("syntax.zig");

pub const Op = enum { same, del, add };

pub const Limit = struct {
    /// Skip line diff when (a_lines + b_lines) exceeds this. The DP table is
    /// O(M*N) bytes; cap protects against pathological pasted content.
    max_total_lines: usize = 4000,
};

pub const default_limit: Limit = .{};

const OpEntry = struct { op: Op, line: []const u8 };

fn splitLines(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try out.append(gpa, text[line_start..i]);
            line_start = i + 1;
        }
    }
    if (line_start <= text.len) try out.append(gpa, text[line_start..]);
}

/// Emit unified-diff lines for `a` vs `b`. `prefix` is prepended to each
/// emitted line (e.g. "  " for context indent). Each line is then marked with
/// `-`, `+`, or space, then content syntax-highlighted.
///
/// Returns `false` when the input exceeds the limit; caller should fall back.
pub fn writeUnified(
    gpa: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    writer: *std.Io.Writer,
    lang: syntax.Lang,
    theme: syntax.Theme,
    limit: Limit,
) !bool {
    var a_lines: std.ArrayList([]const u8) = .empty;
    defer a_lines.deinit(gpa);
    var b_lines: std.ArrayList([]const u8) = .empty;
    defer b_lines.deinit(gpa);

    try splitLines(gpa, a, &a_lines);
    try splitLines(gpa, b, &b_lines);

    const m: usize = a_lines.items.len;
    const n: usize = b_lines.items.len;
    if (m + n > limit.max_total_lines) return false;

    // DP table.
    const stride: usize = n + 1;
    const dp = try gpa.alloc(u32, (m + 1) * stride);
    defer gpa.free(dp);
    @memset(dp, 0);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, a_lines.items[i - 1], b_lines.items[j - 1])) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                const up = dp[(i - 1) * stride + j];
                const left = dp[i * stride + (j - 1)];
                dp[i * stride + j] = if (up >= left) up else left;
            }
        }
    }

    // Backtrack to build reversed ops.
    var ops: std.ArrayList(OpEntry) = .empty;
    defer ops.deinit(gpa);

    i = m;
    var j: usize = n;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, a_lines.items[i - 1], b_lines.items[j - 1])) {
            try ops.append(gpa, .{ .op = .same, .line = a_lines.items[i - 1] });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j])) {
            try ops.append(gpa, .{ .op = .add, .line = b_lines.items[j - 1] });
            j -= 1;
        } else {
            try ops.append(gpa, .{ .op = .del, .line = a_lines.items[i - 1] });
            i -= 1;
        }
    }

    std.mem.reverse(OpEntry, ops.items);

    const c_minus = if (theme.enabled) "\x1b[31m" else "";
    const c_plus = if (theme.enabled) "\x1b[32m" else "";
    const reset = if (theme.enabled) "\x1b[0m" else "";

    for (ops.items) |e| {
        switch (e.op) {
            .same => {
                try writer.writeAll("    ");
                try syntax.writeHighlighted(lang, e.line, writer, theme);
                try writer.writeByte('\n');
            },
            .del => {
                try writer.print("{s}  - {s}", .{ c_minus, reset });
                try syntax.writeHighlighted(lang, e.line, writer, theme);
                try writer.writeByte('\n');
            },
            .add => {
                try writer.print("{s}  + {s}", .{ c_plus, reset });
                try syntax.writeHighlighted(lang, e.line, writer, theme);
                try writer.writeByte('\n');
            },
        }
    }
    return true;
}

pub const Counts = struct { added: u32, removed: u32 };

/// Same LCS as `writeUnified`, but only returns counts. Allocates the DP table
/// and frees it before returning. Returns `.{ .added = 0, .removed = 0 }` if
/// `a == b`. Capped at the same `max_total_lines` as `writeUnified` — if
/// exceeded, returns approximate counts based on raw line counts (each `a` line
/// reported as removed, each `b` line as added).
pub fn unifiedCounts(gpa: std.mem.Allocator, a: []const u8, b: []const u8) !Counts {
    if (std.mem.eql(u8, a, b)) return .{ .added = 0, .removed = 0 };

    var a_lines: std.ArrayList([]const u8) = .empty;
    defer a_lines.deinit(gpa);
    var b_lines: std.ArrayList([]const u8) = .empty;
    defer b_lines.deinit(gpa);

    try splitLines(gpa, a, &a_lines);
    try splitLines(gpa, b, &b_lines);

    const m = a_lines.items.len;
    const n = b_lines.items.len;
    if (m + n > default_limit.max_total_lines) {
        // Approximate: report each line as either fully added or removed.
        return .{ .added = @intCast(n), .removed = @intCast(m) };
    }

    const stride = n + 1;
    const dp = try gpa.alloc(u32, (m + 1) * stride);
    defer gpa.free(dp);
    @memset(dp, 0);
    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, a_lines.items[i - 1], b_lines.items[j - 1])) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                const up = dp[(i - 1) * stride + j];
                const left = dp[i * stride + (j - 1)];
                dp[i * stride + j] = if (up >= left) up else left;
            }
        }
    }
    const lcs = dp[m * stride + n];
    return .{ .added = @intCast(n - lcs), .removed = @intCast(m - lcs) };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn run(a: []const u8, b: []const u8, lang: syntax.Lang) ![]u8 {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try writeUnified(testing.allocator, a, b, &w, lang, syntax.off_theme, default_limit);
    return testing.allocator.dupe(u8, buf[0..w.end]);
}

test "single-line modification reduces to del+add" {
    const out = try run("foo", "bar", .none);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("  - foo\n  + bar\n", out);
}

test "shared lines are context, not flagged" {
    const out = try run("a\nb\nc\n", "a\nB\nc\n", .none);
    defer testing.allocator.free(out);
    // Expect: a context, -b, +B, c context, [trailing empty line context].
    try testing.expect(std.mem.indexOf(u8, out, "    a\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  - b\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  + B\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    c\n") != null);
}

test "pure additions" {
    const out = try run("", "x\ny\n", .none);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  + x\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  + y\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  - ") == null);
}

test "unifiedCounts returns LCS-based add/remove" {
    const gpa = std.testing.allocator;
    const c = try unifiedCounts(gpa, "a\nb\nc\n", "a\nB\nc\n");
    try std.testing.expectEqual(@as(u32, 1), c.added);
    try std.testing.expectEqual(@as(u32, 1), c.removed);
}

test "exceeds limit returns false" {
    var w: std.Io.Writer = .fixed(&[_]u8{});
    var huge: std.ArrayList(u8) = .empty;
    defer huge.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < 5000) : (i += 1) try huge.appendSlice(testing.allocator, "x\n");
    const ok = try writeUnified(testing.allocator, huge.items, huge.items, &w, .none, syntax.off_theme, .{ .max_total_lines = 100 });
    try testing.expect(!ok);
}
