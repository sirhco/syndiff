//! Recursive-descent JSON parser populating an `ast.Tree`.
//!
//! Standard-library only. Hand-rolled (rather than wrapping std.json.Scanner)
//! so we maintain exact byte ranges and post-order push of nodes.
//!
//! Layout invariants produced:
//!   - Children are pushed before their parent (post-order).
//!   - Root node is the LAST node in the array.
//!   - parent_idx is backpatched after the parent is pushed.
//!   - Subtree hash is computed bottom-up during parse.
//!   - Identity hash composes parent identity + kind + identity bytes (key for
//!     members, decimal index for array elements via parent_identity).

const std = @import("std");
const ast = @import("ast.zig");
const hash_mod = @import("hash.zig");

const NodeIndex = ast.NodeIndex;
const Range = ast.Range;
const Kind = ast.Kind;
const ROOT_PARENT = ast.ROOT_PARENT;

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedChar,
    InvalidLiteral,
    InvalidNumber,
    InvalidString,
    TrailingContent,
    DepthExceeded,
} || std.mem.Allocator.Error;

const MAX_DEPTH: u16 = 256;

const ChildResult = struct {
    idx: NodeIndex,
    hash: u64,
};

const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: u32,
    tree: *ast.Tree,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.pos >= self.src.len) return error.UnexpectedEof;
        if (self.src[self.pos] != c) return error.UnexpectedChar;
        self.pos += 1;
    }

    /// Patch parent_idx of a node already in the tree.
    fn setParent(self: *Parser, child: NodeIndex, parent: NodeIndex) void {
        const parents = self.tree.nodes.items(.parent_idx);
        parents[child] = parent;
    }

    fn parseValue(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        if (depth >= MAX_DEPTH) return error.DepthExceeded;
        self.skipWhitespace();
        const c = self.peek() orelse return error.UnexpectedEof;
        return switch (c) {
            '{' => try self.parseObject(parent_identity, depth),
            '[' => try self.parseArray(parent_identity, depth),
            '"' => try self.parseString(parent_identity, depth),
            't', 'f' => try self.parseBool(parent_identity, depth),
            'n' => try self.parseNull(parent_identity, depth),
            '-', '0'...'9' => try self.parseNumber(parent_identity, depth),
            else => error.UnexpectedChar,
        };
    }

    fn parseObject(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        try self.expect('{');

        const self_identity = hash_mod.identityHash(parent_identity, .json_object, "");

        var member_indices: std.ArrayList(NodeIndex) = .empty;
        defer member_indices.deinit(self.gpa);
        var member_hashes: std.ArrayList(u64) = .empty;
        defer member_hashes.deinit(self.gpa);

        self.skipWhitespace();
        if (self.peek() != @as(u8, '}')) {
            while (true) {
                self.skipWhitespace();
                const m = try self.parseMember(self_identity, depth + 1);
                try member_indices.append(self.gpa, m.idx);
                try member_hashes.append(self.gpa, m.hash);
                self.skipWhitespace();
                const nc = self.peek() orelse return error.UnexpectedEof;
                if (nc == ',') {
                    self.pos += 1;
                    continue;
                }
                if (nc == '}') break;
                return error.UnexpectedChar;
            }
        }
        try self.expect('}');
        const end = self.pos;

        const subtree_h = hash_mod.subtreeHash(.json_object, member_hashes.items, "");

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .json_object,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = Range.empty,
            .is_exported = false,
        });

        for (member_indices.items) |m_idx| self.setParent(m_idx, idx);

        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseMember(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        const key_range = try self.scanStringRange();
        const key_bytes = self.src[key_range.start..key_range.end];

        self.skipWhitespace();
        try self.expect(':');

        const self_identity = hash_mod.identityHash(parent_identity, .json_member, key_bytes);

        self.skipWhitespace();
        const value = try self.parseValue(self_identity, depth + 1);

        const end = self.pos;

        const child_hashes = [_]u64{value.hash};
        const subtree_h = hash_mod.subtreeHash(.json_member, &child_hashes, key_bytes);

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, key_bytes),
            .kind = .json_member,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = key_range,
            .is_exported = false,
        });

        self.setParent(value.idx, idx);

        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseArray(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        try self.expect('[');

        const self_identity = hash_mod.identityHash(parent_identity, .json_array, "");

        var elem_indices: std.ArrayList(NodeIndex) = .empty;
        defer elem_indices.deinit(self.gpa);
        var elem_hashes: std.ArrayList(u64) = .empty;
        defer elem_hashes.deinit(self.gpa);

        self.skipWhitespace();
        if (self.peek() != @as(u8, ']')) {
            var index: u32 = 0;
            while (true) : (index += 1) {
                self.skipWhitespace();

                // Synthesize per-element parent identity carrying the index, so
                // each element's identity_hash differs by position.
                var idx_buf: [16]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch unreachable;
                const elem_parent_id = hash_mod.identityHash(self_identity, .json_array, idx_str);

                const e = try self.parseValue(elem_parent_id, depth + 1);
                try elem_indices.append(self.gpa, e.idx);
                try elem_hashes.append(self.gpa, e.hash);

                self.skipWhitespace();
                const nc = self.peek() orelse return error.UnexpectedEof;
                if (nc == ',') {
                    self.pos += 1;
                    continue;
                }
                if (nc == ']') break;
                return error.UnexpectedChar;
            }
        }
        try self.expect(']');
        const end = self.pos;

        const subtree_h = hash_mod.subtreeHash(.json_array, elem_hashes.items, "");

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .json_array,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = Range.empty,
            .is_exported = false,
        });

        for (elem_indices.items) |e_idx| self.setParent(e_idx, idx);

        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseString(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        const inner = try self.scanStringRange();
        const end = self.pos;

        const self_identity = hash_mod.identityHash(parent_identity, .json_string, "");
        const value_bytes = self.src[inner.start..inner.end];
        const subtree_h = hash_mod.subtreeHash(.json_string, &.{}, value_bytes);

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .json_string,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        return .{ .idx = idx, .hash = subtree_h };
    }

    /// Returns the byte range BETWEEN the quotes (key/value content).
    /// Advances `pos` past the closing quote.
    fn scanStringRange(self: *Parser) ParseError!Range {
        if ((self.peek() orelse return error.UnexpectedEof) != '"') return error.UnexpectedChar;
        self.pos += 1;
        const inner_start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '\\') {
                if (self.pos + 1 >= self.src.len) return error.InvalidString;
                self.pos += 1; // skip escape's payload byte
                continue;
            }
            if (c == '"') {
                const inner_end = self.pos;
                self.pos += 1; // consume closing quote
                return .{ .start = inner_start, .end = inner_end };
            }
            if (c < 0x20) return error.InvalidString;
        }
        return error.UnexpectedEof;
    }

    fn parseNumber(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        if (self.src[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.src.len) return error.InvalidNumber;
        // integer part
        if (self.src[self.pos] == '0') {
            self.pos += 1;
        } else if (self.src[self.pos] >= '1' and self.src[self.pos] <= '9') {
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
        } else {
            return error.InvalidNumber;
        }
        // fractional
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            const frac_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
            if (self.pos == frac_start) return error.InvalidNumber;
        }
        // exponent
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                self.pos += 1;
            }
            const exp_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
            if (self.pos == exp_start) return error.InvalidNumber;
        }
        const end = self.pos;

        const self_identity = hash_mod.identityHash(parent_identity, .json_number, "");
        const subtree_h = hash_mod.subtreeHash(.json_number, &.{}, self.src[start..end]);

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .json_number,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseBool(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        if (std.mem.startsWith(u8, self.src[self.pos..], "true")) {
            self.pos += 4;
        } else if (std.mem.startsWith(u8, self.src[self.pos..], "false")) {
            self.pos += 5;
        } else return error.InvalidLiteral;
        const end = self.pos;

        const self_identity = hash_mod.identityHash(parent_identity, .json_bool, "");
        const subtree_h = hash_mod.subtreeHash(.json_bool, &.{}, self.src[start..end]);

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .json_bool,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseNull(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        if (!std.mem.startsWith(u8, self.src[self.pos..], "null")) return error.InvalidLiteral;
        self.pos += 4;
        const end = self.pos;

        const self_identity = hash_mod.identityHash(parent_identity, .json_null, "");
        const subtree_h = hash_mod.subtreeHash(.json_null, &.{}, "");

        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .json_null,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        return .{ .idx = idx, .hash = subtree_h };
    }
};

