//! Review-mode NDJSON pipeline.
//!
//! Wraps the existing `differ.diff → suppressCascade → sortByLocation → filter`
//! pipeline with enrichment passes and a `review-v1`-versioned NDJSON renderer.
//! Existing `differ.renderJson` / `differ.renderYaml` are untouched.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const differ = @import("differ.zig");
const line_diff = @import("line_diff.zig");
const signature = @import("signature.zig");
const sensitivity = @import("sensitivity.zig");
const rename = @import("rename.zig");
const symbols = @import("symbols.zig");

const json_parser = @import("json_parser.zig");
const yaml_parser = @import("yaml_parser.zig");
const rust_parser = @import("rust_parser.zig");
const go_parser = @import("go_parser.zig");
const zig_parser = @import("zig_parser.zig");
const dart_parser = @import("dart_parser.zig");
const js_parser = @import("js_parser.zig");
const ts_parser = @import("ts_parser.zig");
const test_pair = @import("test_pair.zig");
const complexity = @import("complexity.zig");

pub const SCHEMA_VERSION = "review-v1";
pub const SYNDIFF_VERSION = "0.1.0";

/// Sidecar metadata parallel to `DiffSet.changes`. Index `i` of `metas`
/// corresponds to index `i` of `set.changes.items`.
pub const ChangeMeta = struct {
    change_id: u64 = 0,
    /// Dotted scope path (e.g. "pkg.Foo.bar"). Owned by orchestrator arena.
    scope: []const u8 = "",
    kind_tag: KindTag = .body_change,
    is_exported: bool = false,
    lines_added: u32 = 0,
    lines_removed: u32 = 0,
    /// Set by `annotateSignatureDelta` for `modified` fn/method changes when
    /// both sides have an extractable signature. Slices are owned by the
    /// orchestrator allocator and must be freed in `renderReviewJson`'s defer.
    signature_diff: ?SignatureDiff = null,
    /// Set by `annotateSensitivity` from a single byte-scan over the post-image
    /// (or pre-image for `.deleted`). Heuristic — false positives tolerated.
    sensitivity_tags: sensitivity.TagSet = sensitivity.TagSet.initEmpty(),
    /// Set by `annotateComplexity` for `.modified` and `.renamed` changes:
    /// stmt-child counts in trees A and B, plus their delta.
    complexity_delta: ?ComplexityDelta = null,
    /// Set by `annotateCallsites` for `.signature_change` records: a list of
    /// `(path, line)` for every `*_stmt` node in tree B that mentions the
    /// changed symbol's name. Capped at 50. Outer slice is owned by the
    /// orchestrator allocator; `Callsite.path` borrows from `tree.path` and
    /// must NOT be freed.
    callsites: []const symbols.Callsite = &.{},
};

pub const ComplexityDelta = struct {
    stmt_a: u32,
    stmt_b: u32,
    delta: i32,
    method: []const u8 = "cyclomatic",
};

pub const KindTag = enum { signature_change, body_change, structural };

pub const ParamChange = struct {
    name: []const u8,
    from: []const u8,
    to: []const u8,
};

pub const SignatureDiff = struct {
    params_added: []const signature.Param = &.{},
    params_removed: []const signature.Param = &.{},
    params_changed: []const ParamChange = &.{},
    return_changed: bool = false,
    visibility_changed: bool = false,

    /// True when at least one element of the diff is non-empty/true. Used by
    /// the renderer to omit the block entirely for body-only changes.
    pub fn hasAnyChange(self: SignatureDiff) bool {
        return self.params_added.len > 0 or
            self.params_removed.len > 0 or
            self.params_changed.len > 0 or
            self.return_changed or
            self.visibility_changed;
    }
};

pub const Summary = struct {
    files_changed: u32 = 0,
    counts: struct { added: u32 = 0, deleted: u32 = 0, modified: u32 = 0, moved: u32 = 0, renamed: u32 = 0 } = .{},
    exported_changes: u32 = 0,
    sensitivity_totals: struct {
        crypto: u32 = 0,
        auth: u32 = 0,
        sql: u32 = 0,
        shell: u32 = 0,
        network: u32 = 0,
        fs_io: u32 = 0,
        secrets: u32 = 0,
    } = .{},
    /// Total identity-hash collisions detected across all file pairs in this run.
    /// Always emitted in the summary record, even when 0.
    hash_collisions: u32 = 0,
};

const Lang = enum { json, yaml, rust, go, zig, dart, js, ts, unknown };

fn langFromPath(path: []const u8) Lang {
    if (std.ascii.endsWithIgnoreCase(path, ".json")) return .json;
    if (std.ascii.endsWithIgnoreCase(path, ".yaml") or std.ascii.endsWithIgnoreCase(path, ".yml")) return .yaml;
    if (std.ascii.endsWithIgnoreCase(path, ".rs")) return .rust;
    if (std.ascii.endsWithIgnoreCase(path, ".go")) return .go;
    if (std.ascii.endsWithIgnoreCase(path, ".zig")) return .zig;
    if (std.ascii.endsWithIgnoreCase(path, ".dart")) return .dart;
    if (std.ascii.endsWithIgnoreCase(path, ".js") or std.ascii.endsWithIgnoreCase(path, ".mjs") or std.ascii.endsWithIgnoreCase(path, ".cjs")) return .js;
    if (std.ascii.endsWithIgnoreCase(path, ".ts") or std.ascii.endsWithIgnoreCase(path, ".tsx") or std.ascii.endsWithIgnoreCase(path, ".mts") or std.ascii.endsWithIgnoreCase(path, ".cts")) return .ts;
    return .unknown;
}

