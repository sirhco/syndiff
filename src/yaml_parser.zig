//! YAML subset parser. Block-style only.
//!
//! Supported:
//!   - Block mappings: `key: value`, nested via indentation
//!   - Block sequences: `- item`, nested via indentation
//!   - Plain scalars (rest of line, comment-stripped)
//!   - Single- and double-quoted scalars (no escape interpretation; bytes
//!     between quotes form the identity/content range)
//!   - Comments (`#` to end of line)
//!   - Blank lines
//!
//! NOT supported (will produce error or garbage):
//!   - Flow style: `{...}`, `[...]`
//!   - Anchors `&`, aliases `*`, tags `!!`
//!   - Multi-document `---`
//!   - Folded `>` / literal `|` block scalars
//!   - Complex / non-string keys
//!   - Tab indentation (YAML spec forbids)
//!
//! Layout invariants match `json_parser`: post-order push, root last,
//! parent_idx backpatched, hashes computed bottom-up.

const std = @import("std");
const ast_mod = @import("ast.zig");
const hash_mod = @import("hash.zig");

const NodeIndex = ast_mod.NodeIndex;
const Range = ast_mod.Range;
const Kind = ast_mod.Kind;
const ROOT_PARENT = ast_mod.ROOT_PARENT;

pub const ParseError = error{
    UnexpectedChar,
    UnexpectedEof,
    TabIndent,
    InvalidIndent,
    UnterminatedString,
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
    tree: *ast_mod.Tree,

    fn atEnd(self: *Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.atEnd()) null else self.src[self.pos];
    }

    /// Skip blank lines and comment-only lines. Stop at first byte of a
    /// non-blank, non-comment line.
    fn skipBlanks(self: *Parser) ParseError!void {
        while (!self.atEnd()) {
            const line_start = self.pos;
            // Skip leading whitespace within this line.
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (c == ' ') {
                    self.pos += 1;
                } else if (c == '\t') {
                    return error.TabIndent;
                } else break;
            }
            if (self.atEnd()) return;
            const c = self.src[self.pos];
            if (c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                if (!self.atEnd()) self.pos += 1;
                continue;
            }
            // Real content starts on this line — rewind to its start.
            self.pos = line_start;
            return;
        }
    }

    /// Indent of the line that contains `pos`. Walks back to line start.
    fn lineIndent(self: *Parser) ParseError!u16 {
        var p = self.pos;
        while (p > 0 and self.src[p - 1] != '\n') p -= 1;
        var indent: u16 = 0;
        while (p < self.src.len) : (p += 1) {
            const c = self.src[p];
            if (c == ' ') indent += 1 else if (c == '\t') return error.TabIndent else break;
        }
        return indent;
    }

    /// Advance past leading spaces of the current line.
    fn consumeIndent(self: *Parser) ParseError!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ') {
                self.pos += 1;
            } else if (c == '\t') {
                return error.TabIndent;
            } else break;
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;
    }

    /// Set parent_idx of `child` to `parent`.
    fn setParent(self: *Parser, child: NodeIndex, parent: NodeIndex) void {
        const parents = self.tree.nodes.items(.parent_idx);
        parents[child] = parent;
    }

    /// Top-level dispatch. Returns the document root node.
    fn parseDocument(self: *Parser) ParseError!ChildResult {
        try self.skipBlanks();
        if (self.atEnd()) {
            // Empty doc: emit a null-ish scalar root.
            const h = hash_mod.subtreeHash(.yaml_scalar, &.{}, "");
            const id = hash_mod.identityHash(0, .yaml_scalar, "");
            const idx = try self.tree.addNode(.{
                .hash = h,
                .identity_hash = id,
                .identity_range_hash = 0,
                .kind = .yaml_scalar,
                .depth = 0,
                .parent_idx = ROOT_PARENT,
                .content_range = Range.empty,
                .identity_range = Range.empty,
                .is_exported = false,
            });
            return .{ .idx = idx, .hash = h };
        }

        const indent = try self.lineIndent();
        return try self.parseValue(0, indent, 0);
    }

    /// Parse a value starting at the current position.
    /// `parent_identity` — identity context inherited from caller.
    /// `cur_indent`     — indent of the current line (scalar's column or `- ` start).
    /// `depth`          — recursion depth.
    fn parseValue(
        self: *Parser,
        parent_identity: u64,
        cur_indent: u16,
        depth: u16,
    ) ParseError!ChildResult {
        if (depth >= MAX_DEPTH) return error.DepthExceeded;

        try self.consumeIndent();
        const c = self.peek() orelse return error.UnexpectedEof;

        if (c == '{') {
            return try self.parseFlowMapping(parent_identity, depth);
        }
        if (c == '[') {
            return try self.parseFlowSequence(parent_identity, depth);
        }

        if (c == '-' and self.isSequenceMarker()) {
            return try self.parseSequence(parent_identity, cur_indent, depth);
        }

        // Otherwise: mapping or scalar.
        // Look ahead: does the current line contain `:` (key marker)?
        if (try self.lineHasKeyColon()) {
            return try self.parseMapping(parent_identity, cur_indent, depth);
        }

        return try self.parseScalar(parent_identity, depth);
    }

    /// True if the byte at `pos` is `-` followed by space, tab(unsupported),
    /// or newline / EOF — i.e. a block sequence indicator.
    fn isSequenceMarker(self: *Parser) bool {
        if (self.atEnd() or self.src[self.pos] != '-') return false;
        const next = self.pos + 1;
        if (next >= self.src.len) return true;
        const nc = self.src[next];
        return nc == ' ' or nc == '\n' or nc == '\t';
    }

    /// Scan the rest of the current line for an unquoted `:` followed by
    /// whitespace / newline / EOF — the YAML mapping key marker. Position
    /// is unchanged.
    fn lineHasKeyColon(self: *Parser) ParseError!bool {
        var p = self.pos;
        var in_single = false;
        var in_double = false;
        while (p < self.src.len) : (p += 1) {
            const c = self.src[p];
            if (c == '\n') return false;
            if (c == '\\' and in_double) {
                p += 1;
                continue;
            }
            if (c == '"' and !in_single) {
                in_double = !in_double;
                continue;
            }
            if (c == '\'' and !in_double) {
                in_single = !in_single;
                continue;
            }
            if (in_single or in_double) continue;
            if (c == '#') return false;
            if (c == ':') {
                const next = p + 1;
                if (next >= self.src.len) return true;
                const nc = self.src[next];
                if (nc == ' ' or nc == '\n') return true;
            }
        }
        return false;
    }

    fn parseMapping(
        self: *Parser,
        parent_identity: u64,
        block_indent: u16,
        depth: u16,
    ) ParseError!ChildResult {
        const start = self.pos;
        const self_identity = hash_mod.identityHash(parent_identity, .yaml_mapping, "");

        var pair_indices: std.ArrayList(NodeIndex) = .empty;
        defer pair_indices.deinit(self.gpa);
        var pair_hashes: std.ArrayList(u64) = .empty;
        defer pair_hashes.deinit(self.gpa);

        var end_pos: u32 = self.pos;

        while (true) {
            try self.skipBlanks();
            if (self.atEnd()) break;
            const ind = try self.lineIndent();
            if (ind != block_indent) break;
            try self.consumeIndent();
            // If next char looks like a sequence start, mapping ends.
            if (self.isSequenceMarker()) break;
            // If this line has no key colon, mapping ends.
            if (!try self.lineHasKeyColon()) break;

            const pair = try self.parsePair(self_identity, block_indent, depth + 1);
            try pair_indices.append(self.gpa, pair.idx);
            try pair_hashes.append(self.gpa, pair.hash);
            end_pos = self.pos;
        }

        const subtree_h = hash_mod.subtreeHash(.yaml_mapping, pair_hashes.items, "");
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .yaml_mapping,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end_pos },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        for (pair_indices.items) |p| self.setParent(p, idx);
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parsePair(
        self: *Parser,
        parent_identity: u64,
        block_indent: u16,
        depth: u16,
    ) ParseError!ChildResult {
        const start = self.pos;
        const key_range = try self.scanKey();
        const key_bytes = self.src[key_range.start..key_range.end];

        // Expect ':'
        if (self.atEnd() or self.src[self.pos] != ':') return error.UnexpectedChar;
        self.pos += 1;
        // Skip space after colon.
        self.skipSpaces();

        const self_identity = hash_mod.identityHash(parent_identity, .yaml_pair, key_bytes);

        // Determine value: same-line scalar, or nested block on following lines.
        const value: ChildResult = blk: {
            // Skip trailing comment on this line (no value here).
            const end_of_line = self.findEndOfLine();
            const rest = self.src[self.pos..end_of_line];
            const rest_trimmed = std.mem.trimEnd(u8, rest, " \t");
            const has_inline_value = rest_trimmed.len > 0 and rest_trimmed[0] != '#';

            if (has_inline_value) {
                // Inline value: dispatch to flow if `{` / `[` else plain/quoted scalar.
                const first = self.src[self.pos];
                if (first == '{') {
                    break :blk try self.parseFlowMapping(self_identity, depth + 1);
                }
                if (first == '[') {
                    break :blk try self.parseFlowSequence(self_identity, depth + 1);
                }
                const inline_result = try self.parseScalar(self_identity, depth + 1);
                break :blk inline_result;
            }

            // No inline value: advance to next non-blank line.
            self.pos = end_of_line;
            if (!self.atEnd() and self.src[self.pos] == '\n') self.pos += 1;
            try self.skipBlanks();

            if (self.atEnd()) {
                // Treat empty value as empty scalar.
                const empty_id = hash_mod.identityHash(self_identity, .yaml_scalar, "");
                const empty_h = hash_mod.subtreeHash(.yaml_scalar, &.{}, "");
                const empty_idx = try self.tree.addNode(.{
                    .hash = empty_h,
                    .identity_hash = empty_id,
                    .identity_range_hash = 0,
                    .kind = .yaml_scalar,
                    .depth = depth + 1,
                    .parent_idx = ROOT_PARENT,
                    .content_range = Range.empty,
                    .identity_range = Range.empty,
                    .is_exported = false,
                });
                break :blk .{ .idx = empty_idx, .hash = empty_h };
            }

            const child_indent = try self.lineIndent();
            if (child_indent <= block_indent) {
                // Sibling or dedent: empty value.
                const empty_id = hash_mod.identityHash(self_identity, .yaml_scalar, "");
                const empty_h = hash_mod.subtreeHash(.yaml_scalar, &.{}, "");
                const empty_idx = try self.tree.addNode(.{
                    .hash = empty_h,
                    .identity_hash = empty_id,
                    .identity_range_hash = 0,
                    .kind = .yaml_scalar,
                    .depth = depth + 1,
                    .parent_idx = ROOT_PARENT,
                    .content_range = Range.empty,
                    .identity_range = Range.empty,
                    .is_exported = false,
                });
                break :blk .{ .idx = empty_idx, .hash = empty_h };
            }

            // Nested block.
            break :blk try self.parseValue(self_identity, child_indent, depth + 1);
        };

        const end = self.pos;
        const child_hashes = [_]u64{value.hash};
        const subtree_h = hash_mod.subtreeHash(.yaml_pair, &child_hashes, key_bytes);
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, key_bytes),
            .kind = .yaml_pair,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = key_range,
            .is_exported = false,
        });
        self.setParent(value.idx, idx);
        return .{ .idx = idx, .hash = subtree_h };
    }

    /// Scan a key. Supports plain identifiers and quoted strings.
    fn scanKey(self: *Parser) ParseError!Range {
        const c = self.peek() orelse return error.UnexpectedEof;
        if (c == '"' or c == '\'') {
            return try self.scanQuoted();
        }
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const k = self.src[self.pos];
            if (k == ':' or k == '\n') break;
        }
        // Trim trailing whitespace from key.
        var end = self.pos;
        while (end > start and (self.src[end - 1] == ' ' or self.src[end - 1] == '\t')) end -= 1;
        if (end == start) return error.UnexpectedChar;
        return .{ .start = start, .end = end };
    }

    fn scanQuoted(self: *Parser) ParseError!Range {
        const quote = self.src[self.pos];
        self.pos += 1;
        const inner_start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '\\' and quote == '"') {
                if (self.pos + 1 >= self.src.len) return error.UnterminatedString;
                self.pos += 1;
                continue;
            }
            if (c == quote) {
                const inner_end = self.pos;
                self.pos += 1;
                return .{ .start = inner_start, .end = inner_end };
            }
            if (c == '\n') return error.UnterminatedString;
        }
        return error.UnterminatedString;
    }

    fn parseSequence(
        self: *Parser,
        parent_identity: u64,
        block_indent: u16,
        depth: u16,
    ) ParseError!ChildResult {
        const start = self.pos;
        const self_identity = hash_mod.identityHash(parent_identity, .yaml_sequence, "");

        var elem_indices: std.ArrayList(NodeIndex) = .empty;
        defer elem_indices.deinit(self.gpa);
        var elem_hashes: std.ArrayList(u64) = .empty;
        defer elem_hashes.deinit(self.gpa);

        var end_pos: u32 = self.pos;
        var index: u32 = 0;
        var idx_buf: [16]u8 = undefined;

        while (true) {
            try self.skipBlanks();
            if (self.atEnd()) break;
            const ind = try self.lineIndent();
            if (ind != block_indent) break;
            try self.consumeIndent();
            if (!self.isSequenceMarker()) break;

            // Consume `-` and one trailing space (if any).
            self.pos += 1;
            if (!self.atEnd() and self.src[self.pos] == ' ') self.pos += 1;

            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch unreachable;
            const elem_parent = hash_mod.identityHash(self_identity, .yaml_sequence, idx_str);

            // Indent for nested content under this `-` is determined by
            // current pos column. For inline scalars we don't recurse.
            const elem_col: u16 = @intCast(self.pos - lineStartByte(self.src, self.pos));

            // Inline content vs continuation on next line.
            const eol = self.findEndOfLine();
            const rest = self.src[self.pos..eol];
            const rest_trim = std.mem.trimEnd(u8, rest, " \t");
            const has_inline = rest_trim.len > 0 and rest_trim[0] != '#';

            const elem: ChildResult = if (has_inline)
                try self.parseValue(elem_parent, elem_col, depth + 1)
            else blk: {
                self.pos = eol;
                if (!self.atEnd() and self.src[self.pos] == '\n') self.pos += 1;
                try self.skipBlanks();
                if (self.atEnd()) {
                    const eh = hash_mod.subtreeHash(.yaml_scalar, &.{}, "");
                    const ei = hash_mod.identityHash(elem_parent, .yaml_scalar, "");
                    const e_idx = try self.tree.addNode(.{
                        .hash = eh,
                        .identity_hash = ei,
                        .identity_range_hash = 0,
                        .kind = .yaml_scalar,
                        .depth = depth + 1,
                        .parent_idx = ROOT_PARENT,
                        .content_range = Range.empty,
                        .identity_range = Range.empty,
                        .is_exported = false,
                    });
                    break :blk .{ .idx = e_idx, .hash = eh };
                }
                const ci = try self.lineIndent();
                if (ci <= block_indent) {
                    const eh = hash_mod.subtreeHash(.yaml_scalar, &.{}, "");
                    const ei = hash_mod.identityHash(elem_parent, .yaml_scalar, "");
                    const e_idx = try self.tree.addNode(.{
                        .hash = eh,
                        .identity_hash = ei,
                        .identity_range_hash = 0,
                        .kind = .yaml_scalar,
                        .depth = depth + 1,
                        .parent_idx = ROOT_PARENT,
                        .content_range = Range.empty,
                        .identity_range = Range.empty,
                        .is_exported = false,
                    });
                    break :blk .{ .idx = e_idx, .hash = eh };
                }
                break :blk try self.parseValue(elem_parent, ci, depth + 1);
            };

            try elem_indices.append(self.gpa, elem.idx);
            try elem_hashes.append(self.gpa, elem.hash);
            end_pos = self.pos;
            index += 1;
        }

        const subtree_h = hash_mod.subtreeHash(.yaml_sequence, elem_hashes.items, "");
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .yaml_sequence,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end_pos },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        for (elem_indices.items) |e| self.setParent(e, idx);
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseScalar(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        // Quoted or plain.
        const start = self.pos;
        const c = self.peek() orelse return error.UnexpectedEof;

        const inner_range: Range = if (c == '"' or c == '\'')
            try self.scanQuoted()
        else blk: {
            // Plain scalar: read until end of line, strip trailing whitespace
            // and inline comment.
            const s = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            // Inline comment? Trim from " #" to end.
            var end = self.pos;
            // Find " #" boundary (require space before # for plain scalars).
            var i: u32 = s;
            while (i + 1 < end) : (i += 1) {
                if ((self.src[i] == ' ' or self.src[i] == '\t') and self.src[i + 1] == '#') {
                    end = i;
                    break;
                }
            }
            // Trim trailing whitespace.
            while (end > s and (self.src[end - 1] == ' ' or self.src[end - 1] == '\t')) end -= 1;
            break :blk .{ .start = s, .end = end };
        };

        const end = self.pos;
        const value_bytes = self.src[inner_range.start..inner_range.end];
        const self_identity = hash_mod.identityHash(parent_identity, .yaml_scalar, "");
        const subtree_h = hash_mod.subtreeHash(.yaml_scalar, &.{}, value_bytes);
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .yaml_scalar,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = inner_range,
            .is_exported = false,
        });
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn findEndOfLine(self: *Parser) u32 {
        var p = self.pos;
        while (p < self.src.len and self.src[p] != '\n') p += 1;
        return p;
    }

    fn parseFlowMapping(
        self: *Parser,
        parent_identity: u64,
        depth: u16,
    ) ParseError!ChildResult {
        if (depth >= MAX_DEPTH) return error.DepthExceeded;
        const start = self.pos;
        if (self.atEnd() or self.src[self.pos] != '{') return error.UnexpectedChar;
        self.pos += 1;

        const self_identity = hash_mod.identityHash(parent_identity, .yaml_mapping, "");

        var pair_indices: std.ArrayList(NodeIndex) = .empty;
        defer pair_indices.deinit(self.gpa);
        var pair_hashes: std.ArrayList(u64) = .empty;
        defer pair_hashes.deinit(self.gpa);

        try self.skipFlowWhitespace();
        if (!self.atEnd() and self.src[self.pos] == '}') {
            self.pos += 1;
            const empty_h = hash_mod.subtreeHash(.yaml_mapping, &.{}, "");
            const idx = try self.tree.addNode(.{
                .hash = empty_h,
                .identity_hash = self_identity,
                .identity_range_hash = 0,
                .kind = .yaml_mapping,
                .depth = depth,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = start, .end = self.pos },
                .identity_range = Range.empty,
                .is_exported = false,
            });
            return .{ .idx = idx, .hash = empty_h };
        }

        while (true) {
            try self.skipFlowWhitespace();
            const pair = try self.parseFlowPair(self_identity, depth + 1);
            try pair_indices.append(self.gpa, pair.idx);
            try pair_hashes.append(self.gpa, pair.hash);
            try self.skipFlowWhitespace();
            if (self.atEnd()) return error.UnexpectedEof;
            const sep = self.src[self.pos];
            if (sep == ',') {
                self.pos += 1;
                try self.skipFlowWhitespace();
                // Trailing comma: `{a: 1,}` — accept and close.
                if (!self.atEnd() and self.src[self.pos] == '}') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (sep == '}') {
                self.pos += 1;
                break;
            }
            return error.UnexpectedChar;
        }

        const subtree_h = hash_mod.subtreeHash(.yaml_mapping, pair_hashes.items, "");
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .yaml_mapping,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = self.pos },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        for (pair_indices.items) |p| self.setParent(p, idx);
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseFlowSequence(
        self: *Parser,
        parent_identity: u64,
        depth: u16,
    ) ParseError!ChildResult {
        if (depth >= MAX_DEPTH) return error.DepthExceeded;
        const start = self.pos;
        if (self.atEnd() or self.src[self.pos] != '[') return error.UnexpectedChar;
        self.pos += 1;

        const self_identity = hash_mod.identityHash(parent_identity, .yaml_sequence, "");

        var elem_indices: std.ArrayList(NodeIndex) = .empty;
        defer elem_indices.deinit(self.gpa);
        var elem_hashes: std.ArrayList(u64) = .empty;
        defer elem_hashes.deinit(self.gpa);

        try self.skipFlowWhitespace();
        if (!self.atEnd() and self.src[self.pos] == ']') {
            self.pos += 1;
            const empty_h = hash_mod.subtreeHash(.yaml_sequence, &.{}, "");
            const idx = try self.tree.addNode(.{
                .hash = empty_h,
                .identity_hash = self_identity,
                .identity_range_hash = 0,
                .kind = .yaml_sequence,
                .depth = depth,
                .parent_idx = ROOT_PARENT,
                .content_range = .{ .start = start, .end = self.pos },
                .identity_range = Range.empty,
                .is_exported = false,
            });
            return .{ .idx = idx, .hash = empty_h };
        }

        var index: u32 = 0;
        var idx_buf: [16]u8 = undefined;
        while (true) {
            try self.skipFlowWhitespace();
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch unreachable;
            const elem_parent = hash_mod.identityHash(self_identity, .yaml_sequence, idx_str);
            const elem = try self.parseFlowValue(elem_parent, depth + 1);
            try elem_indices.append(self.gpa, elem.idx);
            try elem_hashes.append(self.gpa, elem.hash);
            index += 1;
            try self.skipFlowWhitespace();
            if (self.atEnd()) return error.UnexpectedEof;
            const sep = self.src[self.pos];
            if (sep == ',') {
                self.pos += 1;
                try self.skipFlowWhitespace();
                if (!self.atEnd() and self.src[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (sep == ']') {
                self.pos += 1;
                break;
            }
            return error.UnexpectedChar;
        }

        const subtree_h = hash_mod.subtreeHash(.yaml_sequence, elem_hashes.items, "");
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .yaml_sequence,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = self.pos },
            .identity_range = Range.empty,
            .is_exported = false,
        });
        for (elem_indices.items) |e| self.setParent(e, idx);
        return .{ .idx = idx, .hash = subtree_h };
    }

    /// Whitespace permitted inside flow context: spaces, tabs (only INSIDE
    /// flow context — tab indentation outside flow remains forbidden), and
    /// newlines. Comments after `#` are also skipped.
    fn skipFlowWhitespace(self: *Parser) ParseError!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            return;
        }
    }

    fn parseFlowPair(
        self: *Parser,
        parent_identity: u64,
        depth: u16,
    ) ParseError!ChildResult {
        const start = self.pos;
        const key_range = try self.scanFlowKey();
        const key_bytes = self.src[key_range.start..key_range.end];

        try self.skipFlowWhitespace();
        if (self.atEnd() or self.src[self.pos] != ':') return error.UnexpectedChar;
        self.pos += 1;
        try self.skipFlowWhitespace();

        const self_identity = hash_mod.identityHash(parent_identity, .yaml_pair, key_bytes);
        const value = try self.parseFlowValue(self_identity, depth + 1);

        const end = self.pos;
        const child_hashes = [_]u64{value.hash};
        const subtree_h = hash_mod.subtreeHash(.yaml_pair, &child_hashes, key_bytes);
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = std.hash.Wyhash.hash(0, key_bytes),
            .kind = .yaml_pair,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = end },
            .identity_range = key_range,
            .is_exported = false,
        });
        self.setParent(value.idx, idx);
        return .{ .idx = idx, .hash = subtree_h };
    }

    fn parseFlowValue(
        self: *Parser,
        parent_identity: u64,
        depth: u16,
    ) ParseError!ChildResult {
        if (depth >= MAX_DEPTH) return error.DepthExceeded;
        const c = self.peek() orelse return error.UnexpectedEof;
        if (c == '{') return try self.parseFlowMapping(parent_identity, depth);
        if (c == '[') return try self.parseFlowSequence(parent_identity, depth);
        if (c == '"' or c == '\'') return try self.parseScalar(parent_identity, depth);
        return try self.parseFlowPlainScalar(parent_identity, depth);
    }

    fn scanFlowKey(self: *Parser) ParseError!Range {
        const c = self.peek() orelse return error.UnexpectedEof;
        if (c == '"' or c == '\'') return try self.scanQuoted();
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const k = self.src[self.pos];
            if (k == ':' or k == ',' or k == '}' or k == ']' or k == '\n') break;
        }
        var end = self.pos;
        while (end > start and (self.src[end - 1] == ' ' or self.src[end - 1] == '\t')) end -= 1;
        if (end == start) return error.UnexpectedChar;
        return .{ .start = start, .end = end };
    }

    fn parseFlowPlainScalar(self: *Parser, parent_identity: u64, depth: u16) ParseError!ChildResult {
        const start = self.pos;
        const inner_start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const k = self.src[self.pos];
            if (k == ',' or k == '}' or k == ']' or k == '\n') break;
        }
        var inner_end = self.pos;
        while (inner_end > inner_start and (self.src[inner_end - 1] == ' ' or self.src[inner_end - 1] == '\t')) {
            inner_end -= 1;
        }
        const inner = Range{ .start = inner_start, .end = inner_end };
        const value_bytes = self.src[inner.start..inner.end];
        const self_identity = hash_mod.identityHash(parent_identity, .yaml_scalar, "");
        const subtree_h = hash_mod.subtreeHash(.yaml_scalar, &.{}, value_bytes);
        const idx = try self.tree.addNode(.{
            .hash = subtree_h,
            .identity_hash = self_identity,
            .identity_range_hash = 0,
            .kind = .yaml_scalar,
            .depth = depth,
            .parent_idx = ROOT_PARENT,
            .content_range = .{ .start = start, .end = self.pos },
            .identity_range = inner,
            .is_exported = false,
        });
        return .{ .idx = idx, .hash = subtree_h };
    }
};

