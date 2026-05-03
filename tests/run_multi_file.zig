//! Integration tests for review.Run multi-file driver + test_not_updated emission.

const std = @import("std");
const syndiff = @import("syndiff");
const differ = syndiff.differ;
const review = syndiff.review;
const go_parser = syndiff.go_parser;

test "Run emits test_not_updated for source without co-changed test" {
    const gpa = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var run = try review.Run.init(gpa, &aw.writer);
    defer run.deinit();

    var a = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 1 }\n", "src/foo.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 2 }\n", "src/foo.go");
    defer b.deinit();
    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    try run.recordChangedPath("src/foo.go");
    try run.addFilePair(&a, &b, &set);
    try run.finish();

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"test_not_updated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/foo.go") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/foo_test.go") != null);
}

test "Run does NOT emit test_not_updated when test file is co-changed" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var run = try review.Run.init(gpa, &aw.writer);
    defer run.deinit();

    var a = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 1 }\n", "src/foo.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 2 }\n", "src/foo.go");
    defer b.deinit();
    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    try run.recordChangedPath("src/foo.go");
    try run.recordChangedPath("src/foo_test.go");
    try run.addFilePair(&a, &b, &set);
    try run.finish();

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"test_not_updated\"") == null);
}

test "Run emits single schema header and single summary across multiple file pairs" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var run = try review.Run.init(gpa, &aw.writer);
    defer run.deinit();

    var a1 = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 1 }\n", "a.go");
    defer a1.deinit();
    var b1 = try go_parser.parse(gpa, "package main\nfunc Foo() int { return 2 }\n", "a.go");
    defer b1.deinit();
    var set1 = try differ.diff(gpa, &a1, &b1);
    defer set1.deinit(gpa);
    try differ.suppressCascade(&set1, &a1, &b1, gpa);

    var a2 = try go_parser.parse(gpa, "package main\nfunc Bar() int { return 3 }\n", "b.go");
    defer a2.deinit();
    var b2 = try go_parser.parse(gpa, "package main\nfunc Bar() int { return 4 }\n", "b.go");
    defer b2.deinit();
    var set2 = try differ.diff(gpa, &a2, &b2);
    defer set2.deinit(gpa);
    try differ.suppressCascade(&set2, &a2, &b2, gpa);

    try run.recordChangedPath("a.go");
    try run.recordChangedPath("b.go");
    try run.recordChangedPath("a_test.go");
    try run.recordChangedPath("b_test.go");
    try run.addFilePair(&a1, &b1, &set1);
    try run.addFilePair(&a2, &b2, &set2);
    try run.finish();

    const out = aw.writer.buffered();
    var schema_count: usize = 0;
    var summary_count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "\"kind\":\"schema\"")) |pos| {
        schema_count += 1;
        i = pos + 1;
    }
    i = 0;
    while (std.mem.indexOfPos(u8, out, i, "\"kind\":\"summary\"")) |pos| {
        summary_count += 1;
        i = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), schema_count);
    try std.testing.expectEqual(@as(usize, 1), summary_count);
}
