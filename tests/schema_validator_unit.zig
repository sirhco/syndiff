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

test "oneOf dispatches summary record to summary branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);
    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    const summary_doc = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"kind":"summary","files_changed":3,"counts":{"added":1,"deleted":0,"modified":2,"moved":0,"renamed":0}}
        ,
        .{},
    );
    defer summary_doc.deinit();

    var diag = validator.Diagnostic{};
    try validator.validateAgainst(&schema, schema.root(), summary_doc.value, &diag);
}

test "oneOf rejects record matching no branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);
    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    const bad_doc = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"kind\":\"banana\"}",
        .{},
    );
    defer bad_doc.deinit();

    var diag = validator.Diagnostic{};
    const result = validator.validateAgainst(&schema, schema.root(), bad_doc.value, &diag);
    try std.testing.expectError(error.SchemaViolation, result);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "oneOf") != null);
}

test "array items recurse and minimum is enforced" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);
    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    // A change record with a negative lines_added must fail (minimum: 0).
    const json_text =
        \\{"kind":"modified","change_id":"0123456789abcdef","scope":"x","kind_tag":"body_change","is_exported":true,"lines_added":-1,"lines_removed":0}
    ;
    const bad = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer bad.deinit();

    var diag = validator.Diagnostic{};
    const r = validator.validateAgainst(&schema, schema.root(), bad.value, &diag);
    try std.testing.expectError(error.SchemaViolation, r);
    try std.testing.expectEqualStrings("/lines_added", diag.pointer);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "minimum") != null);
}

test "$ref resolves recursively (sub_changes uses #)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(src);
    var schema = try validator.Schema.load(gpa, src);
    defer schema.deinit();

    // Outer modified with one sub_change of kind "added" — both must validate.
    const json_text =
        \\{"kind":"modified","change_id":"aaaaaaaaaaaaaaaa","scope":"outer","kind_tag":"body_change","is_exported":true,"lines_added":1,"lines_removed":0,"sub_changes":[{"kind":"added","change_id":"bbbbbbbbbbbbbbbb","scope":"inner","kind_tag":"structural","is_exported":false,"lines_added":1,"lines_removed":0}]}
    ;
    const ok = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer ok.deinit();

    var diag = validator.Diagnostic{};
    try validator.validateAgainst(&schema, schema.root(), ok.value, &diag);
}
