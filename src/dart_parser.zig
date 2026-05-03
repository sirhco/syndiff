//! Dart top-level + body parser. Same shape as `rust_parser.zig` /
//! `go_parser.zig`: skim lexer + brace-counting body skip + per-decl node.
//!
//! Recognized top-level items (with leading annotations `@...` and modifiers
//! absorbed into the decl's content range):
//!   import / export / library / part / part of  → dart_import
//!   typedef                                      → dart_typedef
//!   class / abstract class                       → dart_class (with member children)
//!   mixin                                        → dart_mixin
//!   enum                                         → dart_enum
//!   extension                                    → dart_extension
//!   typedef                                      → dart_typedef
//!   <ret-type> name(args) {body}                 → dart_fn
//!   <ret-type> name = ...; / final/var/const     → dart_const
//!
//! Class body members:
//!   <ret-type> name(args) [body|;]   → dart_method
//!   <type> name [= init];            → dart_field
//!
//! Function bodies break into `dart_stmt` children (per-statement, split on
//! `;` at brace-depth 0 OR balanced `{...}` blocks).
//!
//! Limitations:
//!   * String interpolation `${...}` is treated opaquely (the parser tracks
//!     escapes and braces inside the literal but does not recurse into the
//!     interpolation expression). Pathological code with unbalanced braces
//!     inside `${...}` may confuse the body parser.
//!   * Triple-quoted strings (`'''...'''`, `"""..."""`) are handled.
//!   * Raw strings `r'...'` / `r"..."` (non-triple) are handled.

