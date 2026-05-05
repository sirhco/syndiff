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
        .ts_interface => try extractTsInterface(gpa, tree, idx),
        .ts_type => try extractTsType(gpa, tree, idx),
        .ts_enum => try extractTsEnum(gpa, tree, idx),
        .java_method, .java_constructor => try extractJava(gpa, tree, idx),
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
// Java
// -----------------------------------------------------------------------------

fn extractJava(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const kinds = tree.nodes.items(.kind);
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
            try pushJavaParam(c.gpa, c.list, seg);
        }
    }.cb);

    // Return type: the trimmed slice between the last modifier/annotation/
    // generic parameter and the method name. Constructors have none.
    var ret: ?[]const u8 = null;
    if (kinds[idx] == .java_method) {
        const name_start_in_slice: usize = @intCast(ident_ranges[idx].start - r.start);
        if (name_start_in_slice > 0) {
            const before = slice[0..name_start_in_slice];
            ret = trimJavaReturnType(before);
        }
    }

    // Visibility: leading `public/private/protected` keyword (after annotations).
    const vis = visibilityJava(slice, name_end_in_slice);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);
    if (ret) |s| hasher.update(s);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = vis,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushJavaParam(gpa: std.mem.Allocator, list: *std.ArrayList(Param), seg: []const u8) !void {
    var trimmed = std.mem.trim(u8, seg, " \t\n\r");
    if (trimmed.len == 0) return;
    // Strip leading annotations like `@Nullable Foo bar`.
    while (trimmed.len > 0 and trimmed[0] == '@') {
        // Skip @ + ident + optional balanced (...).
        var i: usize = 1;
        while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '_' or trimmed[i] == '.')) i += 1;
        if (i < trimmed.len and trimmed[i] == '(') {
            var depth: u32 = 1;
            i += 1;
            while (i < trimmed.len and depth > 0) : (i += 1) {
                if (trimmed[i] == '(') depth += 1;
                if (trimmed[i] == ')') depth -= 1;
            }
        }
        trimmed = std.mem.trim(u8, trimmed[i..], " \t\n\r");
    }
    // Strip leading `final`.
    if (std.mem.startsWith(u8, trimmed, "final") and trimmed.len > 5 and (trimmed[5] == ' ' or trimmed[5] == '\t')) {
        trimmed = std.mem.trim(u8, trimmed[5..], " \t\n\r");
    }
    if (trimmed.len == 0) return;

    // Java is "Type name". Split on last whitespace at depth 0 of `<>`/`[]`.
    var split: ?usize = null;
    var depth_a: u32 = 0;
    var depth_s: u32 = 0;
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        const c = trimmed[i];
        if (c == '>') depth_a += 1;
        if (c == '<' and depth_a > 0) depth_a -= 1;
        if (c == ']') depth_s += 1;
        if (c == '[' and depth_s > 0) depth_s -= 1;
        if (depth_a == 0 and depth_s == 0 and (c == ' ' or c == '\t' or c == '\n')) {
            split = i;
            break;
        }
    }
    if (split) |s| {
        const name_part = std.mem.trim(u8, trimmed[s + 1 ..], " \t\n\r");
        const type_part = std.mem.trim(u8, trimmed[0..s], " \t\n\r");
        try list.append(gpa, .{ .name = name_part, .type_str = type_part, .has_default = false });
    } else {
        try list.append(gpa, .{ .name = "", .type_str = trimmed, .has_default = false });
    }
}