fn lineStartByte(src: []const u8, pos: u32) u32 {
    var p = pos;
    while (p > 0 and src[p - 1] != '\n') p -= 1;
    return p;
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8, path: []const u8) ParseError!ast_mod.Tree {
    var tree = ast_mod.Tree.init(gpa, source, path);
    errdefer tree.deinit();

    var p: Parser = .{
        .gpa = gpa,
        .src = source,
        .pos = 0,
        .tree = &tree,
    };
    _ = try p.parseDocument();
    return tree;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty doc" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "", "x.yaml");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqual(Kind.yaml_scalar, t.nodes.items(.kind)[0]);
}

test "parse simple mapping" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "name: alice\nage: 30\n", "x.yaml");
    defer t.deinit();

    // Expect: scalar(alice), pair(name), scalar(30), pair(age), mapping
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.yaml_scalar, kinds[0]);
    try std.testing.expectEqual(Kind.yaml_pair, kinds[1]);
    try std.testing.expectEqual(Kind.yaml_scalar, kinds[2]);
    try std.testing.expectEqual(Kind.yaml_pair, kinds[3]);
    try std.testing.expectEqual(Kind.yaml_mapping, kinds[4]);

    try std.testing.expectEqualStrings("name", t.identitySlice(1));
    try std.testing.expectEqualStrings("age", t.identitySlice(3));
}

