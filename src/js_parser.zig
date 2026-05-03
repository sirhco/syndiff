//! JavaScript top-level + body parser. Same shape as `rust_parser.zig` /
//! `go_parser.zig`: skim lexer + brace-counting body skip + per-decl node.
//!
//! Recognized top-level items:
//!   import / export                              → js_import / js_export
//!   function / async function NAME(...)          → js_function
//!   class NAME { ... }                           → js_class (with method/field children)
//!   const / let / var NAME ...                   → js_const / js_let / js_var
//!
//! Class body members:
//!   NAME(...) { ... }   → js_method
//!   NAME = ...;          → js_const (field-style)
//!
//! Function bodies break into `js_stmt` children (per-statement, split on `;`
//! OR newline at brace-depth 0 OR a balanced `{...}` block — Go-ish).
//!
//! Limitations:
//!   * Regex/division disambiguation is heuristic (last-token context).
//!     Pathological code may misclassify a `/`.
//!   * Template literals (with `${...}` interpolation) are handled.
//!   * JSX is NOT recognized in plain `.js` (use `.tsx` for TS+JSX).

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

const TokenContext = enum { expression, operand };

const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: u32,
    tree: *ast_mod.Tree,
    current_depth: u16 = 1,
    /// For `/` ambiguity: regex vs division. `.expression` → regex, else division.
    last_ctx: TokenContext = .expression,

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
        const quote = self.src[self.pos];
        if (quote == '"') {
            self.pos = lex.skipDoubleQuoteString(self.src, self.pos) catch return error.UnterminatedString;
        } else {
            self.pos = lex.skipSingleQuoteString(self.src, self.pos) catch return error.UnterminatedString;
        }
    }

    /// Template literal: `text ${expr} more`. Calls back into balanced-block
    /// scanning for the interpolation expression.
    fn skipTemplate(self: *Parser) ParseError!void {
        self.pos += 1; // opening `
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            if (c == '`') {
                self.pos += 1;
                return;
            }
            if (c == '$' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '{') {
                self.pos += 2;
                // Walk to matching `}`, treating nested strings/templates etc.
                try self.skipBalancedBraceContent();
                continue;
            }
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    /// Walk until matching `}` after entering a `${...}` interpolation.
    /// Caller has consumed the opening `${`. Returns just after the matching `}`.
    fn skipBalancedBraceContent(self: *Parser) ParseError!void {
        var depth: u32 = 1;
        while (!self.atEnd() and depth > 0) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => {
                    self.pos += 1;
                },
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else if (self.last_ctx == .expression) {
                        try self.skipRegex();
                        self.last_ctx = .operand;
                    } else {
                        self.pos += 1;
                        self.last_ctx = .expression;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.last_ctx = .operand;
                },
                '`' => {
                    try self.skipTemplate();
                    self.last_ctx = .operand;
                },
                '{' => {
                    depth += 1;
                    self.pos += 1;
                    self.last_ctx = .expression;
                },
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                    if (depth == 0) return;
                    self.last_ctx = .operand;
                },
                else => {
                    if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.last_ctx = identCtxAfter(word);
                    } else {
                        self.pos += 1;
                        self.last_ctx = punctCtxAfter(c);
                    }
                },
            }
        }
        if (depth != 0) return error.UnterminatedBlock;
    }

    fn skipRegex(self: *Parser) ParseError!void {
        self.pos += 1; // opening /
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            if (c == '[') {
                self.pos += 1;
                while (self.pos < self.src.len and self.src[self.pos] != ']') {
                    if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                        self.pos += 2;
                    } else self.pos += 1;
                }
                if (self.pos < self.src.len) self.pos += 1;
                continue;
            }
            if (c == '/') {
                self.pos += 1;
                while (self.pos < self.src.len and lex.isIdentCont(self.src[self.pos])) self.pos += 1;
                return;
            }
            if (c == '\n') return error.UnterminatedString;
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    /// Generic balanced delimiter walk for non-brace pairs (parens, brackets,
    /// generics). Tracks `last_ctx` so regex/template scans inside work.
    fn skipBalanced(self: *Parser, open: u8, close: u8) ParseError!void {
        if (self.atEnd() or self.src[self.pos] != open) return;
        self.pos += 1;
        var depth: u32 = 1;
        const saved = self.last_ctx;
        self.last_ctx = .expression;
        while (!self.atEnd() and depth > 0) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else if (self.last_ctx == .expression) {
                        try self.skipRegex();
                        self.last_ctx = .operand;
                    } else {
                        self.pos += 1;
                        self.last_ctx = .expression;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.last_ctx = .operand;
                },
                '`' => {
                    try self.skipTemplate();
                    self.last_ctx = .operand;
                },
                '{' => {
                    if (open == '{') depth += 1;
                    self.pos += 1;
                    self.last_ctx = .expression;
                    if (open != '{') {
                        // Inner brace block — recurse to balance.
                        try self.skipUntilBraceClose();
                    }
                },
                '}' => {
                    if (open == '{') {
                        depth -= 1;
                        self.pos += 1;
                        self.last_ctx = .operand;
                    } else {
                        // Stray } — bail.
                        return;
                    }
                },
                else => {
                    if (c == open) {
                        depth += 1;
                        self.pos += 1;
                        self.last_ctx = .expression;
                    } else if (c == close) {
                        depth -= 1;
                        self.pos += 1;
                        self.last_ctx = .operand;
                    } else if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.last_ctx = identCtxAfter(word);
                    } else {
                        self.pos += 1;
                        self.last_ctx = punctCtxAfter(c);
                    }
                },
            }
        }
        self.last_ctx = saved;
        if (depth != 0) return error.UnterminatedBlock;
    }

    /// Walk until a matching `}` for a brace block that the caller has already
    /// stepped INSIDE of. Used recursively when nested blocks appear inside
    /// non-brace balanced scans.
    fn skipUntilBraceClose(self: *Parser) ParseError!void {
        var depth: u32 = 1;
        while (!self.atEnd() and depth > 0) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else if (self.last_ctx == .expression) {
                        try self.skipRegex();
                        self.last_ctx = .operand;
                    } else {
                        self.pos += 1;
                        self.last_ctx = .expression;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.last_ctx = .operand;
                },
                '`' => {
                    try self.skipTemplate();
                    self.last_ctx = .operand;
                },
                '{' => {
                    depth += 1;
                    self.pos += 1;
                    self.last_ctx = .expression;
                },
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                    self.last_ctx = .operand;
                },
                else => {
                    if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.last_ctx = identCtxAfter(word);
                    } else {
                        self.pos += 1;
                        self.last_ctx = punctCtxAfter(c);
                    }
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

            // Recognize keyword-led decls.
            if (self.matchKeyword("import")) {
                self.pos += "import".len;
                try self.parseDirective(.js_import, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("export")) {
                self.pos += "export".len;
                try self.parseExport(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }
            if (self.matchKeyword("async")) {
                // Look ahead: `async function ...`
                const save = self.pos;
                self.pos += "async".len;
                self.skipTrivia();
                if (self.matchKeyword("function")) {
                    self.pos += "function".len;
                    try self.parseFunction(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                    continue;
                }
                self.pos = save;
                // Fall through to member/stmt handler.
            }
            if (self.matchKeyword("function")) {
                self.pos += "function".len;
                try self.parseFunction(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }
            if (self.matchKeyword("class")) {
                self.pos += "class".len;
                try self.parseClass(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }
            if (self.matchKeyword("const")) {
                self.pos += "const".len;
                try self.parseVarLike(.js_const, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("let")) {
                self.pos += "let".len;
                try self.parseVarLike(.js_let, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("var")) {
                self.pos += "var".len;
                try self.parseVarLike(.js_var, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }

            // Class body: parse member.
            if (stop_at_close_brace) {
                try self.parseClassMember(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }

            // Top-level expression-stmt: skip to `;`/newline.
            try self.skipUntilStmtEnd();
        }
    }

    fn parseDirective(
        self: *Parser,
        kind: Kind,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        var ident_range = Range.empty;
        while (!self.atEnd() and self.src[self.pos] != ';' and self.src[self.pos] != '\n') {
            const c = self.src[self.pos];
            if (c == '"' or c == '\'') {
                const q_open = self.pos + 1;
                try self.skipString();
                const q_close = self.pos - 1;
                if (ident_range.end == ident_range.start and q_close > q_open) {
                    ident_range = .{ .start = q_open, .end = q_close };
                }
                continue;
            }
            if (c == '{') {
                try self.skipBalanced('{', '}');
                continue;
            }
            self.pos += 1;
        }
        if (!self.atEnd()) self.pos += 1;
        try self.emitDecl(kind, ident_range, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    fn parseExport(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        self.skipTrivia();
        // `export default ...`
        if (self.matchKeyword("default")) {
            self.pos += "default".len;
            self.skipTrivia();
        }
        if (self.matchKeyword("function") or self.matchKeyword("async")) {
            // Forward to function parser; emitted as js_function with the
            // export wrapping absorbed into decl content range.
            if (self.matchKeyword("async")) {
                self.pos += "async".len;
                self.skipTrivia();
            }
            if (self.matchKeyword("function")) {
                self.pos += "function".len;
            }
            try self.parseFunction(decl_start, parent_identity, decl_indices, decl_hashes, anon_counter);
            return;
        }
        if (self.matchKeyword("class")) {
            self.pos += "class".len;
            try self.parseClass(decl_start, parent_identity, decl_indices, decl_hashes, anon_counter);
            return;
        }
        if (self.matchKeyword("const")) {
            self.pos += "const".len;
            try self.parseVarLike(.js_const, decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }
        if (self.matchKeyword("let")) {
            self.pos += "let".len;
            try self.parseVarLike(.js_let, decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }
        if (self.matchKeyword("var")) {
            self.pos += "var".len;
            try self.parseVarLike(.js_var, decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }
        // `export { foo, bar };` / `export * from '...'` / `export default expr;`
        try self.parseDirective(.js_export, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    fn parseFunction(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        self.skipTrivia();
        // Generator: `function*`
        if (!self.atEnd() and self.src[self.pos] == '*') self.pos += 1;
        self.skipTrivia();
        var name = self.scanIdent() orelse blk: {
            anon_counter.* += 1;
            break :blk Range{ .start = self.pos, .end = self.pos };
        };
        const name_bytes = self.src[name.start..name.end];

        // Header (params + return type for TS — skipped here too).
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '{' or c == ';') break;
            switch (c) {
                '(' => try self.skipBalanced('(', ')'),
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '"', '\'' => try self.skipString(),
                else => self.pos += 1,
            }
        }

        const fn_identity = hash_mod.identityHash(parent_identity, .js_function, name_bytes);

        var stmt_indices: std.ArrayList(NodeIndex) = .empty;
        defer stmt_indices.deinit(self.gpa);
        var stmt_hashes: std.ArrayList(u64) = .empty;
        defer stmt_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1;
            try self.parseFnBody(.js_stmt, fn_identity, &stmt_indices, &stmt_hashes);
        } else if (!self.atEnd() and self.src[self.pos] == ';') {
            self.pos += 1;
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(.js_function, stmt_hashes.items, decl_bytes);

        _ = &name;
        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = fn_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .js_function,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = startsWithExport(self.src, decl_start),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (stmt_indices.items) |s| parents[s] = idx;
    }

    fn parseClass(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        self.skipTrivia();
        var name = self.scanIdent() orelse blk: {
            anon_counter.* += 1;
            break :blk Range{ .start = self.pos, .end = self.pos };
        };
        const name_bytes = self.src[name.start..name.end];

        // Header (extends, implements for TS) until `{`.
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '{') break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '(' => try self.skipBalanced('(', ')'),
                '"', '\'' => try self.skipString(),
                else => self.pos += 1,
            }
        }

        const class_identity = hash_mod.identityHash(parent_identity, .js_class, name_bytes);

        var member_indices: std.ArrayList(NodeIndex) = .empty;
        defer member_indices.deinit(self.gpa);
        var member_hashes: std.ArrayList(u64) = .empty;
        defer member_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1;
            try self.scanContainer(class_identity, self.current_depth + 1, true, &member_indices, &member_hashes);
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(.js_class, member_hashes.items, decl_bytes);

        _ = &name;
        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = class_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .js_class,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = startsWithExport(self.src, decl_start),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (member_indices.items) |m| parents[m] = idx;
    }

    fn parseClassMember(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        _ = anon_counter;
        // Skip modifiers like `static`, `async`, `*`, `get`/`set`.
        while (true) {
            self.skipTrivia();
            if (self.matchKeyword("static")) {
                self.pos += "static".len;
                continue;
            }
            if (self.matchKeyword("async")) {
                self.pos += "async".len;
                continue;
            }
            if (self.matchKeyword("get") or self.matchKeyword("set")) {
                // Look ahead — `get(`/`set(` could be a method named get/set.
                const save = self.pos;
                self.pos += 3;
                self.skipTrivia();
                if (!self.atEnd() and (self.src[self.pos] == '(' or self.src[self.pos] == '=')) {
                    // Treat `get`/`set` as the method name.
                    self.pos = save;
                    break;
                }
                continue;
            }
            if (!self.atEnd() and self.src[self.pos] == '*') {
                self.pos += 1;
                continue;
            }
            break;
        }
        self.skipTrivia();
        var name = self.scanIdent() orelse blk: {
            // Computed name `[expr]` or `'string'` keys.
            if (!self.atEnd() and self.src[self.pos] == '[') {
                const ident_start = self.pos + 1;
                try self.skipBalanced('[', ']');
                break :blk Range{ .start = ident_start, .end = self.pos - 1 };
            }
            if (!self.atEnd() and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
                const ident_start = self.pos + 1;
                try self.skipString();
                break :blk Range{ .start = ident_start, .end = self.pos - 1 };
            }
            break :blk Range{ .start = self.pos, .end = self.pos };
        };
        const name_bytes = self.src[name.start..name.end];

        self.skipTrivia();
        var saw_paren = false;
        if (!self.atEnd() and self.src[self.pos] == '(') {
            saw_paren = true;
            try self.skipBalanced('(', ')');
        }

        // Walk to body / `;`.
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
                '`' => try self.skipTemplate(),
                else => self.pos += 1,
            }
        }

        const kind: Kind = if (saw_paren) .js_method else .js_const;
        const member_identity = hash_mod.identityHash(parent_identity, kind, name_bytes);

        var stmt_indices: std.ArrayList(NodeIndex) = .empty;
        defer stmt_indices.deinit(self.gpa);
        var stmt_hashes: std.ArrayList(u64) = .empty;
        defer stmt_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{' and saw_paren) {
            self.pos += 1;
            try self.parseFnBody(.js_stmt, member_identity, &stmt_indices, &stmt_hashes);
        } else {
            try self.skipUntilStmtEnd();
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(kind, stmt_hashes.items, decl_bytes);

        _ = &name;
        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = member_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = kind,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = startsWithExport(self.src, decl_start),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (stmt_indices.items) |s| parents[s] = idx;
    }

    fn parseVarLike(
        self: *Parser,
        kind: Kind,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilStmtEnd();
        try self.emitDecl(kind, name, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    /// Body recursion — emits one stmt per `;`/newline/balanced-block, parented
    /// to fn_identity.
    pub fn parseFnBody(
        self: *Parser,
        stmt_kind: Kind,
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
            // Skip whitespace, comments, bare semicolons.
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
            self.last_ctx = .expression;
            try self.skipStatement();
            const stmt_end = self.pos;

            const raw = self.src[stmt_start..stmt_end];
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;

            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{stmt_idx}) catch unreachable;
            const stmt_identity = hash_mod.identityHash(fn_identity, stmt_kind, idx_str);
            const stmt_h = hash_mod.subtreeHash(stmt_kind, &.{}, trimmed);

            const node = try self.tree.addNode(.{
                .hash = stmt_h,
                .identity_hash = stmt_identity,
                .identity_range_hash = 0,
                .kind = stmt_kind,
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
                ';', '\n' => {
                    self.pos += 1;
                    return;
                },
                '{' => {
                    try self.skipBalanced('{', '}');
                    return;
                },
                '}' => return,
                '(' => {
                    try self.skipBalanced('(', ')');
                    self.last_ctx = .operand;
                },
                '[' => {
                    try self.skipBalanced('[', ']');
                    self.last_ctx = .operand;
                },
                '"', '\'' => {
                    try self.skipString();
                    self.last_ctx = .operand;
                },
                '`' => {
                    try self.skipTemplate();
                    self.last_ctx = .operand;
                },
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else if (self.last_ctx == .expression) {
                        try self.skipRegex();
                        self.last_ctx = .operand;
                    } else {
                        self.pos += 1;
                        self.last_ctx = .expression;
                    }
                },
                else => {
                    if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.last_ctx = identCtxAfter(word);
                    } else {
                        self.pos += 1;
                        self.last_ctx = punctCtxAfter(c);
                    }
                },
            }
        }
    }

    /// Skip to `;` OR newline at depth 0, OR balanced block.
    fn skipUntilStmtEnd(self: *Parser) ParseError!void {
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            switch (c) {
                ';', '\n' => {
                    self.pos += 1;
                    return;
                },
                '{' => try self.skipBalanced('{', '}'),
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '"', '\'' => try self.skipString(),
                '`' => try self.skipTemplate(),
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

        const is_decl_bearing = switch (kind) {
            .js_const, .js_let, .js_var => true,
            else => false, // js_import / js_export
        };
        const irh: u64 = if (is_decl_bearing) std.hash.Wyhash.hash(0, ident_bytes) else 0;
        const exported = is_decl_bearing and startsWithExport(self.src, decl_start);

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

/// True when source starting at `start` (after leading whitespace) begins with
/// the literal token `export`. Used by JS parser for is_exported.
fn startsWithExport(src: []const u8, start: u32) bool {
    const trimmed = std.mem.trimStart(u8, src[start..], " \t\n\r");
    return std.mem.startsWith(u8, trimmed, "export");
}

// Keywords whose successor starts an expression (regex valid after).
fn identCtxAfter(word: []const u8) TokenContext {
    const expr_keywords = [_][]const u8{
        "return",  "typeof", "void",   "delete", "in",     "of",
        "new",     "throw",  "case",   "do",     "else",   "yield",
        "await",   "instanceof", "if", "while", "for",     "switch",
    };
    for (expr_keywords) |kw| {
        if (std.mem.eql(u8, kw, word)) return .expression;
    }
    return .operand;
}

fn punctCtxAfter(c: u8) TokenContext {
    return switch (c) {
        ')', ']' => .operand,
        '+' => .expression, // `++` handled inexactly; OK for skim.
        else => .expression,
    };
}

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

test "parse single function" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "function add(a, b) { return a + b; }", "x.js");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_fn = false;
    for (kinds) |k| {
        if (k == .js_function) has_fn = true;
    }
    try std.testing.expect(has_fn);
}

test "regex literal does not break parser" {
    const gpa = std.testing.allocator;
    const src = "function f() { const r = /a\\/b}/g; return r; }\nfunction g() {}";
    var t = try parse(gpa, src, "x.js");
    defer t.deinit();
    var fn_count: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_function) fn_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fn_count);
}

test "template literal with interpolation" {
    const gpa = std.testing.allocator;
    const src = "function tag(x) { return `hello ${x.name} } more`; }\nfunction next() {}";
    var t = try parse(gpa, src, "x.js");
    defer t.deinit();
    var fn_count: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_function) fn_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fn_count);
}

test "class method extracted" {
    const gpa = std.testing.allocator;
    const src =
        \\class Foo {
        \\  bar() { return 1; }
        \\  baz() { return 2; }
        \\}
    ;
    var t = try parse(gpa, src, "x.js");
    defer t.deinit();
    var method_count: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), method_count);
}

test "fn body extracts js_stmt children" {
    const gpa = std.testing.allocator;
    const src =
        \\function compute(a, b) {
        \\  const x = a + b;
        \\  const y = x * 2;
        \\  return y;
        \\}
    ;
    var t = try parse(gpa, src, "x.js");
    defer t.deinit();
    var stmt_count: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_stmt) stmt_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), stmt_count);
}

test "import statement captured" {
    const gpa = std.testing.allocator;
    const src = "import foo from 'foo';\n";
    var t = try parse(gpa, src, "x.js");
    defer t.deinit();
    var has_import = false;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_import) has_import = true;
    }
    try std.testing.expect(has_import);
}

test "is_exported for export keyword; identity_range_hash non-zero" {
    const gpa = std.testing.allocator;
    const src = "export function foo() {}\nfunction bar() {}\n";
    var tree = try parse(gpa, src, "x.js");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exps = tree.nodes.items(.is_exported);
    const irhs = tree.nodes.items(.identity_range_hash);
    var saw_pub = false;
    var saw_priv = false;
    for (kinds, exps, irhs, 0..) |k, exp, h, i| {
        if (k != .js_function) continue;
        try std.testing.expect(h != 0);
        const name = tree.identitySlice(@intCast(i));
        if (std.mem.eql(u8, name, "foo")) {
            try std.testing.expect(exp);
            saw_pub = true;
        } else if (std.mem.eql(u8, name, "bar")) {
            try std.testing.expect(!exp);
            saw_priv = true;
        }
    }
    try std.testing.expect(saw_pub and saw_priv);
}