/// Walk the slice that sits before the method name. Skip annotations,
/// modifiers, and a leading generic `<...>` block; return the remaining
/// trimmed return-type substring.
fn trimJavaReturnType(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    var ret_start: usize = 0;
    var ret_end: usize = 0;
    while (i < s.len) {
        // Skip whitespace.
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
        if (i >= s.len) break;
        const c = s[i];
        // Annotation `@Foo(...)`
        if (c == '@') {
            i += 1;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.')) i += 1;
            if (i < s.len and s[i] == '(') {
                var depth: u32 = 1;
                i += 1;
                while (i < s.len and depth > 0) : (i += 1) {
                    if (s[i] == '(') depth += 1;
                    if (s[i] == ')') depth -= 1;
                }
            }
            continue;
        }
        // Generic `<T,...>` — only a leading method-level type parameter list,
        // not part of return type. Detect by: it's the first non-modifier/
        // non-annotation token. If we've already started building return type,
        // this `<` is part of the type and stays.
        if (c == '<' and ret_end == ret_start) {
            var depth: u32 = 1;
            i += 1;
            while (i < s.len and depth > 0) : (i += 1) {
                if (s[i] == '<') depth += 1;
                if (s[i] == '>') depth -= 1;
            }
            continue;
        }
        // Identifier: could be modifier or part of type.
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            i += 1;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
            const word = s[start..i];
            if (isJavaModifier(word)) continue;
            // Part of return type.
            if (ret_start == ret_end) ret_start = start;
            ret_end = i;
            // Continue — type may include further `.`, `<...>`, `[]`, etc.
            continue;
        }
        // `.`, `<`, `[`, `]`, `>` — part of type if we've started one.
        if (c == '.' or c == '[' or c == ']' or c == '<' or c == '>' or c == '?' or c == ',') {
            if (ret_end > ret_start) {
                if (c == '<' or c == '[') {
                    const open: u8 = c;
                    const close: u8 = if (c == '<') '>' else ']';
                    var depth: u32 = 1;
                    i += 1;
                    while (i < s.len and depth > 0) : (i += 1) {
                        if (s[i] == open) depth += 1;
                        if (s[i] == close) depth -= 1;
                    }
                    ret_end = i;
                    continue;
                }
                i += 1;
                ret_end = i;
                continue;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    if (ret_end > ret_start) {
        return std.mem.trim(u8, s[ret_start..ret_end], " \t\n\r");
    }
    return null;
}

fn isJavaModifier(w: []const u8) bool {
    const mods = [_][]const u8{
        "public",     "private",    "protected", "static",
        "final",      "abstract",   "sealed",    "default",
        "synchronized", "native",   "strictfp",  "volatile",
        "transient",
    };
    for (mods) |m| if (std.mem.eql(u8, w, m)) return true;
    return false;
}

fn visibilityJava(slice: []const u8, name_end_in_slice: usize) Visibility {
    // Walk the prefix before the name; stop at the name's start.
    const prefix = if (name_end_in_slice <= slice.len) slice[0..name_end_in_slice] else slice;
    var i: usize = 0;
    while (i < prefix.len) {
        // Skip whitespace.
        while (i < prefix.len and (prefix[i] == ' ' or prefix[i] == '\t' or prefix[i] == '\n' or prefix[i] == '\r')) i += 1;
        if (i >= prefix.len) break;
        const c = prefix[i];
        if (c == '@') {
            i += 1;
            while (i < prefix.len and (std.ascii.isAlphanumeric(prefix[i]) or prefix[i] == '_' or prefix[i] == '.')) i += 1;
            if (i < prefix.len and prefix[i] == '(') {
                var depth: u32 = 1;
                i += 1;
                while (i < prefix.len and depth > 0) : (i += 1) {
                    if (prefix[i] == '(') depth += 1;
                    if (prefix[i] == ')') depth -= 1;
                }
            }
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            i += 1;
            while (i < prefix.len and (std.ascii.isAlphanumeric(prefix[i]) or prefix[i] == '_')) i += 1;
            const word = prefix[start..i];
            if (std.mem.eql(u8, word, "public")) return .public;
            if (std.mem.eql(u8, word, "private")) return .private;
            if (std.mem.eql(u8, word, "protected")) return .protected;
            // Other modifiers continue.
            continue;
        }
        i += 1;
    }
    return .package;
}

// -----------------------------------------------------------------------------
// TypeScript
// -----------------------------------------------------------------------------

fn extractTsInterface(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const content_ranges = tree.nodes.items(.content_range);
    const identity_ranges = tree.nodes.items(.identity_range);
    const cr = content_ranges[idx];
    const ir = identity_ranges[idx];
    const src = tree.source[cr.start..cr.end];
    const name = tree.source[ir.start..ir.end];

    // Members live between the first `{` and the matching `}` at depth 0.
    const open_brace = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    const close_brace = findBalancedCloseBrace(src, open_brace) orelse return null;
    const body = src[open_brace + 1 .. close_brace];

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    // Iterate `;`-separated members at depth 0.
    var seg_start: usize = 0;
    var paren: u32 = 0;
    var brace: u32 = 0;
    var angle: u32 = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '(' => paren += 1,
            ')' => paren -|= 1,
            '{' => brace += 1,
            '}' => brace -|= 1,
            '<' => angle += 1,
            '>' => angle -|= 1,
            ';' => if (paren == 0 and brace == 0 and angle == 0) {
                try pushInterfaceMember(gpa, &params, body[seg_start..i]);
                seg_start = i + 1;
            },
            else => {},
        }
    }
    try pushInterfaceMember(gpa, &params, body[seg_start..]);

    const params_slice = try params.toOwnedSlice(gpa);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params_slice) |p| hasher.update(p.type_str);

    return .{
        .name = name,
        .params = params_slice,
        .return_type = null,
        .visibility = .public,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushInterfaceMember(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Param),
    seg: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, seg, " \t\r\n");
    if (trimmed.len == 0) return;
    // Skip method-style members (those carrying a `(` are not properties).
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return;
    const raw_name = std.mem.trim(u8, trimmed[0..colon], " \t");
    const has_default = raw_name.len > 0 and raw_name[raw_name.len - 1] == '?';
    const member_name = if (has_default) std.mem.trim(u8, raw_name[0 .. raw_name.len - 1], " \t") else raw_name;
    const member_type = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    try list.append(gpa, .{
        .name = member_name,
        .type_str = member_type,
        .has_default = has_default,
    });
}

