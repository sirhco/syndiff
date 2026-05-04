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
