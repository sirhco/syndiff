//! C#/.NET top-level + member parser. Same shape as `java_parser.zig`:
//! skim lexer + brace-counting body skip + per-decl node.
//!
//! Recognized top-level items (with leading attributes `[Attr]` and modifiers
//! absorbed into the decl's content range):
//!   using <qualified.name>;                       → cs_using
//!   using <Alias> = <Target>;                     → cs_using
//!   using static <qualified.name>;                → cs_using
//!   global using <qualified.name>;                → cs_using
//!   namespace <Foo> { ... }                       → cs_namespace (recurse)
//!   namespace <Foo>;                              → cs_namespace (file-scoped,
//!                                                   subsequent decls reparented)
//!   class / interface / struct / record / enum / @interface
//!     [<T,...>] [: BaseList] [where ...] { ... } → cs_class | cs_interface
//!                                                   cs_struct | cs_record |
//!                                                   cs_enum
//!   delegate <ReturnType> <Name>(...);            → cs_method
//!
//! Type body members (inside `class { ... }`, `struct { ... }` etc.):
//!   [modifiers] <TypeName>(...) [: this(...)|: base(...)] { ... }
//!                                                       → cs_method (constructor)
//!   ~<TypeName>() { ... }                               → cs_method (finalizer)
//!   [modifiers] [<T,...>] <ReturnType> <name>(...)
//!     [where ...] [{ ... } | =>expr; | ;]               → cs_method
//!   [modifiers] <Type> <name> { get; set; }             → cs_property
//!   [modifiers] <Type> <name> => expr;                  → cs_property
//!   [modifiers] <Type> this[...] { get; set; }          → cs_property (indexer)
//!   [modifiers] event <DelegateType> <name>;            → cs_event
//!   [modifiers] event <DelegateType> <name> { add; remove; } → cs_event
//!   [modifiers] const <Type> <name> = ...;              → cs_const
//!   [modifiers] <Type> <name>[, <name2> ...] [= ...];   → cs_field per name
//!   Operator overloads + conversion operators            → cs_method
//!   Nested types recurse into their own body.
//!
//! Function bodies break into `cs_stmt` children (per-statement, split on
//! `;` at brace-depth 0 OR balanced `{...}` blocks).
//!
//! Limitations:
//!   * Attribute arg expressions inside `[Foo(...)]` are absorbed into the
//!     decl's content range — they do not emit sub-nodes.
//!   * LINQ query syntax (`from x in y select x`) is body-internal — no
//!     separate kinds.
//!   * Reflection-style strings (e.g. `Type.GetType("...")`) are not flagged
//!     here — that's the language-neutral `sensitivity` scan's job.
//!   * `unsafe` blocks are body-internal: content range absorbs them.
//!   * Lambda bodies (`(x) => expr`) are body-internal.
//!   * Partial classes are emitted per-file as separate `cs_class` nodes;
//!     cross-file partial coalescing is deferred.
//!   * Top-level statements (C# 9+) parse as a sequence of `cs_stmt` nodes.
//!   * Verbatim, interpolated, and raw strings are recognized in `skipString`.

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

    /// Skip a string starting at `self.pos`. Handles:
    ///   - Regular `"..."` with `\` escapes
    ///   - Char literal `'.'` with `\` escapes
    ///   - Verbatim `@"..."` (doubled `""` escapes; `\` is literal)
    ///   - Interpolated `$"...{expr}..."` (recurse into `{...}`)
    ///   - Verbatim+interpolated `$@"..."` / `@$"..."` (combine both rules)
    ///   - Raw strings `"""..."""` (or longer runs)
    ///   - Raw interpolated `$"""..."""`, `$$"""..."""` (more `$` = need that
    ///     many `{` to start interpolation)
    fn skipString(self: *Parser) ParseError!void {
        // First, detect prefix: `$`, `$$`, `@`, `$@`, `@$`, `$$@` etc.
        var dollars: u32 = 0;
        var verbatim = false;
        const start = self.pos;
        while (!self.atEnd() and (self.src[self.pos] == '$' or self.src[self.pos] == '@')) {
            if (self.src[self.pos] == '$') dollars += 1;
            if (self.src[self.pos] == '@') verbatim = true;
            self.pos += 1;
            if (self.atEnd()) {
                self.pos = start;
                self.pos += 1;
                return;
            }
        }
        if (self.atEnd()) return;

        const quote = self.src[self.pos];
        if (quote != '"' and quote != '\'') {
            // Wasn't actually a string prefix (e.g. `@` was an identifier
            // marker like `@class`). Reset and emit just the prefix bytes.
            self.pos = start + 1;
            return;
        }

        // Char literal — `'` only allowed without prefixes.
        if (quote == '\'' and dollars == 0 and !verbatim) {
            self.pos += 1;
            while (!self.atEnd()) {
                const c = self.src[self.pos];
                if (c == '\\') {
                    if (self.pos + 1 >= self.src.len) return error.UnterminatedString;
                    self.pos += 2;
                    continue;
                }
                self.pos += 1;
                if (c == '\'') return;
                if (c == '\n') return error.UnterminatedString;
            }
            return error.UnterminatedString;
        }

        // Triple-quoted raw string? Only `"""...` (need at least 3 quotes).
        const at_triple = quote == '"' and self.pos + 2 < self.src.len and
            self.src[self.pos + 1] == '"' and self.src[self.pos + 2] == '"';

        if (at_triple) {
            // Count run of opening quotes.
            var q_run: u32 = 0;
            while (self.pos < self.src.len and self.src[self.pos] == '"') : (self.pos += 1) {
                q_run += 1;
            }
            // Min `{` count to start interpolation = max(1, dollars).
            const min_braces: u32 = if (dollars == 0) 0 else dollars;
            // Scan until matching closing quote run.
            while (!self.atEnd()) {
                if (min_braces > 0 and self.src[self.pos] == '{') {
                    // Count opening brace run.
                    var b_run: u32 = 0;
                    while (self.pos < self.src.len and self.src[self.pos] == '{') : (self.pos += 1) {
                        b_run += 1;
                    }
                    if (b_run >= min_braces) {
                        // Consumed `min_braces` for the interpolation hole;
                        // remaining (b_run - min_braces) are literal `{`s.
                        // Recurse into the brace body.
                        try self.skipInterpolationBody();
                    }
                    continue;
                }
                if (self.src[self.pos] == '"') {
                    var c_run: u32 = 0;
                    const close_start = self.pos;
                    while (self.pos < self.src.len and self.src[self.pos] == '"') : (self.pos += 1) {
                        c_run += 1;
                    }
                    if (c_run >= q_run) {
                        // Done. Back up if extra quotes spilled past q_run
                        // (caller doesn't need them; they're part of literal).
                        // Standard: closing run must equal opening run — extras
                        // belong to next token. Be lenient: accept >= q_run.
                        _ = close_start;
                        return;
                    }
                    continue;
                }
                self.pos += 1;
            }
            return error.UnterminatedString;
        }

        // Single-quote string: `"..."`, `@"..."`, `$"..."`, `$@"..."` or `@$"..."`.
        self.pos += 1; // consume opening `"`
        const min_braces: u32 = if (dollars == 0) 0 else dollars;
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (verbatim) {
                if (c == '"') {
                    // Doubled `""` is escape. Otherwise terminator.
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
                        self.pos += 2;
                        continue;
                    }
                    self.pos += 1;
                    return;
                }
                if (min_braces > 0 and c == '{') {
                    var b_run: u32 = 0;
                    while (self.pos < self.src.len and self.src[self.pos] == '{') : (self.pos += 1) {
                        b_run += 1;
                    }
                    if (b_run >= min_braces and (b_run - min_braces) % 2 == 0) {
                        try self.skipInterpolationBody();
                    }
                    // `{{` is literal `{` in interp/verbatim.
                    continue;
                }
                self.pos += 1;
                continue;
            }
            // Regular non-verbatim: `\` is escape.
            if (c == '\\') {
                if (self.pos + 1 >= self.src.len) return error.UnterminatedString;
                self.pos += 2;
                continue;
            }
            if (min_braces > 0 and c == '{') {
                var b_run: u32 = 0;
                while (self.pos < self.src.len and self.src[self.pos] == '{') : (self.pos += 1) {
                    b_run += 1;
                }
                if (b_run >= min_braces and (b_run - min_braces) % 2 == 0) {
                    try self.skipInterpolationBody();
                }
                continue;
            }
            if (c == '"') {
                self.pos += 1;
                return;
            }
            if (c == '\n') return error.UnterminatedString;
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    /// We've just consumed the opening `{` of an interpolation hole. Scan
    /// until the matching `}` at depth 0, recursing through nested strings,
    /// parens, brackets, and braces.
    fn skipInterpolationBody(self: *Parser) ParseError!void {
        var depth: u32 = 1;
        while (!self.atEnd() and depth > 0) {
            const c = self.src[self.pos];
            switch (c) {
                '{' => {
                    depth += 1;
                    self.pos += 1;
                },
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                },
                '"', '\'' => try self.skipString(),
                '$', '@' => try self.skipString(),
                '/' => {
                    const n = self.peek(1);
                    if (n == @as(u8, '/') or n == @as(u8, '*')) {
                        self.skipTrivia();
                    } else self.pos += 1;
                },
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                else => self.pos += 1,
            }
        }
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
                '$', '@' => {
                    // Possible string prefix or just an `@`/`$` token.
                    const next = self.peek(1);
                    if (next == @as(u8, '"') or next == @as(u8, '$') or next == @as(u8, '@')) {
                        try self.skipString();
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

    /// Skip `[Attribute]`, `[Attribute(arg)]`, `[assembly: Foo]`, multi-bracket
    /// runs `[A][B]` and `[A, B]`.
    fn skipAttributes(self: *Parser) ParseError!void {
        while (true) {
            self.skipTrivia();
            if (self.atEnd() or self.src[self.pos] != '[') return;
            try self.skipBalanced('[', ']');
        }
    }

    /// Eat a sequence of leading modifier keywords. Returns when the next
    /// non-trivia token is not a modifier.
    fn skipModifiers(self: *Parser) void {
        const mods = [_][]const u8{
            "public",   "private",  "protected", "internal",
            "static",   "sealed",   "abstract",  "virtual",
            "override", "async",    "readonly",  "partial",
            "extern",   "unsafe",   "new",       "ref",
            "out",      "in",       "params",    "init",
            "volatile", "fixed",    "implicit",  "explicit",
            "global",
        };
        outer: while (true) {
            self.skipTrivia();
            if (self.atEnd()) return;
            for (mods) |m| {
                if (self.matchKeyword(m)) {
                    self.pos += @intCast(m.len);
                    continue :outer;
                }
            }
            return;
        }
    }

    fn parseFile(self: *Parser) ParseError!void {
        const root_identity = hash_mod.identityHash(0, .file_root, "");

        var decl_indices: std.ArrayList(NodeIndex) = .empty;
        defer decl_indices.deinit(self.gpa);
        var decl_hashes: std.ArrayList(u64) = .empty;
        defer decl_hashes.deinit(self.gpa);

        try self.scanContainer(root_identity, 1, .file_scope, &decl_indices, &decl_hashes);

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

    const ContainerKind = enum {
        file_scope,
        namespace_body,
        class_body,
        interface_body,
        struct_body,
        enum_body,
    };

    /// Scan items in a container scope. Returns when a `}` closes the scope
    /// (for non-file_scope containers) or at EOF.
    fn scanContainer(
        self: *Parser,
        parent_identity: u64,
        decl_depth: u16,
        kind: ContainerKind,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const saved_depth = self.current_depth;
        self.current_depth = decl_depth;
        defer self.current_depth = saved_depth;

        const stop_at_close_brace = kind != .file_scope;

        if (kind == .enum_body) {
            try self.parseEnumConstants(parent_identity, decl_indices, decl_hashes);
        }

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;

            if (stop_at_close_brace and self.src[self.pos] == '}') {
                self.pos += 1;
                return;
            }

            // Stray semicolons in class bodies are valid; just consume.
            if (self.src[self.pos] == ';') {
                self.pos += 1;
                continue;
            }

            const decl_start = self.pos;
            try self.skipAttributes();
            self.skipTrivia();
            if (self.atEnd()) break;

            // File / namespace scope: using, namespace.
            if (kind == .file_scope or kind == .namespace_body) {
                if (self.matchKeyword("using")) {
                    try self.parseUsing(decl_start, parent_identity, decl_indices, decl_hashes);
                    continue;
                }
                // `global using ...;`
                if (self.matchKeyword("global")) {
                    self.pos += "global".len;
                    self.skipTrivia();
                    if (self.matchKeyword("using")) {
                        try self.parseUsing(decl_start, parent_identity, decl_indices, decl_hashes);
                        continue;
                    }
                    // Wasn't a using directive; rewind.
                    self.pos = decl_start;
                    try self.skipAttributes();
                    self.skipTrivia();
                }
                if (self.matchKeyword("namespace")) {
                    try self.parseNamespace(decl_start, parent_identity, kind, decl_indices, decl_hashes);
                    continue;
                }
            }

            // Modifier prefix.
            self.skipModifiers();
            self.skipTrivia();
            if (self.atEnd()) break;
            // Attributes may interleave with modifiers.
            try self.skipAttributes();
            self.skipTrivia();
            self.skipModifiers();
            self.skipTrivia();

            if (self.atEnd()) break;

            // Type declarations.
            if (self.matchKeyword("class")) {
                self.pos += "class".len;
                try self.parseTypeContainer(.cs_class, .class_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("interface")) {
                self.pos += "interface".len;
                try self.parseTypeContainer(.cs_interface, .interface_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("struct")) {
                self.pos += "struct".len;
                try self.parseTypeContainer(.cs_struct, .struct_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("record")) {
                self.pos += "record".len;
                self.skipTrivia();
                // Optional `class` or `struct` keyword.
                if (self.matchKeyword("class")) self.pos += "class".len
                else if (self.matchKeyword("struct")) self.pos += "struct".len;
                try self.parseTypeContainer(.cs_record, .class_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("enum")) {
                self.pos += "enum".len;
                try self.parseTypeContainer(.cs_enum, .enum_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("delegate")) {
                self.pos += "delegate".len;
                try self.parseDelegate(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("event")) {
                self.pos += "event".len;
                try self.parseEvent(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }

            // Finalizer `~Name() { ... }` (only inside class bodies).
            if (self.src[self.pos] == '~') {
                try self.parseFinalizer(decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }

            // Member-or-fn (or top-level statement).
            try self.parseMemberOrFn(decl_start, parent_identity, kind, decl_indices, decl_hashes);
        }
    }

    fn parseUsing(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.pos += "using".len;
        self.skipTrivia();
        // Optional `static`.
        if (self.matchKeyword("static")) {
            self.pos += "static".len;
            self.skipTrivia();
        }
        const ident_start = self.pos;
        while (!self.atEnd() and self.src[self.pos] != ';') {
            const c = self.src[self.pos];
            if (c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        const ident_end = self.pos;
        if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;

        var ir_start: u32 = ident_start;
        while (ir_start < ident_end and (self.src[ir_start] == ' ' or self.src[ir_start] == '\t')) ir_start += 1;
        var ir_end: u32 = ident_end;
        while (ir_end > ir_start and (self.src[ir_end - 1] == ' ' or self.src[ir_end - 1] == '\t')) ir_end -= 1;

        const name_bytes = self.src[ir_start..ir_end];
        try self.emitDecl(.cs_using, .{ .start = ir_start, .end = ir_end }, decl_start, parent_identity, decl_indices, decl_hashes, name_bytes.len > 0);
    }

    fn parseNamespace(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        outer_kind: ContainerKind,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.pos += "namespace".len;
        self.skipTrivia();
        // Capture qualified name (dotted).
        const name_start = self.pos;
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '{' or c == ';' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        var name_end = self.pos;
        // Trim trailing whitespace.
        while (name_end > name_start and (self.src[name_end - 1] == ' ' or self.src[name_end - 1] == '\t')) name_end -= 1;
        const name_range: Range = .{ .start = name_start, .end = name_end };
        const name_bytes = self.src[name_range.start..name_range.end];

        self.skipTrivia();
        const ns_identity = hash_mod.identityHash(parent_identity, .cs_namespace, name_bytes);

        var member_indices: std.ArrayList(NodeIndex) = .empty;
        defer member_indices.deinit(self.gpa);
        var member_hashes: std.ArrayList(u64) = .empty;
        defer member_hashes.deinit(self.gpa);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1;
            try self.scanContainer(ns_identity, self.current_depth + 1, .namespace_body, &member_indices, &member_hashes);
        } else if (!self.atEnd() and self.src[self.pos] == ';') {
            // File-scoped namespace: subsequent decls in the same outer container
            // are reparented under this namespace.
            self.pos += 1;
            try self.scanContainer(ns_identity, self.current_depth + 1, outer_kind, &member_indices, &member_hashes);
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(.cs_namespace, member_hashes.items, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = ns_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .cs_namespace,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name_range,
            .is_exported = name_bytes.len > 0,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (member_indices.items) |m| parents[m] = idx;
    }

    /// `class | interface | struct | record | enum <Name> ... { ... }`. Recurse.
    fn parseTypeContainer(
        self: *Parser,
        kind: Kind,
        body_kind: ContainerKind,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        const name_bytes = self.src[name.start..name.end];

        // Walk header until `{` or `;`. May include generics, base list, where,
        // and (for records) a primary parameter list.
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
                '[' => try self.skipBalanced('[', ']'),
                '"', '\'' => try self.skipString(),
                '$', '@' => {
                    const next = self.peek(1);
                    if (next == @as(u8, '"') or next == @as(u8, '$') or next == @as(u8, '@')) {
                        try self.skipString();
                    } else self.pos += 1;
                },
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
            try self.scanContainer(container_identity, self.current_depth + 1, body_kind, &member_indices, &member_hashes);
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
            .is_exported = name_bytes.len > 0,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);

        const parents = self.tree.nodes.items(.parent_idx);
        for (member_indices.items) |m| parents[m] = idx;
    }

    /// `delegate <ReturnType> <Name>(...);` — emit as `cs_method`.
    fn parseDelegate(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        // Walk to the `(` that starts the parameter list. The token immediately
        // before is the delegate name.
        var last_ident: ?Range = null;
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '(' or c == ';') break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '"', '\'' => try self.skipString(),
                '[', ']' => self.pos += 1,
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
            try self.skipBalanced('(', ')');
        }
        // Optional where clauses + `;`.
        while (!self.atEnd() and self.src[self.pos] != ';') {
            self.pos += 1;
        }
        if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const name_bytes = self.src[name.start..name.end];
        const fn_identity = hash_mod.identityHash(parent_identity, .cs_method, name_bytes);
        const h = hash_mod.subtreeHash(.cs_method, &.{}, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = fn_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .cs_method,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = isPublic(self.src[decl_start..name.start]),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);
    }

    /// `event <DelegateType> <Name>;` or `event <DelegateType> <Name> { add; remove; }`.
    fn parseEvent(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        var last_ident: ?Range = null;
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == ';' or c == '{' or c == ',' or c == '=') break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '[', ']' => self.pos += 1,
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

        // Walk past the rest: either `;`, `{ add; remove; }`, or initializer.
        if (!self.atEnd() and self.src[self.pos] == '{') {
            try self.skipBalanced('{', '}');
        } else {
            while (!self.atEnd() and self.src[self.pos] != ';') {
                const c = self.src[self.pos];
                switch (c) {
                    '"', '\'' => try self.skipString(),
                    '(' => try self.skipBalanced('(', ')'),
                    '[' => try self.skipBalanced('[', ']'),
                    '{' => try self.skipBalanced('{', '}'),
                    else => self.pos += 1,
                }
            }
            if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;
        }

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const name_bytes = self.src[name.start..name.end];
        const ev_identity = hash_mod.identityHash(parent_identity, .cs_event, name_bytes);
        const h = hash_mod.subtreeHash(.cs_event, &.{}, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = ev_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .cs_event,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = isPublic(self.src[decl_start..name.start]),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);
    }

    /// `~TypeName() { ... }` finalizer — emit as `cs_method`.
    fn parseFinalizer(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.pos += 1; // consume `~`
        self.skipTrivia();
        const name = self.scanIdent() orelse Range{ .start = self.pos, .end = self.pos };
        self.skipTrivia();
        if (!self.atEnd() and self.src[self.pos] == '(') {
            try self.skipBalanced('(', ')');
        }
        while (!self.atEnd() and self.src[self.pos] != '{' and self.src[self.pos] != ';') {
            self.pos += 1;
        }
        var stmt_indices: std.ArrayList(NodeIndex) = .empty;
        defer stmt_indices.deinit(self.gpa);
        var stmt_hashes: std.ArrayList(u64) = .empty;
        defer stmt_hashes.deinit(self.gpa);

        const name_bytes = self.src[name.start..name.end];
        const fn_identity = hash_mod.identityHash(parent_identity, .cs_method, name_bytes);

        if (!self.atEnd() and self.src[self.pos] == '{') {
            self.pos += 1;
            try self.parseFnBody(fn_identity, &stmt_indices, &stmt_hashes);
        } else if (!self.atEnd() and self.src[self.pos] == ';') {
            self.pos += 1;
        }
        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(.cs_method, stmt_hashes.items, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = fn_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .cs_method,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = false,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);
        const parents = self.tree.nodes.items(.parent_idx);
        for (stmt_indices.items) |s| parents[s] = idx;
    }

    /// Parse the leading constant list of an enum body. Constants are
    /// comma-separated identifiers (with optional `= value`), terminated by
    /// the closing `}`.
    fn parseEnumConstants(
        self: *Parser,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) return;
            const c = self.src[self.pos];
            if (c == '}') return;
            const decl_start = self.pos;
            try self.skipAttributes();
            self.skipTrivia();
            const name = self.scanIdent() orelse {
                self.pos += 1;
                continue;
            };
            // Optional `= value`.
            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == '=') {
                self.pos += 1;
                while (!self.atEnd() and self.src[self.pos] != ',' and self.src[self.pos] != '}') {
                    const cc = self.src[self.pos];
                    switch (cc) {
                        '(' => try self.skipBalanced('(', ')'),
                        '"', '\'' => try self.skipString(),
                        else => self.pos += 1,
                    }
                }
            }
            const decl_end = self.pos;
            try self.emitConstantNamed(.cs_const, name, decl_start, decl_end, parent_identity, decl_indices, decl_hashes);
            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
        }
    }

    fn emitConstantNamed(
        self: *Parser,
        kind: Kind,
        name: Range,
        decl_start: u32,
        decl_end: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const name_bytes = self.src[name.start..name.end];
        const decl_bytes = self.src[decl_start..decl_end];
        const ident = hash_mod.identityHash(parent_identity, kind, name_bytes);
        const h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);
        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = ident,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = kind,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = true,
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);
    }

    /// Parse a method/property/field/const declaration.
    /// Header walk classifies by the first significant punctuator after the
    /// candidate name:
    ///   `(`        → method or constructor
    ///   `{`        → property (or indexer) — auto-property
    ///   `=>`       → arrow-bodied property/method
    ///   `=` / `;`  → field
    ///   `,`        → multi-name field declaration; emit one node per name
    fn parseMemberOrFn(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        container: ContainerKind,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        // Track the LAST identifier seen — that's the member name.
        // Special case: `this[...]` indexer — `this` is the name.
        var last_ident: ?Range = null;
        var is_const = false;
        var saw_indexer = false;

        // Capture leading `const` modifier (already eaten by skipModifiers but
        // keep this defensive: skipModifiers does not eat `const`).
        if (self.matchKeyword("const")) {
            is_const = true;
            self.pos += "const".len;
            self.skipTrivia();
        }

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '(' or c == '=' or c == ';' or c == '{' or c == ',') break;
            if (c == '}') break;
            // Arrow-bodied form `=>` (handle here so the `>` doesn't trip us).
            if (c == '=' and self.peek(1) == @as(u8, '>')) break;
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '"', '\'' => try self.skipString(),
                '$', '@' => {
                    const next = self.peek(1);
                    if (next == @as(u8, '"') or next == @as(u8, '$') or next == @as(u8, '@')) {
                        try self.skipString();
                    } else self.pos += 1;
                },
                '[' => {
                    // `Type this[...]` indexer: if the previous ident was
                    // `this`, treat the bracket as the param list opener.
                    if (last_ident != null and last_ident.?.end - last_ident.?.start == 4 and
                        std.mem.eql(u8, self.src[last_ident.?.start..last_ident.?.end], "this"))
                    {
                        saw_indexer = true;
                        try self.skipBalanced('[', ']');
                    } else {
                        try self.skipBalanced('[', ']');
                    }
                },
                ']' => self.pos += 1,
                else => {
                    if (lex.isIdentStart(c)) {
                        last_ident = self.scanIdent();
                    } else {
                        self.pos += 1;
                    }
                },
            }
        }

        const first_name: Range = last_ident orelse .{ .start = self.pos, .end = self.pos };

        // Indexer: emit as cs_property (the `[...]` was already consumed).
        if (saw_indexer) {
            // Body: `{ get; set; }` or `=> expr;` or `;`.
            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == '{') {
                try self.skipBalanced('{', '}');
            } else if (!self.atEnd() and self.src[self.pos] == '=' and self.peek(1) == @as(u8, '>')) {
                self.pos += 2;
                while (!self.atEnd() and self.src[self.pos] != ';') {
                    const cc = self.src[self.pos];
                    switch (cc) {
                        '"', '\'' => try self.skipString(),
                        '(' => try self.skipBalanced('(', ')'),
                        '[' => try self.skipBalanced('[', ']'),
                        '{' => try self.skipBalanced('{', '}'),
                        else => self.pos += 1,
                    }
                }
                if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;
            } else if (!self.atEnd() and self.src[self.pos] == ';') {
                self.pos += 1;
            }
            try self.emitProperty(first_name, decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }

        if (!self.atEnd() and self.src[self.pos] == '(') {
            try self.skipBalanced('(', ')');
            // Method or constructor. Walk until body or `;` or `=>`.
            while (!self.atEnd()) {
                self.skipTrivia();
                if (self.atEnd()) break;
                const c = self.src[self.pos];
                if (c == '{' or c == ';') break;
                if (c == '=' and self.peek(1) == @as(u8, '>')) break;
                switch (c) {
                    '<' => self.skipBalanced('<', '>') catch {
                        self.pos += 1;
                    },
                    '(' => try self.skipBalanced('(', ')'),
                    '[' => try self.skipBalanced('[', ']'),
                    '"', '\'' => try self.skipString(),
                    else => self.pos += 1,
                }
            }

            var stmt_indices: std.ArrayList(NodeIndex) = .empty;
            defer stmt_indices.deinit(self.gpa);
            var stmt_hashes: std.ArrayList(u64) = .empty;
            defer stmt_hashes.deinit(self.gpa);

            const name_bytes = self.src[first_name.start..first_name.end];
            const fn_identity = hash_mod.identityHash(parent_identity, .cs_method, name_bytes);

            if (!self.atEnd() and self.src[self.pos] == '{') {
                self.pos += 1;
                try self.parseFnBody(fn_identity, &stmt_indices, &stmt_hashes);
            } else if (!self.atEnd() and self.src[self.pos] == '=' and self.peek(1) == @as(u8, '>')) {
                // Expression-bodied method: `=> expr;`.
                self.pos += 2;
                while (!self.atEnd() and self.src[self.pos] != ';') {
                    const cc = self.src[self.pos];
                    switch (cc) {
                        '"', '\'' => try self.skipString(),
                        '(' => try self.skipBalanced('(', ')'),
                        '[' => try self.skipBalanced('[', ']'),
                        '{' => try self.skipBalanced('{', '}'),
                        else => self.pos += 1,
                    }
                }
                if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;
            } else if (!self.atEnd() and self.src[self.pos] == ';') {
                self.pos += 1;
            }

            const decl_end = self.pos;
            const decl_bytes = self.src[decl_start..decl_end];
            const h = hash_mod.subtreeHash(.cs_method, stmt_hashes.items, decl_bytes);

            const idx = try self.tree.addNode(.{
                .hash = h,
                .identity_hash = fn_identity,
                .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
                .kind = .cs_method,
                .depth = self.current_depth,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = decl_start, .end = decl_end },
                .identity_range = first_name,
                .is_exported = isPublic(self.src[decl_start..first_name.start]),
            });
            try decl_indices.append(self.gpa, idx);
            try decl_hashes.append(self.gpa, h);

            const parents = self.tree.nodes.items(.parent_idx);
            for (stmt_indices.items) |s| parents[s] = idx;
            return;
        }

        // No `(` — could be property (`{` next), arrow-bodied property (`=>` next),
        // field with init (`=` next), or field decl (`;`/`,`).
        if (!self.atEnd() and self.src[self.pos] == '{') {
            // Auto-property.
            try self.skipBalanced('{', '}');
            // Optional `= initializer;` after auto-property body.
            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == '=') {
                while (!self.atEnd() and self.src[self.pos] != ';') {
                    const cc = self.src[self.pos];
                    switch (cc) {
                        '"', '\'' => try self.skipString(),
                        '(' => try self.skipBalanced('(', ')'),
                        '[' => try self.skipBalanced('[', ']'),
                        '{' => try self.skipBalanced('{', '}'),
                        else => self.pos += 1,
                    }
                }
                if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;
            }
            try self.emitProperty(first_name, decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }
        if (!self.atEnd() and self.src[self.pos] == '=' and self.peek(1) == @as(u8, '>')) {
            // Arrow-bodied property.
            self.pos += 2;
            while (!self.atEnd() and self.src[self.pos] != ';') {
                const cc = self.src[self.pos];
                switch (cc) {
                    '"', '\'' => try self.skipString(),
                    '(' => try self.skipBalanced('(', ')'),
                    '[' => try self.skipBalanced('[', ']'),
                    '{' => try self.skipBalanced('{', '}'),
                    else => self.pos += 1,
                }
            }
            if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;
            try self.emitProperty(first_name, decl_start, parent_identity, decl_indices, decl_hashes);
            return;
        }

        // Field/const. Collect additional names separated by `,`. Top-level
        // statements at file scope also fall through here — emit as `cs_stmt`.
        const is_top_level_stmt = container == .file_scope;

        var names: std.ArrayList(Range) = .empty;
        defer names.deinit(self.gpa);
        try names.append(self.gpa, first_name);

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == ';') break;
            if (c == '}') break;
            if (c == ',') {
                self.pos += 1;
                self.skipTrivia();
                if (self.scanIdent()) |n| try names.append(self.gpa, n);
                continue;
            }
            switch (c) {
                '<' => self.skipBalanced('<', '>') catch {
                    self.pos += 1;
                },
                '(' => try self.skipBalanced('(', ')'),
                '[' => try self.skipBalanced('[', ']'),
                '{' => try self.skipBalanced('{', '}'),
                '"', '\'' => try self.skipString(),
                '$', '@' => {
                    const next = self.peek(1);
                    if (next == @as(u8, '"') or next == @as(u8, '$') or next == @as(u8, '@')) {
                        try self.skipString();
                    } else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
        if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];

        if (is_top_level_stmt) {
            // Top-level statement: emit one cs_stmt covering the whole decl.
            const trimmed = std.mem.trim(u8, decl_bytes, " \t\r\n");
            if (trimmed.len == 0) return;
            const stmt_identity = hash_mod.identityHash(parent_identity, .cs_stmt, trimmed);
            const h = hash_mod.subtreeHash(.cs_stmt, &.{}, trimmed);
            const idx = try self.tree.addNode(.{
                .hash = h,
                .identity_hash = stmt_identity,
                .identity_range_hash = 0,
                .kind = .cs_stmt,
                .depth = self.current_depth,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = decl_start, .end = decl_end },
                .identity_range = Range.empty,
                .is_exported = false,
            });
            try decl_indices.append(self.gpa, idx);
            try decl_hashes.append(self.gpa, h);
            return;
        }

        const kind: Kind = if (is_const) .cs_const else .cs_field;
        const exported = isPublic(self.src[decl_start..first_name.start]);

        for (names.items) |nm| {
            const name_bytes = self.src[nm.start..nm.end];
            const ident = hash_mod.identityHash(parent_identity, kind, name_bytes);
            const h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);
            const idx = try self.tree.addNode(.{
                .hash = h,
                .identity_hash = ident,
                .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
                .kind = kind,
                .depth = self.current_depth,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = decl_start, .end = decl_end },
                .identity_range = nm,
                .is_exported = exported,
            });
            try decl_indices.append(self.gpa, idx);
            try decl_hashes.append(self.gpa, h);
        }
    }

    fn emitProperty(
        self: *Parser,
        name: Range,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const name_bytes = self.src[name.start..name.end];
        const prop_identity = hash_mod.identityHash(parent_identity, .cs_property, name_bytes);
        const h = hash_mod.subtreeHash(.cs_property, &.{}, decl_bytes);

        const idx = try self.tree.addNode(.{
            .hash = h,
            .identity_hash = prop_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
            .kind = .cs_property,
            .depth = self.current_depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = decl_start, .end = decl_end },
            .identity_range = name,
            .is_exported = isPublic(self.src[decl_start..name.start]),
        });
        try decl_indices.append(self.gpa, idx);
        try decl_hashes.append(self.gpa, h);
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
            const stmt_identity = hash_mod.identityHash(fn_identity, .cs_stmt, idx_str);
            const stmt_h = hash_mod.subtreeHash(.cs_stmt, &.{}, trimmed);

            const node = try self.tree.addNode(.{
                .hash = stmt_h,
                .identity_hash = stmt_identity,
                .identity_range_hash = 0,
                .kind = .cs_stmt,
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
                '$', '@' => {
                    const next = self.peek(1);
                    if (next == @as(u8, '"') or next == @as(u8, '$') or next == @as(u8, '@')) {
                        try self.skipString();
                    } else self.pos += 1;
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
        is_named: bool,
    ) ParseError!void {
        const decl_end = self.pos;
        const ident_bytes = self.src[identity_range.start..identity_range.end];
        const decl_identity = hash_mod.identityHash(parent_identity, kind, ident_bytes);
        const decl_bytes = self.src[decl_start..decl_end];
        const h = hash_mod.subtreeHash(kind, &.{}, decl_bytes);

        const irh: u64 = if (is_named) std.hash.Wyhash.hash(0, ident_bytes) else 0;
        const exported = is_named and ident_bytes.len > 0;

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

/// True if the leading-modifier slice contains the keyword `public`.
fn isPublic(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '[') {
            // Skip attribute.
            var depth: u32 = 1;
            i += 1;
            while (i < s.len and depth > 0) : (i += 1) {
                if (s[i] == '[') depth += 1;
                if (s[i] == ']') depth -= 1;
            }
            continue;
        }
        if (lex.isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < s.len and lex.isIdentCont(s[i])) i += 1;
            const word = s[start..i];
            if (std.mem.eql(u8, word, "public")) return true;
            continue;
        }
        i += 1;
    }
    return false;
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

test "parse empty cs file" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "", "x.cs");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.file_root, t.nodes.items(.kind)[0]);
}

