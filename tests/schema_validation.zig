//! Lightweight check: the body_only fixture's NDJSON must include each
//! required Phase 1 key. Real JSON Schema validation is deferred.

const std = @import("std");
const Io = std.Io;

test "body_only fixture has all required Phase 1 keys" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const ndjson = try cwd.readFileAlloc(io, "testdata/review/body_only/expected.ndjson", gpa, .limited(1 << 16));
    defer gpa.free(ndjson);

    const required = [_][]const u8{
        "\"kind\":\"schema\"",
        "\"version\":\"review-v1\"",
        "\"change_id\"",
        "\"scope\"",
        "\"kind_tag\"",
        "\"is_exported\"",
        "\"lines_added\"",
        "\"lines_removed\"",
        "\"kind\":\"summary\"",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, ndjson, needle) == null) {
            std.debug.print("missing key: {s}\n", .{needle});
            return error.MissingRequiredKey;
        }
    }
}
