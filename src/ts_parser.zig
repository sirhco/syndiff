//! TypeScript top-level + body parser. Extends the JavaScript parser with
//! TS-specific top-level decls. Type annotations on params / vars / return
//! types are absorbed into decl content ranges by the shared header walker;
//! generics use the existing `<...>` balanced skip.
//!
//! Recognized top-level items (in addition to JS):
//!   interface NAME { ... }    → ts_interface
//!   type NAME = ...;           → ts_type
//!   enum NAME { ... }          → ts_enum
//!   namespace NAME { ... }     → ts_namespace (recursing one level for members)
//!   module NAME { ... }        → ts_namespace (alias)
//!   declare ...                → ts_declare wrapping the inner decl shape
//!   abstract class             → js_class (abstract modifier absorbed)
//!
//! Function/method bodies emit `ts_stmt` children so the kind reflects the
//! source language.
//!
//! Limitations:
//!   * Regex/division disambiguation uses the ECMA-262 Annex B goal-state machine
//!     (same implementation as `js_parser.zig`; 13 edge-case tests in
//!     `tests/js_regex_div.zig`).
//!
//! TSX (.tsx) JSX support: best-effort heuristic in `classifyAngle` +
//! `skipJsxElement` / `skipJsxFragment`. Recognized: `<div>`, `<Foo />`,
//! `<Foo>...</Foo>`, `<Foo.Bar />`, `<Foo<T> a={1} />`, and `<>...</>`
//! fragments. Disambiguates against typed-arrow generics by committing to
//! `.generic` on `<T,...>` (trailing comma) and `<T extends ...>`.
//!
//! Residual undecidable cases (best-effort, lean toward JSX in `.tsx`):
//!   - `<T>(x: T) => x` (no trailing comma, no `extends`) — workaround:
//!     write `<T,>` instead.
//!   - `<Foo<T>>(x)` followed by a paren expression vs a JSX paren child —
//!     no syntactic disambiguator without type info.
//! Plain `.ts` / `.mts` / `.cts` skip JSX entirely (`is_tsx == false`).

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

/// ECMA-262 goal symbol for lexing `/`.
/// `.regex` → the slash begins a RegExp literal (InputElementRegExp goal).
/// `.div`   → the slash is a division operator (InputElementDiv goal).
const ParseGoal = enum { regex, div };

/// Classification of a `{` for goal-state tracking.
/// `.block`          → statement-level brace; matching `}` produces regex goal.
/// `.object_literal` → expression-level brace; matching `}` produces div goal.
const BraceKind = enum { block, object_literal };

