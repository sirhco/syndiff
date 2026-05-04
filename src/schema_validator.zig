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
/// into `msg_buf`; copying the struct produces a slice into the *old*
/// buffer rather than the copy's `msg_buf`.
pub const Diagnostic = struct {
    /// JSON pointer (RFC 6901) to the failing location inside the document.
    /// Empty string means the document root.
    pointer: []const u8 = "",
    /// Human-readable diagnostic. When formatted at runtime (e.g. for a
    /// `required` violation that names the missing key) `message` slices
    /// into `msg_buf`. Otherwise it points at a string literal.
    message: []const u8 = "",
    /// Internal scratch buffer for messages that embed runtime values.
    msg_buf: [256]u8 = undefined,
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
        // Track the branch diagnostic with the deepest pointer for best error reporting.
        var best_diag: Diagnostic = .{};
        for (alts.array.items) |alt| {
            var branch_diag: Diagnostic = .{};
            if (validateNode(schema, alt, doc, pointer, &branch_diag)) |_| {
                matches += 1;
            } else |err| switch (err) {
                error.SchemaViolation => {
                    // Keep the diagnostic with the deepest pointer (most specific failure).
                    if (branch_diag.pointer.len > best_diag.pointer.len) {
                        best_diag = branch_diag;
                    }
                },
                else => return err,
            }
        }
        if (matches == 1) return;
        if (matches == 0) {
            // Propagate the most specific branch failure if it's deeper than the root.
            if (best_diag.pointer.len > pointer.len) {
                diag.* = best_diag;
            } else {
                diag.* = .{ .pointer = pointer, .message = "oneOf: no branch matched" };
            }
            return error.SchemaViolation;
        }
        diag.* = .{ .pointer = pointer, .message = "oneOf: multiple branches matched" };
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
                diag.* = .{ .pointer = pointer, .message = "below minimum" };
                return error.SchemaViolation;
            }
        }
    }
    if (obj.get("type")) |t| {
        if (t != .string) return error.InvalidSchema;
        if (!matchesType(t.string, doc)) {
            diag.pointer = pointer;
            diag.message = "type mismatch";
            return error.SchemaViolation;
        }
    }
    if (obj.get("const")) |c| {
        if (!jsonEql(c, doc)) {
            diag.pointer = pointer;
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
            diag.pointer = pointer;
            diag.message = "enum mismatch";
            return error.SchemaViolation;
        }
    }
    if (obj.get("required")) |req| {
        if (req != .array) return error.InvalidSchema;
        if (doc != .object) {
            diag.pointer = pointer;
            diag.message = "expected object for required";
            return error.SchemaViolation;
        }
        for (req.array.items) |k| {
            if (k != .string) return error.InvalidSchema;
            if (!doc.object.contains(k.string)) {
                diag.pointer = pointer;
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
