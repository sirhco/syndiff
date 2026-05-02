//! Rust top-level decl parser. Extracts every item at file scope and recurses
//! one level into `impl` blocks so methods become individual children of the
//! impl node. Function bodies, mod bodies, and trait bodies remain opaque —
//! body changes register as MODIFIED on the enclosing decl.
//!
//! Recognized items (with leading attributes & visibility absorbed into the
//! decl's content range):
//!   fn, struct, enum, union, trait, impl (with method children), mod, use,
//!   const, static, type, extern, macro_rules! and macro invocations.
//!
//! Identity composition:
//!   * fn / struct / etc. at file scope: `parent_root + kind + name`
//!   * methods inside impl:              `impl_identity + .rust_fn + name`
//!     so two `impl A { fn x }` and `impl B { fn x }` produce distinct
//!     identities — diffs attribute correctly across receiver types.
//!
//! Strategy: skim lexer that correctly skips comments, string literals, raw
//! strings, char literals, and lifetimes — so the brace-counting body skip
//! never gets confused by `}` inside a string. The shared `scanContainer`
//! drives both file-scope and impl-body iteration.

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
    UnterminatedRawString,
} || std.mem.Allocator.Error;

const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: u32,
    tree: *ast_mod.Tree,
    /// Depth at which `emitDecl*` records nodes — set by `scanContainer`
    /// and restored on exit. File-scope decls = 1, impl-body items = 2.
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
                        while (!self.atEnd() and self.src[self.pos] != '\n') self.pos += 1;
                    } else if (n == '*') {
                        self.pos += 2;
                        var depth: u32 = 1;
                        while (self.pos + 1 < self.src.len and depth > 0) {
                            const a = self.src[self.pos];
                            const b = self.src[self.pos + 1];
                            if (a == '/' and b == '*') {
                                depth += 1;
                                self.pos += 2;
                            } else if (a == '*' and b == '/') {
                                depth -= 1;
                                self.pos += 2;
                            } else {
                                self.pos += 1;
                            }
                        }
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
        }
        return error.UnterminatedString;
    }

    /// Raw string: r"..." / r#"..."# / r##"..."## etc.
    /// Caller has confirmed `r` at pos and one of `"` or `#` at pos+1.
    fn skipRawString(self: *Parser) ParseError!void {
        self.pos += 1; // r
        var hashes: u32 = 0;
        while (!self.atEnd() and self.src[self.pos] == '#') : (self.pos += 1) hashes += 1;
        if (self.atEnd() or self.src[self.pos] != '"') return error.UnterminatedRawString;
        self.pos += 1; // opening "
        while (!self.atEnd()) {
            if (self.src[self.pos] == '"') {
                // need `hashes` closing #s
                var i: u32 = 0;
                while (i < hashes and self.pos + 1 + i < self.src.len and self.src[self.pos + 1 + i] == '#') : (i += 1) {}
                if (i == hashes) {
                    self.pos += 1 + hashes;
                    return;
                }
            }
            self.pos += 1;
        }
        return error.UnterminatedRawString;
    }

    /// Apostrophe at pos: char literal or lifetime. Char literals can contain
    /// `{`/`}`, lifetimes cannot, so they must be distinguished.
    fn skipQuoteOrLifetime(self: *Parser) void {
        // 'x' (3 chars) — char.
        if (self.peek(1) != null and self.peek(2) == '\'') {
            self.pos += 3;
            return;
        }
        // '\X...' — char with escape.
        if (self.peek(1) == '\\') {
            self.pos += 1; // '
            // Find closing '.
            while (!self.atEnd()) {
                const c = self.src[self.pos];
                if (c == '\\') {
                    self.pos += 2;
                    continue;
                }
                self.pos += 1;
                if (c == '\'') return;
            }
            return;
        }
        // Lifetime: skip apostrophe, ident chars consumed by main loop.
        self.pos += 1;
    }

    /// True if `r` at pos starts a raw-string token (followed by # or ").
    fn looksLikeRawString(self: *Parser) bool {
        if (self.atEnd() or self.src[self.pos] != 'r') return false;
        const n = self.peek(1) orelse return false;
        if (n == '"' or n == '#') return true;
        return false;
    }

    /// True if `b` at pos starts a byte/raw-byte string token.
    fn looksLikeByteString(self: *Parser) bool {
        if (self.atEnd() or self.src[self.pos] != 'b') return false;
        const n = self.peek(1) orelse return false;
        if (n == '"' or n == '\'') return true;
        if (n == 'r') {
            const n2 = self.peek(2) orelse return false;
            return n2 == '"' or n2 == '#';
        }
        return false;
    }

    /// Skip past a balanced delimited block at pos. open/close must match.
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
                '\'' => self.skipQuoteOrLifetime(),
                'r' => {
                    if (self.looksLikeRawString()) {
                        try self.skipRawString();
                    } else self.pos += 1;
                },
                'b' => {
                    if (self.looksLikeByteString()) {
                        // b"..." or b'.' or br"..."#...
                        if (self.peek(1) == '\'') {
                            self.skipQuoteOrLifetime();
                        } else if (self.peek(1) == '"') {
                            self.pos += 1;
                            try self.skipString();
                        } else {
                            // br...
                            self.pos += 1; // skip b
                            try self.skipRawString();
                        }
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
        // Ensure word boundary.
        const next = self.pos + word.len;
        if (next < self.src.len and isIdentCont(self.src[next])) return false;
        return true;
    }

    /// Skip `pub`, `pub(crate)`, `pub(super)`, `pub(self)`, `pub(in path::...)`.
    fn skipVisibility(self: *Parser) void {
        if (!self.matchKeyword("pub")) return;
        self.pos += 3;
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '(') {
            self.skipBalanced('(', ')') catch {};
        }
    }

    /// Skip `unsafe`, `async`, `const`, `extern "C"`, `default` modifiers.
    /// Stops at the actual decl keyword.
    fn skipFnModifiers(self: *Parser) void {
        while (true) {
            self.skipTrivia();
            if (self.matchKeyword("unsafe")) {
                self.pos += 6;
            } else if (self.matchKeyword("async")) {
                self.pos += 5;
            } else if (self.matchKeyword("default")) {
                self.pos += 7;
            } else break;
        }
    }

    /// Skip an attribute starting with `#`. Handles `#[...]` and `#![...]`.
    fn skipAttribute(self: *Parser) ParseError!void {
        if (self.atEnd() or self.src[self.pos] != '#') return;
        self.pos += 1;
        if (!self.atEnd() and self.src[self.pos] == '!') self.pos += 1;
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '[') {
            try self.skipBalanced('[', ']');
        }
    }

    /// Top-level entry: walk the file, emit one Node per decl.
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
            .kind = .file_root,
            .depth = 0,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = 0, .end = @intCast(self.src.len) },
            .identity_range = Range.empty,
        });
        const parents = self.tree.nodes.items(.parent_idx);
        for (decl_indices.items) |d| parents[d] = root_idx;
    }

    /// Scan a sequence of items in a container scope. Used both for the file
    /// scope (`stop_at_close_brace = false`, runs to EOF) and for impl bodies
    /// (`stop_at_close_brace = true`, runs to matching `}` and consumes it).
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
        var anon_buf: [32]u8 = undefined;

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;

            if (stop_at_close_brace and self.src[self.pos] == '}') {
                self.pos += 1; // consume closing brace
                return;
            }

            const decl_start = self.pos;

            // Absorb any number of leading attributes.
            while (!self.atEnd() and self.src[self.pos] == '#' and
                (self.peek(1) == '[' or self.peek(1) == '!'))
            {
                try self.skipAttribute();
                self.skipTrivia();
            }

            if (self.atEnd()) break;

            self.skipVisibility();
            self.skipTrivia();
            self.skipFnModifiers();
            self.skipTrivia();

            // Macro-rules: `macro_rules! name { ... }`
            if (self.matchKeyword("macro_rules")) {
                self.pos += "macro_rules".len;
                self.skipTrivia();
                if (!self.atEnd() and self.src[self.pos] == '!') self.pos += 1;
                self.skipTrivia();
                const name = self.scanIdent() orelse blk: {
                    anon_counter += 1;
                    break :blk Range{ .start = 0, .end = 0 };
                };
                self.skipTrivia();
                // Body: { ... } or ( ... ) or [ ... ]
                if (!self.atEnd()) {
                    const c = self.src[self.pos];
                    if (c == '{') try self.skipBalanced('{', '}')
                    else if (c == '(') try self.skipBalanced('(', ')')
                    else if (c == '[') try self.skipBalanced('[', ']');
                }
                // Optional trailing semicolon.
                self.skipTrivia();
                if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;

                try self.emitDecl(.rust_macro, name, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }

            const kw_start = self.pos;
            const kw_range = self.scanIdent() orelse {
                // Unrecognized / stray byte. Advance and retry.
                if (!self.atEnd()) self.pos += 1;
                continue;
            };
            const kw = self.src[kw_range.start..kw_range.end];

            // Dispatch on keyword.
            if (std.mem.eql(u8, kw, "fn")) {
                try self.parseFn(decl_start, parent_identity, decl_indices, decl_hashes);
            } else if (std.mem.eql(u8, kw, "struct") or
                std.mem.eql(u8, kw, "enum") or
                std.mem.eql(u8, kw, "union"))
            {
                try self.parseTypeContainer(decl_start, parent_identity, decl_indices, decl_hashes);
            } else if (std.mem.eql(u8, kw, "trait")) {
                try self.parseNamedBraced(.rust_trait, decl_start, parent_identity, decl_indices, decl_hashes);
            } else if (std.mem.eql(u8, kw, "impl")) {
                try self.parseImpl(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter, &anon_buf);
            } else if (std.mem.eql(u8, kw, "mod")) {
                try self.parseMod(decl_start, parent_identity, decl_indices, decl_hashes);
            } else if (std.mem.eql(u8, kw, "use")) {
                try self.parseTerminated(.rust_use, decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter, &anon_buf);
            } else if (std.mem.eql(u8, kw, "const") or
                std.mem.eql(u8, kw, "static") or
                std.mem.eql(u8, kw, "type"))
            {
                try self.parseConstLike(decl_start, parent_identity, decl_indices, decl_hashes);
            } else if (std.mem.eql(u8, kw, "extern")) {
                try self.parseExtern(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter, &anon_buf);
            } else {
                // Possibly a macro invocation: `name!(...);` or `name!{...}`.
                self.skipTrivia();
                if (!self.atEnd() and self.src[self.pos] == '!') {
                    self.pos += 1;
                    self.skipTrivia();
                    if (!self.atEnd()) {
                        const c = self.src[self.pos];
                        if (c == '{') try self.skipBalanced('{', '}')
                        else if (c == '(') {
                            try self.skipBalanced('(', ')');
                            // Often followed by ; for stmt-style invocation.
                            self.skipTrivia();
                            if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;
                        } else if (c == '[') try self.skipBalanced('[', ']');
                    }
                    try self.emitDecl(.rust_macro, kw_range, decl_start, parent_identity, decl_indices, decl_hashes);
                    continue;
                }
                // Unknown construct — skip past this token and keep scanning.
                _ = kw_start;
            }
        }
    }

    /// Helpers to absorb common decl shapes.

    fn parseFn(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        // Already past `fn`. Parse name, then skip generics/params/ret, then
        // body or `;` (for trait fn defaulting to no body but at top level
        // this means an extern fn declaration which needs `;`).
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        // Consume generics, params, where clauses, return type, body.
        try self.skipUntilDeclEnd();
        try self.emitDecl(.rust_fn, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseTypeContainer(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilDeclEnd();
        try self.emitDecl(.rust_struct, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseNamedBraced(
        self: *Parser,
        kind: Kind,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilDeclEnd();
        try self.emitDecl(kind, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseImpl(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        // Capture impl signature bytes (between `impl` and `{`).
        const sig_start = self.pos;
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '{') break;
            if (c == '<') {
                self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                };
                continue;
            }
            if (c == '(') {
                try self.skipBalanced('(', ')');
                continue;
            }
            if (c == '"') {
                try self.skipString();
                continue;
            }
            self.pos += 1;
        }
        const sig_end = self.pos;

        // Trim signature for identity range.
        var s: u32 = sig_start;
        while (s < sig_end and (self.src[s] == ' ' or self.src[s] == '\t' or self.src[s] == '\n' or self.src[s] == '\r')) s += 1;
        var e: u32 = sig_end;
        while (e > s and (self.src[e - 1] == ' ' or self.src[e - 1] == '\t' or self.src[e - 1] == '\n' or self.src[e - 1] == '\r')) e -= 1;
        const sig_range: Range = if (e > s) .{ .start = s, .end = e } else blk: {
            _ = std.fmt.bufPrint(anon_buf, "<impl:{d}>", .{anon_counter.*}) catch unreachable;
            anon_counter.* += 1;
            break :blk Range.empty;
        };

        // Compose impl identity from parent + sig bytes; methods inside use
        // this as their parent_identity, so two impl blocks for different
        // types yield distinct method identities.
        const sig_bytes = self.src[sig_range.start..sig_range.end];
        const impl_identity = hash_mod.identityHash(parent_identity, .rust_impl, sig_bytes);

        // Recurse into impl body.
        var method_indices: std.ArrayList(NodeIndex) = .empty;
        defer method_indices.deinit(self.gpa);
        var method_hashes: std.ArrayList(u64) = .empty;
        defer method_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1; // enter body
            try self.scanContainer(impl_identity, self.current_depth + 1, true, &method_indices, &method_hashes);
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const impl_hash = hash_mod.subtreeHash(.rust_impl, method_hashes.items, decl_bytes);

        const impl_idx = try self.tree.addNode(.{
            .hash = impl_hash,
            .identity_hash = impl_identity,
            .kind = .rust_impl,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = sig_range,
        });
        try decl_indices.append(self.gpa, impl_idx);
        try decl_hashes.append(self.gpa, impl_hash);

        // Backpatch each method's parent_idx to the impl node.
        const parents = self.tree.nodes.items(.parent_idx);
        for (method_indices.items) |m| parents[m] = impl_idx;
    }

    fn parseMod(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        self.skipTrivia();
        // `mod foo;` or `mod foo { ... }`
        if (!self.atEnd() and self.src[self.pos] == ';') {
            self.pos += 1;
        } else if (!self.atEnd() and self.src[self.pos] == '{') {
            try self.skipBalanced('{', '}');
        } else {
            try self.skipUntilDeclEnd();
        }
        try self.emitDecl(.rust_mod, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseConstLike(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilSemi();
        try self.emitDecl(.rust_const, name, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseTerminated(
        self: *Parser,
        kind: Kind,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        const name_start = self.pos;
        try self.skipUntilSemi();
        const name_end = self.pos;
        // `use` paths are not single identifiers; use the path bytes (trimmed
        // of trailing `;`) as identity.
        var s = name_start;
        while (s < self.src.len and (self.src[s] == ' ' or self.src[s] == '\t' or self.src[s] == '\n' or self.src[s] == '\r')) s += 1;
        var e = name_end;
        if (e > s and self.src[e - 1] == ';') e -= 1;
        while (e > s and (self.src[e - 1] == ' ' or self.src[e - 1] == '\t' or self.src[e - 1] == '\n' or self.src[e - 1] == '\r')) e -= 1;
        const name_range: Range = if (e > s) .{ .start = s, .end = e } else blk: {
            const idx_str = std.fmt.bufPrint(anon_buf, "<{d}>", .{anon_counter.*}) catch unreachable;
            anon_counter.* += 1;
            _ = idx_str;
            break :blk Range.empty;
        };
        try self.emitDeclWithRange(kind, name_range, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn parseExtern(
        self: *Parser,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
        anon_buf: *[32]u8,
    ) ParseError!void {
        // `extern crate foo;` / `extern "C" { ... }` / `extern "C" fn foo(...)`
        self.skipTrivia();
        // ABI string?
        if (!self.atEnd() and self.src[self.pos] == '"') {
            try self.skipString();
            self.skipTrivia();
        } else if (self.matchKeyword("crate")) {
            self.pos += 5;
            self.skipTrivia();
            const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
            try self.skipUntilSemi();
            try self.emitDecl(.rust_use, name, decl_start, root_identity, decl_indices, decl_hashes);
            return;
        }
        // Block or fn.
        if (!self.atEnd() and self.src[self.pos] == '{') {
            try self.skipBalanced('{', '}');
            const idx_str = std.fmt.bufPrint(anon_buf, "<extern:{d}>", .{anon_counter.*}) catch unreachable;
            anon_counter.* += 1;
            _ = idx_str;
            try self.emitDeclWithRange(.rust_struct, Range.empty, decl_start, root_identity, decl_indices, decl_hashes);
        } else if (self.matchKeyword("fn")) {
            self.pos += 2;
            try self.parseFn(decl_start, root_identity, decl_indices, decl_hashes);
        } else {
            try self.skipUntilDeclEnd();
        }
    }

    /// Skip up to and including the next `;` at depth 0, OR a balanced `{...}`
    /// body, whichever comes first.
    fn skipUntilDeclEnd(self: *Parser) ParseError!void {
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) return;
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
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '"' => try self.skipString(),
                '\'' => self.skipQuoteOrLifetime(),
                'r' => {
                    if (self.looksLikeRawString()) try self.skipRawString() else self.pos += 1;
                },
                'b' => {
                    if (self.looksLikeByteString()) {
                        if (self.peek(1) == '\'') self.skipQuoteOrLifetime()
                        else if (self.peek(1) == '"') {
                            self.pos += 1;
                            try self.skipString();
                        } else {
                            self.pos += 1;
                            try self.skipRawString();
                        }
                    } else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn skipUntilSemi(self: *Parser) ParseError!void {
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) return;
            const c = self.src[self.pos];
            switch (c) {
                ';' => {
                    self.pos += 1;
                    return;
                },
                '{' => try self.skipBalanced('{', '}'),
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"' => try self.skipString(),
                '\'' => self.skipQuoteOrLifetime(),
                'r' => {
                    if (self.looksLikeRawString()) try self.skipRawString() else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn emitDecl(
        self: *Parser,
        kind: Kind,
        name_range: Range,
        decl_start: u32,
        root_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        try self.emitDeclWithRange(kind, name_range, decl_start, root_identity, decl_indices, decl_hashes);
    }

    fn emitDeclWithRange(
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
        const decl_h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = decl_h,
            .identity_hash = decl_identity,
            .kind = kind,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = identity_range,
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
    var t = try parse(gpa, "", "x.rs");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.file_root, t.nodes.items(.kind)[0]);
}

test "parse single fn" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "pub fn add(a: i32, b: i32) -> i32 { a + b }", "x.rs");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
    try std.testing.expectEqual(Kind.rust_fn, t.nodes.items(.kind)[0]);
    try std.testing.expectEqualStrings("add", t.identitySlice(0));
}

test "parse mixed top-level decls" {
    const gpa = std.testing.allocator;
    const src =
        \\use std::collections::HashMap;
        \\
        \\pub struct Point { x: i32, y: i32 }
        \\
        \\pub enum Color { R, G, B }
        \\
        \\pub trait Shape { fn area(&self) -> f64; }
        \\
        \\impl Shape for Point {
        \\    fn area(&self) -> f64 { 0.0 }
        \\}
        \\
        \\const MAX: usize = 100;
        \\
        \\pub fn foo() {}
    ;
    var t = try parse(gpa, src, "x.rs");
    defer t.deinit();

    const kinds = t.nodes.items(.kind);
    // 7 file-scope decls + 1 impl method (area) + file_root = 9
    try std.testing.expectEqual(@as(usize, 9), t.nodes.len);
    try std.testing.expectEqual(Kind.rust_use, kinds[0]);
    try std.testing.expectEqual(Kind.rust_struct, kinds[1]);
    try std.testing.expectEqual(Kind.rust_struct, kinds[2]);
    try std.testing.expectEqual(Kind.rust_trait, kinds[3]);
    // Methods pushed before impl (post-order).
    try std.testing.expectEqual(Kind.rust_fn, kinds[4]); // area inside impl
    try std.testing.expectEqual(Kind.rust_impl, kinds[5]);
    try std.testing.expectEqual(Kind.rust_const, kinds[6]);
    try std.testing.expectEqual(Kind.rust_fn, kinds[7]); // foo
    try std.testing.expectEqual(Kind.file_root, kinds[8]);

    // Method's parent_idx points at impl.
    const parents = t.nodes.items(.parent_idx);
    try std.testing.expectEqual(@as(NodeIndex, 5), parents[4]);
}

test "impl methods extracted as children with composed identity" {
    const gpa = std.testing.allocator;
    const src =
        \\impl Foo {
        \\    pub fn a(&self) {}
        \\    pub fn b(&self) {}
        \\}
        \\
        \\impl Bar {
        \\    pub fn a(&self) {}
        \\}
    ;
    var t = try parse(gpa, src, "x.rs");
    defer t.deinit();

    const kinds = t.nodes.items(.kind);
    const idents = t.nodes.items(.identity_hash);
    var fn_a_in_foo: ?NodeIndex = null;
    var fn_a_in_bar: ?NodeIndex = null;

    for (kinds, 0..) |k, i| if (k == .rust_fn) {
        const idx: NodeIndex = @intCast(i);
        if (std.mem.eql(u8, t.identitySlice(idx), "a")) {
            if (fn_a_in_foo == null) fn_a_in_foo = idx else fn_a_in_bar = idx;
        }
    };

    try std.testing.expect(fn_a_in_foo != null and fn_a_in_bar != null);
    // Same name, different parent impls → different identity hashes.
    try std.testing.expect(idents[fn_a_in_foo.?] != idents[fn_a_in_bar.?]);
}

test "fn body containing braces in strings does not break parser" {
    const gpa = std.testing.allocator;
    const src =
        \\fn weird() {
        \\    let s = "}}{{}}";
        \\    let r = r#"more } { junk"#;
        \\    let c = '}';
        \\}
        \\
        \\fn next() {}
    ;
    var t = try parse(gpa, src, "x.rs");
    defer t.deinit();
    // 2 fns + file_root
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    try std.testing.expectEqualStrings("weird", t.identitySlice(0));
    try std.testing.expectEqualStrings("next", t.identitySlice(1));
}

test "attributes absorbed into decl content" {
    const gpa = std.testing.allocator;
    const src =
        \\#[derive(Debug, Clone)]
        \\pub struct Thing {}
    ;
    var t = try parse(gpa, src, "x.rs");
    defer t.deinit();
    // Decl content range should start at the `#`, not at `pub struct`.
    const r = t.nodes.items(.content_range)[0];
    try std.testing.expectEqual(@as(u32, 0), r.start);
}

test "comments do not break parser" {
    const gpa = std.testing.allocator;
    const src =
        \\// comment
        \\/* block /* nested */ comment */
        \\fn one() {}
        \\fn two() {}
    ;
    var t = try parse(gpa, src, "x.rs");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
}

test "subtree hash differs when fn body changes" {
    const gpa = std.testing.allocator;
    var a = try parse(gpa, "fn f() -> i32 { 1 }", "a.rs");
    defer a.deinit();
    var b = try parse(gpa, "fn f() -> i32 { 2 }", "b.rs");
    defer b.deinit();
    try std.testing.expect(a.nodes.items(.hash)[0] != b.nodes.items(.hash)[0]);
    try std.testing.expectEqual(a.nodes.items(.identity_hash)[0], b.nodes.items(.identity_hash)[0]);
}

test "macro_rules and macro invocation captured" {
    const gpa = std.testing.allocator;
    const src =
        \\macro_rules! my_macro {
        \\    ($x:expr) => { $x + 1 };
        \\}
        \\
        \\println!("hello");
    ;
    var t = try parse(gpa, src, "x.rs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.rust_macro, kinds[0]);
    try std.testing.expectEqual(Kind.rust_macro, kinds[1]);
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
    if (parse(gpa, buf.items, "fuzz.rs")) |t| {
        var t2 = t;
        defer t2.deinit();
    } else |err| switch (err) {
        error.UnterminatedBlock,
        error.UnterminatedString,
        error.UnterminatedRawString,
        error.OutOfMemory,
        => {},
    }
}
