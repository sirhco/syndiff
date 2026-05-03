//! Per-language signature extraction. Operates on a single Node — does NOT
//! re-tokenize or re-parse files. Each per-language sub-extractor uses byte
//! ranges (`content_range`, `identity_range`) plus a small ad-hoc tokenizer
//! over the content slice to pull out params and return type.
//!
//! Ownership: `Signature.params` is allocated with the caller's allocator
//! and MUST be freed by the caller (e.g. `gpa.free(sig.params)`). The
//! `name`, `type_str`, and `return_type` strings are all borrowed slices
//! into `tree.source` and have the lifetime of the Tree.

const std = @import("std");
const ast = @import("ast.zig");

pub const Param = struct {
    name: []const u8,
    type_str: []const u8,
    has_default: bool,
};

pub const Visibility = enum { private, public, protected, package };

pub const Modifiers = packed struct(u8) {
    is_async: bool = false,
    is_static: bool = false,
    is_const: bool = false,
    is_unsafe: bool = false,
    _pad: u4 = 0,
};

pub const Signature = struct {
    name: []const u8,
    params: []Param,
    return_type: ?[]const u8,
    visibility: Visibility,
    modifiers: Modifiers,
    /// Wyhash over name + concatenated param types + return type. Used by
    /// rename pairing in Tier 3.
    hash: u64,
};

/// Returns `null` for nodes that aren't fn/method-shaped (e.g. structs,
/// imports, statements). Each per-language extractor below dispatches on
/// `Node.kind`.
pub fn extract(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const kind = tree.nodes.items(.kind)[idx];
    return switch (kind) {
        .go_fn, .go_method => try extractGo(gpa, tree, idx),
        .rust_fn => try extractRust(gpa, tree, idx),
        .zig_fn => try extractZig(gpa, tree, idx),
        .dart_fn, .dart_method => try extractDart(gpa, tree, idx),
        .js_function, .js_method => try extractJs(gpa, tree, idx),
        else => null,
    };
}

// -----------------------------------------------------------------------------
// Shared helpers
// -----------------------------------------------------------------------------

