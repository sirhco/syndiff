const std = @import("std");
const validator = @import("schema_validator");

test "Schema.load parses schemas/review-v1.json and exposes oneOf" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);

    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    // Root is an object with a `oneOf` array of 5 alternatives.
    const root = schema.root();
    try std.testing.expect(root == .object);
    const one_of = root.object.get("oneOf") orelse return error.MissingOneOf;
    try std.testing.expectEqual(@as(usize, 5), one_of.array.items.len);
}