fn extractTsType(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const content_ranges = tree.nodes.items(.content_range);
    const identity_ranges = tree.nodes.items(.identity_range);
    const cr = content_ranges[idx];
    const ir = identity_ranges[idx];
    const src = tree.source[cr.start..cr.end];
    const name = tree.source[ir.start..ir.end];

    // RHS lives after the first `=` at depth 0, before the trailing `;`.
    const eq = std.mem.indexOfScalar(u8, src, '=') orelse return null;
    var rhs_end = src.len;
    if (rhs_end > 0 and src[rhs_end - 1] == ';') rhs_end -= 1;
    const rhs = std.mem.trim(u8, src[eq + 1 .. rhs_end], " \t\r\n");

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    // Split on `|` at brace/paren/angle depth 0.
    var seg_start: usize = 0;
    var paren: u32 = 0;
    var brace: u32 = 0;
    var angle: u32 = 0;
    var i: usize = 0;
    while (i < rhs.len) : (i += 1) {
        switch (rhs[i]) {
            '(' => paren += 1,
            ')' => paren -|= 1,
            '{' => brace += 1,
            '}' => brace -|= 1,
            '<' => angle += 1,
            '>' => angle -|= 1,
            '|' => if (paren == 0 and brace == 0 and angle == 0) {
                const seg = std.mem.trim(u8, rhs[seg_start..i], " \t\r\n");
                if (seg.len > 0) try params.append(gpa, .{
                    .name = seg,
                    .type_str = "",
                    .has_default = false,
                });
                seg_start = i + 1;
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, rhs[seg_start..], " \t\r\n");
    if (tail.len > 0) try params.append(gpa, .{
        .name = tail,
        .type_str = "",
        .has_default = false,
    });

    const params_slice = try params.toOwnedSlice(gpa);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params_slice) |p| hasher.update(p.type_str);

    return .{
        .name = name,
        .params = params_slice,
        .return_type = null,
        .visibility = .public,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn extractTsEnum(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const content_ranges = tree.nodes.items(.content_range);
    const identity_ranges = tree.nodes.items(.identity_range);
    const cr = content_ranges[idx];
    const ir = identity_ranges[idx];
    const src = tree.source[cr.start..cr.end];
    const name = tree.source[ir.start..ir.end];

    const open_brace = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    const close_brace = findBalancedCloseBrace(src, open_brace) orelse return null;
    const body = src[open_brace + 1 .. close_brace];

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    var seg_start: usize = 0;
    var paren: u32 = 0;
    var brace: u32 = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '(' => paren += 1,
            ')' => paren -|= 1,
            '{' => brace += 1,
            '}' => brace -|= 1,
            ',' => if (paren == 0 and brace == 0) {
                try pushEnumVariant(gpa, &params, body[seg_start..i]);
                seg_start = i + 1;
            },
            else => {},
        }
    }
    try pushEnumVariant(gpa, &params, body[seg_start..]);

    const params_slice = try params.toOwnedSlice(gpa);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params_slice) |p| hasher.update(p.type_str);

    return .{
        .name = name,
        .params = params_slice,
        .return_type = null,
        .visibility = .public,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushEnumVariant(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Param),
    seg: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, seg, " \t\r\n");
    if (trimmed.len == 0) return;
    const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=');
    const variant_name = if (eq_idx) |e| std.mem.trim(u8, trimmed[0..e], " \t") else trimmed;
    try list.append(gpa, .{
        .name = variant_name,
        .type_str = "",
        .has_default = eq_idx != null,
    });
}