fn parseLang(gpa: std.mem.Allocator, src: []const u8, path: []const u8, lang: Lang) !ast.Tree {
    return switch (lang) {
        .json => json_parser.parse(gpa, src, path),
        .yaml => yaml_parser.parse(gpa, src, path),
        .rust => rust_parser.parse(gpa, src, path),
        .go => go_parser.parse(gpa, src, path),
        .zig => blk: {
            // zig_parser requires sentinel-terminated source. dupeZ allocates
            // outside the Tree's arena, so we must rehome it: parse first
            // (which copies the slice header into Tree.source), then dupe
            // again into the Tree's arena and rebind, freeing the temporary.
            const z = try gpa.dupeZ(u8, src);
            var tree = zig_parser.parse(gpa, z, path) catch |e| {
                gpa.free(z);
                break :blk e;
            };
            // Move ownership: copy bytes into the tree's arena and free temp.
            const arena_src = tree.arena.allocator().dupeZ(u8, z) catch |e| {
                tree.deinit();
                gpa.free(z);
                break :blk e;
            };
            tree.source = arena_src;
            gpa.free(z);
            break :blk tree;
        },
        .dart => dart_parser.parse(gpa, src, path),
        .js => js_parser.parse(gpa, src, path),
        .ts => ts_parser.parse(gpa, src, path),
        .unknown => error.UnsupportedLanguage,
    };
}

