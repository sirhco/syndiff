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
//! Post-processing pipeline (caller-driven):
//!   * `suppressCascade` drops ancestor-of-changed redundancies (e.g. parent
//!     MODIFIED only because child MODIFIED).
//!   * `sortByLocation` orders changes by source byte offset.
//!   * `filter` keeps only requested `ChangeKind`s.
//!
//! Renderers:
//!   * `render`     — human-readable text, optional ANSI color + per-language
//!                    syntax highlighting. With `RenderOptions.gpa` set,
//!                    multi-line MODIFIED bodies render via
//!                    `line_diff.writeUnified` for a sub-statement view.
//!   * `renderJson` — NDJSON (one event per line).
//!   * `renderYaml` — YAML sequence (one item per change).
//!
//! `identity_hash` collisions across distinct nodes within one tree are treated
//! as a hashing pathology; first-write-wins. With `parent_identity` composed in
//! and a 64-bit hash, real-world collision probability is negligible.

const std = @import("std");
const ast = @import("ast.zig");
const syntax = @import("syntax.zig");
const line_diff = @import("line_diff.zig");

pub const ChangeKind = enum {
    added,
    deleted,
    modified,
    moved,
    renamed,
};

pub const KindFilter = struct {
    added: bool = true,
    deleted: bool = true,
    modified: bool = true,
    moved: bool = true,
    renamed: bool = true,

    pub const all: KindFilter = .{};
    pub const none: KindFilter = .{
        .added = false,
        .deleted = false,
        .modified = false,
        .moved = false,
        .renamed = false,
    };

    pub fn allows(self: KindFilter, k: ChangeKind) bool {
        return switch (k) {
            .added => self.added,
            .deleted => self.deleted,
            .modified => self.modified,
            .moved => self.moved,
            .renamed => self.renamed,
        };
    }
};

pub fn filter(set: *DiffSet, f: KindFilter) void {
    var w: usize = 0;
    for (set.changes.items) |c| {
        if (f.allows(c.kind)) {
            set.changes.items[w] = c;
            w += 1;
        }
    }
    set.changes.shrinkRetainingCapacity(w);
}

pub const RenderOptions = struct {
    theme: syntax.Theme = syntax.off_theme,
    lang: syntax.Lang = .none,
    /// When set, MODIFIED bodies render via `line_diff.writeUnified` for a
    /// statement-level view. Without this the renderer falls back to whole
    /// `- old / + new` blocks.
    gpa: ?std.mem.Allocator = null,
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
    /// Total identity-hash collisions across both trees (A + B).
    /// Collisions are counted when two distinct nodes share an `identity_hash`
    /// within the same tree. Each duplicate after the first counts as one
    /// collision. The first-write-wins policy still applies: only the first
    /// node for a given hash participates in matching.
    hash_collisions: u32 = 0,

    pub fn deinit(self: *DiffSet, gpa: std.mem.Allocator) void {
        self.changes.deinit(gpa);
    }
};

const IdentityMap = std.AutoHashMap(u64, ast.NodeIndex);

fn buildMap(gpa: std.mem.Allocator, tree: *ast.Tree) !struct { map: IdentityMap, collisions: u32 } {
    var map: IdentityMap = .init(gpa);
    errdefer map.deinit();
    const idents = tree.nodes.items(.identity_hash);
    try map.ensureTotalCapacity(@intCast(idents.len));
    var collisions: u32 = 0;
    for (idents, 0..) |id, i| {
        const gop = map.getOrPutAssumeCapacity(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
        } else {
            collisions += 1; // Keep first occurrence (deterministic); count the drop.
        }
    }
    return .{ .map = map, .collisions = collisions };
}

pub fn diff(gpa: std.mem.Allocator, a: *ast.Tree, b: *ast.Tree) !DiffSet {
    const a_result = try buildMap(gpa, a);
    var a_map = a_result.map;
    defer a_map.deinit();
    const b_result = try buildMap(gpa, b);
    var b_map = b_result.map;
    defer b_map.deinit();
    const total_collisions: u32 = a_result.collisions + b_result.collisions;

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

    return .{ .changes = changes, .hash_collisions = total_collisions };
}