fn findBalancedCloseBrace(slice: []const u8, brace_open: usize) ?usize {
    var depth: u32 = 0;
    var i: usize = brace_open;
    while (i < slice.len) : (i += 1) {
        switch (slice[i]) {
            '{' => depth += 1,
            '}' => if (depth > 0) {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
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

test "extractTsInterface: single property" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(gpa, "interface Foo { name: string; }\n", "x.ts");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var iface_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_interface) {
        iface_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, iface_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Foo", sig.name);
    try std.testing.expectEqual(@as(usize, 1), sig.params.len);
    try std.testing.expectEqualStrings("name", sig.params[0].name);
    try std.testing.expectEqualStrings("string", sig.params[0].type_str);
    try std.testing.expectEqual(false, sig.params[0].has_default);
    try std.testing.expect(sig.return_type == null);
    try std.testing.expectEqual(Visibility.public, sig.visibility);
}

test "extractTsInterface: optional and method members" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "interface Foo { id: number; nick?: string; greet(): void; }\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var iface_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_interface) {
        iface_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, iface_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    // greet() is a method — Phase 1 skips methods, leaves only properties.
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("id", sig.params[0].name);
    try std.testing.expectEqualStrings("number", sig.params[0].type_str);
    try std.testing.expectEqual(false, sig.params[0].has_default);
    try std.testing.expectEqualStrings("nick", sig.params[1].name);
    try std.testing.expectEqualStrings("string", sig.params[1].type_str);
    try std.testing.expectEqual(true, sig.params[1].has_default);
}

test "extractTsType: union variants become params" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "type Color = \"red\" | \"green\" | \"blue\";\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var t_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_type) {
        t_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, t_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Color", sig.name);
    try std.testing.expectEqual(@as(usize, 3), sig.params.len);
    try std.testing.expectEqualStrings("\"red\"", sig.params[0].name);
    try std.testing.expectEqualStrings("\"green\"", sig.params[1].name);
    try std.testing.expectEqualStrings("\"blue\"", sig.params[2].name);
}

test "extractTsType: single-RHS yields one param" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "type Id = number;\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var t_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_type) {
        t_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, t_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Id", sig.name);
    try std.testing.expectEqual(@as(usize, 1), sig.params.len);
    try std.testing.expectEqualStrings("number", sig.params[0].name);
}

test "extractTsEnum: variants become params" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "enum Status { Active, Disabled, Pending = 99 }\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var e_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_enum) {
        e_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, e_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Status", sig.name);
    try std.testing.expectEqual(@as(usize, 3), sig.params.len);
    try std.testing.expectEqualStrings("Active", sig.params[0].name);
    try std.testing.expectEqual(false, sig.params[0].has_default);
    try std.testing.expectEqualStrings("Disabled", sig.params[1].name);
    try std.testing.expectEqualStrings("Pending", sig.params[2].name);
    try std.testing.expectEqual(true, sig.params[2].has_default);
}