/// Find balanced `)` matching the `(` at `paren_open`. Returns the index of
/// the close paren, or null if unbalanced.
fn findBalancedClose(slice: []const u8, paren_open: usize) ?usize {
    var depth: u32 = 0;
    var i: usize = paren_open;
    while (i < slice.len) : (i += 1) {
        switch (slice[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Iterate depth-0 comma-separated segments inside `slice[paren_open+1..paren_close]`.
/// Calls `cb` with each trimmed segment slice.
fn forEachDepth0Segment(
    slice: []const u8,
    paren_open: usize,
    paren_close: usize,
    ctx: anytype,
    cb: fn (ctx: anytype, seg: []const u8) anyerror!void,
) !void {
    if (paren_close <= paren_open + 1) return;
    var seg_start: usize = paren_open + 1;
    var d: u32 = 0;
    var k: usize = paren_open + 1;
    while (k < paren_close) : (k += 1) {
        const c = slice[k];
        switch (c) {
            '(', '[', '{', '<' => d += 1,
            ')', ']', '}', '>' => if (d > 0) {
                d -= 1;
            },
            ',' => if (d == 0) {
                try cb(ctx, slice[seg_start..k]);
                seg_start = k + 1;
            },
            else => {},
        }
    }
    // Final segment.
    try cb(ctx, slice[seg_start..paren_close]);
}

/// True when, after skipping whitespace and `#[...]` attributes starting at
/// `start`, the next non-trivia bytes are exactly `keyword`.
fn startsWithVisibility(src: []const u8, start: usize, keyword: []const u8) bool {
    var i: usize = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '#' and i + 1 < src.len and src[i + 1] == '[') {
            while (i < src.len and src[i] != ']') i += 1;
            if (i < src.len) i += 1;
            continue;
        }
        if (c == '@' and i + 1 < src.len and std.ascii.isAlphabetic(src[i + 1])) {
            // Annotations like `@override` (Dart) — skip identifier and any args.
            i += 1;
            while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
            if (i < src.len and src[i] == '(') {
                var depth: u32 = 0;
                while (i < src.len) : (i += 1) {
                    if (src[i] == '(') depth += 1;
                    if (src[i] == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
            }
            continue;
        }
        break;
    }
    return std.mem.startsWith(u8, src[i..], keyword);
}

// -----------------------------------------------------------------------------
// Go
// -----------------------------------------------------------------------------

fn extractGo(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const r = ranges[idx];
    const slice = tree.source[r.start..r.end];
    const name = tree.source[ident_ranges[idx].start..ident_ranges[idx].end];

    // identity_range is in absolute file coords; convert to slice coords.
    const name_end_in_slice: usize = @intCast(ident_ranges[idx].end - r.start);
    const paren_open = std.mem.indexOfScalarPos(u8, slice, name_end_in_slice, '(') orelse return null;
    const paren_close = findBalancedClose(slice, paren_open) orelse return null;

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    const Ctx = struct { gpa: std.mem.Allocator, list: *std.ArrayList(Param) };
    var ctx: Ctx = .{ .gpa = gpa, .list = &params };
    try forEachDepth0Segment(slice, paren_open, paren_close, &ctx, struct {
        fn cb(c: anytype, seg: []const u8) anyerror!void {
            try pushGoParam(c.gpa, c.list, seg);
        }
    }.cb);

    // Return type = trimmed slice between paren_close+1 and `{` (or EOL).
    var ret: ?[]const u8 = null;
    var post: usize = paren_close + 1;
    while (post < slice.len and (slice[post] == ' ' or slice[post] == '\t')) post += 1;
    if (post < slice.len and slice[post] != '{' and slice[post] != '\n') {
        const brace = std.mem.indexOfScalarPos(u8, slice, post, '{') orelse slice.len;
        const r_str = std.mem.trim(u8, slice[post..brace], " \t\n");
        if (r_str.len > 0) ret = r_str;
    }

    const visibility: Visibility = if (name.len > 0 and std.ascii.isUpper(name[0])) .public else .private;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);
    if (ret) |s| hasher.update(s);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = visibility,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushGoParam(gpa: std.mem.Allocator, list: *std.ArrayList(Param), seg: []const u8) !void {
    const trimmed = std.mem.trim(u8, seg, " \t\n");
    if (trimmed.len == 0) return;
    // Go params: "name type" or just "type" (anonymous). Split on last whitespace.
    var split: usize = trimmed.len;
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (trimmed[i] == ' ' or trimmed[i] == '\t') {
            split = i;
            break;
        }
    }
    if (split == trimmed.len) {
        try list.append(gpa, .{ .name = "", .type_str = trimmed, .has_default = false });
    } else {
        try list.append(gpa, .{
            .name = std.mem.trim(u8, trimmed[0..split], " \t"),
            .type_str = std.mem.trim(u8, trimmed[split + 1 ..], " \t"),
            .has_default = false,
        });
    }
}

// -----------------------------------------------------------------------------
// Rust
// -----------------------------------------------------------------------------

fn extractRust(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const r = ranges[idx];
    const slice = tree.source[r.start..r.end];
    const name = tree.source[ident_ranges[idx].start..ident_ranges[idx].end];

    const name_end_in_slice: usize = @intCast(ident_ranges[idx].end - r.start);
    const paren_open = std.mem.indexOfScalarPos(u8, slice, name_end_in_slice, '(') orelse return null;
    const paren_close = findBalancedClose(slice, paren_open) orelse return null;

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    const Ctx = struct { gpa: std.mem.Allocator, list: *std.ArrayList(Param) };
    var ctx: Ctx = .{ .gpa = gpa, .list = &params };
    try forEachDepth0Segment(slice, paren_open, paren_close, &ctx, struct {
        fn cb(c: anytype, seg: []const u8) anyerror!void {
            try pushColonParam(c.gpa, c.list, seg);
        }
    }.cb);

    // Return type = after `->` and before `{`/`where`/`;`.
    var ret: ?[]const u8 = null;
    if (std.mem.indexOfPos(u8, slice, paren_close + 1, "->")) |arrow| {
        var end: usize = slice.len;
        // Stop at `{` or `where` or `;`.
        if (std.mem.indexOfScalarPos(u8, slice, arrow + 2, '{')) |b| end = @min(end, b);
        if (std.mem.indexOfPos(u8, slice, arrow + 2, "where")) |w| end = @min(end, w);
        if (std.mem.indexOfScalarPos(u8, slice, arrow + 2, ';')) |s| end = @min(end, s);
        const r_str = std.mem.trim(u8, slice[arrow + 2 .. end], " \t\n");
        if (r_str.len > 0) ret = r_str;
    }

    const is_pub = startsWithVisibility(tree.source, r.start, "pub");
    const visibility: Visibility = if (is_pub) .public else .private;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);
    if (ret) |s| hasher.update(s);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = visibility,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

/// Push a param of the form `name: Type` (Rust, Zig).
fn pushColonParam(gpa: std.mem.Allocator, list: *std.ArrayList(Param), seg: []const u8) !void {
    const trimmed = std.mem.trim(u8, seg, " \t\n");
    if (trimmed.len == 0) return;
    // `self`, `&self`, `&mut self`, `mut self` — special Rust receivers, no type.
    if (std.mem.eql(u8, trimmed, "self") or
        std.mem.eql(u8, trimmed, "&self") or
        std.mem.eql(u8, trimmed, "&mut self") or
        std.mem.eql(u8, trimmed, "mut self"))
    {
        try list.append(gpa, .{ .name = "self", .type_str = "", .has_default = false });
        return;
    }
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
        // No colon: treat whole thing as type with no name.
        try list.append(gpa, .{ .name = "", .type_str = trimmed, .has_default = false });
        return;
    };
    const name_part = std.mem.trim(u8, trimmed[0..colon], " \t");
    const type_part = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\n");
    try list.append(gpa, .{ .name = name_part, .type_str = type_part, .has_default = false });
}

// -----------------------------------------------------------------------------
// Zig
// -----------------------------------------------------------------------------

fn extractZig(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const r = ranges[idx];
    const slice = tree.source[r.start..r.end];
    const name = tree.source[ident_ranges[idx].start..ident_ranges[idx].end];

    const name_end_in_slice: usize = @intCast(ident_ranges[idx].end - r.start);
    const paren_open = std.mem.indexOfScalarPos(u8, slice, name_end_in_slice, '(') orelse return null;
    const paren_close = findBalancedClose(slice, paren_open) orelse return null;

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    const Ctx = struct { gpa: std.mem.Allocator, list: *std.ArrayList(Param) };
    var ctx: Ctx = .{ .gpa = gpa, .list = &params };
    try forEachDepth0Segment(slice, paren_open, paren_close, &ctx, struct {
        fn cb(c: anytype, seg: []const u8) anyerror!void {
            try pushColonParam(c.gpa, c.list, seg);
        }
    }.cb);

    // Zig: return type is between `)` and `{` (no `->`). May include `!Error`.
    var ret: ?[]const u8 = null;
    var post: usize = paren_close + 1;
    while (post < slice.len and (slice[post] == ' ' or slice[post] == '\t')) post += 1;
    if (post < slice.len and slice[post] != '{') {
        const brace = std.mem.indexOfScalarPos(u8, slice, post, '{') orelse slice.len;
        const r_str = std.mem.trim(u8, slice[post..brace], " \t\n");
        if (r_str.len > 0) ret = r_str;
    }

    const is_pub = startsWithVisibility(tree.source, r.start, "pub");
    const visibility: Visibility = if (is_pub) .public else .private;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);
    if (ret) |s| hasher.update(s);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = visibility,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

// -----------------------------------------------------------------------------
// Dart
// -----------------------------------------------------------------------------

fn extractDart(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const r = ranges[idx];
    const slice = tree.source[r.start..r.end];
    const name = tree.source[ident_ranges[idx].start..ident_ranges[idx].end];

    const name_end_in_slice: usize = @intCast(ident_ranges[idx].end - r.start);
    const paren_open = std.mem.indexOfScalarPos(u8, slice, name_end_in_slice, '(') orelse return null;
    const paren_close = findBalancedClose(slice, paren_open) orelse return null;

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    const Ctx = struct { gpa: std.mem.Allocator, list: *std.ArrayList(Param) };
    var ctx: Ctx = .{ .gpa = gpa, .list = &params };
    try forEachDepth0Segment(slice, paren_open, paren_close, &ctx, struct {
        fn cb(c: anytype, seg: []const u8) anyerror!void {
            try pushDartParam(c.gpa, c.list, seg);
        }
    }.cb);

    // Return type: tokens before the name, skipping modifiers.
    const name_start_in_slice: usize = @intCast(ident_ranges[idx].start - r.start);
    var ret: ?[]const u8 = null;
    if (name_start_in_slice > 0) {
        const before = std.mem.trim(u8, slice[0..name_start_in_slice], " \t\n");
        // Skip leading modifiers.
        const skip_words = [_][]const u8{ "static", "const", "final", "external", "abstract", "factory" };
        var rest = before;
        outer: while (true) {
            const trim = std.mem.trim(u8, rest, " \t\n");
            for (skip_words) |sw| {
                if (std.mem.startsWith(u8, trim, sw)) {
                    const after = trim[sw.len..];
                    if (after.len == 0 or after[0] == ' ' or after[0] == '\t') {
                        rest = after;
                        continue :outer;
                    }
                }
            }
            rest = trim;
            break;
        }
        const trimmed = std.mem.trim(u8, rest, " \t\n");
        if (trimmed.len > 0) ret = trimmed;
    }

    // Dart visibility: leading underscore → private, else public.
    const visibility: Visibility = if (name.len > 0 and name[0] == '_') .private else .public;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);
    if (ret) |s| hasher.update(s);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = visibility,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushDartParam(gpa: std.mem.Allocator, list: *std.ArrayList(Param), seg: []const u8) !void {
    var trimmed = std.mem.trim(u8, seg, " \t\n");
    if (trimmed.len == 0) return;
    // Strip leading `[`/`{` for optional/named params; trailing `]`/`}` likewise.
    if (trimmed[0] == '[' or trimmed[0] == '{') trimmed = std.mem.trim(u8, trimmed[1..], " \t\n");
    if (trimmed.len > 0 and (trimmed[trimmed.len - 1] == ']' or trimmed[trimmed.len - 1] == '}'))
        trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\n");
    if (trimmed.len == 0) return;

    // Strip default: "Type name = value".
    var has_default = false;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
        has_default = true;
        trimmed = std.mem.trim(u8, trimmed[0..eq], " \t\n");
    }

    // Dart: "Type name". Split on last whitespace at depth 0 of `<>`.
    var split: ?usize = null;
    var depth: u32 = 0;
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        const c = trimmed[i];
        if (c == '>') depth += 1;
        if (c == '<' and depth > 0) depth -= 1;
        if (depth == 0 and (c == ' ' or c == '\t')) {
            split = i;
            break;
        }
    }
    if (split) |s| {
        try list.append(gpa, .{
            .name = std.mem.trim(u8, trimmed[s + 1 ..], " \t"),
            .type_str = std.mem.trim(u8, trimmed[0..s], " \t"),
            .has_default = has_default,
        });
    } else {
        // Just a name (untyped).
        try list.append(gpa, .{ .name = trimmed, .type_str = "", .has_default = has_default });
    }
}