const std = @import("std");
const ast_mod = @import("ast.zig");
const hash_mod = @import("hash.zig");
const lex = @import("lex.zig");

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
    current_depth: u16 = 1,

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
                        self.pos = lex.skipLineComment(self.src, self.pos);
                    } else if (n == '*') {
                        self.pos = lex.skipBlockComment(self.src, self.pos, false);
                    } else return;
                },
                else => return,
            }
        }
    }

    /// Skip a string starting at `self.pos`. Detects `'''` / `"""` triple-quoted
    /// forms and consumes through the matching triple. Single/double also handled.
    fn skipString(self: *Parser) ParseError!void {
        const quote = self.src[self.pos];
        // Triple-quoted?
        if (self.pos + 2 < self.src.len and
            self.src[self.pos + 1] == quote and
            self.src[self.pos + 2] == quote)
        {
            self.pos += 3;
            while (self.pos + 2 < self.src.len) {
                if (self.src[self.pos] == quote and
                    self.src[self.pos + 1] == quote and
                    self.src[self.pos + 2] == quote)
                {
                    self.pos += 3;
                    return;
                }
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                    self.pos += 2;
                } else self.pos += 1;
            }
            return error.UnterminatedString;
        }
        // Single-line.
        if (quote == '"') {
            self.pos = lex.skipDoubleQuoteString(self.src, self.pos) catch return error.UnterminatedString;
        } else {
            self.pos = lex.skipSingleQuoteString(self.src, self.pos) catch return error.UnterminatedString;
        }
    }

    /// Raw string: r'...' / r"..." (non-triple) or r'''...''' / r"""..."""
    /// Caller has confirmed `r` at pos and quote at pos+1.
    fn skipRawString(self: *Parser) ParseError!void {
        self.pos += 1; // 'r'
        const quote = self.src[self.pos];
        // Triple raw?
        if (self.pos + 2 < self.src.len and
            self.src[self.pos + 1] == quote and
            self.src[self.pos + 2] == quote)
        {
            self.pos += 3;
            while (self.pos + 2 < self.src.len) {
                if (self.src[self.pos] == quote and
                    self.src[self.pos + 1] == quote and
                    self.src[self.pos + 2] == quote)
                {
                    self.pos += 3;
                    return;
                }
                self.pos += 1;
            }
            return error.UnterminatedString;
        }
        // Single-line raw — no escape processing, terminate at quote or newline.
        self.pos += 1; // opening quote
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == quote) return;
            if (c == '\n') return error.UnterminatedString;
        }
        return error.UnterminatedString;
    }

    fn looksLikeRawString(self: *Parser) bool {
        if (self.atEnd() or self.src[self.pos] != 'r') return false;
        const n = self.peek(1) orelse return false;
        return n == '\'' or n == '"';
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
                '"', '\'' => try self.skipString(),
                'r' => {
                    if (self.looksLikeRawString()) {
                        try self.skipRawString();
                    } else self.pos += 1;
                },
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

    fn scanIdent(self: *Parser) ?Range {
        const r = lex.scanIdent(self.src, self.pos) orelse return null;
        self.pos = r.end;
        return .{ .start = r.start, .end = r.end };
    }

    fn matchKeyword(self: *Parser, word: []const u8) bool {
        return lex.matchKeyword(self.src, self.pos, word);
    }

    /// Skip annotations like `@override`, `@Deprecated('msg')`.
    fn skipAnnotations(self: *Parser) ParseError!void {
        while (true) {
            self.skipTrivia();
            if (self.atEnd() or self.src[self.pos] != '@') return;
            self.pos += 1;
            // optional name + dotted path
            _ = self.scanIdent();
            while (!self.atEnd() and self.src[self.pos] == '.') {
                self.pos += 1;
                _ = self.scanIdent();
            }
            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == '(') {
                try self.skipBalanced('(', ')');
            }
        }
    }

    fn parseFile(self: *Parser) ParseError!void {
        const root_identity = hash_mod.identityHash(0, .file_root, "");

        var decl_indices: std.ArrayList(NodeIndex) = .empty;
        defer decl_indices.deinit(self.gpa);
        var decl_hashes: std.ArrayList(u64) = .empty;
        defer decl_hashes.deinit(self.gpa);

        try self.scanContainer(root_identity, 1, false, &decl_indices, &decl_hashes);

        const root_hash = hash_mod.subtreeHash(.file_root, decl_hashes.items, "");
        const root_idx = try self.tree.addNode(.{
            .hash = root_hash,
            .identity_hash = root_identity,
            .identity_range_hash = 0,
            .kind = .file_root,
            .depth = 0,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = 0, .end = @intCast(self.src.len) },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        const parents = self.tree.nodes.items(.parent_idx);
        for (decl_indices.items) |d| parents[d] = root_idx;
    }

    /// Scan items in a container scope (file or class body).
    fn scanContainer(
        self: *Parser,
        parent_identity: u64,
        decl_depth: u16,
        stop_at_close_brace: bool,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const saved_depth = self.current_depth;
        self.current_depth = decl_depth;
        defer self.current_depth = saved_depth;

        var anon_counter: u32 = 0;

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;

            if (stop_at_close_brace and self.src[self.pos] == '}') {
                self.pos += 1;
                return;
            }

            const decl_start = self.pos;
            try self.skipAnnotations();
            self.skipTrivia();
            if (self.atEnd()) break;

            // Top-level keyword dispatch.
            if (self.matchKeyword("import") or self.matchKeyword("export") or
                self.matchKeyword("library") or self.matchKeyword("part"))
            {
                try self.parseDirective(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }
            if (self.matchKeyword("typedef")) {
                self.pos += "typedef".len;
                try self.parseTypedef(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }
            if (self.matchKeyword("abstract")) {
                self.pos += "abstract".len;
                self.skipTrivia();
                // Expect `class` or `interface`/`mixin`.
            }
            if (self.matchKeyword("class")) {
                self.pos += "class".len;
                try self.parseTypeContainer(.dart_class, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("mixin")) {
                self.pos += "mixin".len;
                try self.parseTypeContainer(.dart_mixin, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("enum")) {
                self.pos += "enum".len;
                try self.parseTypeContainer(.dart_enum, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("extension")) {
                self.pos += "extension".len;
                try self.parseTypeContainer(.dart_extension, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }

            // Member-or-fn: read a "header" until we hit `(`, `=`, `;`, or `{`.
            //   (   → fn/method
            //   =;  → field/const
            //   {   → fn (arrow body uses `=>`, also fn)
            try self.parseMemberOrFn(decl_start, parent_identity, decl_indices, decl_hashes, stop_at_close_brace, &anon_counter);
        }
    }

    /// import / export / library / part. Identity = string-literal path
    /// (between quotes), or first ident for library/part-of.
    fn parseDirective(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        // Consume keyword (and optional `of` for `part of`).
        _ = self.scanIdent();
        self.skipTrivia();
        if (self.matchKeyword("of")) {
            self.pos += 2;
            self.skipTrivia();
        }

        // Identity: first quoted string literal. If none, use first ident.
        var ident_range = Range.empty;

        // Walk to `;` capturing first quoted path.
        while (!self.atEnd() and self.src[self.pos] != ';') {
            const c = self.src[self.pos];
            if (c == '"' or c == '\'') {
                const q_open = self.pos + 1;
                try self.skipString();
                // If we just consumed a single-quoted/double-quoted single line,
                // identity range = bytes between quotes.
                const q_close = self.pos - 1;
                if (ident_range.end == ident_range.start and q_close > q_open) {
                    ident_range = .{ .start = q_open, .end = q_close };
                }
                continue;
            }
            if (c == '/' and self.peek(1) != null and (self.peek(1) == @as(u8, '/') or self.peek(1) == @as(u8, '*'))) {
                self.skipTrivia();
                continue;
            }
            self.pos += 1;
        }
        if (!self.atEnd()) self.pos += 1; // consume ;

        if (ident_range.end == ident_range.start) {
            anon_counter.* += 1;
        }
        try self.emitDecl(.dart_import, ident_range, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    fn parseTypedef(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        _ = anon_counter;
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilSemi();
        try self.emitDecl(.dart_typedef, name, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    /// class/mixin/enum/extension <Name> ... { ... }. Recurse into body.
    fn parseTypeContainer(
        self: *Parser,
        kind: Kind,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        const name_bytes = self.src[name.start..name.end];

        // Walk header until `{`.
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '{' or c == ';') break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '(' => try self.skipBalanced('(', ')'),
                '"', '\'' => try self.skipString(),
                else => self.pos += 1,
            }
        }

        const container_identity = hash_mod.identityHash(parent_identity, kind, name_bytes);

        var member_indices: std.ArrayList(NodeIndex) = .empty;
        defer member_indices.deinit(self.gpa);
        var member_hashes: std.ArrayList(u64) = .empty;
        defer member_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1;
            try self.scanContainer(container_identity, self.current_depth + 1, true, &member_indices, &member_hashes);
        } else if (!self.atEnd() and self.src[self.pos] == ';') {
            self.pos += 1;
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(kind, member_hashes.items, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = container_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = kind,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = name_bytes.len > 0 and name_bytes[0] != '_',
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (member_indices.items) |m| parents[m] = idx;
    }

    /// Parse a fn/method/field/const decl. Header walk classifies by first
    /// significant punctuator: `(` → fn, `;`/`=` → field/const.
    fn parseMemberOrFn(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        in_class_body: bool,
        anon_counter: *u32,
    ) ParseError!void {
        _ = anon_counter;
        // Track the LAST identifier seen — that's the member name (return type
        // identifiers come earlier).
        var last_ident: ?Range = null;
        var saw_paren = false;

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '(' or c == '=' or c == ';' or c == '{') break;
            if (c == '}') break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '"', '\'' => try self.skipString(),
                else => {
                    if (lex.isIdentStart(c)) {
                        last_ident = self.scanIdent();
                    } else {
                        self.pos += 1;
                    }
                },
            }
        }

        const name: Range = last_ident orelse .{ .start = self.pos, .end = self.pos };

        if (!self.atEnd() and self.src[self.pos] == '(') {
            saw_paren = true;
            try self.skipBalanced('(', ')');
        }

        // Walk past initializer list / async / =>arrow-body / where clauses
        // until `{` (block body), `;` (proto / arrow-stmt-end), or end of
        // expression.
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '{' or c == ';') break;
            if (c == '}') break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"', '\'' => try self.skipString(),
                'r' => {
                    if (self.looksLikeRawString()) try self.skipRawString() else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }

        const kind: Kind = if (saw_paren)
            (if (in_class_body) .dart_method else .dart_fn)
        else
            (if (in_class_body) .dart_field else .dart_const);

        const name_bytes = self.src[name.start..name.end];
        const fn_identity = hash_mod.identityHash(parent_identity, kind, name_bytes);

        var stmt_indices: std.ArrayList(NodeIndex) = .empty;
        defer stmt_indices.deinit(self.gpa);
        var stmt_hashes: std.ArrayList(u64) = .empty;
        defer stmt_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{' and saw_paren) {
            self.pos += 1;
            try self.parseFnBody(fn_identity, &stmt_indices, &stmt_hashes);
        } else {
            try self.skipUntilSemi();
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(kind, stmt_hashes.items, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = fn_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = kind,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = name_bytes.len > 0 and name_bytes[0] != '_',
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (stmt_indices.items) |s| parents[s] = idx;
    }

    fn parseFnBody(
        self: *Parser,
        fn_identity: u64,
        stmt_indices: *std.ArrayList(NodeIndex),
        stmt_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const saved_depth = self.current_depth;
        self.current_depth = saved_depth + 1;
        defer self.current_depth = saved_depth;

        var stmt_idx: u32 = 0;
        var idx_buf: [16]u8 = undefined;

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) return;
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                return;
            }
            const stmt_start = self.pos;
            try self.skipStatement();
            const stmt_end = self.pos;

            const raw = self.src[stmt_start..stmt_end];
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;

            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{stmt_idx}) catch unreachable;
            const stmt_identity = hash_mod.identityHash(fn_identity, .dart_stmt, idx_str);
            const stmt_h = hash_mod.subtreeHash(.dart_stmt, &.{}, trimmed);

            const node = try self.tree.addNode(.{
                .hash = stmt_h,
                .identity_hash = stmt_identity,
                .identity_range_hash = 0,
                .kind = .dart_stmt,
                .depth = self.current_depth,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = stmt_start, .end = stmt_end },
                .identity_range = Range.empty,
                .is_exported = false,
            });
            try stmt_indices.append(self.gpa, node);
            try stmt_hashes.append(self.gpa, stmt_h);
            stmt_idx += 1;
        }
    }

    fn skipStatement(self: *Parser) ParseError!void {
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            switch (c) {
                ';' => {
                    self.pos += 1;
                    return;
                },
                '{' => {
                    try self.skipBalanced('{', '}');
                    return;
                },
                '}' => return,
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"', '\'' => try self.skipString(),
                'r' => {
                    if (self.looksLikeRawString()) try self.skipRawString() else self.pos += 1;
                },
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) self.skipTrivia()
                    else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn skipUntilSemi(self: *Parser) ParseError!void {
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            switch (c) {
                ';' => {
                    self.pos += 1;
                    return;
                },
                '{' => try self.skipBalanced('{', '}'),
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"', '\'' => try self.skipString(),
                'r' => {
                    if (self.looksLikeRawString()) try self.skipRawString() else self.pos += 1;
                },
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) self.skipTrivia()
                    else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn emitDecl(
        self: *Parser,
        kind: Kind,
        identity_range: Range,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const decl_end = self.pos;
        const ident_bytes = self.src[identity_range.start..identity_range.end];
        const decl_identity = hash_mod.identityHash(parent_identity, kind, ident_bytes);
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);

        // dart_import is treated as a non-decl; everything else routed here is decl-bearing.
        const is_decl_bearing = kind != .dart_import;
        const irh: u64 = if (is_decl_bearing) std.hash.Wyhash.hash(0, ident_bytes) else 0;
        const exported = is_decl_bearing and ident_bytes.len > 0 and ident_bytes[0] != '_';

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = decl_identity,
            .identity_range_hash = irh,
            .kind = kind,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = identity_range,
            .is_exported = exported,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);
    }
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8, path: []const u8) ParseError!ast_mod.Tree {
    var tree = ast_mod.Tree.init(gpa, source, path);
    errdefer tree.deinit();
    var p: Parser = .{ .gpa = gpa, .src = source, .pos = 0, .tree = &tree };
    try p.parseFile();
    return tree;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty dart file" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "", "x.dart");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.file_root, t.nodes.items(.kind)[0]);
}