/// Suppress redundant cascading changes so output reflects the deepest
/// real change, not its propagation up the tree.
///
///   - MODIFIED ancestor of another MODIFIED node => suppressed.
///     (Subtree hash propagated up; the descendant is the real change.)
///   - ADDED descendant of another ADDED node    => suppressed.
///     (Whole subtree was added; child rows are noise.)
///   - DELETED descendant of another DELETED in A => suppressed.
///   - MOVED whose ancestor in B is MODIFIED      => suppressed.
///     (Sibling insert/delete shifted byte offsets; not a real move.)
pub fn suppressCascade(set: *DiffSet, a: *ast.Tree, b: *ast.Tree, gpa: std.mem.Allocator) !void {
    var modified_b: std.AutoHashMap(ast.NodeIndex, void) = .init(gpa);
    defer modified_b.deinit();
    var added_b: std.AutoHashMap(ast.NodeIndex, void) = .init(gpa);
    defer added_b.deinit();
    var deleted_a: std.AutoHashMap(ast.NodeIndex, void) = .init(gpa);
    defer deleted_a.deinit();

    for (set.changes.items) |c| {
        switch (c.kind) {
            .modified => if (c.b_idx) |bi| try modified_b.put(bi, {}),
            .added => if (c.b_idx) |bi| try added_b.put(bi, {}),
            .deleted => if (c.a_idx) |ai| try deleted_a.put(ai, {}),
            .moved => {},
            // `renamed` is only produced by review-mode post-processing
            // (`rename.pairRenames`); `differ.diff` never emits it. If callers
            // run suppressCascade after pairing, treat it like a no-op.
            .renamed => {},
        }
    }

    const parents_b = b.nodes.items(.parent_idx);
    const parents_a = a.nodes.items(.parent_idx);

    const Helpers = struct {
        fn ancestorIn(
            set_map: *const std.AutoHashMap(ast.NodeIndex, void),
            parents: []const ast.NodeIndex,
            start: ast.NodeIndex,
        ) bool {
            var p = parents[start];
            while (p != ast.ROOT_PARENT) : (p = parents[p]) {
                if (set_map.contains(p)) return true;
            }
            return false;
        }
    };

    // Set of B-nodes whose subtree gained/lost a child. Their MODIFIED is
    // explained by the child-level ADDED/DELETED rows and is redundant; their
    // descendant MOVEDs are caused by sibling shift, also redundant.
    var struct_changed_b: std.AutoHashMap(ast.NodeIndex, void) = .init(gpa);
    defer struct_changed_b.deinit();

    // Each ADDED node's direct parent gained a child.
    {
        var it = added_b.keyIterator();
        while (it.next()) |idx_ptr| {
            const p = parents_b[idx_ptr.*];
            if (p != ast.ROOT_PARENT) try struct_changed_b.put(p, {});
        }
    }
    // Each DELETED node (in A) whose A-parent maps by identity to a B-node:
    // mark that B-node.
    {
        var b_id_map: std.AutoHashMap(u64, ast.NodeIndex) = .init(gpa);
        defer b_id_map.deinit();
        const b_idents = b.nodes.items(.identity_hash);
        try b_id_map.ensureTotalCapacity(@intCast(b_idents.len));
        for (b_idents, 0..) |id, i| {
            const gop = b_id_map.getOrPutAssumeCapacity(id);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        }

        const a_idents = a.nodes.items(.identity_hash);
        var it = deleted_a.keyIterator();
        while (it.next()) |idx_ptr| {
            const pa = parents_a[idx_ptr.*];
            if (pa == ast.ROOT_PARENT) continue;
            if (b_id_map.get(a_idents[pa])) |pb| {
                try struct_changed_b.put(pb, {});
            }
        }
    }

    // MODIFIED on a node is redundant if a descendant is also MODIFIED.
    var redundant_modified: std.AutoHashMap(ast.NodeIndex, void) = .init(gpa);
    defer redundant_modified.deinit();
    var it = modified_b.keyIterator();
    while (it.next()) |idx_ptr| {
        var p = parents_b[idx_ptr.*];
        while (p != ast.ROOT_PARENT) : (p = parents_b[p]) {
            if (modified_b.contains(p)) try redundant_modified.put(p, {});
        }
    }

    var w: usize = 0;
    for (set.changes.items) |c| {
        const drop = switch (c.kind) {
            // Drop if (a) a deeper MODIFIED is the real cause, or (b) the
            // change is purely structural and already shown as ADDED/DELETED.
            .modified => redundant_modified.contains(c.b_idx.?) or
                struct_changed_b.contains(c.b_idx.?),
            // Drop if a higher ADDED already covers the subtree.
            .added => Helpers.ancestorIn(&added_b, parents_b, c.b_idx.?),
            .deleted => Helpers.ancestorIn(&deleted_a, parents_a, c.a_idx.?),
            // Drop if an ancestor's structural change explains the offset shift.
            .moved => Helpers.ancestorIn(&struct_changed_b, parents_b, c.b_idx.?),
            // `renamed` only appears post-pairing; never suppress.
            .renamed => false,
        };
        if (drop) continue;
        set.changes.items[w] = c;
        w += 1;
    }
    set.changes.shrinkRetainingCapacity(w);
}

