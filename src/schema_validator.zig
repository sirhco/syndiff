//! Minimal draft-07 JSON Schema validator covering only the constructs used
//! in `schemas/review-v1.json`. Used exclusively by the test suite to
//! validate every `testdata/review/<scenario>/expected.ndjson` line.
//!
//! Supported keywords: type, const, enum, required, properties, items,
//! minimum, pattern, oneOf, $ref (root "#" and "#/$defs/<name>").
//!
//! Unsupported keywords are silently ignored. Adding a keyword to
//! `schemas/review-v1.json` that the validator does not handle is a plan
//! failure — extend this module first.

const std = @import("std");

pub const Schema = struct {
    /// Internal; consumers access values through `root()`.
    parsed: std.json.Parsed(std.json.Value),

    pub fn load(gpa: std.mem.Allocator, source: []const u8) !Schema {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, source, .{});
        return .{ .parsed = parsed };
    }

    pub fn deinit(self: *Schema) void {
        self.parsed.deinit();
    }

    pub fn root(self: *const Schema) std.json.Value {
        return self.parsed.value;
    }
};

/// WARNING: Do not copy this struct after a violation. `message` may slice
/// into `msg_buf`, and `pointer` may slice into `ptr_buf`. Copying produces
/// slices into the *old* buffers rather than the copy's buffers.
pub const Diagnostic = struct {
    /// JSON pointer (RFC 6901) to the failing location inside the document.
    /// Empty string means the document root. When set, `pointer` slices into
    /// `ptr_buf` so its lifetime is tied to the `Diagnostic` itself.
    pointer: []const u8 = "",
    /// Human-readable diagnostic. When formatted at runtime (e.g. for a
    /// `required` violation that names the missing key) `message` slices
    /// into `msg_buf`. Otherwise it points at a string literal.
    message: []const u8 = "",
    /// Internal scratch buffer for messages that embed runtime values.
    msg_buf: [256]u8 = undefined,
    /// Internal scratch buffer that owns the `pointer` slice's bytes so the
    /// pointer survives after `validateNode`'s stack frame is freed.
    ptr_buf: [256]u8 = undefined,
};

pub const ValidateError = error{
    SchemaViolation,
    OutOfMemory,
    InvalidSchema,
};

/// Validate `doc` against the schema node `node`. `schema` is required
/// because `$ref` resolution walks back to the root and `$defs`. Diagnostics
/// borrow from `schema.parsed.arena` and string literals; never allocates.
pub fn validateAgainst(
    schema: *const Schema,
    node: std.json.Value,
    doc: std.json.Value,
    diag: *Diagnostic,
) ValidateError!void {
    return validateNode(schema, node, doc, "", diag);
}

fn setPointer(diag: *Diagnostic, ptr: []const u8) void {
    if (ptr.len > diag.ptr_buf.len) {
        // Truncate rather than alloc — diagnostic precision degrades but
        // memory safety is preserved.
        @memcpy(diag.ptr_buf[0..diag.ptr_buf.len], ptr[0..diag.ptr_buf.len]);
        diag.pointer = diag.ptr_buf[0..diag.ptr_buf.len];
        return;
    }
    @memcpy(diag.ptr_buf[0..ptr.len], ptr);
    diag.pointer = diag.ptr_buf[0..ptr.len];
}