test "parse top-level fn" {
    const gpa = std.testing.allocator;
    const src = "void main() { print('hi'); }";
    var t = try parse(gpa, src, "x.dart");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_fn = false;
    for (kinds) |k| {
        if (k == .dart_fn) has_fn = true;
    }
    try std.testing.expect(has_fn);
}

test "parse class with method" {
    const gpa = std.testing.allocator;
    const src =
        \\class Point {
        \\  int x = 0;
        \\  int y = 0;
        \\  double distance() => 0.0;
        \\}
    ;
    var t = try parse(gpa, src, "x.dart");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_class = false;
    var has_method = false;
    for (kinds) |k| {
        if (k == .dart_class) has_class = true;
        if (k == .dart_method) has_method = true;
    }
    try std.testing.expect(has_class);
    try std.testing.expect(has_method);
}

test "import statement captured" {
    const gpa = std.testing.allocator;
    const src = "import 'package:foo/bar.dart';\n";
    var t = try parse(gpa, src, "x.dart");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_import = false;
    for (kinds, 0..) |k, i| {
        if (k == .dart_import) {
            has_import = true;
            try std.testing.expectEqualStrings("package:foo/bar.dart", t.identitySlice(@intCast(i)));
        }
    }
    try std.testing.expect(has_import);
}

