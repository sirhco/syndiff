//! Java top-level + member parser. Same shape as `dart_parser.zig`:
//! skim lexer + brace-counting body skip + per-decl node.
//!
//! Recognized top-level items (with leading annotations `@...` and modifiers
//! absorbed into the decl's content range):
//!   package <qualified.name>;                     → java_package
//!   import [static] <qualified.name>[.*];         → java_import
//!   class / interface / enum / record / @interface
//!     [<T,...>] [extends ...] [implements ...] {} → java_class | java_interface
//!                                                   java_enum | java_record |
//!                                                   java_annotation_decl
//!
//! Type body members (inside `class { ... }`, `interface { ... }` etc.):
//!   [modifiers] <ClassName>(...) [throws ...] { ... }   → java_constructor
//!   [modifiers] [<T,...>] <ReturnType> <name>(...) [body|;]
//!                                                       → java_method
//!   [modifiers] <Type> <name>[, <name2> ...] [= ...];   → java_field per name
//!     (one node emitted per declared name; content_range spans whole decl)
//!   In an interface body, the same field shape emits `java_const` instead
//!   (interface fields are implicitly `public static final`).
//!   Nested types recurse into their own body.
//!
//! Function bodies break into `java_stmt` children (per-statement, split on
//! `;` at brace-depth 0 OR balanced `{...}` blocks).
//!
//! Limitations:
//!   * Annotation arg expressions inside `@Foo(...)` are absorbed into the
//!     decl's content range — they do not emit sub-nodes.
//!   * Reflection-style strings (e.g. `Class.forName("...")`) are not flagged
//!     here — that's the language-neutral `sensitivity` scan's job.
//!   * `module-info.java` parses but is treated as opaque package-info-style
//!     (a single top-level `module {...}` block is absorbed).
//!   * Lambda bodies (`(x) -> expr`) and method references (`X::y`) are
//!     body-internal: content range absorbs them, no separate kinds.
//!   * Text blocks (`"""..."""`) are handled.

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

    /// Skip a string starting at `self.pos`. Detects `"""` Java text block
    /// form and consumes through the matching triple. Single double-quote
    /// strings + single-quoted char literals also handled. Java does NOT
    /// support `${}` interpolation so no recursion needed.
    fn skipString(self: *Parser) ParseError!void {
        const quote = self.src[self.pos];
        // Triple-quoted text block? Only `"""` in Java.
        if (quote == '"' and self.pos + 2 < self.src.len and
            self.src[self.pos + 1] == '"' and
            self.src[self.pos + 2] == '"')
        {
            self.pos += 3;
            while (self.pos + 2 < self.src.len) {
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                    self.pos += 2;
                    continue;
                }
                if (self.src[self.pos] == '"' and
                    self.src[self.pos + 1] == '"' and
                    self.src[self.pos + 2] == '"')
                {
                    self.pos += 3;
                    return;
                }
                self.pos += 1;
            }
            return error.UnterminatedString;
        }
        self.pos += 1; // consume opening quote
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '\\') {
                if (self.pos + 1 >= self.src.len) return error.UnterminatedString;
                self.pos += 2;
                continue;
            }
            if (c == quote) {
                self.pos += 1;
                return;
            }
            if (c == '\n') return error.UnterminatedString;
            self.pos += 1;
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
                '"', '\'' => try self.skipString(),
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

    /// Skip `@Annotation`, `@Annotation(...)`, and dotted `@a.b.C(...)`.
    fn skipAnnotations(self: *Parser) ParseError!void {
        while (true) {
            self.skipTrivia();
            if (self.atEnd() or self.src[self.pos] != '@') return;
            // Don't eat the `@` of `@interface` declarations — that's not an
            // annotation usage, it's a top-level type declaration.
            if (lex.matchKeyword(self.src, self.pos + 1, "interface")) return;
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

    /// Eat a sequence of leading modifier keywords. Returns when the next
    /// non-trivia token is not a modifier.
    fn skipModifiers(self: *Parser) void {
        const mods = [_][]const u8{
            "public", "private", "protected", "static", "final", "abstract",
            "sealed", "default", "synchronized", "native", "strictfp",
            "volatile", "transient",
        };
        outer: while (true) {
            self.skipTrivia();
            if (self.atEnd()) return;
            // `non-sealed` is a contextual hyphenated keyword.
            if (self.matchKeyword("non") and self.pos + 4 < self.src.len and
                self.src[self.pos + 3] == '-' and
                std.mem.startsWith(u8, self.src[self.pos + 4 ..], "sealed"))
            {
                self.pos += "non-sealed".len;
                continue;
            }
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
        class_body, // class, record curly form, annotation_decl
        interface_body,
        enum_body,
    };

    /// Scan items in a container scope (file, class body, interface body, ...).
    /// `kind` controls whether to stop at `}` and how to classify field-shaped
    /// declarations (`java_field` in a class body, `java_const` in an interface
    /// body).
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
            // Enum bodies have a leading constant list before the optional `;`
            // and member section. Parse it specially.
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
            try self.skipAnnotations();
            self.skipTrivia();
            if (self.atEnd()) break;

            // File-scope: package / import (only at file scope).
            if (kind == .file_scope) {
                if (self.matchKeyword("package")) {
                    try self.parsePackage(decl_start, parent_identity, decl_indices, decl_hashes);
                    continue;
                }
                if (self.matchKeyword("import")) {
                    try self.parseImport(decl_start, parent_identity, decl_indices, decl_hashes);
                    continue;
                }
                if (self.matchKeyword("module") or
                    self.matchKeyword("open"))
                {
                    // module-info: opaque, single block. Treat as a
                    // package-info-style java_package node spanning the decl.
                    try self.parseModuleInfo(decl_start, parent_identity, decl_indices, decl_hashes);
                    continue;
                }
            }

            // Modifier prefix.
            self.skipModifiers();
            self.skipTrivia();
            if (self.atEnd()) break;
            // Annotations may be interleaved with modifiers in Java syntax.
            try self.skipAnnotations();
            self.skipTrivia();
            self.skipModifiers();
            self.skipTrivia();

            // Type declarations.
            if (self.matchKeyword("class")) {
                self.pos += "class".len;
                try self.parseTypeContainer(.java_class, .class_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("interface")) {
                self.pos += "interface".len;
                try self.parseTypeContainer(.java_interface, .interface_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("enum")) {
                self.pos += "enum".len;
                try self.parseTypeContainer(.java_enum, .enum_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            if (self.matchKeyword("record")) {
                self.pos += "record".len;
                try self.parseTypeContainer(.java_record, .class_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }
            // `@interface` annotation declaration.
            if (self.src[self.pos] == '@' and lex.matchKeyword(self.src, self.pos + 1, "interface")) {
                self.pos += 1; // '@'
                self.pos += "interface".len;
                try self.parseTypeContainer(.java_annotation_decl, .interface_body, decl_start, parent_identity, decl_indices, decl_hashes);
                continue;
            }

            // Member-or-fn: read header until `(`, `=`, `;`, or `{`.
            try self.parseMemberOrFn(decl_start, parent_identity, kind, decl_indices, decl_hashes);
        }
    }

    fn parsePackage(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.pos += "package".len;
        self.skipTrivia();
        const ident_start = self.pos;
        // Capture qualified name.
        while (!self.atEnd() and self.src[self.pos] != ';') {
            const c = self.src[self.pos];
            if (c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        const ident_end = self.pos;
        if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;

        const name_bytes = std.mem.trim(u8, self.src[ident_start..ident_end], " \t");
        // Compute trimmed range (relative to original src offsets).
        var ir_start: u32 = ident_start;
        while (ir_start < ident_end and (self.src[ir_start] == ' ' or self.src[ir_start] == '\t')) ir_start += 1;
        var ir_end: u32 = ident_end;
        while (ir_end > ir_start and (self.src[ir_end - 1] == ' ' or self.src[ir_end - 1] == '\t')) ir_end -= 1;

        try self.emitDecl(.java_package, .{ .start = ir_start, .end = ir_end }, decl_start, parent_identity, decl_indices, decl_hashes, name_bytes.len > 0);
    }

    fn parseImport(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        self.pos += "import".len;
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

        try self.emitDecl(.java_import, .{ .start = ir_start, .end = ir_end }, decl_start, parent_identity, decl_indices, decl_hashes, false);
    }

    fn parseModuleInfo(
        self: *Parser,
        decl_start: u32,
        parent_identity: u64,
        decl_indices: *std.ArrayList(NodeIndex),
        decl_hashes: *std.ArrayList(u64),
    ) ParseError!void {
        // Consume `module` or `open module`.
        if (self.matchKeyword("open")) {
            self.pos += "open".len;
            self.skipTrivia();
            if (self.matchKeyword("module")) self.pos += "module".len;
        } else if (self.matchKeyword("module")) {
            self.pos += "module".len;
        }
        self.skipTrivia();
        const name = self.scanIdent() orelse Range.empty;
        // Consume any further dotted name.
        while (!self.atEnd() and self.src[self.pos] == '.') {
            self.pos += 1;
            _ = self.scanIdent();
        }
        // Skip until `{` then balanced.
        while (!self.atEnd() and self.src[self.pos] != '{' and self.src[self.pos] != ';') {
            self.pos += 1;
        }
        if (!self.atEnd() and self.src[self.pos] == '{') {
            try self.skipBalanced('{', '}');
        } else if (!self.atEnd() and self.src[self.pos] == ';') {
            self.pos += 1;
        }
        try self.emitDecl(.java_package, name, decl_start, parent_identity, decl_indices, decl_hashes, true);
    }

    /// class/interface/enum/record/@interface <Name> ... { ... }. Recurse.
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

        // Walk header until `{` or `;`. Records have a `(...)` parameter list.
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

    /// Parse the leading constant list of an enum body. Constants are
    /// comma-separated identifiers (with optional `(args)` and `{ class body }`),
    /// terminated by `;` or the closing `}`.
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
            if (c == '}') return; // empty enum
            if (c == ';') {
                self.pos += 1;
                return;
            }
            const decl_start = self.pos;
            try self.skipAnnotations();
            self.skipTrivia();
            const name = self.scanIdent() orelse {
                // Not an identifier — bail to avoid infinite loop.
                self.pos += 1;
                continue;
            };
            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == '(') {
                try self.skipBalanced('(', ')');
                self.skipTrivia();
            }
            if (!self.atEnd() and self.src[self.pos] == '{') {
                try self.skipBalanced('{', '}');
                self.skipTrivia();
            }
            const decl_end = self.pos;
            try self.emitConstantNamed(.java_const, name, decl_start, decl_end, parent_identity, decl_indices, decl_hashes);

            self.skipTrivia();
            if (!self.atEnd() and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            // Otherwise loop will see `;` or `}` and stop.
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

    /// Parse a method/constructor/field declaration. Header walk classifies by
    /// the first significant punctuator after the candidate name:
    ///   `(`        → method or constructor
    ///   `=` / `;`  → field (or const, in interface)
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
        var last_ident: ?Range = null;
        var saw_paren = false;

        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == '(' or c == '=' or c == ';' or c == '{' or c == ',') break;
            if (c == '}') break;
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

        const first_name: Range = last_ident orelse .{ .start = self.pos, .end = self.pos };

        if (!self.atEnd() and self.src[self.pos] == '(') {
            saw_paren = true;
            try self.skipBalanced('(', ')');
        }

        if (saw_paren) {
            // Method or constructor. Walk until body or `;`.
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
                    else => self.pos += 1,
                }
            }

            // Determine method vs constructor: a method has a return type
            // before the name; a constructor's name equals the enclosing
            // class name and has no return type. We can't easily check the
            // class name here — fall back to "if any non-modifier ident
            // appeared before the name, it's a method". The header walk
            // does not preserve that detail, so use a simpler proxy:
            // compute the slice between `decl_start` and `first_name.start`
            // (after stripping annotations and modifiers); if non-empty,
            // it's a method.
            const kind: Kind = blk: {
                const before = self.src[decl_start..first_name.start];
                const trimmed = headerHasReturnType(before);
                break :blk if (trimmed) .java_method else .java_constructor;
            };

            const fn_identity = hash_mod.identityHash(parent_identity, kind, self.src[first_name.start..first_name.end]);

            var stmt_indices: std.ArrayList(NodeIndex) = .empty;
            defer stmt_indices.deinit(self.gpa);
            var stmt_hashes: std.ArrayList(u64) = .empty;
            defer stmt_hashes.deinit(self.gpa);

            if (!self.atEnd() and self.src[self.pos] == '{') {
                self.pos += 1;
                try self.parseFnBody(fn_identity, &stmt_indices, &stmt_hashes);
            } else if (!self.atEnd() and self.src[self.pos] == ';') {
                self.pos += 1;
            }

            const decl_end = self.pos;
            const decl_bytes = self.src[decl_start..decl_end];
            const h = hash_mod.subtreeHash(kind, stmt_hashes.items, decl_bytes);

            const name_bytes = self.src[first_name.start..first_name.end];
            const idx = try self.tree.addNode(.{
                .hash = h,
                .identity_hash = fn_identity,
                .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
                .kind = kind,
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

        // No paren — it's a field/const declaration. Walk to `;` collecting
        // additional names separated by `,` (multi-name fields). Each name
        // gets its own node, all sharing the same content range.
        var names: std.ArrayList(Range) = .empty;
        defer names.deinit(self.gpa);
        try names.append(self.gpa, first_name);

        // Walk through initializer / additional names until `;`.
        while (!self.atEnd()) {
            self.skipTrivia();
            if (self.atEnd()) break;
            const c = self.src[self.pos];
            if (c == ';') break;
            if (c == '}') break;
            if (c == ',') {
                self.pos += 1;
                self.skipTrivia();
                // Optional `[]` modifiers.
                while (!self.atEnd() and self.src[self.pos] == '[') {
                    try self.skipBalanced('[', ']');
                    self.skipTrivia();
                }
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
                else => self.pos += 1,
            }
        }
        if (!self.atEnd() and self.src[self.pos] == ';') self.pos += 1;

        const decl_end = self.pos;
        const decl_bytes = self.src[decl_start..decl_end];
        const kind: Kind = if (container == .interface_body) .java_const else .java_field;
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
                .is_exported = exported or container == .interface_body,
            });
            try decl_indices.append(self.gpa, idx);
            try decl_hashes.append(self.gpa, h);
        }
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
            const stmt_identity = hash_mod.identityHash(fn_identity, .java_stmt, idx_str);
            const stmt_h = hash_mod.subtreeHash(.java_stmt, &.{}, trimmed);

            const node = try self.tree.addNode(.{
                .hash = stmt_h,
                .identity_hash = stmt_identity,
                .identity_range_hash = 0,
                .kind = .java_stmt,
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

/// True if the slice (which sits before the method/constructor name) contains
/// a return-type identifier that's not a modifier or annotation. Used to
/// distinguish `Foo()` (constructor) from `void foo()` (method).
fn headerHasReturnType(s: []const u8) bool {
    var i: usize = 0;
    var saw_type_ident: bool = false;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        // Skip line comment.
        if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
            while (i < s.len and s[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
            i += 2;
            while (i + 1 < s.len and !(s[i] == '*' and s[i + 1] == '/')) i += 1;
            if (i + 1 < s.len) i += 2;
            continue;
        }
        // Skip annotation `@...(...)`.
        if (c == '@') {
            i += 1;
            while (i < s.len and (lex.isIdentCont(s[i]) or s[i] == '.')) i += 1;
            // Skip optional balanced parens.
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
        // Skip generic `<...>`.
        if (c == '<') {
            var depth: u32 = 1;
            i += 1;
            while (i < s.len and depth > 0) : (i += 1) {
                if (s[i] == '<') depth += 1;
                if (s[i] == '>') depth -= 1;
            }
            continue;
        }
        // Skip `[]`.
        if (c == '[' or c == ']') {
            i += 1;
            continue;
        }
        if (lex.isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < s.len and lex.isIdentCont(s[i])) i += 1;
            const word = s[start..i];
            if (isModifierKeyword(word)) continue;
            saw_type_ident = true;
            // Continue — there may be `<...>` or array brackets after.
            continue;
        }
        // Anything else: skip.
        i += 1;
    }
    return saw_type_ident;
}

fn isModifierKeyword(w: []const u8) bool {
    const mods = [_][]const u8{
        "public",     "private",     "protected", "static",
        "final",      "abstract",    "sealed",    "default",
        "synchronized", "native",    "strictfp",  "volatile",
        "transient",  "non-sealed",
    };
    for (mods) |m| if (std.mem.eql(u8, m, w)) return true;
    return false;
}

/// True if the leading-modifier slice contains the keyword `public`.
fn isPublic(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '@') {
            // Skip annotation.
            i += 1;
            while (i < s.len and (lex.isIdentCont(s[i]) or s[i] == '.')) i += 1;
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

test "parse empty java file" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "", "x.java");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.file_root, t.nodes.items(.kind)[0]);
}

test "parse package and import" {
    const gpa = std.testing.allocator;
    const src =
        \\package com.example.app;
        \\import java.util.List;
        \\import static java.lang.Math.PI;
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var pkg: usize = 0;
    var imp: usize = 0;
    for (kinds) |k| {
        if (k == .java_package) pkg += 1;
        if (k == .java_import) imp += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pkg);
    try std.testing.expectEqual(@as(usize, 2), imp);
}

test "parse class with method" {
    const gpa = std.testing.allocator;
    const src =
        \\package x;
        \\public class Calc {
        \\    public int add(int a, int b) { return a + b; }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var has_class = false;
    var has_method = false;
    for (kinds) |k| {
        if (k == .java_class) has_class = true;
        if (k == .java_method) has_method = true;
    }
    try std.testing.expect(has_class);
    try std.testing.expect(has_method);
}

test "parse abstract class with abstract method" {
    const gpa = std.testing.allocator;
    const src =
        \\public abstract class Shape {
        \\    public abstract double area();
        \\    public String name() { return "shape"; }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var class_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .java_class) class_count += 1;
        if (k == .java_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_count);
    try std.testing.expectEqual(@as(usize, 2), method_count);
}

test "parse interface with default method" {
    const gpa = std.testing.allocator;
    const src =
        \\public interface Greeter {
        \\    String name();
        \\    default String greet() { return "hi " + name(); }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var iface = false;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .java_interface) iface = true;
        if (k == .java_method) method_count += 1;
    }
    try std.testing.expect(iface);
    try std.testing.expectEqual(@as(usize, 2), method_count);
}

test "parse enum with constants" {
    const gpa = std.testing.allocator;
    const src =
        \\public enum Color {
        \\    RED, GREEN, BLUE;
        \\    public int rgb() { return 0; }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var enum_count: usize = 0;
    var const_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .java_enum) enum_count += 1;
        if (k == .java_const) const_count += 1;
        if (k == .java_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), enum_count);
    try std.testing.expectEqual(@as(usize, 3), const_count);
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse record" {
    const gpa = std.testing.allocator;
    const src =
        \\public record Point(int x, int y) {}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var rec = false;
    for (kinds) |k| if (k == .java_record) {
        rec = true;
    };
    try std.testing.expect(rec);
}

test "parse nested class" {
    const gpa = std.testing.allocator;
    const src =
        \\public class Outer {
        \\    public class Inner {
        \\        public int x = 0;
        \\    }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var class_count: usize = 0;
    for (kinds) |k| if (k == .java_class) {
        class_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), class_count);
}

test "parse generic class" {
    const gpa = std.testing.allocator;
    const src =
        \\public class Box<T> {
        \\    public T value;
        \\    public T get() { return value; }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var class_count: usize = 0;
    var field_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .java_class) class_count += 1;
        if (k == .java_field) field_count += 1;
        if (k == .java_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_count);
    try std.testing.expectEqual(@as(usize, 1), field_count);
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "parse annotation declaration" {
    const gpa = std.testing.allocator;
    const src =
        \\public @interface Frozen {
        \\    String value() default "";
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var anno = false;
    for (kinds) |k| if (k == .java_annotation_decl) {
        anno = true;
    };
    try std.testing.expect(anno);
}

test "constructor vs method classification" {
    const gpa = std.testing.allocator;
    const src =
        \\public class Foo {
        \\    public Foo() {}
        \\    public void bar() {}
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var ctor_count: usize = 0;
    var method_count: usize = 0;
    for (kinds) |k| {
        if (k == .java_constructor) ctor_count += 1;
        if (k == .java_method) method_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ctor_count);
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

test "multi-name field decl emits one node per name" {
    const gpa = std.testing.allocator;
    const src =
        \\class C {
        \\    private int a, b, c;
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var field_count: usize = 0;
    for (kinds) |k| if (k == .java_field) {
        field_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), field_count);
}

test "fn body extracts java_stmt children" {
    const gpa = std.testing.allocator;
    const src =
        \\class C {
        \\    int compute(int a, int b) {
        \\        int x = a + b;
        \\        int y = x * 2;
        \\        return y;
        \\    }
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var stmt_count: usize = 0;
    for (kinds) |k| if (k == .java_stmt) {
        stmt_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), stmt_count);
}

test "text block does not break parser" {
    const gpa = std.testing.allocator;
    const src =
        \\class C {
        \\    String greet() {
        \\        return """
        \\        hello
        \\        world
        \\        """;
        \\    }
        \\    void next() {}
        \\}
    ;
    var t = try parse(gpa, src, "x.java");
    defer t.deinit();
    const kinds = t.nodes.items(.kind);
    var method_count: usize = 0;
    for (kinds) |k| if (k == .java_method) {
        method_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), method_count);
}
