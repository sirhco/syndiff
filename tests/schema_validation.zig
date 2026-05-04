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

// Hard-coded for explicitness — keep in sync with `testdata/review/`. Task 8
// (per-kind fixture coverage audit) will revisit this list to ensure every
// review-v1 record kind has at least one fixture.
const fixtures = [_][]const u8{
    "testdata/review/body_only/expected.ndjson",
    "testdata/review/rename_only/expected.ndjson",
    "testdata/review/security_touch/expected.ndjson",
    "testdata/review/ts_enum_change/expected.ndjson",
    "testdata/review/ts_interface_change/expected.ndjson",
    "testdata/review/ts_type_change/expected.ndjson",
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