/// Multi-file run context. Manages the lifecycle of a review-mode NDJSON
/// stream: `init` writes the schema header, each `addFilePair` accumulates
/// per-file records and updates the running summary, and `finish` writes
/// the `test_not_updated` records (one per non-test source file with no
/// co-changed test) followed by the final `summary` record.
///
/// Memory ownership:
///   - `all_changed_paths` stores caller-provided path slices verbatim. Run
///     does NOT take ownership of those strings; the caller must keep them
///     alive at least until `finish` completes. The list backing array is
///     owned by Run and freed in `deinit`.
///   - `summary.files_changed` counts the distinct entries in
///     `all_changed_paths` at `finish` time, so callers must invoke
///     `recordChangedPath` exactly once per logical file (NOT once per
///     `a.path` and once per `b.path`).
///
/// `addFilePair` MUTATES the supplied DiffSet (it calls `pairRenames`).
/// Caller still owns the trees and the DiffSet.
pub const Run = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    summary: Summary = .{},
    /// All paths (test files included) recorded by the caller. Used by
    /// `finish` to detect "non-test source path with no co-changed test
    /// file" AND to compute `summary.files_changed`. Slices are NOT owned
    /// by Run; caller must keep them alive.
    all_changed_paths: std.ArrayList([]const u8) = .empty,
    /// When true, `addFilePair` collapses `*_stmt` changes whose parent
    /// node is also a change in the same DiffSet into a `sub_changes`
    /// array on the parent's record. Default off preserves byte-identical
    /// legacy output for fixtures.
    group_by_symbol: bool = false,

    pub fn init(gpa: std.mem.Allocator, w: *std.Io.Writer) !Run {
        try w.print("{{\"kind\":\"schema\",\"version\":\"{s}\",\"syndiff\":\"{s}\"}}\n", .{ SCHEMA_VERSION, SYNDIFF_VERSION });
        return .{
            .gpa = gpa,
            .writer = w,
        };
    }

    pub fn deinit(self: *Run) void {
        self.all_changed_paths.deinit(self.gpa);
    }

    /// Mark a path as part of the changed set. Used both for
    /// `test_not_updated` pairing and the final `summary.files_changed`
    /// count. Does NOT take ownership of the slice. Call exactly once per
    /// logical file (not once per a/b pair). For multi-file (git) mode,
    /// pass the bare repository path (no `@ref` suffix).
    pub fn recordChangedPath(self: *Run, path: []const u8) !void {
        try self.all_changed_paths.append(self.gpa, path);
    }

    /// Process one file pair: pair renames, run all enrichment passes,
    /// emit per-change records, and update the running summary. Mutates
    /// the supplied DiffSet via `pairRenames`. The trees and DiffSet
    /// remain owned by the caller. Does NOT touch `all_changed_paths` —
    /// the caller is responsible for `recordChangedPath`.
    pub fn addFilePair(self: *Run, a: *ast.Tree, b: *ast.Tree, set: *differ.DiffSet) !void {
        // Pair (deleted, added) into renamed before allocating metas: rename
        // pairing collapses two rows into one, so meta indexing stays in sync.
        try rename.pairRenames(self.gpa, set, a, b);
        // Accumulate hash-collision count from this file pair's DiffSet.
        self.summary.hash_collisions += set.hash_collisions;

        // Allocate sidecar.
        const metas = try self.gpa.alloc(ChangeMeta, set.changes.items.len);
        defer {
            // Free per-change scope strings allocated by annotateScope.
            for (metas) |m| {
                if (m.scope.len > 0) self.gpa.free(m.scope);
                if (m.signature_diff) |sd| {
                    self.gpa.free(sd.params_added);
                    self.gpa.free(sd.params_removed);
                    self.gpa.free(sd.params_changed);
                }
                // Callsite outer slice owned by orchestrator; `.path` borrows
                // from `tree.path` and is not freed here.
                if (m.callsites.len > 0) self.gpa.free(m.callsites);
            }
            self.gpa.free(metas);
        }
        for (metas) |*m| m.* = .{};

        try annotateScope(self.gpa, set, a, b, metas);
        try annotateKindTag(set, a, b, metas);
        annotateExport(set, a, b, metas);
        try annotateChangeId(set, a, b, metas);
        try annotateLineChurn(self.gpa, set, a, b, metas);
        try annotateSignatureDelta(self.gpa, set, a, b, metas);
        annotateSensitivity(set, a, b, metas);
        try annotateComplexity(self.gpa, set, a, b, metas);
        if (anySignatureChange(metas)) try annotateCallsites(self.gpa, set, a, b, metas);

        if (self.group_by_symbol) {
            // Two-pass emission. Pass 1: build a `b_idx -> meta_index` map
            // so a stmt change can find its parent change (if any). Pass 2:
            // emit top-level records, attaching nested stmt children as
            // `sub_changes`.
            //
            // `nested_under[i] = j` means meta `i` is a stmt change that
            // should be emitted as a sub_change of meta `j`. `null` means
            // emit `i` at top level.
            const nested_under = try self.gpa.alloc(?usize, set.changes.items.len);
            defer self.gpa.free(nested_under);
            for (nested_under) |*x| x.* = null;

            // b_idx -> meta_index map for parent lookup. Use the b-side
            // (post-image) for consistency; pure deletions wouldn't have a
            // b_idx but they also won't have stmt-level children that
            // outlived the delete, so b-side coverage is sufficient.
            var b_to_meta: std.AutoHashMap(ast.NodeIndex, usize) = .init(self.gpa);
            defer b_to_meta.deinit();
            for (set.changes.items, 0..) |c, i| {
                if (c.b_idx) |bi| try b_to_meta.put(bi, i);
            }

            const b_kinds = b.nodes.items(.kind);
            const b_parents = b.nodes.items(.parent_idx);

            for (set.changes.items, 0..) |c, i| {
                const bi = c.b_idx orelse continue;
                if (!isStmtKind(b_kinds[bi])) continue;
                const parent = b_parents[bi];
                if (parent == ast.ROOT_PARENT) continue;
                if (b_to_meta.get(parent)) |pj| {
                    if (pj != i) nested_under[i] = pj;
                }
            }

            for (set.changes.items, metas, 0..) |c, m, i| {
                if (nested_under[i] != null) continue;
                try writeRecordPrefix(self.writer, &c, &m, a, b);
                // Append any nested children, in their original order.
                var first_child = true;
                for (set.changes.items, metas, 0..) |cc, mm, j| {
                    if (nested_under[j] != i) continue;
                    if (first_child) {
                        try self.writer.writeAll(",\"sub_changes\":[");
                        first_child = false;
                    } else {
                        try self.writer.writeByte(',');
                    }
                    try writeRecordPrefix(self.writer, &cc, &mm, a, b);
                    try self.writer.writeByte('}');
                }
                if (!first_child) try self.writer.writeByte(']');
                try self.writer.writeAll("}\n");

                self.bumpSummary(&c, &m);
            }
            // Stmt children that became sub_changes still count in the summary.
            for (set.changes.items, metas, 0..) |c, m, i| {
                if (nested_under[i] == null) continue;
                self.bumpSummary(&c, &m);
            }
        } else {
            for (set.changes.items, metas) |c, m| {
                try writeRecord(self.writer, &c, &m, a, b);
                self.bumpSummary(&c, &m);
            }
        }
    }

    fn bumpSummary(self: *Run, c: *const differ.Change, m: *const ChangeMeta) void {
        switch (c.kind) {
            .added => self.summary.counts.added += 1,
            .deleted => self.summary.counts.deleted += 1,
            .modified => self.summary.counts.modified += 1,
            .moved => self.summary.counts.moved += 1,
            .renamed => self.summary.counts.renamed += 1,
        }
        if (m.is_exported) self.summary.exported_changes += 1;
        var stit = m.sensitivity_tags.iterator();
        while (stit.next()) |t| switch (t) {
            .crypto => self.summary.sensitivity_totals.crypto += 1,
            .auth => self.summary.sensitivity_totals.auth += 1,
            .sql => self.summary.sensitivity_totals.sql += 1,
            .shell => self.summary.sensitivity_totals.shell += 1,
            .network => self.summary.sensitivity_totals.network += 1,
            .fs_io => self.summary.sensitivity_totals.fs_io += 1,
            .secrets => self.summary.sensitivity_totals.secrets += 1,
        };
    }

    /// Emit `test_not_updated` records for non-test source paths whose
    /// expected test sibling is NOT in `all_changed_paths`, then write
    /// the final `summary` record. If `summary.files_changed` is already
    /// nonzero (set by the single-file wrappers) it is left alone;
    /// otherwise it is computed from the distinct entries in
    /// `all_changed_paths`.
    pub fn finish(self: *Run) !void {
        try emitTestPairing(self.gpa, self.writer, self.all_changed_paths.items);
        if (self.summary.files_changed == 0) {
            self.summary.files_changed = try countDistinct(self.gpa, self.all_changed_paths.items);
        }

        const sc = self.summary.counts;
        const st = self.summary.sensitivity_totals;
        try self.writer.print(
            "{{\"kind\":\"summary\",\"files_changed\":{d},\"counts\":{{\"added\":{d},\"deleted\":{d},\"modified\":{d},\"moved\":{d},\"renamed\":{d}}},\"exported_changes\":{d},\"sensitivity_totals\":{{\"crypto\":{d},\"auth\":{d},\"sql\":{d},\"shell\":{d},\"network\":{d},\"fs_io\":{d},\"secrets\":{d}}},\"hash_collisions\":{d}}}\n",
            .{
                self.summary.files_changed,
                sc.added,                sc.deleted,                sc.modified,                sc.moved,                sc.renamed,
                self.summary.exported_changes,
                st.crypto, st.auth, st.sql, st.shell, st.network, st.fs_io, st.secrets,
                self.summary.hash_collisions,
            },
        );
    }

    pub fn totalChanges(self: *const Run) u32 {
        const c = self.summary.counts;
        return c.added + c.deleted + c.modified + c.moved + c.renamed;
    }
};