test "parse nested mapping" {
    const gpa = std.testing.allocator;
    const src =
        \\outer:
        \\  inner: 1
        \\
    ;
    var t = try parse(gpa, src, "x.yaml");
    defer t.deinit();

    // scalar(1), pair(inner), mapping(inner block), pair(outer), mapping(root)
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.yaml_mapping, kinds[4]);
}

test "parse sequence" {
    const gpa = std.testing.allocator;
    const src =
        \\items:
        \\  - foo
        \\  - bar
        \\
    ;
    var t = try parse(gpa, src, "x.yaml");
    defer t.deinit();

    // scalar(foo), scalar(bar), sequence, pair(items), mapping
    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
    const kinds = t.nodes.items(.kind);
    try std.testing.expectEqual(Kind.yaml_scalar, kinds[0]);
    try std.testing.expectEqual(Kind.yaml_scalar, kinds[1]);
    try std.testing.expectEqual(Kind.yaml_sequence, kinds[2]);
    try std.testing.expectEqual(Kind.yaml_pair, kinds[3]);
    try std.testing.expectEqual(Kind.yaml_mapping, kinds[4]);
}

test "comments and blank lines ignored" {
    const gpa = std.testing.allocator;
    const src =
        \\# top comment
        \\
        \\name: alice  # trailing comment
        \\
        \\# another
        \\age: 30
        \\
    ;
    var t = try parse(gpa, src, "x.yaml");
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 5), t.nodes.len);
}

