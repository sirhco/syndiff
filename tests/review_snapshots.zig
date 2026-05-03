//! End-to-end snapshot tests for `syndiff --review` output.
//!
//! Each subdirectory under `testdata/review/<case>/` is a fixture pair plus
//! `expected.ndjson`. The test parses both files, runs the review orchestrator,
//! and compares the rendered NDJSON against `expected.ndjson` byte-for-byte.

const std = @import("std");
const Io = std.Io;
const syndiff = @import("syndiff");
const review = @import("syndiff").review;

fn runCase(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) !void {
    // Zig 0.16 replaced `std.fs` with `std.Io.Dir`/`std.Io.File`; FS calls now
    // take an `io: Io` parameter. See `src/main.zig` for the same pattern.
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var a_path: ?[]u8 = null;
    var b_path: ?[]u8 = null;
    defer if (a_path) |p| gpa.free(p);
    defer if (b_path) |p| gpa.free(p);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "a.")) {
            a_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        } else if (std.mem.startsWith(u8, entry.name, "b.")) {
            b_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        }
    }
    const a = a_path orelse return error.MissingA;
    const b = b_path orelse return error.MissingB;

    const expected_path = try std.fmt.allocPrint(gpa, "{s}/expected.ndjson", .{dir_path});
    defer gpa.free(expected_path);
    const expected = try cwd.readFileAlloc(io, expected_path, gpa, .limited(1 << 20));
    defer gpa.free(expected);

    // Zig 0.16: `std.Io.Writer.Allocating` produces a `Writer` backed by a
    // growable allocation. (The plan's pseudo-code `std.Io.Writer.fromArrayList(gpa, &buf)`
    // does not exist with that signature — `Writer.fromArrayList` takes only a
    // `*ArrayList(u8)` and consumes it. `Allocating.init` is the simpler option.)
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try review.runFilePair(gpa, io, a, b, &aw.writer);

    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "review snapshot: body_only" {
    try runCase(std.testing.allocator, std.testing.io, "testdata/review/body_only");
}

test "review snapshot: security_touch" {
    try runCase(std.testing.allocator, std.testing.io, "testdata/review/security_touch");
}

test "review snapshot: rename_only" {
    try runCase(std.testing.allocator, std.testing.io, "testdata/review/rename_only");
}