/// Count the distinct values in `paths` (linear, since the list is small in
/// practice — git diffs touch tens of files, not millions).
fn countDistinct(gpa: std.mem.Allocator, paths: []const []const u8) !u32 {
    var seen: std.StringHashMap(void) = .init(gpa);
    defer seen.deinit();
    for (paths) |p| try seen.put(p, {});
    return @intCast(seen.count());
}

/// Walk `all_paths`, ignore test-shaped paths, and for each non-test source
/// path: compute its expected test sibling. If no candidate matches any
/// member of `all_paths`, emit a `test_not_updated` record naming the first
/// candidate as the missing sibling.
fn emitTestPairing(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    all_paths: []const []const u8,
) !void {
    for (all_paths) |src_path| {
        if (test_pair.isTestPath(src_path)) continue;
        const candidates = test_pair.expectedTestPath(gpa, src_path) catch continue;
        defer {
            for (candidates) |c| if (c) |s| gpa.free(s);
            gpa.free(candidates);
        }
        if (candidates.len == 0) continue;

        var any_match = false;
        for (candidates) |maybe| {
            const cand = maybe orelse continue;
            for (all_paths) |p| {
                if (std.mem.eql(u8, cand, p)) {
                    any_match = true;
                    break;
                }
            }
            if (any_match) break;
        }
        if (any_match) continue;

        const first = candidates[0] orelse continue;
        try writer.writeAll("{\"kind\":\"test_not_updated\",\"path\":");
        try writeJsonString(writer, src_path);
        try writer.writeAll(",\"reason\":");
        const reason = try std.fmt.allocPrint(gpa, "no churn in {s}", .{first});
        defer gpa.free(reason);
        try writeJsonString(writer, reason);
        try writer.writeAll("}\n");
    }
}

/// Test-friendly entry: read two files from disk, run the review pipeline,
/// emit a complete review-mode NDJSON stream (header + records + summary).
/// Internally routed through `Run` so the byte stream matches the multi-file
/// driver for a single-pair run.
///
/// Zig 0.16 file I/O takes an `io: Io` parameter (see `src/main.zig`); the
/// plan's `std.fs.cwd().readFileAlloc(...)` signature does not exist.
pub fn runFilePair(
    gpa: std.mem.Allocator,
    io: Io,
    a_path: []const u8,
    b_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const cwd = std.Io.Dir.cwd();
    const a_src = try cwd.readFileAlloc(io, a_path, gpa, .limited(1 << 28));
    defer gpa.free(a_src);
    const b_src = try cwd.readFileAlloc(io, b_path, gpa, .limited(1 << 28));
    defer gpa.free(b_src);

    const lang = langFromPath(a_path);
    var a = try parseLang(gpa, a_src, a_path, lang);
    defer a.deinit();
    var b = try parseLang(gpa, b_src, b_path, lang);
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);
    differ.sortByLocation(&set, &a, &b);

    var run = try Run.init(gpa, writer);
    defer run.deinit();
    // Single-pair mode: one logical file, no `test_not_updated` pairing.
    // We bypass `recordChangedPath` (which feeds the pairing pass) and set
    // `files_changed` directly so the output stays byte-identical to the
    // pre-Run.refactor renderer.
    run.summary.files_changed = 1;
    try run.addFilePair(&a, &b, &set);
    try run.finish();
}

/// Options for `renderReviewJsonOpts`. `group_by_symbol` collapses
/// `*_stmt` changes under their enclosing fn/method record.
pub const RenderOpts = struct {
    group_by_symbol: bool = false,
};

/// Single-shot back-compat wrapper: emits a complete review-mode NDJSON
/// stream (header + records + summary) for one (a, b) pair, with no
/// `test_not_updated` pairing pass. Used by the file-pair CLI mode
/// (`--files`) and any caller that only needs single-pair output.
pub fn renderReviewJson(
    gpa: std.mem.Allocator,
    set: *differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
) !void {
    return renderReviewJsonOpts(gpa, set, a, b, writer, .{});
}

/// Like `renderReviewJson` but accepts options (e.g. `group_by_symbol`).
pub fn renderReviewJsonOpts(
    gpa: std.mem.Allocator,
    set: *differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
    opts: RenderOpts,
) !void {
    var run = try Run.init(gpa, writer);
    defer run.deinit();
    run.summary.files_changed = 1;
    run.group_by_symbol = opts.group_by_symbol;
    try run.addFilePair(a, b, set);
    try run.finish();
}

// -----------------------------------------------------------------------------
// Enrichment passes
// -----------------------------------------------------------------------------

/// Walk parent_idx chain backwards, collecting identity slices. Joins with '.'.
/// Allocates each scope string via `gpa`; orchestrator owns until end of run.
pub fn annotateScope(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        const tree, const idx = if (c.b_idx) |bi|
            .{ b, bi }
        else
            .{ a, c.a_idx.? };

        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(gpa);

        const parents = tree.nodes.items(.parent_idx);
        const ranges = tree.nodes.items(.identity_range);

        var cur: ast.NodeIndex = idx;
        while (cur != ast.ROOT_PARENT) {
            const r = ranges[cur];
            if (r.end > r.start) try stack.append(gpa, tree.source[r.start..r.end]);
            cur = parents[cur];
        }

        if (stack.items.len == 0) {
            m.scope = "";
            continue;
        }

        // Reverse and join with '.'.
        var total: usize = 0;
        for (stack.items) |s| total += s.len;
        total += stack.items.len - 1; // separators

        const buf = try gpa.alloc(u8, total);
        var w: usize = 0;
        var i: usize = stack.items.len;
        while (i > 0) {
            i -= 1;
            const s = stack.items[i];
            @memcpy(buf[w .. w + s.len], s);
            w += s.len;
            if (i > 0) {
                buf[w] = '.';
                w += 1;
            }
        }
        m.scope = buf;
    }
}