/// Parse `source` into an `ast.Tree`. Caller owns returned tree (call deinit).
/// `source` and `path` must outlive the tree (borrowed).
pub fn parse(gpa: std.mem.Allocator, source: []const u8, path: []const u8) ParseError!ast.Tree {
    var tree = ast.Tree.init(gpa, source, path);
    errdefer tree.deinit();

    var parser: Parser = .{
        .gpa = gpa,
        .src = source,
        .pos = 0,
        .tree = &tree,
    };

    parser.skipWhitespace();
    _ = try parser.parseValue(0, 0);
    parser.skipWhitespace();
    if (parser.pos != source.len) return error.TrailingContent;

    return tree;
}

/// Convenience: index of the root node (always last after parse).
pub fn rootIndex(tree: *ast.Tree) NodeIndex {
    return @intCast(tree.nodes.len - 1);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty object" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "{}", "test.json");
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
    const kinds = tree.nodes.items(.kind);
    try std.testing.expectEqual(Kind.json_object, kinds[0]);
    try std.testing.expectEqual(ROOT_PARENT, tree.nodes.items(.parent_idx)[0]);
}

test "parse simple object with one member" {
    const gpa = std.testing.allocator;
    const src = "{\"k\":1}";
    var tree = try parse(gpa, src, "test.json");
    defer tree.deinit();

    // Post-order push: number (0), member (1), object/root (2)
    try std.testing.expectEqual(@as(usize, 3), tree.nodes.len);
    const kinds = tree.nodes.items(.kind);
    try std.testing.expectEqual(Kind.json_number, kinds[0]);
    try std.testing.expectEqual(Kind.json_member, kinds[1]);
    try std.testing.expectEqual(Kind.json_object, kinds[2]);

    const parents = tree.nodes.items(.parent_idx);
    try std.testing.expectEqual(@as(NodeIndex, 1), parents[0]); // number -> member
    try std.testing.expectEqual(@as(NodeIndex, 2), parents[1]); // member -> object
    try std.testing.expectEqual(ROOT_PARENT, parents[2]);

    // Root last.
    try std.testing.expectEqual(@as(NodeIndex, 2), rootIndex(&tree));

    // Identity slice on member is the key bytes ("k").
    try std.testing.expectEqualStrings("k", tree.identitySlice(1));
    // Content slice on number is "1".
    try std.testing.expectEqualStrings("1", tree.contentSlice(0));
}