fn validateNode(
    schema: *const Schema,
    node: std.json.Value,
    doc: std.json.Value,
    pointer: []const u8,
    diag: *Diagnostic,
) ValidateError!void {
    if (node != .object) return error.InvalidSchema;
    const obj = node.object;

    if (obj.get("oneOf")) |alts| {
        if (alts != .array) return error.InvalidSchema;
        var matches: usize = 0;
        // Track the deepest-pointer branch by index, NOT by copying its
        // Diagnostic. The Diagnostic struct documents a copy hazard
        // (`message` may slice into `msg_buf`); re-validating the winning
        // branch into the caller's `diag` writes diagnostic data directly
        // to the caller's storage and sidesteps the hazard entirely.
        var best_branch: ?usize = null;
        var best_pointer_len: usize = 0;
        for (alts.array.items, 0..) |alt, i| {
            var branch_diag: Diagnostic = .{};
            if (validateNode(schema, alt, doc, pointer, &branch_diag)) |_| {
                matches += 1;
            } else |err| switch (err) {
                error.SchemaViolation => {
                    if (branch_diag.pointer.len > best_pointer_len) {
                        best_pointer_len = branch_diag.pointer.len;
                        best_branch = i;
                    }
                },
                else => return err,
            }
        }
        if (matches == 1) return;
        if (matches == 0) {
            if (best_branch) |idx| {
                // Re-validate the deepest branch directly into the caller's
                // diag. The branch's diagnostic writes are now permanent.
                return validateNode(schema, alts.array.items[idx], doc, pointer, diag);
            }
            setPointer(diag, pointer);
            diag.message = "oneOf: no branch matched";
            return error.SchemaViolation;
        }
        setPointer(diag, pointer);
        diag.message = "oneOf: multiple branches matched";
        return error.SchemaViolation;
    }

    if (obj.get("$ref")) |ref| {
        if (ref != .string) return error.InvalidSchema;
        const target = try resolveRef(schema, ref.string);
        return validateNode(schema, target, doc, pointer, diag);
    }
    if (obj.get("items")) |items| {
        if (doc == .array) {
            for (doc.array.items, 0..) |item, i| {
                var buf: [512]u8 = undefined;
                const child_ptr = try ptrJoinIndex(&buf, pointer, i);
                try validateNode(schema, items, item, child_ptr, diag);
            }
        }
    }
    if (obj.get("minimum")) |m| {
        if (doc == .integer) {
            const min: i64 = switch (m) {
                .integer => m.integer,
                .float => @intFromFloat(m.float),
                else => return error.InvalidSchema,
            };
            if (doc.integer < min) {
                setPointer(diag, pointer);
                diag.message = "below minimum";
                return error.SchemaViolation;
            }
        }
    }
    if (obj.get("pattern")) |p| {
        if (p != .string) return error.InvalidSchema;
        if (doc == .string) {
            if (!matchPattern(p.string, doc.string)) {
                setPointer(diag, pointer);
                diag.message = "pattern mismatch";
                return error.SchemaViolation;
            }
        }
    }
    if (obj.get("type")) |t| {
        if (t != .string) return error.InvalidSchema;
        if (!matchesType(t.string, doc)) {
            setPointer(diag, pointer);
            diag.message = "type mismatch";
            return error.SchemaViolation;
        }
    }
    if (obj.get("const")) |c| {
        if (!jsonEql(c, doc)) {
            setPointer(diag, pointer);
            diag.message = "const mismatch";
            return error.SchemaViolation;
        }
    }
    if (obj.get("enum")) |e| {
        if (e != .array) return error.InvalidSchema;
        var found = false;
        for (e.array.items) |v| {
            if (jsonEql(v, doc)) {
                found = true;
                break;
            }
        }
        if (!found) {
            setPointer(diag, pointer);
            diag.message = "enum mismatch";
            return error.SchemaViolation;
        }
    }
    if (obj.get("required")) |req| {
        if (req != .array) return error.InvalidSchema;
        if (doc != .object) {
            setPointer(diag, pointer);
            diag.message = "expected object for required";
            return error.SchemaViolation;
        }
        for (req.array.items) |k| {
            if (k != .string) return error.InvalidSchema;
            if (!doc.object.contains(k.string)) {
                setPointer(diag, pointer);
                diag.message = std.fmt.bufPrint(
                    &diag.msg_buf,
                    "missing required property: {s}",
                    .{k.string},
                ) catch "missing required property";
                return error.SchemaViolation;
            }
        }
    }
    if (obj.get("properties")) |props| {
        if (doc != .object) return; // type check above is the gatekeeper
        if (props != .object) return error.InvalidSchema;
        var it = props.object.iterator();
        while (it.next()) |entry| {
            // Absent properties are valid; `required` is the gatekeeper for presence.
            const child = doc.object.get(entry.key_ptr.*) orelse continue;
            // 512 bytes is bounded by the schema's max property-path depth (≤4
            // levels in review-v1.json: oneOf → properties → $ref → properties).
            // Per-frame allocation; recursion stacks N copies but N stays small.
            var buf: [512]u8 = undefined;
            const child_ptr = try ptrJoin(&buf, pointer, entry.key_ptr.*);
            try validateNode(schema, entry.value_ptr.*, child, child_ptr, diag);
        }
    }
}

fn matchesType(t: []const u8, doc: std.json.Value) bool {
    return switch (doc) {
        .null => std.mem.eql(u8, t, "null"),
        .bool => std.mem.eql(u8, t, "boolean"),
        .integer => std.mem.eql(u8, t, "integer") or std.mem.eql(u8, t, "number"),
        .float => std.mem.eql(u8, t, "number"),
        .number_string => std.mem.eql(u8, t, "number"),
        .string => std.mem.eql(u8, t, "string"),
        .array => std.mem.eql(u8, t, "array"),
        .object => std.mem.eql(u8, t, "object"),
    };
}

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => false, // not needed by review-v1.json's enums/consts
        .object => false,
    };
}