pub fn annotateKindTag(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    const a_irhs = a.nodes.items(.identity_range_hash);
    const b_irhs = b.nodes.items(.identity_range_hash);
    for (set.changes.items, metas) |c, *m| {
        m.kind_tag = switch (c.kind) {
            .modified => blk: {
                const ai = c.a_idx.?;
                const bi = c.b_idx.?;
                break :blk if (a_irhs[ai] != b_irhs[bi]) .signature_change else .body_change;
            },
            // A rename is, by definition, a name (identity_range) change with
            // a matching body — so it's a signature_change.
            .renamed => .signature_change,
            .added, .deleted, .moved => .structural,
        };
    }
}

pub fn annotateExport(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) void {
    const a_exp = a.nodes.items(.is_exported);
    const b_exp = b.nodes.items(.is_exported);
    for (set.changes.items, metas) |c, *m| {
        m.is_exported = if (c.b_idx) |bi| b_exp[bi] else if (c.a_idx) |ai| a_exp[ai] else false;
    }
}

pub fn annotateChangeId(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    const a_id = a.nodes.items(.identity_hash);
    const b_id = b.nodes.items(.identity_hash);
    for (set.changes.items, metas) |c, *m| {
        var hasher = std.hash.Wyhash.init(0);
        const ai_hash = if (c.a_idx) |ai| a_id[ai] else 0;
        const bi_hash = if (c.b_idx) |bi| b_id[bi] else 0;
        hasher.update(std.mem.asBytes(&ai_hash));
        hasher.update(std.mem.asBytes(&bi_hash));
        hasher.update(a.path);
        hasher.update(b.path);
        m.change_id = hasher.final();
    }
}

pub fn annotateLineChurn(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        switch (c.kind) {
            .modified, .renamed => {
                const a_text = a.contentSlice(c.a_idx.?);
                const b_text = b.contentSlice(c.b_idx.?);
                const counts = try line_diff.unifiedCounts(gpa, a_text, b_text);
                m.lines_added = counts.added;
                m.lines_removed = counts.removed;
            },
            .added => {
                const text = b.contentSlice(c.b_idx.?);
                m.lines_added = countLines(text);
            },
            .deleted => {
                const text = a.contentSlice(c.a_idx.?);
                m.lines_removed = countLines(text);
            },
            .moved => {},
        }
    }
}

fn optStrEq(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null and y == null) return true;
    if (x == null or y == null) return false;
    return std.mem.eql(u8, x.?, y.?);
}

/// For each `.modified` change, attempt to extract a signature on both sides.
/// If both sides yield a signature, compute a `SignatureDiff` and stash it on
/// the meta. Owned slices must be freed by the caller (see `renderReviewJson`).
pub fn annotateSignatureDelta(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        if (c.kind != .modified) continue;
        const a_idx = c.a_idx orelse continue;
        const b_idx = c.b_idx orelse continue;
        const sig_a_opt = try signature.extract(gpa, a, a_idx);
        if (sig_a_opt == null) continue;
        const sig_a = sig_a_opt.?;
        defer gpa.free(sig_a.params);

        const sig_b_opt = try signature.extract(gpa, b, b_idx);
        if (sig_b_opt == null) continue;
        const sig_b = sig_b_opt.?;
        defer gpa.free(sig_b.params);

        var added: std.ArrayList(signature.Param) = .empty;
        errdefer added.deinit(gpa);
        var removed: std.ArrayList(signature.Param) = .empty;
        errdefer removed.deinit(gpa);
        var changed: std.ArrayList(ParamChange) = .empty;
        errdefer changed.deinit(gpa);

        // Match by name. Type mismatch on a matched name → params_changed.
        for (sig_b.params) |pb| {
            var matched = false;
            for (sig_a.params) |pa| {
                if (std.mem.eql(u8, pa.name, pb.name)) {
                    if (!std.mem.eql(u8, pa.type_str, pb.type_str)) {
                        try changed.append(gpa, .{ .name = pb.name, .from = pa.type_str, .to = pb.type_str });
                    }
                    matched = true;
                    break;
                }
            }
            if (!matched) try added.append(gpa, pb);
        }
        for (sig_a.params) |pa| {
            var matched = false;
            for (sig_b.params) |pb| {
                if (std.mem.eql(u8, pa.name, pb.name)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) try removed.append(gpa, pa);
        }

        const ret_changed = !optStrEq(sig_a.return_type, sig_b.return_type);
        const vis_changed = sig_a.visibility != sig_b.visibility;

        m.signature_diff = .{
            .params_added = try added.toOwnedSlice(gpa),
            .params_removed = try removed.toOwnedSlice(gpa),
            .params_changed = try changed.toOwnedSlice(gpa),
            .return_changed = ret_changed,
            .visibility_changed = vis_changed,
        };
    }
}

/// Single byte-scan per change. Reads the post-image (b) when present,
/// otherwise the pre-image (a). Heuristic — false positives tolerated.
pub fn annotateSensitivity(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) void {
    for (set.changes.items, metas) |c, *m| {
        const text = if (c.b_idx) |bi|
            b.contentSlice(bi)
        else if (c.a_idx) |ai|
            a.contentSlice(ai)
        else
            "";
        m.sensitivity_tags = sensitivity.tag(text);
    }
}