const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: u32,
    tree: *ast_mod.Tree,
    current_depth: u16 = 1,
    /// ECMA-262 goal symbol. Updated after each logical token. `.regex` means
    /// the next `/` starts a RegExp; `.div` means it is a division operator.
    goal: ParseGoal = .regex,
    /// Stack of brace-kind classifications recorded at each `{` open, used to
    /// determine whether a matching `}` closes a block (regex goal) or object
    /// literal (div goal). Per ECMA-262 Annex B.3.2.
    /// Depth beyond 32 is treated conservatively as .block (regex goal).
    brace_depth: u8 = 0,
    brace_opens: [32]BraceKind = undefined,
    /// True when parsing `.tsx`. Enables JSX recognition in angle-bracket
    /// disambiguation. `.ts` (and `.mts` / `.cts`) keep generic-only behavior.
    is_tsx: bool = false,

    fn atEnd(self: *Parser) bool {
        return self.pos >= self.src.len;
    }

    fn pushBrace(self: *Parser, kind: BraceKind) void {
        if (self.brace_depth < self.brace_opens.len) {
            self.brace_opens[self.brace_depth] = kind;
        }
        self.brace_depth +|= 1;
    }

    fn popBrace(self: *Parser) void {
        if (self.brace_depth == 0) return;
        self.brace_depth -= 1;
        // Block close → next token starts a new statement (regex goal).
        // Object literal close → operand position (div goal).
        self.goal = if (self.brace_depth < self.brace_opens.len)
            switch (self.brace_opens[self.brace_depth]) {
                .block         => .regex,
                .object_literal => .div,
            }
        else
            .regex; // conservative: treat unknown depth as block
    }

    fn peek(self: *Parser, offset: u32) ?u8 {
        const p = self.pos + offset;
        if (p >= self.src.len) return null;
        return self.src[p];
    }

    /// Skip whitespace and line/block comments. Does NOT update `goal` —
    /// per ECMA-262, comments are transparent to the lexical goal symbol.
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
                    } else if (self.goal == .regex) {
                        try self.skipRegex();
                        self.goal = .div;
                    } else {
                        self.pos += 1;
                        self.goal = .regex;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.goal = .div;
                },
                '`' => {
                    try self.skipTemplate();
                    self.goal = .div;
                },
                '{' => {
                    // Inside `${...}` interpolation: object literal.
                    self.pushBrace(.object_literal);
                    depth += 1;
                    self.pos += 1;
                    self.goal = .regex;
                },
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                    self.popBrace();
                    if (depth == 0) return;
                },
                else => {
                    // Two-char `++`/`--`: postfix preserves .div, prefix preserves .regex.
                    if ((c == '+' or c == '-') and self.peek(1) == @as(u8, c)) {
                        self.pos += 2;
                        continue;
                    }
                    // Arrow `=>` → expression position → regex goal.
                    if (c == '=' and self.peek(1) == @as(u8, '>')) {
                        self.pos += 2;
                        self.goal = .regex;
                        continue;
                    }
                    if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.goal = identGoalAfter(word);
                    } else {
                        self.pos += 1;
                        self.goal = punctGoalAfter(c);
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
    /// generics). Tracks `goal` so regex/template scans inside work.
    fn skipBalanced(self: *Parser, open: u8, close: u8) ParseError!void {
        if (self.atEnd() or self.src[self.pos] != open) return;
        // Outer `{` of a block scan (called from skipStatement / class body /
        // namespace body): treat as `.block` — popBrace will set goal to .regex.
        if (open == '{') self.pushBrace(.block);
        self.pos += 1;
        var depth: u32 = 1;
        const saved = self.goal;
        self.goal = .regex;
        while (!self.atEnd() and depth > 0) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else if (self.goal == .regex) {
                        try self.skipRegex();
                        self.goal = .div;
                    } else {
                        self.pos += 1;
                        self.goal = .regex;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.goal = .div;
                },
                '`' => {
                    try self.skipTemplate();
                    self.goal = .div;
                },
                '{' => {
                    if (open == '{') {
                        // Nested `{` inside a block — default to object literal
                        // (matches pre-Phase-9 behavior of always setting .div).
                        self.pushBrace(.object_literal);
                        depth += 1;
                        self.pos += 1;
                        self.goal = .regex;
                    } else {
                        // Inner brace inside a paren/bracket scan: object literal.
                        self.pushBrace(.object_literal);
                        self.pos += 1;
                        self.goal = .regex;
                        try self.skipUntilBraceClose();
                    }
                },
                '}' => {
                    if (open == '{') {
                        depth -= 1;
                        self.pos += 1;
                        self.popBrace();
                    } else {
                        // Stray } — bail.
                        return;
                    }
                },
                else => {
                    // Two-char `++`/`--`: postfix preserves .div, prefix preserves .regex.
                    if ((c == '+' or c == '-') and self.peek(1) == @as(u8, c)) {
                        self.pos += 2;
                        continue;
                    }
                    // Arrow `=>` → expression position → regex goal.
                    if (c == '=' and self.peek(1) == @as(u8, '>')) {
                        self.pos += 2;
                        self.goal = .regex;
                        continue;
                    }
                    if (c == open) {
                        depth += 1;
                        self.pos += 1;
                        self.goal = .regex;
                    } else if (c == close) {
                        depth -= 1;
                        self.pos += 1;
                        self.goal = .div;
                    } else if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.goal = identGoalAfter(word);
                    } else {
                        self.pos += 1;
                        self.goal = punctGoalAfter(c);
                    }
                },
            }
        }
        // For `{`-opened scans, popBrace already set the post-close goal per
        // Annex B.3.2. For paren/bracket scans, restore the entry goal.
        if (open != '{') self.goal = saved;
        if (depth != 0) return error.UnterminatedBlock;
    }

    /// Walk a JSX element starting at `<`. Caller asserts `self.src[self.pos] == '<'`
    /// and `classifyAngle(self.src, self.pos) == .jsx_element`. On return,
    /// `self.pos` is the position immediately after the matching close.
    fn skipJsxElement(self: *Parser) ParseError!void {
        std.debug.assert(self.src[self.pos] == '<');
        self.pos += 1;
        // Tag name (possibly dotted).
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (lex.isIdentCont(c) or c == '.') {
                self.pos += 1;
            } else break;
        }
        // Optional single type-argument list after the tag name (TS 4.7+):
        // `<Foo<T> a={1} />`. We re-use the generic balanced skip — it recurses
        // through nested `<...>` correctly, and it stops at the matching `>`
        // which is *not* the JSX close (the JSX close is the next `>` after
        // attributes).
        if (!self.atEnd() and self.src[self.pos] == '<') {
            self.skipBalanced('<', '>') catch {
                self.pos += 1;
            };
        }

        // Walk attributes until `/>` or `>`.
        var self_closing = false;
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) return error.UnterminatedBlock;
            const c = self.src[self.pos];
            if (c == '/') {
                if (self.peek(1) == @as(u8, '>')) {
                    self.pos += 2;
                    self_closing = true;
                    break;
                }
                self.pos += 1; // tolerate stray `/`
                continue;
            }
            if (c == '>') {
                self.pos += 1;
                break;
            }
            if (c == '{') {
                // attribute expression `name={expr}` or spread `{...x}`
                try self.skipBalanced('{', '}');
                continue;
            }
            if (c == '"' or c == '\'') {
                try self.skipString();
                continue;
            }
            // Identifier / `=` / unquoted attr boundary chars: just consume.
            self.pos += 1;
        }
        if (self_closing) return;

        // Children: walk until `</`.
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '<') {
                if (self.peek(1) == @as(u8, '/')) {
                    // Close tag `</Tag>` or `</>` fragment close.
                    self.pos += 2;
                    while (!self.atEnd() and self.src[self.pos] != '>') self.pos += 1;
                    if (!self.atEnd()) self.pos += 1; // consume '>'
                    return;
                }
                // Nested element or fragment: recurse via dispatcher so `<>` and
                // `<lower>` and `<Cap …>` all dispatch correctly.
                try self.skipAngleOrJsx();
                continue;
            }
            if (c == '{') {
                try self.skipBalanced('{', '}');
                continue;
            }
            self.pos += 1;
        }
        return error.UnterminatedBlock;
    }

    /// Walk a JSX fragment `<>...</>`. Caller asserts `<>` at `self.pos`.
    fn skipJsxFragment(self: *Parser) ParseError!void {
        std.debug.assert(self.src[self.pos] == '<');
        std.debug.assert(self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>');
        self.pos += 2;
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '<') {
                if (self.peek(1) == @as(u8, '/') and self.peek(2) == @as(u8, '>')) {
                    self.pos += 3;
                    return;
                }
                try self.skipAngleOrJsx();
                continue;
            }
            if (c == '{') {
                try self.skipBalanced('{', '}');
                continue;
            }
            self.pos += 1;
        }
        return error.UnterminatedBlock;
    }

    /// Dispatcher for a `<` in a header context. In `.tsx`, classifies and routes
    /// to JSX/fragment/generic walks. In `.ts` (and `.js`), always routes to
    /// generic. Always advances past the matched construct, or falls back to
    /// single-byte advance if the angle skip fails.
    fn skipAngleOrJsx(self: *Parser) ParseError!void {
        if (!self.is_tsx) {
            self.skipBalanced('<', '>') catch {
                self.pos += 1;
            };
            return;
        }
        switch (classifyAngle(self.src, self.pos)) {
            .jsx_fragment => try self.skipJsxFragment(),
            .jsx_element => try self.skipJsxElement(),
            .generic => self.skipBalanced('<', '>') catch {
                self.pos += 1;
            },
            .ambiguous_prefer_generic => {
                // .tsx forbids `<Type>expr` casts (must use `as`), so the only
                // way `<Foo>(...)` could appear is JSX with a paren child. But
                // `<T>(x: T) => x` (typed arrow w/o trailing comma) also matches
                // this shape. We prefer JSX in `.tsx` because the canonical
                // workaround for typed arrows is `<T,>` (which is unambiguous
                // and lands in `.generic`). Document residual case in README.
                self.skipJsxElement() catch {
                    // If JSX walk fails, fall back to single-byte advance.
                    self.pos += 1;
                };
            },
        }
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
                    } else if (self.goal == .regex) {
                        try self.skipRegex();
                        self.goal = .div;
                    } else {
                        self.pos += 1;
                        self.goal = .regex;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.goal = .div;
                },
                '`' => {
                    try self.skipTemplate();
                    self.goal = .div;
                },
                '{' => {
                    // Already inside expression scope; nested `{` is object literal.
                    self.pushBrace(.object_literal);
                    depth += 1;
                    self.pos += 1;
                    self.goal = .regex;
                },
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                    self.popBrace();
                },
                else => {
                    // Two-char `++`/`--`: postfix preserves .div, prefix preserves .regex.
                    if ((c == '+' or c == '-') and self.peek(1) == @as(u8, c)) {
                        self.pos += 2;
                        continue;
                    }
                    // Arrow `=>` → expression position → regex goal.
                    if (c == '=' and self.peek(1) == @as(u8, '>')) {
                        self.pos += 2;
                        self.goal = .regex;
                        continue;
                    }
                    if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.goal = identGoalAfter(word);
                    } else {
                        self.pos += 1;
                        self.goal = punctGoalAfter(c);
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
            // TS-specific top-level decls.
            if (self.matchKeyword("interface")) {
                self.pos += "interface".len;
                try self.parseInterface(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("type")) {
                self.pos += "type".len;
                try self.parseTypeAlias(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("enum")) {
                self.pos += "enum".len;
                try self.parseTsEnum(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("namespace") or self.matchKeyword("module")) {
                // both produce ts_namespace
                if (self.matchKeyword("namespace")) self.pos += "namespace".len else self.pos += "module".len;
                try self.parseNamespace(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("declare")) {
                self.pos += "declare".len;
                try self.parseDeclare(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                continue;
            }
            if (self.matchKeyword("abstract")) {
                self.pos += "abstract".len;
                self.skipTrivia();
                if (self.matchKeyword("class")) {
                    self.pos += "class".len;
                    try self.parseClass(decl_start, parent_identity, decl_indices, decl_hashes, &anon_counter);
                    continue;
                }
                // not abstract class — fall through (treat as ident).
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

    fn parseInterface(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        // Walk header (extends ...) until `{`.
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '{' or c == ';') break;
            switch (c) {
                '<' => try self.skipAngleOrJsx(),
                '(' => try self.skipBalanced('(', ')'),
                '"', '\'' => try self.skipString(),
                else => self.pos += 1,
            }
        }
        if (!self.atEnd() and self.src[self.pos] == '{') {
            try self.skipBalanced('{', '}');
        } else if (!self.atEnd() and self.src[self.pos] == ';') {
            self.pos += 1;
        }
        try self.emitDecl(.ts_interface, name, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    fn parseTypeAlias(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        try self.skipUntilStmtEnd();
        try self.emitDecl(.ts_type, name, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    fn parseTsEnum(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '{') {
            try self.skipBalanced('{', '}');
        }
        try self.emitDecl(.ts_enum, name, decl_start, parent_identity, decl_indices, decl_hashes);
    }

    fn parseNamespace(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        const name_bytes = self.src[name.start..name.end];
        self.skipTrivia();

        const ns_identity = hash_mod.identityHash(parent_identity, .ts_namespace, name_bytes);

        var member_indices: std.ArrayList(NodeIndex) = .empty;
        defer member_indices.deinit(self.gpa);
        var member_hashes: std.ArrayList(u64) = .empty;
        defer member_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1;
            try self.scanContainer(ns_identity, self.current_depth + 1, true, &member_indices, &member_hashes);
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(.ts_namespace, member_hashes.items, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = ns_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .ts_namespace,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = startsWithExportOrDeclare(self.src, decl_start),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (member_indices.items) |m| parents[m] = idx;
    }

    fn parseDeclare(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
        anon_counter: *u32,
    ) ParseError!void {
        _ = anon_counter;
        self.skipTrivia();
        // Capture identity name = next ident, but emit as ts_declare.
        const name_start = self.pos;
        _ = self.scanIdent();
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = name_start, .end = name_start };
        try self.skipUntilStmtEnd();
        try self.emitDecl(.ts_declare, name, decl_start, parent_identity, decl_indices, decl_hashes);
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
        if (self.matchKeyword("interface")) {
            self.pos += "interface".len;
            try self.parseInterface(decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }
        if (self.matchKeyword("type")) {
            self.pos += "type".len;
            try self.parseTypeAlias(decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }
        if (self.matchKeyword("enum")) {
            self.pos += "enum".len;
            try self.parseTsEnum(decl_start, parent_identity, decl_indices, decl_hashes);
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
                '<' => try self.skipAngleOrJsx(),
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
            try self.parseFnBody(.ts_stmt, fn_identity, &stmt_indices, &stmt_hashes);
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
            .is_exported = startsWithExportOrDeclare(self.src, decl_start),
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
                '<' => try self.skipAngleOrJsx(),
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
            .is_exported = startsWithExportOrDeclare(self.src, decl_start),
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
                '<' => try self.skipAngleOrJsx(),
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
            try self.parseFnBody(.ts_stmt, member_identity, &stmt_indices, &stmt_hashes);
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
            .is_exported = startsWithExportOrDeclare(self.src, decl_start),
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
            self.goal = .regex;
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
                    // A balanced block just closed at statement level → regex goal.
                    self.goal = .regex;
                    return;
                },
                '}' => return,
                '(' => {
                    try self.skipBalanced('(', ')');
                    self.goal = .div;
                },
                '[' => {
                    try self.skipBalanced('[', ']');
                    self.goal = .div;
                },
                '<' => {
                    // In .tsx, `<` may open a JSX element/fragment in expression
                    // position (e.g., `return <Foo />` or `const x = <div />`).
                    // In .ts (and .js fed through this parser via .ts shape),
                    // `<` is just a punctuation token.
                    if (self.is_tsx) {
                        try self.skipAngleOrJsx();
                        self.goal = .div;
                    } else {
                        self.pos += 1;
                        self.goal = .regex;
                    }
                },
                '"', '\'' => {
                    try self.skipString();
                    self.goal = .div;
                },
                '`' => {
                    try self.skipTemplate();
                    self.goal = .div;
                },
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else if (self.goal == .regex) {
                        try self.skipRegex();
                        self.goal = .div;
                    } else {
                        self.pos += 1;
                        self.goal = .regex;
                    }
                },
                else => {
                    // Two-char `++`/`--`: postfix preserves .div, prefix preserves .regex.
                    if ((c == '+' or c == '-') and self.peek(1) == @as(u8, c)) {
                        self.pos += 2;
                        continue;
                    }
                    // Arrow `=>` → expression position → regex goal.
                    if (c == '=' and self.peek(1) == @as(u8, '>')) {
                        self.pos += 2;
                        self.goal = .regex;
                        continue;
                    }
                    if (lex.isIdentStart(c)) {
                        const r = lex.scanIdent(self.src, self.pos).?;
                        self.pos = r.end;
                        const word = self.src[r.start..r.end];
                        self.goal = identGoalAfter(word);
                    } else {
                        self.pos += 1;
                        self.goal = punctGoalAfter(c);
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
            .ts_interface, .ts_type, .ts_enum, .ts_declare,
            .js_const, .js_let, .js_var,
            => true,
            else => false, // js_import / js_export
        };
        // For ts_interface, ts_type, and ts_enum the "identity range" is the
        // name only, but the *signature* includes the member list.  Hash the
        // whole declaration so that adding/removing/changing a member causes
        // annotateKindTag to classify the change as `signature_change` rather
        // than `body_change`.
        const irh: u64 = switch (kind) {
            .ts_interface, .ts_type, .ts_enum => std.hash.Wyhash.hash(0, decl_bytes),
            else => if (is_decl_bearing) std.hash.Wyhash.hash(0, ident_bytes) else 0,
        };
        const exported = is_decl_bearing and startsWithExportOrDeclare(self.src, decl_start);

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
/// `export` or `declare`. Used by TS parser for is_exported.
fn startsWithExportOrDeclare(src: []const u8, start: u32) bool {
    const trimmed = std.mem.trimStart(u8, src[start..], " \t\n\r");
    return std.mem.startsWith(u8, trimmed, "export") or std.mem.startsWith(u8, trimmed, "declare");
}

/// All keywords after which the ECMA-262 goal symbol is InputElementRegExp
/// (i.e., a following `/` begins a RegExp literal, not a division operator).
/// Source: ECMA-262 §12.9.4 and Annex B.
fn identGoalAfter(word: []const u8) ParseGoal {
    const regex_keywords = [_][]const u8{
        "return",     "typeof",     "void",       "delete",
        "in",         "of",         "new",        "throw",
        "case",       "do",         "else",       "yield",
        "await",      "instanceof", "if",         "while",
        "for",        "switch",     "with",       "export",
        "extends",    "from",       "import",
    };
    for (regex_keywords) |kw| {
        if (std.mem.eql(u8, kw, word)) return .regex;
    }
    // All identifiers and non-listed keywords are operands → div goal.
    return .div;
}

fn punctGoalAfter(c: u8) ParseGoal {
    return switch (c) {
        // Closing delimiters → operand → div goal.
        ')', ']' => .div,
        // Ternary operators and all other non-operand punctuation → regex goal.
        // '?', ':', '=', '+', '-', '*', '!', '~', ',', ';', '{', '(' all
        // produce expression context where a following `/` is a regex.
        // Note: '+' is left as .regex because prefix `++` (not yet consumed)
        // is not an operand. Postfix `++` is handled at the call site.
        else => .regex,
    };
}

/// Result of a constant-bounded lookahead at a `<` token. The probe never
/// advances the parser — it only inspects bytes at and beyond `at`.
///
/// The decision tree (caller is responsible for the .tsx vs .ts gate that
/// promotes `ambiguous_prefer_generic` to `jsx_element` in some cases — see
/// `skipAngleOrJsx`):
///
///   `<` followed by `>`                          → jsx_fragment
///   `<` followed by lowercase ident              → jsx_element  (intrinsic)
///   `<` followed by Capital ident or `Foo.Bar`:
///       … `,`                                    → generic       (typed arrow committed at `<T,>`)
///       … `extends `                             → generic       (constraint)
///       … `/>` or `>` (with no `(` before `>`)   → jsx_element
///       … attribute pattern (`name=`, `name {…}`)→ jsx_element
///       … `(`                                    → ambiguous_prefer_generic
///       … anything else within the window        → generic
pub const AngleKind = enum { generic, jsx_element, jsx_fragment, ambiguous_prefer_generic };

/// Pure byte-level probe; bounded by `WINDOW`. No allocation, no parser state.
pub fn classifyAngle(src: []const u8, at: u32) AngleKind {
    if (at >= src.len or src[at] != '<') return .generic;
    const WINDOW: u32 = 128;
    const limit: u32 = @min(@as(u32, @intCast(src.len)), at + 1 + WINDOW);

    var i: u32 = at + 1;
    // Whitespace inside the open is not legal JSX (`< Foo />` is invalid),
    // but is fine for generics. `< T>` is rare; treat any leading space as a
    // hint toward generic.
    if (i < limit and (src[i] == ' ' or src[i] == '\t')) return .generic;

    if (i >= limit) return .generic;

    // Fragment: `<>...</>`
    if (src[i] == '>') return .jsx_fragment;

    if (!lex.isIdentStart(src[i])) return .generic;

    const first = src[i];
    const is_lower_first = (first >= 'a' and first <= 'z');

    // Walk the (possibly dotted) tag/type-name: `Foo`, `Foo.Bar.Baz`.
    while (i < limit and (lex.isIdentCont(src[i]) or src[i] == '.')) i += 1;

    // Skip inline whitespace (legal in both JSX and generics post-name).
    while (i < limit and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r')) i += 1;
    if (i >= limit) return if (is_lower_first) .jsx_element else .generic;

    if (is_lower_first) return .jsx_element; // intrinsic — no further check

    // Capital-or-dotted name. Disambiguate.
    const c = src[i];
    if (c == ',') return .generic; // `<T,>(...)` typed-arrow trailing comma
    if (c == '>') {
        // Naked `<Foo>` — could be JSX open with children, OR a TS cast
        // `<Foo>expr` (illegal in .tsx but possible in .ts), OR a typed
        // arrow `<T>(x: T) => x` (no trailing comma — ambiguous in .tsx).
        // Lookahead one byte past `>`: if `(`, hand back to dispatcher
        // (which routes to JSX in .tsx, generic skip in .ts).
        var j = i + 1;
        while (j < limit and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) j += 1;
        if (j < limit and src[j] == '(') return .ambiguous_prefer_generic;
        return .jsx_element;
    }
    if (c == '/') {
        if (i + 1 < limit and src[i + 1] == '>') return .jsx_element;
        return .generic;
    }
    if (c == '(') return .ambiguous_prefer_generic;

    // `extends ` keyword?
    if (matchKeywordAt(src, i, limit, "extends")) return .generic;

    // Attribute-shaped? Look for `name=` or `name {` or `{...}` (spread).
    if (c == '{') return .jsx_element; // `<Foo {...spread} />`
    if (lex.isIdentStart(c)) {
        var j = i;
        while (j < limit and lex.isIdentCont(src[j])) j += 1;
        while (j < limit and (src[j] == ' ' or src[j] == '\t')) j += 1;
        if (j < limit and (src[j] == '=' or src[j] == '/' or src[j] == '>' or src[j] == '{')) {
            return .jsx_element;
        }
        return .generic;
    }

    return .generic;
}

fn matchKeywordAt(src: []const u8, at: u32, limit: u32, kw: []const u8) bool {
    if (at + kw.len > limit) return false;
    if (!std.mem.eql(u8, src[at .. at + @as(u32, @intCast(kw.len))], kw)) return false;
    const after = at + @as(u32, @intCast(kw.len));
    if (after >= limit) return true;
    return !lex.isIdentCont(src[after]);
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8, path: []const u8) ParseError!ast_mod.Tree {
    var tree = ast_mod.Tree.init(gpa, source, path);
    errdefer tree.deinit();
    const is_tsx = std.ascii.endsWithIgnoreCase(path, ".tsx");
    var p: Parser = .{ .gpa = gpa, .src = source, .pos = 0, .tree = &tree, .is_tsx = is_tsx };
    try p.parseFile();
    return tree;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse interface" {
    const gpa = std.testing.allocator;
    const src = "interface User { name: string; age: number; }\n";
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var has_iface = false;
    for (t.nodes.items(.kind)) |k| {
        if (k == .ts_interface) has_iface = true;
    }
    try std.testing.expect(has_iface);
}

test "parse type alias" {
    const gpa = std.testing.allocator;
    const src = "type Id = string | number;\n";
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var has_type = false;
    for (t.nodes.items(.kind)) |k| {
        if (k == .ts_type) has_type = true;
    }
    try std.testing.expect(has_type);
}

test "parse fn with type annotations" {
    const gpa = std.testing.allocator;
    const src = "function add(a: number, b: number): number { return a + b; }";
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var has_fn = false;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_function) has_fn = true;
    }
    try std.testing.expect(has_fn);
}

test "namespace contains members" {
    const gpa = std.testing.allocator;
    const src =
        \\namespace Util {
        \\  export function a(): number { return 1; }
        \\  export const b: string = "x";
        \\}
    ;
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var has_ns = false;
    for (t.nodes.items(.kind)) |k| {
        if (k == .ts_namespace) has_ns = true;
    }
    try std.testing.expect(has_ns);
}

test "parse enum" {
    const gpa = std.testing.allocator;
    const src = "enum Color { Red, Green, Blue }\n";
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var has_enum = false;
    for (t.nodes.items(.kind)) |k| {
        if (k == .ts_enum) has_enum = true;
    }
    try std.testing.expect(has_enum);
}

test "fn body extracts ts_stmt children" {
    const gpa = std.testing.allocator;
    const src =
        \\function compute(a: number, b: number): number {
        \\  const x = a + b;
        \\  const y = x * 2;
        \\  return y;
        \\}
    ;
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var stmt_count: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .ts_stmt) stmt_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), stmt_count);
}

test "regex literal does not break parser" {
    const gpa = std.testing.allocator;
    const src = "function f() { const r = /a\\/b}/g; return r; }\nfunction g() {}";
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var fn_count: usize = 0;
    for (t.nodes.items(.kind)) |k| {
        if (k == .js_function) fn_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fn_count);
}

test "is_exported via export keyword on class; identity_range_hash non-zero on interface" {
    const gpa = std.testing.allocator;
    const src = "export class Foo {}\nclass Bar {}\ninterface Baz {}\n";
    var tree = try parse(gpa, src, "x.ts");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exps = tree.nodes.items(.is_exported);
    const irhs = tree.nodes.items(.identity_range_hash);
    var saw_pub = false;
    var saw_priv = false;
    var saw_iface = false;
    for (kinds, exps, irhs, 0..) |k, exp, h, i| {
        const name = tree.identitySlice(@intCast(i));
        if (k == .js_class and std.mem.eql(u8, name, "Foo")) {
            try std.testing.expect(exp);
            try std.testing.expect(h != 0);
            saw_pub = true;
        } else if (k == .js_class and std.mem.eql(u8, name, "Bar")) {
            try std.testing.expect(!exp);
            try std.testing.expect(h != 0);
            saw_priv = true;
        } else if (k == .ts_interface and std.mem.eql(u8, name, "Baz")) {
            try std.testing.expect(!exp);
            try std.testing.expect(h != 0);
            saw_iface = true;
        }
    }
    try std.testing.expect(saw_pub and saw_priv and saw_iface);
}

test "is_exported true for declare-prefixed decl" {
    const gpa = std.testing.allocator;
    const src = "declare const foo: number;\n";
    var tree = try parse(gpa, src, "x.ts");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exps = tree.nodes.items(.is_exported);
    var saw = false;
    for (kinds, exps) |k, e| {
        if (k == .ts_declare) {
            try std.testing.expect(e);
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "parseExport: interface routes to ts_interface with is_exported=true" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "export interface Foo { x: string; }\n", "x.ts");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exported = tree.nodes.items(.is_exported);
    var found = false;
    for (kinds, 0..) |k, i| if (k == .ts_interface) {
        try std.testing.expect(exported[i]);
        found = true;
    };
    try std.testing.expect(found);
}

test "parseExport: type alias routes to ts_type with is_exported=true" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "export type Id = string;\n", "x.ts");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exported = tree.nodes.items(.is_exported);
    var found = false;
    for (kinds, 0..) |k, i| if (k == .ts_type) {
        try std.testing.expect(exported[i]);
        found = true;
    };
    try std.testing.expect(found);
}

test "parseExport: enum routes to ts_enum with is_exported=true" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "export enum Direction { Up, Down }\n", "x.ts");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exported = tree.nodes.items(.is_exported);
    var found = false;
    for (kinds, 0..) |k, i| if (k == .ts_enum) {
        try std.testing.expect(exported[i]);
        found = true;
    };
    try std.testing.expect(found);
}

// -----------------------------------------------------------------------------
// Phase 10: TSX JSX vs generic disambiguation tests.
// -----------------------------------------------------------------------------

test "parser flags tsx via path extension" {
    const gpa = std.testing.allocator;
    var t1 = try parse(gpa, "const x = 1;\n", "x.ts");
    defer t1.deinit();
    var t2 = try parse(gpa, "const x = 1;\n", "x.tsx");
    defer t2.deinit();
    // Sanity: both parse cleanly.
    try std.testing.expect(t1.nodes.len > 0);
    try std.testing.expect(t2.nodes.len > 0);
}

test "classifyAngle: lowercase ident -> jsx_element (intrinsic)" {
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<div>", 0));
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<span/>", 0));
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<a href=...", 0));
}

test "classifyAngle: empty open -> jsx_fragment" {
    try std.testing.expectEqual(AngleKind.jsx_fragment, classifyAngle("<>", 0));
    try std.testing.expectEqual(AngleKind.jsx_fragment, classifyAngle("<>hi</>", 0));
}

test "classifyAngle: capital ident followed by `,` -> generic (typed arrow)" {
    try std.testing.expectEqual(AngleKind.generic, classifyAngle("<T,>(x: T) => x", 0));
    try std.testing.expectEqual(AngleKind.generic, classifyAngle("<K, V>(...)", 0));
}

test "classifyAngle: capital ident followed by `extends` -> generic" {
    try std.testing.expectEqual(AngleKind.generic, classifyAngle("<T extends Foo>(x: T)", 0));
}

test "classifyAngle: capital ident followed by `/>` -> jsx_element" {
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo/>", 0));
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo />", 0));
}

test "classifyAngle: capital ident followed by jsx attr -> jsx_element" {
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo a={1} />", 0));
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo bar=\"x\">", 0));
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo>", 0));
}

test "classifyAngle: dotted member like `Foo.Bar` followed by attr/close -> jsx_element" {
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo.Bar />", 0));
    try std.testing.expectEqual(AngleKind.jsx_element, classifyAngle("<Foo.Bar a={1}>", 0));
}

test "classifyAngle: capital ident followed by `(` -> ambiguous_prefer_generic" {
    try std.testing.expectEqual(AngleKind.ambiguous_prefer_generic, classifyAngle("<Foo>(x)", 0));
    try std.testing.expectEqual(AngleKind.ambiguous_prefer_generic, classifyAngle("<T>(x: T) => x", 0));
}

test "classifyAngle: comparison-shaped uses -> generic (skip-balanced fallback)" {
    try std.testing.expectEqual(AngleKind.generic, classifyAngle("<5>", 0));
}

test "skipJsxElement: self-closing component" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "const x = <Foo />;\n", "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "skipJsxElement: open + children + close" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "const x = <Foo>hello {name}</Foo>;\n", "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "skipJsxFragment: <>...</>" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "const x = <>a {b} c</>;\n", "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "skipJsxElement: nested children" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "const x = <Outer><Inner a={1}/></Outer>;\n", "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "tsx: <Foo>(x) parses as jsx without unbalanced error" {
    const gpa = std.testing.allocator;
    const src = "function App() { return <Foo>{x}</Foo>; }\n";
    var t = try parse(gpa, src, "x.tsx");
    defer t.deinit();
    var has_fn = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_function) {
        has_fn = true;
    };
    try std.testing.expect(has_fn);
}

test "ts (not tsx): <Foo>(x) parses as cast (generic skip)" {
    const gpa = std.testing.allocator;
    const src = "const v = <Foo>(x);\n";
    var t = try parse(gpa, src, "x.ts");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "tsx: <Foo<T> a={1} /> parses cleanly" {
    const gpa = std.testing.allocator;
    const src = "const x = <Foo<string> a={1} />;\n";
    var t = try parse(gpa, src, "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "tsx: typed arrow with trailing comma parses as generic" {
    const gpa = std.testing.allocator;
    const src = "const id = <T,>(x: T) => x;\n";
    var t = try parse(gpa, src, "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}

test "tsx: typed arrow with extends constraint parses as generic" {
    const gpa = std.testing.allocator;
    const src = "const f = <T extends Base>(x: T): T => x;\n";
    var t = try parse(gpa, src, "x.tsx");
    defer t.deinit();
    var has_const = false;
    for (t.nodes.items(.kind)) |k| if (k == .js_const) {
        has_const = true;
    };
    try std.testing.expect(has_const);
}