// -----------------------------------------------------------------------------
// JavaScript
// -----------------------------------------------------------------------------

fn extractJs(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const r = ranges[idx];
    const slice = tree.source[r.start..r.end];
    const name = tree.source[ident_ranges[idx].start..ident_ranges[idx].end];

    const name_end_in_slice: usize = @intCast(ident_ranges[idx].end - r.start);
    const paren_open = std.mem.indexOfScalarPos(u8, slice, name_end_in_slice, '(') orelse return null;
    const paren_close = findBalancedClose(slice, paren_open) orelse return null;

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    const Ctx = struct { gpa: std.mem.Allocator, list: *std.ArrayList(Param) };
    var ctx: Ctx = .{ .gpa = gpa, .list = &params };
    try forEachDepth0Segment(slice, paren_open, paren_close, &ctx, struct {
        fn cb(c: anytype, seg: []const u8) anyerror!void {
            try pushJsParam(c.gpa, c.list, seg);
        }
    }.cb);

    // JS has no return type annotation (TS would, but TS is out of scope).
    const ret: ?[]const u8 = null;

    // Visibility: JS exports are tracked by `is_exported` on the Node, but
    // there's no stable visibility-from-source check that matches the
    // private/public/package enum. Default to .package.
    const visibility: Visibility = .package;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = visibility,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushJsParam(gpa: std.mem.Allocator, list: *std.ArrayList(Param), seg: []const u8) !void {
    var trimmed = std.mem.trim(u8, seg, " \t\n");
    if (trimmed.len == 0) return;
    var has_default = false;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
        has_default = true;
        trimmed = std.mem.trim(u8, trimmed[0..eq], " \t\n");
    }
    // Strip leading `...` (rest param).
    if (std.mem.startsWith(u8, trimmed, "...")) trimmed = trimmed[3..];
    try list.append(gpa, .{ .name = trimmed, .type_str = "", .has_default = has_default });
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const json_parser = @import("json_parser.zig");
const go_parser = @import("go_parser.zig");
const rust_parser = @import("rust_parser.zig");
const zig_parser = @import("zig_parser.zig");
const dart_parser = @import("dart_parser.zig");
const js_parser = @import("js_parser.zig");

test "extract returns null for non-fn kinds" {
    const gpa = std.testing.allocator;
    var tree = try json_parser.parse(gpa, "{\"k\":1}", "x.json");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    // Find any non-fn kind (json_object/json_member/etc.).
    var found_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| {
        switch (k) {
            .go_fn, .go_method, .rust_fn, .zig_fn, .dart_fn, .dart_method, .js_function, .js_method => {},
            else => {
                found_idx = @intCast(i);
                break;
            },
        }
    }
    try std.testing.expect(found_idx != null);
    const sig = try extract(gpa, &tree, found_idx.?);
    try std.testing.expect(sig == null);
}

test "extractGo: simple fn with params and return type" {
    const gpa = std.testing.allocator;
    var tree = try go_parser.parse(gpa, "package main\nfunc Add(a int, b int) int { return a + b }\n", "x.go");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .go_fn) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);

    const sig = (try extract(gpa, &tree, fn_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Add", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("a", sig.params[0].name);
    try std.testing.expectEqualStrings("int", sig.params[0].type_str);
    try std.testing.expectEqualStrings("b", sig.params[1].name);
    try std.testing.expectEqualStrings("int", sig.params[1].type_str);
    try std.testing.expect(sig.return_type != null);
    try std.testing.expectEqualStrings("int", sig.return_type.?);
    try std.testing.expectEqual(Visibility.public, sig.visibility);
}

test "extractGo: lowercase name → private" {
    const gpa = std.testing.allocator;
    var tree = try go_parser.parse(gpa, "package main\nfunc add(a int) {}\n", "x.go");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .go_fn) {
        fn_idx = @intCast(i);
        break;
    };

    const sig = (try extract(gpa, &tree, fn_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);
    try std.testing.expectEqual(Visibility.private, sig.visibility);
    try std.testing.expect(sig.return_type == null);
}

test "extractRust: pub fn with typed params and return" {
    const gpa = std.testing.allocator;
    var tree = try rust_parser.parse(gpa, "pub fn add(a: i32, b: i32) -> i32 { 0 }", "x.rs");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .rust_fn) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);

    const sig = (try extract(gpa, &tree, fn_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("add", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("a", sig.params[0].name);
    try std.testing.expectEqualStrings("i32", sig.params[0].type_str);
    try std.testing.expectEqualStrings("b", sig.params[1].name);
    try std.testing.expectEqualStrings("i32", sig.params[1].type_str);
    try std.testing.expect(sig.return_type != null);
    try std.testing.expectEqualStrings("i32", sig.return_type.?);
    try std.testing.expectEqual(Visibility.public, sig.visibility);
}

test "extractZig: pub fn with params and return" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "pub fn add(a: u32, b: u32) u32 { return 0; }";
    var tree = try zig_parser.parse(gpa, src, "x.zig");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .zig_fn) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);

    const sig = (try extract(gpa, &tree, fn_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("add", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("a", sig.params[0].name);
    try std.testing.expectEqualStrings("u32", sig.params[0].type_str);
    try std.testing.expectEqualStrings("b", sig.params[1].name);
    try std.testing.expectEqualStrings("u32", sig.params[1].type_str);
    try std.testing.expect(sig.return_type != null);
    try std.testing.expectEqualStrings("u32", sig.return_type.?);
    try std.testing.expectEqual(Visibility.public, sig.visibility);
}

test "extractDart: typed params and return type" {
    const gpa = std.testing.allocator;
    var tree = try dart_parser.parse(gpa, "int add(int a, int b) => a + b;\n", "x.dart");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .dart_fn) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);

    const sig = (try extract(gpa, &tree, fn_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("add", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("a", sig.params[0].name);
    try std.testing.expectEqualStrings("int", sig.params[0].type_str);
    try std.testing.expectEqualStrings("b", sig.params[1].name);
    try std.testing.expectEqualStrings("int", sig.params[1].type_str);
    try std.testing.expect(sig.return_type != null);
    try std.testing.expectEqualStrings("int", sig.return_type.?);
}

test "extractJs: untyped params, no return type" {
    const gpa = std.testing.allocator;
    var tree = try js_parser.parse(gpa, "function add(a, b) { return a + b; }\n", "x.js");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .js_function) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);

    const sig = (try extract(gpa, &tree, fn_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("add", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("a", sig.params[0].name);
    try std.testing.expectEqualStrings("", sig.params[0].type_str);
    try std.testing.expectEqualStrings("b", sig.params[1].name);
    try std.testing.expectEqualStrings("", sig.params[1].type_str);
    try std.testing.expect(sig.return_type == null);
}