test "double-quoted string scalar" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "k: \"hello world\"\n", "x.yaml");
    defer t.deinit();

    // Identity of scalar = "hello world" (between quotes).
    try std.testing.expectEqualStrings("hello world", t.identitySlice(0));
}

test "tab in indent rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.TabIndent, parse(gpa, "\tk: v\n", "x.yaml"));
}

test "subtree hash equal for identical YAML" {
    const gpa = std.testing.allocator;
    const src = "k: 1\nv: 2\n";
    var a = try parse(gpa, src, "a.yaml");
    defer a.deinit();
    var b = try parse(gpa, src, "b.yaml");
    defer b.deinit();
    const a_root = a.nodes.len - 1;
    const b_root = b.nodes.len - 1;
    try std.testing.expectEqual(a.nodes.items(.hash)[a_root], b.nodes.items(.hash)[b_root]);
}

test "subtree hash differs on value change" {
    const gpa = std.testing.allocator;
    var a = try parse(gpa, "k: 1\n", "a.yaml");
    defer a.deinit();
    var b = try parse(gpa, "k: 2\n", "b.yaml");
    defer b.deinit();
    const a_root = a.nodes.len - 1;
    const b_root = b.nodes.len - 1;
    try std.testing.expect(a.nodes.items(.hash)[a_root] != b.nodes.items(.hash)[b_root]);
}