test "parse array of three numbers" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "[1, 2, 3]", "test.json");
    defer tree.deinit();

    // 3 numbers + 1 array = 4 nodes.
    try std.testing.expectEqual(@as(usize, 4), tree.nodes.len);
    const kinds = tree.nodes.items(.kind);
    try std.testing.expectEqual(Kind.json_number, kinds[0]);
    try std.testing.expectEqual(Kind.json_number, kinds[1]);
    try std.testing.expectEqual(Kind.json_number, kinds[2]);
    try std.testing.expectEqual(Kind.json_array, kinds[3]);

    const parents = tree.nodes.items(.parent_idx);
    try std.testing.expectEqual(@as(NodeIndex, 3), parents[0]);
    try std.testing.expectEqual(@as(NodeIndex, 3), parents[1]);
    try std.testing.expectEqual(@as(NodeIndex, 3), parents[2]);
    try std.testing.expectEqual(ROOT_PARENT, parents[3]);
}

test "parse nested structure with all primitive kinds" {
    const gpa = std.testing.allocator;
    const src =
        \\{"s":"hi","n":42,"b":true,"x":null,"a":[1]}
    ;
    var tree = try parse(gpa, src, "test.json");
    defer tree.deinit();

    // Expect 1 string + 1 number + 1 bool + 1 null + 1 number(in array) + 1 array
    //      + 5 members + 1 object = 12 nodes
    try std.testing.expectEqual(@as(usize, 12), tree.nodes.len);
}