fn countLines(s: []const u8) u32 {
    var n: u32 = if (s.len == 0) 0 else 1;
    for (s) |c| if (c == '\n') {
        n += 1;
    };
    if (s.len > 0 and s[s.len - 1] == '\n') n -= 1;
    return n;
}

/// For each `.modified` or `.renamed` change, count direct stmt children of
/// the changed node in both trees. Cheap proxy for "did the function get
/// bigger/smaller". Languages that don't emit `*_stmt` children produce 0/0.
pub fn annotateComplexity(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    _ = gpa;
    for (set.changes.items, metas) |c, *m| {
        if (c.kind != .modified and c.kind != .renamed) continue;
        const ai = c.a_idx orelse continue;
        const bi = c.b_idx orelse continue;
        const sa = complexity.count(a, ai);
        const sb = complexity.count(b, bi);
        m.complexity_delta = .{
            .stmt_a = sa,
            .stmt_b = sb,
            .delta = @as(i32, @intCast(sb)) - @as(i32, @intCast(sa)),
            .method = "cyclomatic",
        };
    }
}

fn countStmtChildren(gpa: std.mem.Allocator, tree: *ast.Tree, parent: ast.NodeIndex) !u32 {
    var buf: std.ArrayList(ast.NodeIndex) = .empty;
    defer buf.deinit(gpa);
    try tree.childrenOf(gpa, parent, &buf);
    var n: u32 = 0;
    const kinds = tree.nodes.items(.kind);
    for (buf.items) |i| {
        if (isStmtKind(kinds[i])) n += 1;
    }
    return n;
}

/// True iff this node kind is a per-language statement variant
/// (`*_stmt`). Used by `--group-by symbol` to decide which changes
/// can be collapsed under a parent fn/method record.
pub fn isStmtKind(k: ast.Kind) bool {
    return k == .rust_stmt or k == .go_stmt or k == .zig_stmt or
        k == .dart_stmt or k == .js_stmt or k == .ts_stmt;
}

fn anySignatureChange(metas: []const ChangeMeta) bool {
    for (metas) |m| if (m.kind_tag == .signature_change) return true;
    return false;
}

/// For each change tagged `.signature_change`, find statement-level
/// occurrences of the symbol name in tree B and stash them on the meta as
/// `Callsite{ path, line }` entries. Capped at 50 per change to bound
/// output size. The owned outer slice is freed by `renderReviewJson`'s
/// defer; `Callsite.path` borrows from `tree.path` and is not freed.
pub fn annotateCallsites(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    const a_idents = a.nodes.items(.identity_range);
    const b_idents = b.nodes.items(.identity_range);
    const max_per_change: usize = 50;
    for (set.changes.items, metas) |c, *m| {
        if (m.kind_tag != .signature_change) continue;
        // Pick the symbol name from whichever side has a node — prefer B.
        const name = if (c.b_idx) |bi| blk: {
            const r = b_idents[bi];
            break :blk b.source[r.start..r.end];
        } else if (c.a_idx) |ai| blk: {
            const r = a_idents[ai];
            break :blk a.source[r.start..r.end];
        } else continue;
        if (name.len == 0) continue;

        var sites: std.ArrayList(symbols.Callsite) = .empty;
        errdefer sites.deinit(gpa);
        try symbols.findCallsites(gpa, b, name, &sites);
        if (sites.items.len > max_per_change) sites.shrinkRetainingCapacity(max_per_change);
        m.callsites = try sites.toOwnedSlice(gpa);
    }
}

// -----------------------------------------------------------------------------
// Record rendering
// -----------------------------------------------------------------------------

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

fn kindStr(k: differ.ChangeKind) []const u8 {
    return differ.kindStr(k);
}

fn kindTagStr(t: KindTag) []const u8 {
    return switch (t) {
        .signature_change => "signature_change",
        .body_change => "body_change",
        .structural => "structural",
    };
}

fn writeParamObj(w: *std.Io.Writer, p: signature.Param) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, p.name);
    try w.writeAll(",\"type\":");
    try writeJsonString(w, p.type_str);
    try w.writeByte('}');
}

fn writeSignatureDiff(w: *std.Io.Writer, sd: SignatureDiff) !void {
    try w.writeAll(",\"signature_diff\":{\"params_added\":[");
    for (sd.params_added, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try writeParamObj(w, p);
    }
    try w.writeAll("],\"params_removed\":[");
    for (sd.params_removed, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try writeParamObj(w, p);
    }
    try w.writeAll("],\"params_changed\":[");
    for (sd.params_changed, 0..) |pc, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, pc.name);
        try w.writeAll(",\"from\":");
        try writeJsonString(w, pc.from);
        try w.writeAll(",\"to\":");
        try writeJsonString(w, pc.to);
        try w.writeByte('}');
    }
    try w.print("],\"return_changed\":{},\"visibility_changed\":{}", .{ sd.return_changed, sd.visibility_changed });
    try w.writeByte('}');
}

