//! Go top-level decl parser. Same pattern as `rust_parser.zig`: skim lexer,
//! brace-counting body skip, one node per top-level decl. Function bodies stay
//! opaque (body change → MODIFIED on the func/method).
//!
//! Recognized items:
//!   package, import, func, method (`func (recv) Name(...)`),
//!   type, var, const.
//!
//! Grouped declarations split into per-name nodes:
//!   import ( "fmt"; "io" )                 → 2 go_import nodes (paths)
//!   const ( A = 1; B = 2 )                 → 2 go_const nodes (A, B)
//!   var ( x int; y = "" )                  → 2 go_var nodes
//!   type ( Foo struct{...}; Bar []T )      → 2 go_type nodes
//! Aliased imports keep the path as identity:
//!   alias "path" / _ "path" / . "path"     → identity = `path`

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

    fn skipString(self: *Parser) ParseError!void {
        self.pos = lex.skipDoubleQuoteString(self.src, self.pos) catch return error.UnterminatedString;
    }

    /// Go raw string: `...` (no escapes, can span lines).
    fn skipRawString(self: *Parser) ParseError!void {
        self.pos = lex.skipBacktickRaw(self.src, self.pos) catch return error.UnterminatedString;
    }

    /// Go rune literal: 'X' or '\X...' (always closed by ').
    fn skipRune(self: *Parser) ParseError!void {
        self.pos = lex.skipSingleQuoteString(self.src, self.pos) catch return error.UnterminatedString;
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

    fn scanIdent(self: *Parser) ?Range {
        const r = lex.scanIdent(self.src, self.pos) orelse return null;
        self.pos = r.end;
        return .{ .start = r.start, .end = r.end };
    }

    fn matchKeyword(self: *Parser, word: []const u8) bool {
        return lex.matchKeyword(self.src, self.pos, word);
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

    /// Inside a grouped `(...)` block, advance to the end of one entry:
    /// next `;` at depth 0, end of line at depth 0, or the outer `)`.
    /// Pos is left on the terminator (caller advances past it as appropriate).
    fn skipGroupedEntryEnd(self: *Parser) ParseError!void {
        var paren_depth: u32 = 0;
        var brace_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            const at_zero = paren_depth == 0 and brace_depth == 0 and bracket_depth == 0;
            if (at_zero) {
                if (c == '\n' or c == ';') return;
                if (c == ')') return; // outer paren close — caller handles
            }
            switch (c) {
                '(' => {
                    paren_depth += 1;
                    self.pos += 1;
                },
                ')' => {
                    if (paren_depth == 0) return;
                    paren_depth -= 1;
                    self.pos += 1;
                },
                '{' => {
                    brace_depth += 1;
                    self.pos += 1;
                },
                '}' => {
                    if (brace_depth > 0) brace_depth -= 1;
                    self.pos += 1;
                },
                '[' => {
                    bracket_depth += 1;
                    self.pos += 1;
                },
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                    self.pos += 1;
                },
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

    /// Walk a grouped block `(...)`, emitting one node per entry.
    /// Caller must have already consumed the opening `(`.
    /// `extract_name` is invoked with `pos` pointing at the entry's first
    /// non-whitespace byte; it should return a Range identifying the entry's
    /// name, or `Range.empty` to fall back to a synthetic counter.
    fn parseGroupedEntries(
        self: *Parser,
        kind: Kind,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
        comptime extract_name: fn (*Parser) ParseError!Range,
    ) ParseError!void {
        while (!self.atEnd()) {
            // Skip whitespace, blank lines, and comments between entries.
            while (!self.atEnd()) {
                const c = self.src[self.pos];
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ';') {
                    self.pos += 1;
                    continue;
                }
                if (c == '/' and (self.peek(1) == @as(u8, '/') or self.peek(1) == @as(u8, '*'))) {
                    self.skipTrivia();
                    continue;
                }
                break;
            }
            if (self.atEnd()) return;
            if (self.src[self.pos] == ')') {
                self.pos += 1; // consume closing paren
                return;
            }
            const entry_start = self.pos;
            const name_range = extract_name(self) catch Range.empty;
            try self.skipGroupedEntryEnd();
            const entry_end = self.pos;

            const name_bytes = self.src[name_range.start..name_range.end];
            const decl_identity = if (name_bytes.len > 0)
                hash_mod.identityHash(parent_identity, kind, name_bytes)
            else blk: {
                const idx_str = std.fmt.bufPrint(anon_buf, "<anon:{d}>", .{anon_counter.*}) catch unreachable;
                anon_counter.* += 1;
                break :blk hash_mod.identityHash(parent_identity, kind, idx_str);
            };
            const decl_bytes = self.src[entry_start..entry_end];
            const decl_h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);

            const idx = try self.tree.addNode(.{
                .hash = decl_h,
                .identity_hash = decl_identity,
                .kind = kind,
                .depth = 1,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = entry_start, .end = entry_end },
                .identity_range = name_range,
            });
            try decl_indices.append(self.gpa, idx);
            try decl_hashes.append(self.gpa, decl_h);
        }
    }

    /// Name extractor for `import (...)` entries.
    /// `alias "path"` → path is the identity. `"path"` → path is identity.
    /// `_ "path"` / `. "path"` → path is identity.
    fn extractImportName(self: *Parser) ParseError!Range {
        // Optional alias ident or `_` / `.`.
        if (!self.atEnd() and (lex.isIdentStart(self.src[self.pos]) or self.src[self.pos] == '_' or self.src[self.pos] == '.')) {
            // Consume alias / underscore / dot.
            const save = self.pos;
            if (self.src[self.pos] == '.') {
                self.pos += 1;
            } else {
                _ = self.scanIdent();
            }
            // Whitespace.
            while (!self.atEnd() and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
            // If next char is not `"`, this wasn't an alias — rewind.
            if (self.atEnd() or self.src[self.pos] != '"') {
                self.pos = save;
                return Range.empty;
            }
        }
        if (self.atEnd() or self.src[self.pos] != '"') return Range.empty;
        // Path is the bytes between quotes.
        const inner_start = self.pos + 1;
        var p = inner_start;
        while (p < self.src.len and self.src[p] != '"' and self.src[p] != '\n') {
            if (self.src[p] == '\\' and p + 1 < self.src.len) p += 2 else p += 1;
        }
        return .{ .start = inner_start, .end = p };
    }

    /// Name extractor for `var (...)` / `const (...)` / `type (...)` entries.
    /// Takes the first identifier on the line.
    fn extractFirstIdent(self: *Parser) ParseError!Range {
        return self.scanIdent() orelse Range.empty;
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
            self.pos += 1; // consume `(`
            try self.parseGroupedEntries(.go_import, root_identity, decl_indices, decl_hashes, anon_counter, anon_buf, extractImportName);
            return;
        }
        // Single: `import "path"` or `import alias "path"`
        const name_range = try extractImportName(self);
        // Skip to end of line.
        while (!self.atEnd() and self.src[self.pos] != '\n') self.pos += 1;
        if (!self.atEnd()) self.pos += 1;
        try self.emitDecl(.go_import, name_range, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseFunc(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
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
            const recv_start = self.pos;
            try self.skipBalanced('(', ')');
            const recv_end = self.pos;
            kind = .go_method;
            receiver_range = .{ .start = recv_start, .end = recv_end };
            self.skipTrivia();
        }
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        const ident_range: Range = if (kind == .go_method and receiver_range.end > receiver_range.start) blk: {
            _ = anon_counter;
            _ = anon_buf;
            break :blk name;
        } else name;
        const name_bytes = self.src[ident_range.start..ident_range.end];

        // Walk header (params + return type) until `{` (body) or newline (proto).
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '{' or c == '\n') break;
            switch (c) {
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"' => try self.skipString(),
                '\'' => try self.skipRune(),
                '`' => try self.skipRawString(),
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) self.skipTrivia()
                    else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }

        const fn_identity = hash_mod.identityHash(parent_identity, kind, name_bytes);

        var stmt_indices: std.ArrayList(NodeIndex) = .empty;
        defer stmt_indices.deinit(self.gpa);
        var stmt_hashes: std.ArrayList(u64) = .empty;
        defer stmt_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1; // enter body
            try self.parseFnBody(fn_identity, &stmt_indices, &stmt_hashes);
        } else {
            // Proto / no-body: consume to newline.
            if (!self.atEnd() and self.src[self.pos] == '\n') self.pos += 1;
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const fn_h = hash_mod.subtreeHash(kind, stmt_hashes.items, decl_bytes);

        const fn_idx = try self.tree.addNode(.{
            .hash = fn_h,
            .identity_hash = fn_identity,
            .kind = kind,
            .depth = 1,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = ident_range,
        });
        try decl_indices.append(self.gpa, fn_idx);
        try decl_hashes.append(self.gpa, fn_h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (stmt_indices.items) |s| parents[s] = fn_idx;
    }

    /// Walk inside a Go fn body's `{...}`, emit one node per top-level statement.
    /// Statements terminate at `\n` (Go ASI), `;`, OR a complete `{...}` block.
    /// Caller has set `self.pos` to just AFTER opening `{`. On return, `self.pos`
    /// is just AFTER the matching closing `}`.
    fn parseFnBody(
        self: *Parser,
        fn_identity: u64,
        stmt_indices: *std.ArrayList(NodeIndex),
        stmt_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        var stmt_idx: u32 = 0;
        var idx_buf: [16]u8 = undefined;

        while (!self.atEnd()) {
            // Skip leading whitespace + comments + bare semicolons.
            while (!self.atEnd()) {
                const c = self.src[self.pos];
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ';') {
                    self.pos += 1;
                    continue;
                }
                if (c == '/' and (self.peek(1) == @as(u8, '/') or self.peek(1) == @as(u8, '*'))) {
                    self.skipTrivia();
                    continue;
                }
                break;
            }
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
            const stmt_identity = hash_mod.identityHash(fn_identity, .go_stmt, idx_str);
            const stmt_h = hash_mod.subtreeHash(.go_stmt, &.{}, trimmed);

            const node = try self.tree.addNode(.{
                .hash = stmt_h,
                .identity_hash = stmt_identity,
                .kind = .go_stmt,
                .depth = 2,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = stmt_start, .end = stmt_end },
                .identity_range = Range.empty,
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
                '\n', ';' => {
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
                '"' => try self.skipString(),
                '\'' => try self.skipRune(),
                '`' => try self.skipRawString(),
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) self.skipTrivia()
                    else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
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
            self.pos += 1;
            try self.parseGroupedEntries(.go_type, root_identity, decl_indices, decl_hashes, anon_counter, anon_buf, extractFirstIdent);
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
            self.pos += 1;
            try self.parseGroupedEntries(kind, root_identity, decl_indices, decl_hashes, anon_counter, anon_buf, extractFirstIdent);
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

test "parse package and imports (split)" {
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
    // package, import "fmt", import "os", import "io", file_root = 5
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    try std.testing.expectEqual(Kind.go_package, kinds[0]);
    try std.testing.expectEqual(Kind.go_import, kinds[1]);
    try std.testing.expectEqual(Kind.go_import, kinds[2]);
    try std.testing.expectEqual(Kind.go_import, kinds[3]);

    try std.testing.expectEqualStrings("main", t.identitySlice(0));
    try std.testing.expectEqualStrings("fmt", t.identitySlice(1));
    try std.testing.expectEqualStrings("os", t.identitySlice(2));
    try std.testing.expectEqualStrings("io", t.identitySlice(3));
}

test "grouped const splits per name" {
    const gpa = std.testing.allocator;
    const src =
        \\package x
        \\
        \\const (
        \\    A = 1
        \\    B = 2
        \\    C = "hello"
        \\)
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    // package, const A, const B, const C, file_root = 5
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    try std.testing.expectEqual(Kind.go_const, kinds[1]);
    try std.testing.expectEqual(Kind.go_const, kinds[2]);
    try std.testing.expectEqual(Kind.go_const, kinds[3]);
    try std.testing.expectEqualStrings("A", t.identitySlice(1));
    try std.testing.expectEqualStrings("B", t.identitySlice(2));
    try std.testing.expectEqualStrings("C", t.identitySlice(3));
}

test "grouped type and var split" {
    const gpa = std.testing.allocator;
    const src =
        \\package x
        \\
        \\type (
        \\    Point struct { X, Y int }
        \\    Vec []float64
        \\)
        \\
        \\var (
        \\    counter int
        \\    name = "foo"
        \\)
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    // package, type Point, type Vec, var counter, var name, file_root
    try std.testing.expectEqual(@as(usize, 6), t.nodes.len);
    try std.testing.expectEqual(Kind.go_type, kinds[1]);
    try std.testing.expectEqual(Kind.go_type, kinds[2]);
    try std.testing.expectEqual(Kind.go_var, kinds[3]);
    try std.testing.expectEqual(Kind.go_var, kinds[4]);
    try std.testing.expectEqualStrings("Point", t.identitySlice(1));
    try std.testing.expectEqualStrings("Vec", t.identitySlice(2));
    try std.testing.expectEqualStrings("counter", t.identitySlice(3));
    try std.testing.expectEqualStrings("name", t.identitySlice(4));
}

test "aliased import keeps path as identity" {
    const gpa = std.testing.allocator;
    const src =
        \\package x
        \\
        \\import (
        \\    f "fmt"
        \\    _ "embed"
        \\    . "math"
        \\)
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();
    // 3 imports + package + file_root
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    try std.testing.expectEqualStrings("fmt", t.identitySlice(1));
    try std.testing.expectEqualStrings("embed", t.identitySlice(2));
    try std.testing.expectEqualStrings("math", t.identitySlice(3));
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
    // Each fn has 1 stmt pushed before it (post-order).
    try std.testing.expectEqual(Kind.go_stmt, kinds[1]);
    try std.testing.expectEqual(Kind.go_fn, kinds[2]);
    try std.testing.expectEqual(Kind.go_stmt, kinds[3]);
    try std.testing.expectEqual(Kind.go_method, kinds[4]);
    try std.testing.expectEqualStrings("Add", t.identitySlice(2));
    try std.testing.expectEqualStrings("Area", t.identitySlice(4));
}

test "go fn body extracts statement nodes" {
    const gpa = std.testing.allocator;
    const src =
        \\package x
        \\
        \\func Add(a, b int) int {
        \\    x := a + b
        \\    y := x * 2
        \\    return y
        \\}
    ;
    var t = try parse(gpa, src, "x.go");
    defer t.deinit();

    const kinds = t.nodes.items(.kind);
    var fn_idx: ?NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .go_fn) {
        fn_idx = @intCast(i);
        break;
    };
    try std.testing.expect(fn_idx != null);

    var stmt_count: usize = 0;
    const parents = t.nodes.items(.parent_idx);
    for (kinds, 0..) |k, i| {
        if (k == .go_stmt and parents[i] == fn_idx.?) stmt_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), stmt_count);
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
    // A has 2 stmts (s := ..., _ = s), B has 0.
    // Order: pkg, stmt, stmt, fn A, fn B, file_root.
    try std.testing.expectEqual(Kind.go_fn, kinds[3]);
    try std.testing.expectEqual(Kind.go_fn, kinds[4]);
    try std.testing.expectEqualStrings("A", t.identitySlice(3));
    try std.testing.expectEqualStrings("B", t.identitySlice(4));
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
