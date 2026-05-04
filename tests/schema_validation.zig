//! Real JSON Schema validation: every line of every
//! `testdata/review/<scenario>/expected.ndjson` fixture is parsed and
//! validated against `schemas/review-v1.json` using the vendored draft-07
//! subset validator in `src/schema_validator.zig`.
//!
//! On failure, the assertion message identifies the fixture, line number,
//! and JSON pointer of the violation so a maintainer can fix the fixture
//! (or the schema) without bisecting.

const std = @import("std");
const Io = std.Io;
const validator = @import("schema_validator");

// Hard-coded for explicitness — keep in sync with `testdata/review/`. Every
// review-v1 record kind has at least one fixture line (Task 8 audit complete).
//
// Note: deleted_only, moved_only, test_not_updated, and file_lifecycle are
// schema-only fixtures (hand-written NDJSON, not syndiff snapshot inputs).
// They are NOT registered in tests/review_snapshots.zig — they exist solely
// to exercise the schema validator against the git-multi-file-mode kinds.
const fixtures = [_][]const u8{
    "testdata/review/body_only/expected.ndjson",
    "testdata/review/rename_only/expected.ndjson",
    "testdata/review/security_touch/expected.ndjson",
    "testdata/review/ts_enum_change/expected.ndjson",
    "testdata/review/ts_interface_change/expected.ndjson",
    "testdata/review/ts_type_change/expected.ndjson",
    // Gap-fill fixtures added by Task 8 (schema-only, option-a):
    "testdata/review/deleted_only/expected.ndjson",
    "testdata/review/moved_only/expected.ndjson",
    "testdata/review/test_not_updated/expected.ndjson",
    "testdata/review/file_lifecycle/expected.ndjson",
    // Phase 6: cyclomatic complexity fixtures (one per supported language).
    "testdata/review/complexity/go/expected.ndjson",
    "testdata/review/complexity/rust/expected.ndjson",
    "testdata/review/complexity/zig/expected.ndjson",
    "testdata/review/complexity/dart/expected.ndjson",
    "testdata/review/complexity/js/expected.ndjson",
};

test "every review-v1 fixture validates against schemas/review-v1.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    const schema_src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(schema_src);
    var schema = try validator.Schema.load(gpa, schema_src);
    defer schema.deinit();

    // Fail-fast: the first violating fixture stops the run. Re-run after fixing
    // each surfaced issue. Subsequent fixtures are not checked until all earlier
    // fixtures pass.
    for (fixtures) |path| {
        const src = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(src);

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch |err| {
                std.debug.print("{s}:{d}: JSON parse error: {s}\n", .{ path, line_no, @errorName(err) });
                return error.InvalidJson;
            };
            defer parsed.deinit();

            var diag = validator.Diagnostic{};
            validator.validateAgainst(&schema, schema.root(), parsed.value, &diag) catch |err| {
                std.debug.print(
                    "{s}:{d}: schema violation at {s}: {s}\n",
                    .{ path, line_no, diag.pointer, diag.message },
                );
                return err;
            };
        }
    }
}

test "deliberate fixture mutation is caught (proves assertions are real)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    const schema_src = try cwd.readFileAlloc(io, "schemas/review-v1.json", gpa, .limited(1 << 20));
    defer gpa.free(schema_src);
    var schema = try validator.Schema.load(gpa, schema_src);
    defer schema.deinit();

    // is_exported must be a boolean. Flip it to a string and assert the
    // validator surfaces a precise pointer + message.
    const mutated_line =
        \\{"kind":"added","change_id":"0123456789abcdef","scope":"x","kind_tag":"structural","is_exported":"yes","lines_added":1,"lines_removed":0}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, mutated_line, .{});
    defer parsed.deinit();

    var diag = validator.Diagnostic{};
    const result = validator.validateAgainst(&schema, schema.root(), parsed.value, &diag);
    try std.testing.expectError(error.SchemaViolation, result);
    // The actual property-level violation surfaces inside the failing branch;
    // root-level diag points at root with "oneOf: no branch matched". Inspect
    // the mutated value's path through a direct branch test for precision.

    // Direct check: validate against the change-record branch (oneOf[1])
    // and confirm the diagnostic targets /is_exported with a type mismatch.
    const change_branch = schema.root().object.get("oneOf").?.array.items[1];
    var branch_diag = validator.Diagnostic{};
    const branch_result = validator.validateAgainst(&schema, change_branch, parsed.value, &branch_diag);
    try std.testing.expectError(error.SchemaViolation, branch_result);
    try std.testing.expectEqualStrings("/is_exported", branch_diag.pointer);
    try std.testing.expect(std.mem.indexOf(u8, branch_diag.message, "type") != null);
}
