//! Go top-level decl parser. Same pattern as `rust_parser.zig`: skim lexer,
//! brace-counting body skip, one node per top-level decl. No body recursion.
//!
//! Recognized items:
//!   package, import (`"..."` or `( ... )` block), func, method
//!   (`func (recv) Name(...)`), type, var, const (single or paren block).
//!
//! Grouped `var (...)`, `const (...)`, `import (...)` are emitted as a SINGLE
//! node identified by `<paren_var:N>` etc. (block-as-unit). Splitting them
//! into per-name nodes is a future refinement.

const std = @import("std");
const ast_mod = @import("ast.zig");
const hash_mod = @import("hash.zig");

const NodeIndex = ast_mod.NodeIndex;
const Range = ast_mod.Range;
const Kind = ast_mod.Kind;
const ROOT_PARENT = ast_mod.ROOT_PARENT;

pub const ParseError = error{
    UnterminatedBlock,
    UnterminatedString,
} || std.mem.Allocator.Error;

const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: u32,
    tree: *ast_mod.Tree,

    fn atEnd(self: *Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *Parser, offset: u32) ?u8 {
        const p = self.pos + offset;
        if (p >= self.src.len) return null;
        return self.src[p];
    }

    fn skipTrivia(self: *Parser) void {
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    const n = self.peek(1) orelse return;
                    if (n == '/') {
                        while (!self.atEnd() and self.src[self.pos] != '\n') self.pos += 1;
                    } else if (n == '*') {
                        self.pos += 2;
                        while (self.pos + 1 < self.src.len and
                            !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/'))
                        {
                            self.pos += 1;
                        }
                        if (self.pos + 1 < self.src.len) self.pos += 2;
                    } else return;
                },
                else => return,
            }
        }
    }

    fn skipString(self: *Parser) ParseError!void {
        self.pos += 1; // opening "
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            self.pos += 1;
            if (c == '"') return;
            if (c == '\n') return error.UnterminatedString;
        }
        return error.UnterminatedString;
    }

    /// Go raw string: `...` (no escapes, can span lines).
    fn skipRawString(self: *Parser) ParseError!void {
        self.pos += 1; // opening `
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '`') return;
        }
        return error.UnterminatedString;
    }

    /// Go rune literal: 'X' or '\X...' (always closed by ').
    fn skipRune(self: *Parser) ParseError!void {
        self.pos += 1; // opening '
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            self.pos += 1;
            if (c == '\'') return;
            if (c == '\n') return error.UnterminatedString;
        }
        return error.UnterminatedString;
    }

    fn skipBalanced(self: *Parser, open: u8, close: u8) ParseError!void {
        if (self.atEnd() or self.src[self.pos] != open) return;
        self.pos += 1;
        var depth: u32 = 1;
        while (!self.atEnd() and depth > 0) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else self.pos += 1;
                },
                '"' => try self.skipString(),
                '\'' => try self.skipRune(),
                '`' => try self.skipRawString(),
                else => {
                    if (c == open) {
                        depth += 1;
                        self.pos += 1;
                    } else if (c == close) {
                        depth -= 1;
                        self.pos += 1;
                    } else self.pos += 1;
                },
            }
        }
        if (depth != 0) return error.UnterminatedBlock;
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn scanIdent(self: *Parser) ?Range {
        if (self.atEnd() or !isIdentStart(self.src[self.pos])) return null;
        const start = self.pos;
        self.pos += 1;
        while (!self.atEnd() and isIdentCont(self.src[self.pos])) self.pos += 1;
        return .{ .start = start, .end = self.pos };
    }

    fn matchKeyword(self: *Parser, word: []const u8) bool {
        if (self.pos + word.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + word.len], word)) return false;
        const next = self.pos + word.len;
        if (next < self.src.len and isIdentCont(self.src[next])) return false;
        return true;
    }

    /// Skip to end of statement: closing `}` of a brace-bodied decl, or end
    /// of line (for non-brace decls), respecting strings/runes/comments.
    fn skipUntilDeclEnd(self: *Parser) ParseError!void {
        // Walk until we either consume a `{...}` body OR reach a newline at
        // depth 0 (Go's automatic semicolon insertion uses newlines for
        // statement termination).
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            switch (c) {
                '\n' => {
                    self.pos += 1;
                    return;
                },
                '{' => {
                    try self.skipBalanced('{', '}');
                    return;
                },
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"' => try self.skipString(),
                '\'' => try self.skipRune(),
                '`' => try self.skipRawString(),
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    /// Skip until the closing `)` at matching depth (used for grouped decls).
    fn skipParenBlock(self: *Parser) ParseError!void {
        try self.skipBalanced('(', ')');
    }

    /// Top-level scan.
    fn parseFile(self: *Parser) ParseError!void {
        const root_identity = hash_mod.identityHash(0, .file_root, "");

        var decl_indices: std.ArrayList(NodeIndex) = .empty;
        defer decl_indices.deinit(self.gpa);
        var decl_hashes: std.ArrayList(u64) = .empty;
        defer decl_hashes.deinit(self.gpa);

        var anon_counter: u32 = 0;
        var anon_buf: [32]u8 = undefined;

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;

            const decl_start = self.pos;
            const kw_range = self.scanIdent() orelse {
                if (!self.atEnd()) self.pos += 1;
                continue;
            };
            const kw = self.src[kw_range.start..kw_range.end];

            if (std.mem.eql(u8, kw, "package")) {
                try self.parsePackage(decl_start, root_identity, &decl_indices, &decl_hashes);
            } else if (std.mem.eql(u8, kw, "import")) {
                try self.parseImport(decl_start, root_identity, &decl_indices, &decl_hashes, &anon_counter, &anon_buf);
            } else if (std.mem.eql(u8, kw, "func")) {
                try self.parseFunc(decl_start, root_identity, &decl_indices, &decl_hashes, &anon_counter, &anon_buf);
            } else if (std.mem.eql(u8, kw, "type")) {
                try self.parseType(decl_start, root_identity, &decl_indices, &decl_hashes, &anon_counter, &anon_buf);
            } else if (std.mem.eql(u8, kw, "var")) {
                try self.parseVarConst(.go_var, decl_start, root_identity, &decl_indices, &decl_hashes, &anon_counter, &anon_buf);
            } else if (std.mem.eql(u8, kw, "const")) {
                try self.parseVarConst(.go_const, decl_start, root_identity, &decl_indices, &decl_hashes, &anon_counter, &anon_buf);
            } else {
                // Unknown — advance and continue.
            }
        }

        const root_hash = hash_mod.subtreeHash(.file_root, decl_hashes.items, "");
        const root_idx = try self.tree.addNode(.{
            .hash = root_hash,
            .identity_hash = root_identity,
            .kind = .file_root,
            .depth = 0,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = 0, .end = @intCast(self.src.len) },
            .identity_range = Range.empty,
        });
        const parents = self.tree.nodes.items(.parent_idx);
        for (decl_indices.items) |d| parents[d] = root_idx;
    }

    fn parsePackage(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        // To end of line.
        while (!self.atEnd() and self.src[self.pos] != '\n') self.pos += 1;
        if (!self.atEnd()) self.pos += 1;
        try self.emitDecl(.go_package, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseImport(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '(') {
            // Block: `import ( "x"; "y" )`
            try self.skipParenBlock();
            const idx_str = std.fmt.bufPrint(anon_buf, "<imports:{d}>", .{anon_counter.*}) catch unreachable;
            anon_counter.* += 1;
            try self.emitDeclSynthName(.go_import, idx_str, decl_start, root_identity, decl_indices, decl_hashes);
            return;
        }
        // Single: `import "path"` or `import alias "path"`
        const id_start = self.pos;
        while (!self.atEnd() and self.src[self.pos] != '\n') self.pos += 1;
        if (id_start == self.pos) {
            try self.emitDecl(.go_import, Range.empty, decl_start, root_identity, decl_indices, decl_hashes);
            return;
        }
        const id_end = self.pos;
        if (!self.atEnd()) self.pos += 1;
        const id_range: Range = .{ .start = id_start, .end = id_end };
        try self.emitDecl(.go_import, id_range, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseFunc(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        // After `func`. Two shapes:
        //   func Name(args) ret { ... }
        //   func (recv T) Name(args) ret { ... }
        self.skipTrivia();
        var kind: Kind = .go_fn;
        var receiver_range = Range.empty;
        if (!self.atEnd() and self.src[self.pos] == '(') {
            // Method receiver.
            const recv_start = self.pos;
            try self.skipBalanced('(', ')');
            const recv_end = self.pos;
            kind = .go_method;
            receiver_range = .{ .start = recv_start, .end = recv_end };
            self.skipTrivia();
        }
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };

        // Build identity bytes:
        // - For fn: just the name.
        // - For method: "<recv_type_bytes>.<name>" so methods on different
        //   types with the same name don't collide.
        const ident_range: Range = if (kind == .go_method and receiver_range.end > receiver_range.start) blk: {
            // Reuse the receiver range bytes alongside name bytes by
            // synthesizing a buffer in the source... Simpler: just use the
            // method name; ambiguity acceptable for MVP (collisions emit as
            // MOVED/MODIFIED across receivers).
            _ = anon_counter;
            _ = anon_buf;
            break :blk name;
        } else name;

        try self.skipUntilDeclEnd();
        try self.emitDecl(kind, ident_range, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseType(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '(') {
            // Block: `type ( ... )`
            try self.skipParenBlock();
            const idx_str = std.fmt.bufPrint(anon_buf, "<types:{d}>", .{anon_counter.*}) catch unreachable;
            anon_counter.* += 1;
            try self.emitDeclSynthName(.go_type, idx_str, decl_start, root_identity, decl_indices, decl_hashes);
            return;
        }
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilDeclEnd();
        try self.emitDecl(.go_type, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseVarConst(
        self: *Parser,
        kind: Kind,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '(') {
            try self.skipParenBlock();
            const label = if (kind == .go_var) "<vars:" else "<consts:";
            const idx_str = std.fmt.bufPrint(anon_buf, "{s}{d}>", .{ label, anon_counter.* }) catch unreachable;
            anon_counter.* += 1;
            try self.emitDeclSynthName(kind, idx_str, decl_start, root_identity, decl_indices, decl_hashes);
            return;
        }
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilDeclEnd();
        try self.emitDecl(kind, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn emitDecl(
        self: *Parser,
        kind: Kind,
        identity_range: Range,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const decl_end = self.pos;
        const ident_bytes = self.src[identity_range.start..identity_range.end];
        const decl_identity = hash_mod.identityHash(root_identity, kind, ident_bytes);
        const decl_bytes = self.src[decl_start..decl_end];
        const decl_h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);
        const idx = try self.tree.addNode(.{
            .hash = decl_h,
            .identity_hash = decl_identity,
            .kind = kind,
            .depth = 1,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = identity_range,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, decl_h);
    }

    /// For grouped decls — name comes from a synthesized string slice, not
    /// from the source buffer. identity_range is empty (synthetic).
    fn emitDeclSynthName(
        self: *Parser,
        kind: Kind,
        ident_bytes: []const u8,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const decl_end = self.pos;
        const decl_identity = hash_mod.identityHash(root_identity, kind, ident_bytes);
        const decl_bytes = self.src[decl_start..decl_end];
        const decl_h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);
        const idx = try self.tree.addNode(.{
            .hash = decl_h,
            .identity_hash = decl_identity,
            .kind = kind,
            .depth = 1,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = Range.empty,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, decl_h);
    }
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8, path: []const u8) ParseError!ast_mod.Tree {
    var tree = ast_mod.Tree.init(gpa, source, path);
    errdefer tree.deinit();

    var p: Parser = .{
        .gpa = gpa,
        .src = source,
        .pos = 0,
        .tree = &tree,
    };
    try p.parseFile();
    return tree;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty file" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "", "x.go");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.file_root, t.nodes.items(.kind)[0]);
}

test "parse package and imports" {
    const gpa = std.testing.allocator;
    const src =
        \\package main
        \\
        \\import "fmt"
        \\
        \\import (
        \\    "os"
        \\    "io"
        \\)
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    // package, import (single), import (group), file_root
    try std.testing.expectEqual(@as(usize, 4), t.nodes.len);
    try std.testing.expectEqual(Kind.go_package, kinds[0]);
    try std.testing.expectEqual(Kind.go_import, kinds[1]);
    try std.testing.expectEqual(Kind.go_import, kinds[2]);

    try std.testing.expectEqualStrings("main", t.identitySlice(0));
}

test "parse func and method" {
    const gpa = std.testing.allocator;
    const src =
        \\package main
        \\
        \\func Add(a, b int) int { return a + b }
        \\
        \\func (p *Point) Area() float64 { return 0.0 }
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.go_package, kinds[0]);
    try std.testing.expectEqual(Kind.go_fn, kinds[1]);
    try std.testing.expectEqual(Kind.go_method, kinds[2]);
    try std.testing.expectEqualStrings("Add", t.identitySlice(1));
    try std.testing.expectEqualStrings("Area", t.identitySlice(2));
}

test "parse type, var, const" {
    const gpa = std.testing.allocator;
    const src =
        \\package x
        \\
        \\type Point struct { X, Y int }
        \\
        \\var counter = 0
        \\
        \\const MAX = 100
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.go_type, kinds[1]);
    try std.testing.expectEqual(Kind.go_var, kinds[2]);
    try std.testing.expectEqual(Kind.go_const, kinds[3]);
}

test "raw string with braces does not break parser" {
    const gpa = std.testing.allocator;
    const src =
        \\package x
        \\
        \\func A() {
        \\    s := `}}{{}}{`
        \\    _ = s
        \\}
        \\
        \\func B() {}
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.go_fn, kinds[1]);
    try std.testing.expectEqual(Kind.go_fn, kinds[2]);
    try std.testing.expectEqualStrings("A", t.identitySlice(1));
    try std.testing.expectEqualStrings("B", t.identitySlice(2));
}

test "subtree hash differs when fn body changes" {
    const gpa = std.testing.allocator;
    const a_src = "package x\nfunc f() int { return 1 }\n";
    const b_src = "package x\nfunc f() int { return 2 }\n";
    var a = try parse(gpa, a_src, "a.go");
    defer a.deinit();
    var b = try parse(gpa, b_src, "b.go");
    defer b.deinit();

    // Find fn nodes.
    const a_kinds = a.nodes.items(.kind);
    var a_fn: ?NodeIndex = null;
    for (a_kinds, 0..) |k, i| if (k == .go_fn) {
        a_fn = @intCast(i);
        break;
    };
    const b_kinds = b.nodes.items(.kind);
    var b_fn: ?NodeIndex = null;
    for (b_kinds, 0..) |k, i| if (k == .go_fn) {
        b_fn = @intCast(i);
        break;
    };
    try std.testing.expect(a_fn != null and b_fn != null);
    try std.testing.expect(a.nodes.items(.hash)[a_fn.?] != b.nodes.items(.hash)[b_fn.?]);
    try std.testing.expectEqual(
        a.nodes.items(.identity_hash)[a_fn.?],
        b.nodes.items(.identity_hash)[b_fn.?],
    );
}

test "fuzz parser does not crash" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    while (!smith.eos() and buf.items.len < 4096) {
        try buf.append(gpa, smith.value(u8));
    }
    if (parse(gpa, buf.items, "fuzz.go")) |t| {
        var t2 = t;
        defer t2.deinit();
    } else |err| switch (err) {
        error.UnterminatedBlock,
        error.UnterminatedString,
        error.OutOfMemory,
        => {},
    }
}