test "triple-quoted string body does not break parser" {
    const gpa = std.testing.allocator;
    const src =
        \\String greet() {
        \\  return """
        \\  multi { line } body
        \\  """;
        \\}
        \\void next() {}
    ;
    var t = try parse(gpa, src, "x.dart");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var fn_count: usize = 0;
    for (kinds) |k| {
        if (k == .dart_fn) fn_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fn_count);
}

test "fn body extracts dart_stmt children" {
    const gpa = std.testing.allocator;
    const src =
        \\int compute(int a, int b) {
        \\  var x = a + b;
        \\  var y = x * 2;
        \\  return y;
        \\}
    ;
    var t = try parse(gpa, src, "x.dart");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var stmt_count: usize = 0;
    for (kinds) |k| {
        if (k == .dart_stmt) stmt_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), stmt_count);
}

test "is_exported by underscore convention; identity_range_hash non-zero" {
    const gpa = std.testing.allocator;
    const src =
        \\void publicFn() {}
        \\void _privateFn() {}
    ;
    var tree = try parse(gpa, src, "x.dart");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exps = tree.nodes.items(.is_exported);
    const irhs = tree.nodes.items(.identity_range_hash);
    var saw_pub = false;
    var saw_priv = false;
    for (kinds, exps, irhs, 0..) |k, exp, h, i| {
        if (k != .dart_fn) continue;
        try std.testing.expect(h != 0);
        const name = tree.identitySlice(@intCast(i));
        if (std.mem.eql(u8, name, "publicFn")) {
            try std.testing.expect(exp);
            saw_pub = true;
        } else if (std.mem.eql(u8, name, "_privateFn")) {
            try std.testing.expect(!exp);
            saw_priv = true;
        }
    }
    try std.testing.expect(saw_pub and saw_priv);
}