fn resolveRef(schema: *const Schema, ref: []const u8) !std.json.Value {
    if (std.mem.eql(u8, ref, "#")) return schema.root();
    const prefix = "#/$defs/";
    if (std.mem.startsWith(u8, ref, prefix)) {
        const name = ref[prefix.len..];
        const defs = schema.root().object.get("$defs") orelse return error.InvalidSchema;
        if (defs != .object) return error.InvalidSchema;
        return defs.object.get(name) orelse return error.InvalidSchema;
    }
    return error.InvalidSchema;
}

fn ptrJoinIndex(buf: []u8, base: []const u8, idx: usize) ValidateError![]const u8 {
    var pos: usize = 0;
    if (pos + base.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[pos .. pos + base.len], base);
    pos += base.len;
    if (pos >= buf.len) return error.OutOfMemory;
    buf[pos] = '/';
    pos += 1;
    const written = std.fmt.bufPrint(buf[pos..], "{d}", .{idx}) catch return error.OutOfMemory;
    pos += written.len;
    return buf[0..pos];
}

/// Anchored regex subset matcher. Supports:
///   * Required leading `^` and trailing `$`.
///   * Literal characters (excluding regex metachars).
///   * Character classes `[abc]`, `[a-z]`, with ranges and literal members.
///   * Quantifier `{N}` applied to the immediately preceding element.
///
/// Anything else returns false from the parser and is reported as an invalid
/// pattern. The intent is to cover what `schemas/review-v1.json` uses today
/// (`^[0-9a-f]{16}$`) without inviting unbounded regex semantics.
pub fn matchPattern(pattern: []const u8, input: []const u8) bool {
    if (pattern.len < 2 or pattern[0] != '^' or pattern[pattern.len - 1] != '$') return false;
    var p_idx: usize = 1;
    const p_end = pattern.len - 1;
    var i_idx: usize = 0;

    while (p_idx < p_end) {
        // Parse one atom: either a char class or a literal char.
        var atom_end = p_idx;
        const atom_kind: enum { class, literal } = if (pattern[p_idx] == '[') .class else .literal;
        if (atom_kind == .class) {
            // Find matching ']'.
            atom_end = p_idx + 1;
            while (atom_end < p_end and pattern[atom_end] != ']') : (atom_end += 1) {}
            if (atom_end >= p_end) return false; // unterminated class
            atom_end += 1; // include ']'
        } else {
            atom_end = p_idx + 1;
        }
        const atom = pattern[p_idx..atom_end];
        p_idx = atom_end;

        // Optional {N} quantifier.
        var count: usize = 1;
        if (p_idx < p_end and pattern[p_idx] == '{') {
            const close = std.mem.indexOfScalarPos(u8, pattern, p_idx, '}') orelse return false;
            if (close >= p_end) return false;
            const n_text = pattern[p_idx + 1 .. close];
            count = std.fmt.parseInt(usize, n_text, 10) catch return false;
            p_idx = close + 1;
        }

        var k: usize = 0;
        while (k < count) : (k += 1) {
            if (i_idx >= input.len) return false;
            if (!atomMatches(atom, input[i_idx])) return false;
            i_idx += 1;
        }
    }
    return i_idx == input.len;
}

fn atomMatches(atom: []const u8, c: u8) bool {
    if (atom[0] != '[') {
        return atom.len == 1 and atom[0] == c;
    }
    // atom is "[...]"
    var idx: usize = 1;
    const end = atom.len - 1; // position of ']'
    while (idx < end) {
        if (idx + 2 < end and atom[idx + 1] == '-') {
            if (c >= atom[idx] and c <= atom[idx + 2]) return true;
            idx += 3;
        } else {
            if (c == atom[idx]) return true;
            idx += 1;
        }
    }
    return false;
}

fn ptrJoin(buf: []u8, base: []const u8, key: []const u8) ValidateError![]const u8 {
    // RFC 6901 escape: "~" -> "~0", "/" -> "~1". `key` is a property name.
    var pos: usize = 0;
    if (pos + base.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[pos .. pos + base.len], base);
    pos += base.len;
    if (pos >= buf.len) return error.OutOfMemory;
    buf[pos] = '/';
    pos += 1;
    for (key) |c| switch (c) {
        '~' => {
            if (pos + 2 > buf.len) return error.OutOfMemory;
            buf[pos] = '~';
            buf[pos + 1] = '0';
            pos += 2;
        },
        '/' => {
            if (pos + 2 > buf.len) return error.OutOfMemory;
            buf[pos] = '~';
            buf[pos + 1] = '1';
            pos += 2;
        },
        else => {
            if (pos >= buf.len) return error.OutOfMemory;
            buf[pos] = c;
            pos += 1;
        },
    };
    return buf[0..pos];
}