test "identity_range_hash non-zero for yaml_pair; is_exported always false" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "k: 1\nv: 2\n", "x.yaml");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const irhs = tree.nodes.items(.identity_range_hash);
    const exps = tree.nodes.items(.is_exported);
    var pair_count: usize = 0;
    for (kinds, irhs, exps) |k, h, e| {
        if (k == .yaml_pair) {
            try std.testing.expect(h != 0);
            pair_count += 1;
        }
        try std.testing.expect(!e);
    }
    try std.testing.expectEqual(@as(usize, 2), pair_count);
}

test "flow mapping subtree hash equals block mapping" {
    const gpa = std.testing.allocator;
    var flow = try parse(gpa, "{a: 1, b: 2}\n", "f.yaml");
    defer flow.deinit();
    var block = try parse(gpa, "a: 1\nb: 2\n", "b.yaml");
    defer block.deinit();
    const flow_root = flow.nodes.len - 1;
    const block_root = block.nodes.len - 1;
    try std.testing.expectEqual(
        block.nodes.items(.hash)[block_root],
        flow.nodes.items(.hash)[flow_root],
    );
    try std.testing.expectEqual(Kind.yaml_mapping, flow.nodes.items(.kind)[flow_root]);
}

test "empty flow containers" {
    const gpa = std.testing.allocator;
    {
        var t = try parse(gpa, "{}\n", "x.yaml");
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
        try std.testing.expectEqual(Kind.yaml_mapping, t.nodes.items(.kind)[0]);
    }
    {
        var t = try parse(gpa, "[]\n", "x.yaml");
        defer t.deinit();
        try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
        try std.testing.expectEqual(Kind.yaml_sequence, t.nodes.items(.kind)[0]);
    }
}