test "identity_hash differs between same key in different parents" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa,
        \\{"a":{"name":1},"b":{"name":2}}
    , "test.json");
    defer t.deinit();

    // Find both `name` members by slicing identity bytes.
    const kinds = t.nodes.items(.kind);
    const idents = t.nodes.items(.identity_hash);
    var name_hashes: std.ArrayList(u64) = .empty;
    defer name_hashes.deinit(gpa);

    for (kinds, 0..) |k, i| {
        if (k != .json_member) continue;
        if (std.mem.eql(u8, t.identitySlice(@intCast(i)), "name")) {
            try name_hashes.append(gpa, idents[i]);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), name_hashes.items.len);
    try std.testing.expect(name_hashes.items[0] != name_hashes.items[1]);
}

test "subtree_hash equal for identical objects in different files" {
    const gpa = std.testing.allocator;
    const src = "{\"k\":1,\"v\":2}";
    var a = try parse(gpa, src, "a.json");
    defer a.deinit();
    var b = try parse(gpa, src, "b.json");
    defer b.deinit();

    const a_root = rootIndex(&a);
    const b_root = rootIndex(&b);
    try std.testing.expectEqual(
        a.nodes.items(.hash)[a_root],
        b.nodes.items(.hash)[b_root],
    );
}

test "subtree_hash differs when leaf changes" {
    const gpa = std.testing.allocator;
    var a = try parse(gpa, "{\"k\":1}", "a.json");
    defer a.deinit();
    var b = try parse(gpa, "{\"k\":2}", "b.json");
    defer b.deinit();

    try std.testing.expect(a.nodes.items(.hash)[rootIndex(&a)] != b.nodes.items(.hash)[rootIndex(&b)]);
}

test "trailing content rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.TrailingContent, parse(gpa, "{} junk", "x.json"));
}

test "bad literal rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidLiteral, parse(gpa, "tru", "x.json"));
}

test "depth limit enforced" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..MAX_DEPTH + 1) |_| try buf.append(gpa, '[');
    for (0..MAX_DEPTH + 1) |_| try buf.append(gpa, ']');
    try std.testing.expectError(error.DepthExceeded, parse(gpa, buf.items, "x.json"));
}

test "identity_range_hash non-zero for json_member; is_exported always false" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "{\"k\":1,\"v\":2}", "x.json");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const irhs = tree.nodes.items(.identity_range_hash);
    const exps = tree.nodes.items(.is_exported);
    var member_count: usize = 0;
    for (kinds, irhs, exps) |k, h, e| {
        if (k == .json_member) {
            try std.testing.expect(h != 0);
            member_count += 1;
        }
        try std.testing.expect(!e);
    }
    try std.testing.expectEqual(@as(usize, 2), member_count);
}

test "fuzz parser does not crash" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    const gpa = std.testing.allocator;

    // Pull up to 4 KiB of random bytes from the fuzzer.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    while (!smith.eos() and buf.items.len < 4096) {
        try buf.append(gpa, smith.value(u8));
    }

    // Parser must either return a valid Tree or a known ParseError.
    // Crashes / leaks / unreachable are bugs.
    if (parse(gpa, buf.items, "fuzz.json")) |t| {
        var t2 = t;
        defer t2.deinit();
    } else |err| switch (err) {
        error.UnexpectedEof,
        error.UnexpectedChar,
        error.InvalidLiteral,
        error.InvalidNumber,
        error.InvalidString,
        error.TrailingContent,
        error.DepthExceeded,
        error.OutOfMemory,
        => {},
    }
}