/// Write the record body up to but not including the closing `}\n`. Used
/// both by `writeRecord` (which then emits `}\n`) and by the `--group-by
/// symbol` path (which appends a `,"sub_changes":[...]` block before the
/// closing brace).
fn writeRecordPrefix(
    w: *std.Io.Writer,
    c: *const differ.Change,
    m: *const ChangeMeta,
    a: *ast.Tree,
    b: *ast.Tree,
) !void {
    try w.print("{{\"kind\":\"{s}\",\"change_id\":\"{x:0>16}\",", .{ kindStr(c.kind), m.change_id });
    try w.writeAll("\"scope\":");
    try writeJsonString(w, m.scope);
    try w.print(",\"kind_tag\":\"{s}\",\"is_exported\":{},\"lines_added\":{d},\"lines_removed\":{d}", .{
        kindTagStr(m.kind_tag), m.is_exported, m.lines_added, m.lines_removed,
    });
    {
        var iter = m.sensitivity_tags.iterator();
        var first = true;
        try w.writeAll(",\"sensitivity\":[");
        while (iter.next()) |t| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonString(w, t.name());
        }
        try w.writeByte(']');
    }
    if (m.signature_diff) |sd| {
        if (sd.hasAnyChange()) try writeSignatureDiff(w, sd);
    }
    if (m.complexity_delta) |cd| {
        try w.print(",\"complexity_delta\":{{\"stmt_a\":{d},\"stmt_b\":{d},\"delta\":{d},\"method\":\"{s}\"}}", .{ cd.stmt_a, cd.stmt_b, cd.delta, cd.method });
    }
    if (m.callsites.len > 0) {
        try w.writeAll(",\"callsites\":[");
        for (m.callsites, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"path\":");
            try writeJsonString(w, s.path);
            try w.print(",\"line\":{d}}}", .{s.line});
        }
        try w.writeByte(']');
    }
    if (c.a_idx) |ai| {
        const lc = a.lineCol(ai);
        try w.writeAll(",\"a\":{\"path\":");
        try writeJsonString(w, a.path);
        try w.print(",\"line\":{d},\"col\":{d},\"text\":", .{ lc.line, lc.col });
        try writeJsonString(w, a.contentSlice(ai));
        try w.writeByte('}');
    }
    if (c.b_idx) |bi| {
        const lc = b.lineCol(bi);
        try w.writeAll(",\"b\":{\"path\":");
        try writeJsonString(w, b.path);
        try w.print(",\"line\":{d},\"col\":{d},\"text\":", .{ lc.line, lc.col });
        try writeJsonString(w, b.contentSlice(bi));
        try w.writeByte('}');
    }
}

fn writeRecord(
    w: *std.Io.Writer,
    c: *const differ.Change,
    m: *const ChangeMeta,
    a: *ast.Tree,
    b: *ast.Tree,
) !void {
    try writeRecordPrefix(w, c, m, a, b);
    try w.writeAll("}\n");
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "review module compiles" {
    try std.testing.expect(SCHEMA_VERSION.len > 0);
}

test "annotateScope joins identity slices with '.'" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() {}\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { return }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer {
        for (metas) |m| if (m.scope.len > 0) gpa.free(m.scope);
        gpa.free(metas);
    }
    for (metas) |*m| m.* = .{};
    try annotateScope(gpa, &set, &a, &b, metas);

    // At least one meta should have a non-empty scope ending in "Foo".
    var found = false;
    for (metas) |m| {
        if (std.mem.endsWith(u8, m.scope, "Foo")) found = true;
    }
    try std.testing.expect(found);
}

test "annotateKindTag: same identity bytes = body_change" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { return 1 }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { return 2 }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};
    try annotateKindTag(&set, &a, &b, metas);

    const kinds_b = b.nodes.items(.kind);
    for (set.changes.items, metas) |c, m| {
        if (c.kind != .modified) continue;
        if (kinds_b[c.b_idx.?] == .go_fn) {
            try std.testing.expectEqual(KindTag.body_change, m.kind_tag);
        }
    }
}

test "annotateSignatureDelta: param added" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo(x int) {}\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo(x int, y string) {}\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer {
        for (metas) |m| {
            if (m.scope.len > 0) gpa.free(m.scope);
            if (m.signature_diff) |sd| {
                gpa.free(sd.params_added);
                gpa.free(sd.params_removed);
                gpa.free(sd.params_changed);
            }
        }
        gpa.free(metas);
    }
    for (metas) |*m| m.* = .{};
    try annotateSignatureDelta(gpa, &set, &a, &b, metas);

    var found = false;
    for (metas) |m| {
        if (m.signature_diff) |sd| {
            if (sd.params_added.len == 1 and std.mem.eql(u8, sd.params_added[0].name, "y")) {
                try std.testing.expectEqualStrings("string", sd.params_added[0].type_str);
                try std.testing.expectEqual(@as(usize, 0), sd.params_removed.len);
                try std.testing.expectEqual(@as(usize, 0), sd.params_changed.len);
                try std.testing.expect(!sd.return_changed);
                try std.testing.expect(!sd.visibility_changed);
                found = true;
            }
        }
    }
    try std.testing.expect(found);
}

test "annotateSignatureDelta: body-only change yields no signature_diff render" {
    // Same shape as body_only fixture: identical signature, body changes.
    // The annotation may run, but `hasAnyChange()` should be false.
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 1 }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 2 }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer {
        for (metas) |m| {
            if (m.scope.len > 0) gpa.free(m.scope);
            if (m.signature_diff) |sd| {
                gpa.free(sd.params_added);
                gpa.free(sd.params_removed);
                gpa.free(sd.params_changed);
            }
        }
        gpa.free(metas);
    }
    for (metas) |*m| m.* = .{};
    try annotateSignatureDelta(gpa, &set, &a, &b, metas);

    // Any signature_diff that exists must be empty (hasAnyChange == false).
    for (metas) |m| {
        if (m.signature_diff) |sd| try std.testing.expect(!sd.hasAnyChange());
    }
}

test "annotateChangeId is stable across runs" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { return 1 }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { return 2 }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    const m1 = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(m1);
    for (m1) |*m| m.* = .{};
    try annotateChangeId(&set, &a, &b, m1);

    const m2 = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(m2);
    for (m2) |*m| m.* = .{};
    try annotateChangeId(&set, &a, &b, m2);

    for (m1, m2) |x, y| try std.testing.expectEqual(x.change_id, y.change_id);
}