test "parse using and namespace block-form" {
    const gpa = std.testing.allocator;
    const src =
        \\using System;
        \\using System.Collections.Generic;
        \\namespace App.Foo {
        \\    public class Bar {}
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var using_count: usize = 0;
    var ns_count: usize = 0;
    var class_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_using) using_count += 1;
        if (k == .cs_namespace) ns_count += 1;
        if (k == .cs_class) class_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), using_count);
    try std.testing.expectEqual(@as(usize, 1), ns_count);
    try std.testing.expectEqual(@as(usize, 1), class_count);
}

test "parse file-scoped namespace" {
    const gpa = std.testing.allocator;
    const src =
        \\namespace App;
        \\public class A {}
        \\public class B {}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var ns_count: usize = 0;
    var class_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_namespace) ns_count += 1;
        if (k == .cs_class) class_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ns_count);
    try std.testing.expectEqual(@as(usize, 2), class_count);
}

test "parse class with method and property" {
    const gpa = std.testing.allocator;
    const src =
        \\public class Calc {
        \\    public int Sum { get; set; }
        \\    public int Add(int a, int b) { return a + b; }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_class = false;
    var has_method = false;
    var has_prop = false;
    for (kinds) |k| {
        if (k == .cs_class) has_class = true;
        if (k == .cs_method) has_method = true;
        if (k == .cs_property) has_prop = true;
    }
    try std.testing.expect(has_class);
    try std.testing.expect(has_method);
    try std.testing.expect(has_prop);
}

test "parse record positional" {
    const gpa = std.testing.allocator;
    const src =
        \\public record Point(int X, int Y);
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var rec = false;
    for (kinds) |k| if (k == .cs_record) {
        rec = true;
    };
    try std.testing.expect(rec);
}

test "parse record body-form" {
    const gpa = std.testing.allocator;
    const src =
        \\public record Foo {
        \\    public int X { get; init; }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var rec = false;
    var prop = false;
    for (kinds) |k| {
        if (k == .cs_record) rec = true;
        if (k == .cs_property) prop = true;
    }
    try std.testing.expect(rec);
    try std.testing.expect(prop);
}

test "parse struct" {
    const gpa = std.testing.allocator;
    const src =
        \\public struct Vec {
        \\    public float X;
        \\    public float Y;
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_struct = false;
    var field_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_struct) has_struct = true;
        if (k == .cs_field) field_count += 1;
    }
    try std.testing.expect(has_struct);
    try std.testing.expectEqual(@as(usize, 2), field_count);
}

test "parse interface with default method" {
    const gpa = std.testing.allocator;
    const src =
        \\public interface IGreeter {
        \\    string Name();
        \\    string Greet() => "hi " + Name();
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var iface = false;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_interface) iface = true;
        if (k == .cs_method) method_count += 1;
    }
    try std.testing.expect(iface);
    try std.testing.expectEqual(@as(usize, 2), method_count);
}

