const std = @import("std");
const Io = std.Io;

const syndiff = @import("syndiff");

const usage =
    \\syndiff — semantic diff for structured data and source code.
    \\
    \\Usage:
    \\  syndiff <a> <b>      Compare two files, report ADDED/DELETED/MODIFIED/MOVED.
    \\  syndiff --help       Show this help.
    \\  syndiff --version    Show version.
    \\
    \\Format dispatch is by file extension:
    \\  .json              supported
    \\  .yaml, .yml        not implemented (planned)
    \\  .rs, .go, .zig     not implemented (planned)
    \\
    \\Exit codes:
    \\  0  no changes
    \\  1  changes found
    \\  2  invalid arguments or read/parse error
    \\
;

const version_str = "syndiff 0.1.0\n";

const ExitCode = enum(u8) {
    no_changes = 0,
    changes_found = 1,
    err = 2,
};

const Format = enum {
    json,
    yaml_unsupported,
    source_unsupported,
    unknown,

    fn fromPath(path: []const u8) Format {
        if (std.ascii.endsWithIgnoreCase(path, ".json")) return .json;
        if (std.ascii.endsWithIgnoreCase(path, ".yaml")) return .yaml_unsupported;
        if (std.ascii.endsWithIgnoreCase(path, ".yml")) return .yaml_unsupported;
        if (std.ascii.endsWithIgnoreCase(path, ".rs")) return .source_unsupported;
        if (std.ascii.endsWithIgnoreCase(path, ".go")) return .source_unsupported;
        if (std.ascii.endsWithIgnoreCase(path, ".zig")) return .source_unsupported;
        return .unknown;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            try stdout.writeAll(usage);
            return;
        }
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) {
            try stdout.writeAll(version_str);
            return;
        }
    }

    if (args.len != 3) {
        try stderr.writeAll(usage);
        std.process.exit(@intFromEnum(ExitCode.err));
    }

    const a_path = args[1];
    const b_path = args[2];

    const a_fmt = Format.fromPath(a_path);
    const b_fmt = Format.fromPath(b_path);

    if (a_fmt != b_fmt) {
        try stderr.print("error: file formats differ: {s} vs {s}\n", .{ a_path, b_path });
        std.process.exit(@intFromEnum(ExitCode.err));
    }

    switch (a_fmt) {
        .json => {},
        .yaml_unsupported => {
            try stderr.writeAll("error: YAML support is not yet implemented.\n");
            std.process.exit(@intFromEnum(ExitCode.err));
        },
        .source_unsupported => {
            try stderr.writeAll("error: source-code diff is not yet implemented.\n");
            std.process.exit(@intFromEnum(ExitCode.err));
        },
        .unknown => {
            try stderr.print("error: unrecognized file extension: {s}\n", .{a_path});
            std.process.exit(@intFromEnum(ExitCode.err));
        },
    }

    const cwd = std.Io.Dir.cwd();
    const a_src = cwd.readFileAlloc(io, a_path, arena, .limited(1 << 28)) catch |err| {
        try stderr.print("error: cannot read {s}: {s}\n", .{ a_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.err));
    };
    const b_src = cwd.readFileAlloc(io, b_path, arena, .limited(1 << 28)) catch |err| {
        try stderr.print("error: cannot read {s}: {s}\n", .{ b_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.err));
    };

    var a_tree = syndiff.json_parser.parse(arena, a_src, a_path) catch |err| {
        try stderr.print("error: parse {s}: {s}\n", .{ a_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.err));
    };
    defer a_tree.deinit();
    var b_tree = syndiff.json_parser.parse(arena, b_src, b_path) catch |err| {
        try stderr.print("error: parse {s}: {s}\n", .{ b_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.err));
    };
    defer b_tree.deinit();

    var set = try syndiff.differ.diff(arena, &a_tree, &b_tree);
    defer set.deinit(arena);

    try syndiff.differ.suppressCascade(&set, &a_tree, &b_tree, arena);
    syndiff.differ.sortByLocation(&set, &a_tree, &b_tree);

    try syndiff.differ.render(&set, &a_tree, &b_tree, stdout);

    if (set.changes.items.len == 0) {
        std.process.exit(@intFromEnum(ExitCode.no_changes));
    }
    std.process.exit(@intFromEnum(ExitCode.changes_found));
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "Format.fromPath" {
    try std.testing.expectEqual(Format.json, Format.fromPath("a.json"));
    try std.testing.expectEqual(Format.json, Format.fromPath("/x/y/A.JSON"));
    try std.testing.expectEqual(Format.yaml_unsupported, Format.fromPath("config.yml"));
    try std.testing.expectEqual(Format.yaml_unsupported, Format.fromPath("config.yaml"));
    try std.testing.expectEqual(Format.source_unsupported, Format.fromPath("foo.rs"));
    try std.testing.expectEqual(Format.source_unsupported, Format.fromPath("main.go"));
    try std.testing.expectEqual(Format.source_unsupported, Format.fromPath("build.zig"));
    try std.testing.expectEqual(Format.unknown, Format.fromPath("README.md"));
    try std.testing.expectEqual(Format.unknown, Format.fromPath("noext"));
}