test "complexity_delta counts cyclomatic decision points" {
    const gpa = std.testing.allocator;
    // A is straight-line (cyclomatic = 1). B adds an `if`, bumping cyclomatic
    // to 2.
    var a = try go_parser.parse(gpa, "package main\nfunc Foo(x int) int { return x }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo(x int) int { if x < 0 { return 0 }; return x }\n", "b.go");
    defer b.deinit();

    // Skip suppressCascade so the fn-level `.modified` survives — the plan's
    // shipping pipeline runs suppressCascade and exposes only the descendant
    // stmt rows, so we exercise the fn-level annotation directly here.
    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};
    try annotateComplexity(gpa, &set, &a, &b, metas);

    var found = false;
    const kinds_b = b.nodes.items(.kind);
    for (set.changes.items, metas) |c, m| {
        if (c.kind != .modified) continue;
        const bi = c.b_idx orelse continue;
        if (kinds_b[bi] != .go_fn) continue;
        const cd = m.complexity_delta orelse continue;
        try std.testing.expectEqualStrings("cyclomatic", cd.method);
        try std.testing.expect(cd.delta > 0);
        try std.testing.expect(cd.stmt_b > cd.stmt_a);
        found = true;
    }
    try std.testing.expect(found);
}

test "annotateCallsites: signature change surfaces callers in tree B" {
    const gpa = std.testing.allocator;
    // A renames Add -> Sum, AND keeps a caller of the (post-rename) name.
    // After rename pairing, the rename row gets `signature_change`, and
    // annotateCallsites should find the call to `Sum(1,2)` in tree B.
    var a = try go_parser.parse(
        gpa,
        "package main\nfunc Add(a, b int) int { return a + b }\nfunc Run() { x := Add(1,2); _ = x }\n",
        "a.go",
    );
    defer a.deinit();
    var b = try go_parser.parse(
        gpa,
        "package main\nfunc Sum(a, b int) int { return a + b }\nfunc Run() { x := Sum(1,2); _ = x }\n",
        "b.go",
    );
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);
    try rename.pairRenames(gpa, &set, &a, &b);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer {
        for (metas) |m| {
            if (m.scope.len > 0) gpa.free(m.scope);
            if (m.signature_diff) |sd| {
                gpa.free(sd.params_added);
                gpa.free(sd.params_removed);
                gpa.free(sd.params_changed);
            }
            if (m.callsites.len > 0) gpa.free(m.callsites);
        }
        gpa.free(metas);
    }
    for (metas) |*m| m.* = .{};
    try annotateScope(gpa, &set, &a, &b, metas);
    try annotateKindTag(&set, &a, &b, metas);
    try annotateCallsites(gpa, &set, &a, &b, metas);

    // Find the renamed row and confirm at least one callsite was recorded.
    var found_callsite = false;
    for (metas) |m| {
        if (m.kind_tag != .signature_change) continue;
        if (m.callsites.len > 0) found_callsite = true;
    }
    try std.testing.expect(found_callsite);
}

test "Run with group_by_symbol nests stmt-level changes under parent fn" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var run = try Run.init(gpa, &aw.writer);
    defer run.deinit();
    run.group_by_symbol = true;

    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { a := 1; b := 2; _ = a + b }\n", "x.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { a := 9; b := 8; _ = a + b }\n", "x.go");
    defer b.deinit();
    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    // Intentionally skip `suppressCascade`: the shipping pipeline removes the
    // fn-level `.modified` row when its descendant stmts are also `.modified`,
    // which is the same redundancy `--group-by symbol` exists to express. To
    // exercise the grouping logic itself we need the fn-level row preserved
    // so its stmt children can attach to it.

    try run.recordChangedPath("x.go");
    try run.addFilePair(&a, &b, &set);
    try run.finish();

    const out = aw.writer.buffered();
    // With grouping, the two stmt changes should be nested under the
    // enclosing fn record as `sub_changes`, not top-level.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sub_changes\":[") != null);
}

test "Run without group_by_symbol does not emit sub_changes" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var run = try Run.init(gpa, &aw.writer);
    defer run.deinit();
    // Default: group_by_symbol = false.

    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { a := 1; b := 2; _ = a + b }\n", "x.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { a := 9; b := 8; _ = a + b }\n", "x.go");
    defer b.deinit();
    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    // Skip `suppressCascade` so we have both fn-level and stmt-level rows;
    // the grouping flag is what selects between flat and nested emission.

    try run.recordChangedPath("x.go");
    try run.addFilePair(&a, &b, &set);
    try run.finish();

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sub_changes\":[") == null);
}

test "ts_interface modification produces signature_change with diff" {
    const gpa = std.testing.allocator;

    var a = try ts_parser.parse(gpa, "interface Foo { name: string; }\n", "x.ts");
    defer a.deinit();
    var b = try ts_parser.parse(gpa, "interface Foo { name: string; age: number; }\n", "x.ts");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer {
        for (metas) |m| {
            if (m.scope.len > 0) gpa.free(m.scope);
            if (m.signature_diff) |sd| {
                gpa.free(sd.params_added);
                gpa.free(sd.params_removed);
                gpa.free(sd.params_changed);
            }
        }
        gpa.free(metas);
    }
    for (metas) |*m| m.* = .{};
    try annotateKindTag(&set, &a, &b, metas);
    try annotateSignatureDelta(gpa, &set, &a, &b, metas);

    var found = false;
    for (metas) |m| {
        if (m.kind_tag == .signature_change and
            m.signature_diff != null and
            m.signature_diff.?.params_added.len == 1)
        {
            try std.testing.expectEqualStrings("age", m.signature_diff.?.params_added[0].name);
            found = true;
        }
    }
    try std.testing.expect(found);
}