test "parse enum" {
    const gpa = std.testing.allocator;
    const src =
        \\public enum Color {
        \\    Red,
        \\    Green = 2,
        \\    Blue
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var enum_count: usize = 0;
    var const_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_enum) enum_count += 1;
        if (k == .cs_const) const_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), enum_count);
    try std.testing.expectEqual(@as(usize, 3), const_count);
}

test "parse generic class" {
    const gpa = std.testing.allocator;
    const src =
        \\public class Box<T> where T : class {
        \\    public T Value { get; set; }
        \\    public T Get() { return Value; }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var class_count: usize = 0;
    var prop_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_class) class_count += 1;
        if (k == .cs_property) prop_count += 1;
        if (k == .cs_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_count);
    try std.testing.expectEqual(@as(usize, 1), prop_count);
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse async method" {
    const gpa = std.testing.allocator;
    const src =
        \\public class C {
        \\    public async Task<int> RunAsync() { return await Task.FromResult(42); }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var method_count: usize = 0;
    for (kinds) |k| if (k == .cs_method) {
        method_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse indexer" {
    const gpa = std.testing.allocator;
    const src =
        \\public class C {
        \\    public int this[int i] { get { return i; } set { } }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var prop_count: usize = 0;
    for (kinds) |k| if (k == .cs_property) {
        prop_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), prop_count);
}

test "parse event" {
    const gpa = std.testing.allocator;
    const src =
        \\public class C {
        \\    public event Action OnFire;
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var ev_count: usize = 0;
    for (kinds) |k| if (k == .cs_event) {
        ev_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), ev_count);
}

test "parse partial class" {
    const gpa = std.testing.allocator;
    const src =
        \\public partial class C {
        \\    public int A() { return 1; }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var class_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_class) class_count += 1;
        if (k == .cs_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_count);
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse attribute on class" {
    const gpa = std.testing.allocator;
    const src =
        \\[Serializable]
        \\public class C {
        \\    [Obsolete("use NewMethod")]
        \\    public void Old() {}
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var class_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .cs_class) class_count += 1;
        if (k == .cs_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_count);
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse interpolated string" {
    const gpa = std.testing.allocator;
    const src =
        \\public class C {
        \\    public string Greet(string name) { return $"Hello, {name}!"; }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var method_count: usize = 0;
    for (kinds) |k| if (k == .cs_method) {
        method_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse verbatim string" {
    const gpa = std.testing.allocator;
    const src =
        \\public class C {
        \\    public string Path = @"C:\Users\foo";
        \\    public int Next() { return 1; }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var method_count: usize = 0;
    for (kinds) |k| if (k == .cs_method) {
        method_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "fn body extracts cs_stmt children" {
    const gpa = std.testing.allocator;
    const src =
        \\public class C {
        \\    public int Compute(int a, int b) {
        \\        int x = a + b;
        \\        int y = x * 2;
        \\        return y;
        \\    }
        \\}
    ;
    var t = try parse(gpa, src, "x.cs");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var stmt_count: usize = 0;
    for (kinds) |k| if (k == .cs_stmt) {
        stmt_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), stmt_count);
}