fn changeStart(c: Change, a: *ast.Tree, b: *ast.Tree) u32 {
    if (c.b_idx) |bi| return b.nodes.items(.content_range)[bi].start;
    if (c.a_idx) |ai| return a.nodes.items(.content_range)[ai].start;
    return 0;
}

const SortCtx = struct {
    a: *ast.Tree,
    b: *ast.Tree,
    fn lessThan(ctx: SortCtx, x: Change, y: Change) bool {
        return changeStart(x, ctx.a, ctx.b) < changeStart(y, ctx.a, ctx.b);
    }
};

/// Stable sort changes by source byte offset. Uses tree B's offset for
/// added/modified/moved; tree A's offset for deleted.
pub fn sortByLocation(set: *DiffSet, a: *ast.Tree, b: *ast.Tree) void {
    std.mem.sort(Change, set.changes.items, SortCtx{ .a = a, .b = b }, SortCtx.lessThan);
}

pub fn kindStr(k: ChangeKind) []const u8 {
    return switch (k) {
        .added => "added",
        .deleted => "deleted",
        .modified => "modified",
        .moved => "moved",
        .renamed => "renamed",
    };
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        0...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Render diff as NDJSON: one JSON object per line, one per change.
/// Schema (per object):
///   { "kind": "added"|"deleted"|"modified"|"moved",
///     "a"?: { "path": str, "line": u32, "col": u32, "text": str },
///     "b"?: { "path": str, "line": u32, "col": u32, "text": str } }
pub fn renderJson(
    set: *const DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
) !void {
    for (set.changes.items) |c| {
        try writer.writeAll("{\"kind\":\"");
        try writer.writeAll(kindStr(c.kind));
        try writer.writeByte('"');
        if (c.a_idx) |ai| {
            const lc = a.lineCol(ai);
            try writer.writeAll(",\"a\":{\"path\":");
            try writeJsonString(writer, a.path);
            try writer.print(",\"line\":{d},\"col\":{d},\"text\":", .{ lc.line, lc.col });
            try writeJsonString(writer, a.contentSlice(ai));
            try writer.writeAll("}");
        }
        if (c.b_idx) |bi| {
            const lc = b.lineCol(bi);
            try writer.writeAll(",\"b\":{\"path\":");
            try writeJsonString(writer, b.path);
            try writer.print(",\"line\":{d},\"col\":{d},\"text\":", .{ lc.line, lc.col });
            try writeJsonString(writer, b.contentSlice(bi));
            try writer.writeAll("}");
        }
        try writer.writeAll("}\n");
    }
}

/// Render diff as YAML — top-level sequence, one item per change.
/// Strings always double-quoted for safety with arbitrary content.
pub fn renderYaml(
    set: *const DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
) !void {
    for (set.changes.items) |c| {
        try writer.writeAll("- kind: ");
        try writer.writeAll(kindStr(c.kind));
        try writer.writeByte('\n');
        if (c.a_idx) |ai| {
            const lc = a.lineCol(ai);
            try writer.writeAll("  a:\n");
            try writer.writeAll("    path: ");
            try writeJsonString(writer, a.path);
            try writer.writeByte('\n');
            try writer.print("    line: {d}\n    col: {d}\n", .{ lc.line, lc.col });
            try writer.writeAll("    text: ");
            try writeJsonString(writer, a.contentSlice(ai));
            try writer.writeByte('\n');
        }
        if (c.b_idx) |bi| {
            const lc = b.lineCol(bi);
            try writer.writeAll("  b:\n");
            try writer.writeAll("    path: ");
            try writeJsonString(writer, b.path);
            try writer.writeByte('\n');
            try writer.print("    line: {d}\n    col: {d}\n", .{ lc.line, lc.col });
            try writer.writeAll("    text: ");
            try writeJsonString(writer, b.contentSlice(bi));
            try writer.writeByte('\n');
        }
    }
}

/// Render a diff to the given writer in human-readable text form.
/// Format: `LABEL path:line:col\n  - old\n  + new\n`
/// `opts.theme.enabled` toggles ANSI color; `opts.lang` selects the syntax
/// highlighter for change content.
pub fn render(
    set: *const DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
    opts: RenderOptions,
) !void {
    const t = opts.theme.enabled;
    const c_path: []const u8 = if (t) "\x1b[36m" else "";
    const c_lab_mod: []const u8 = if (t) "\x1b[1;33m" else "";
    const c_lab_add: []const u8 = if (t) "\x1b[1;32m" else "";
    const c_lab_del: []const u8 = if (t) "\x1b[1;31m" else "";
    const c_lab_mov: []const u8 = if (t) "\x1b[1;36m" else "";
    const c_lab_ren: []const u8 = if (t) "\x1b[1;35m" else "";
    const c_minus: []const u8 = if (t) "\x1b[31m" else "";
    const c_plus: []const u8 = if (t) "\x1b[32m" else "";
    const c_tilde: []const u8 = if (t) "\x1b[33m" else "";
    const reset: []const u8 = if (t) "\x1b[0m" else "";

    for (set.changes.items) |c| switch (c.kind) {
        .added => {
            const bi = c.b_idx.?;
            const lc = b.lineCol(bi);
            try writer.print("{s}ADDED   {s} {s}{s}:{d}:{d}{s}\n", .{
                c_lab_add, reset, c_path, b.path, lc.line, lc.col, reset,
            });
            try writer.print("{s}  + {s}", .{ c_plus, reset });
            try syntax.writeHighlighted(opts.lang, b.contentSlice(bi), writer, opts.theme);
            try writer.writeByte('\n');
        },
        .deleted => {
            const ai = c.a_idx.?;
            const lc = a.lineCol(ai);
            try writer.print("{s}DELETED {s} {s}{s}:{d}:{d}{s}\n", .{
                c_lab_del, reset, c_path, a.path, lc.line, lc.col, reset,
            });
            try writer.print("{s}  - {s}", .{ c_minus, reset });
            try syntax.writeHighlighted(opts.lang, a.contentSlice(ai), writer, opts.theme);
            try writer.writeByte('\n');
        },
        .modified => {
            const ai = c.a_idx.?;
            const bi = c.b_idx.?;
            const lc_a = a.lineCol(ai);
            const lc_b = b.lineCol(bi);
            try writer.print("{s}MODIFIED{s} {s}{s}:{d}:{d}{s} -> {s}{s}:{d}:{d}{s}\n", .{
                c_lab_mod,    reset,
                c_path,       a.path,
                lc_a.line,    lc_a.col,
                reset,        c_path,
                b.path,       lc_b.line,
                lc_b.col,     reset,
            });

            const a_content = a.contentSlice(ai);
            const b_content = b.contentSlice(bi);
            const multi_line = std.mem.indexOfScalar(u8, a_content, '\n') != null or
                std.mem.indexOfScalar(u8, b_content, '\n') != null;

            if (opts.gpa != null and multi_line) {
                const ok = try line_diff.writeUnified(
                    opts.gpa.?,
                    a_content,
                    b_content,
                    writer,
                    opts.lang,
                    opts.theme,
                    line_diff.default_limit,
                );
                if (ok) continue;
            }

            // Fallback: whole `- old / + new` view.
            try writer.print("{s}  - {s}", .{ c_minus, reset });
            try syntax.writeHighlighted(opts.lang, a_content, writer, opts.theme);
            try writer.writeByte('\n');
            try writer.print("{s}  + {s}", .{ c_plus, reset });
            try syntax.writeHighlighted(opts.lang, b_content, writer, opts.theme);
            try writer.writeByte('\n');
        },
        .moved => {
            const ai = c.a_idx.?;
            const bi = c.b_idx.?;
            const lc_a = a.lineCol(ai);
            const lc_b = b.lineCol(bi);
            try writer.print("{s}MOVED   {s} {s}{s}:{d}:{d}{s} -> {s}{s}:{d}:{d}{s}\n", .{
                c_lab_mov,    reset,
                c_path,       a.path,
                lc_a.line,    lc_a.col,
                reset,        c_path,
                b.path,       lc_b.line,
                lc_b.col,     reset,
            });
            try writer.print("{s}  ~ {s}", .{ c_tilde, reset });
            try syntax.writeHighlighted(opts.lang, b.contentSlice(bi), writer, opts.theme);
            try writer.writeByte('\n');
        },
        .renamed => {
            const ai = c.a_idx.?;
            const bi = c.b_idx.?;
            const lc_a = a.lineCol(ai);
            const lc_b = b.lineCol(bi);
            try writer.print("{s}RENAMED {s} {s}{s}:{d}:{d}{s} -> {s}{s}:{d}:{d}{s}\n", .{
                c_lab_ren,    reset,
                c_path,       a.path,
                lc_a.line,    lc_a.col,
                reset,        c_path,
                b.path,       lc_b.line,
                lc_b.col,     reset,
            });
            try writer.print("{s}  - {s}", .{ c_minus, reset });
            try syntax.writeHighlighted(opts.lang, a.contentSlice(ai), writer, opts.theme);
            try writer.writeByte('\n');
            try writer.print("{s}  + {s}", .{ c_plus, reset });
            try syntax.writeHighlighted(opts.lang, b.contentSlice(bi), writer, opts.theme);
            try writer.writeByte('\n');
        },
    };
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

test "suppressCascade removes ancestor MODIFIED noise" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"k\":1}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"k\":2}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // Pre-suppression: number, member, object all MODIFIED.
    try std.testing.expectEqual(@as(usize, 3), countKind(&set, .modified));

    try suppressCascade(&set, &a, &b, gpa);

    // Post-suppression: only the deepest (number) remains.
    try std.testing.expectEqual(@as(usize, 1), countKind(&set, .modified));

    // Verify it's the json_number, not the member or object.
    const kinds = b.nodes.items(.kind);
    for (set.changes.items) |c| {
        if (c.kind == .modified) {
            try std.testing.expectEqual(ast.Kind.json_number, kinds[c.b_idx.?]);
        }
    }
}

test "suppressCascade silences MOVED under MODIFIED ancestor" {
    const gpa = std.testing.allocator;
    // Add a field at the front: existing fields shift in offset (would each
    // report MOVED) but the parent object also shows MODIFIED (new member).
    var a = try json_parser.parse(gpa, "{\"k\":1,\"v\":2}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"new\":0,\"k\":1,\"v\":2}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    const moves_before = countKind(&set, .moved);
    try std.testing.expect(moves_before > 0);

    try suppressCascade(&set, &a, &b, gpa);

    // All MOVEs were under the MODIFIED object: should be suppressed.
    try std.testing.expectEqual(@as(usize, 0), countKind(&set, .moved));
    // ADDED on `new` member + its value should remain.
    try std.testing.expect(countKind(&set, .added) >= 1);
}

test "suppressCascade collapses ADDED subtree to top member" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"obj\":{\"k\":1,\"v\":[1,2]}}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    try suppressCascade(&set, &a, &b, gpa);

    // Only 1 ADDED row should remain: the `obj` member at the top.
    try std.testing.expectEqual(@as(usize, 1), countKind(&set, .added));

    const kinds = b.nodes.items(.kind);
    for (set.changes.items) |c| {
        if (c.kind == .added) {
            try std.testing.expectEqual(ast.Kind.json_member, kinds[c.b_idx.?]);
            try std.testing.expectEqualStrings("obj", b.identitySlice(c.b_idx.?));
        }
    }
}

test "suppressCascade collapses DELETED subtree to top member" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"obj\":{\"k\":1}}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try suppressCascade(&set, &a, &b, gpa);

    try std.testing.expectEqual(@as(usize, 1), countKind(&set, .deleted));

    const kinds = a.nodes.items(.kind);
    for (set.changes.items) |c| {
        if (c.kind == .deleted) {
            try std.testing.expectEqual(ast.Kind.json_member, kinds[c.a_idx.?]);
            try std.testing.expectEqualStrings("obj", a.identitySlice(c.a_idx.?));
        }
    }
}