test "flow sequence of scalars" {
    const gpa = std.testing.allocator;
    var t = try parse(gpa, "[1, 2, 3]\n", "x.yaml");
    defer t.deinit();
    // 3 scalars + 1 sequence
    try std.testing.expectEqual(@as(usize, 4), t.nodes.len);
    try std.testing.expectEqual(Kind.yaml_sequence, t.nodes.items(.kind)[3]);
}

test "nested flow mapping inside block" {
    const gpa = std.testing.allocator;
    const src =
        \\outer:
        \\  inner: {a: 1, b: 2}
        \\
    ;
    var t = try parse(gpa, src, "x.yaml");
    defer t.deinit();
    // scalar(1), pair(a), scalar(2), pair(b), mapping(flow), pair(inner),
    // mapping(inner block), pair(outer), mapping(root) = 9
    try std.testing.expectEqual(@as(usize, 9), t.nodes.len);
}

test "flow mapping trailing comma accepted" {
    const gpa = std.testing.allocator;
    var a = try parse(gpa, "{a: 1, b: 2}\n", "x.yaml");
    defer a.deinit();
    var b = try parse(gpa, "{a: 1, b: 2,}\n", "x.yaml");
    defer b.deinit();
    const ar = a.nodes.len - 1;
    const br = b.nodes.len - 1;
    try std.testing.expectEqual(a.nodes.items(.hash)[ar], b.nodes.items(.hash)[br]);
}

test "flow context permits tab-as-whitespace; block context still rejects" {
    const gpa = std.testing.allocator;
    // Tab inside flow whitespace is fine.
    var t = try parse(gpa, "{a:\t1, b:\t2}\n", "x.yaml");
    defer t.deinit();
    // Tab as block indent is still rejected.
    try std.testing.expectError(error.TabIndent, parse(gpa, "\tk: v\n", "x.yaml"));
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
    if (parse(gpa, buf.items, "fuzz.yaml")) |t| {
        var t2 = t;
        defer t2.deinit();
    } else |err| switch (err) {
        error.UnexpectedChar,
        error.UnexpectedEof,
        error.TabIndent,
        error.InvalidIndent,
        error.UnterminatedString,
        error.DepthExceeded,
        error.OutOfMemory,
        => {},
    }
}
