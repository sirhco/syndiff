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

    // schemas/review-v1.json defines 5 record kinds in oneOf:
    //   schema header, change record, test_not_updated, file_new/removed, summary.
    const root = schema.root();
    try std.testing.expect(root == .object);
    const one_of = root.object.get("oneOf") orelse return error.MissingOneOf;
    try std.testing.expectEqual(@as(usize, 5), one_of.array.items.len);
}

test "validates schema header record against branch 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);
    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    // The schema's first oneOf branch is the `schema` header record.
    const branch0 = schema.root().object.get("oneOf").?.array.items[0];

    const ok_doc = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"kind\":\"schema\",\"version\":\"review-v1\",\"syndiff\":\"0.1.0\"}",
        .{},
    );
    defer ok_doc.deinit();

    var diag = validator.Diagnostic{};
    try validator.validateAgainst(&schema, branch0, ok_doc.value, &diag);
}

test "missing required field returns SchemaViolation with message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);
    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    const branch0 = schema.root().object.get("oneOf").?.array.items[0];

    const bad_doc = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"kind\":\"schema\"}",
        .{},
    );
    defer bad_doc.deinit();

    var diag = validator.Diagnostic{};
    const result = validator.validateAgainst(&schema, branch0, bad_doc.value, &diag);
    try std.testing.expectError(error.SchemaViolation, result);
    try std.testing.expectEqualStrings("", diag.pointer);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "required") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "version") != null);
}