test "sortByLocation orders changes by byte offset" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"x\":1,\"y\":2,\"z\":3}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"x\":9,\"y\":2,\"z\":8}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try suppressCascade(&set, &a, &b, gpa);
    sortByLocation(&set, &a, &b);

    // Walk emitted changes; b-side offset must be non-decreasing.
    var prev: u32 = 0;
    for (set.changes.items) |c| {
        const off = changeStart(c, &a, &b);
        try std.testing.expect(off >= prev);
        prev = off;
    }
}

test "filter drops disallowed kinds" {
    const gpa = std.testing.allocator;
    var a = try json_parser.parse(gpa, "{\"k\":1,\"gone\":2}", "a.json");
    defer a.deinit();
    var b = try json_parser.parse(gpa, "{\"k\":2,\"new\":3}", "b.json");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);

    // Filter to only ADDED.
    filter(&set, .{
        .added = true,
        .deleted = false,
        .modified = false,
        .moved = false,
    });
    for (set.changes.items) |c| try std.testing.expectEqual(ChangeKind.added, c.kind);
    try std.testing.expect(set.changes.items.len > 0);
}

test "stmt-level cascade: parent fn reported only when stmts unstable" {
    const gpa = std.testing.allocator;
    var a = try @import("rust_parser.zig").parse(gpa, "fn f() { let x = 1; let y = 2; }", "a.rs");
    defer a.deinit();
    var b = try @import("rust_parser.zig").parse(gpa, "fn f() { let x = 1; let y = 3; }", "b.rs");
    defer b.deinit();

    var set = try diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try suppressCascade(&set, &a, &b, gpa);

    var modified_kinds: usize = 0;
    const kinds_b = b.nodes.items(.kind);
    for (set.changes.items) |c| {
        if (c.kind == .modified) {
            modified_kinds += 1;
            try std.testing.expectEqual(ast.Kind.rust_stmt, kinds_b[c.b_idx.?]);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), modified_kinds);
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
