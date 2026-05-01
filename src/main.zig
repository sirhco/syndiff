const std = @import("std");
const Io = std.Io;

const syndiff = @import("syndiff");

const usage =
    \\Usage: syndiff <a.json> <b.json>
    \\
    \\Semantic diff between two JSON files. Output labels:
    \\  ADDED, DELETED, MODIFIED, MOVED.
    \\
;

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
    if (args.len != 3) {
        try stderr.writeAll(usage);
        std.process.exit(2);
    }

    const a_path = args[1];
    const b_path = args[2];

    const cwd = std.Io.Dir.cwd();
    const a_src = try cwd.readFileAlloc(io, a_path, arena, .limited(1 << 28));
    const b_src = try cwd.readFileAlloc(io, b_path, arena, .limited(1 << 28));

    var a_tree = try syndiff.json_parser.parse(arena, a_src, a_path);
    defer a_tree.deinit();
    var b_tree = try syndiff.json_parser.parse(arena, b_src, b_path);
    defer b_tree.deinit();

    var set = try syndiff.differ.diff(arena, &a_tree, &b_tree);
    defer set.deinit(arena);

    try syndiff.differ.render(&set, &a_tree, &b_tree, stdout);

    if (set.changes.items.len == 0) {
        try stdout.writeAll("(no changes)\n");
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
