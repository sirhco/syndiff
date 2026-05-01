const std = @import("std");
const Io = std.Io;

const syndiff = @import("syndiff");

const usage =
    \\syndiff — semantic diff for structured data and source code.
    \\
    \\Primary workflow (git-aware, like `git diff`):
    \\  syndiff                          HEAD -> working tree (uncommitted changes).
    \\  syndiff <ref>                    <ref> -> working tree (e.g. `syndiff HEAD~1`).
    \\  syndiff <ref1> <ref2>            <ref1> -> <ref2>.
    \\  syndiff [<refs>] -- <path>...    Restrict to paths (forwarded to git).
    \\
    \\File-pair workflow (auto-detected when both args exist on disk):
    \\  syndiff <a> <b>
    \\
    \\Options:
    \\  --format, -F text|json|yaml      Output format (default: text).
    \\  --files <a> <b>                  Force file-pair mode.
    \\  --help, -h                       Show this help.
    \\  --version, -V                    Show version.
    \\
    \\Format dispatch is by extension:
    \\  .json              supported
    \\  .yaml, .yml        supported (block-style subset)
    \\  .zig               supported (top-level decls)
    \\  .rs                supported (top-level items)
    \\  .go                supported (top-level decls)
    \\  (others)           skipped in git mode, error in file-pair mode
    \\
    \\Exit codes:
    \\  0  no changes
    \\  1  changes found
    \\  2  invalid arguments, git failure, or parse error
    \\
;

const version_str = "syndiff 0.1.0\n";

const ExitCode = enum(u8) {
    no_changes = 0,
    changes_found = 1,
    err = 2,
};

const OutputFormat = enum {
    text,
    json,
    yaml,

    fn parse(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "yaml")) return .yaml;
        return null;
    }
};

const Format = enum {
    json,
    yaml,
    zig,
    rust,
    go,
    unknown,

    fn fromPath(path: []const u8) Format {
        if (std.ascii.endsWithIgnoreCase(path, ".json")) return .json;
        if (std.ascii.endsWithIgnoreCase(path, ".zig")) return .zig;
        if (std.ascii.endsWithIgnoreCase(path, ".yaml")) return .yaml;
        if (std.ascii.endsWithIgnoreCase(path, ".yml")) return .yaml;
        if (std.ascii.endsWithIgnoreCase(path, ".rs")) return .rust;
        if (std.ascii.endsWithIgnoreCase(path, ".go")) return .go;
        return .unknown;
    }

    fn isSupported(self: Format) bool {
        return switch (self) {
            .json, .yaml, .zig, .rust, .go => true,
            else => false,
        };
    }
};

fn die(stderr: *Io.Writer, stdout: *Io.Writer, code: ExitCode) noreturn {
    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(@intFromEnum(code));
}

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const Args = union(enum) {
    help,
    version,
    files: struct { a: []const u8, b: []const u8, output: OutputFormat },
    git: struct {
        ref_a: []const u8, // WORKTREE if empty
        ref_b: []const u8, // WORKTREE if empty
        paths: []const []const u8,
        output: OutputFormat,
    },
    /// 2 positional args, no `--`, no `--files`. Caller resolves to .files
    /// if both args exist on disk, else to .git { a, b }.
    ambiguous_pair: struct { a: []const u8, b: []const u8, output: OutputFormat },
    bad: []const u8,
};

fn parseArgs(raw: []const []const u8) Args {
    if (raw.len < 2) {
        return .{ .git = .{
            .ref_a = "HEAD",
            .ref_b = syndiff.git.WORKTREE,
            .paths = &.{},
            .output = .text,
        } };
    }

    const args = raw[1..];

    // First pass: handle the singleton --help/--version forms.
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return .help;
        if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-V")) return .version;
    }

    // Stack-allocated buffer for filtered args (raw.len is small).
    var buf: [64][]const u8 = undefined;
    if (args.len > buf.len) return .{ .bad = "too many arguments" };
    var n: usize = 0;
    var output: OutputFormat = .text;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--format") or std.mem.eql(u8, a, "-F")) {
            if (i + 1 >= args.len) return .{ .bad = "--format requires an argument" };
            i += 1;
            output = OutputFormat.parse(args[i]) orelse return .{ .bad = "invalid --format value (expected text|json|yaml)" };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--format=")) {
            output = OutputFormat.parse(a["--format=".len..]) orelse return .{ .bad = "invalid --format value (expected text|json|yaml)" };
            continue;
        }
        buf[n] = a;
        n += 1;
    }

    const filtered = buf[0..n];

    // Find -- separator splitting refs from paths.
    var sep: ?usize = null;
    for (filtered, 0..) |a, j| {
        if (std.mem.eql(u8, a, "--")) {
            sep = j;
            break;
        }
    }
    const ref_args = if (sep) |s| filtered[0..s] else filtered;
    const path_args: []const []const u8 = if (sep) |s| filtered[s + 1 ..] else &.{};

    // Explicit --files.
    if (ref_args.len >= 1 and std.mem.eql(u8, ref_args[0], "--files")) {
        if (ref_args.len != 3) return .{ .bad = "--files requires exactly 2 paths" };
        return .{ .files = .{ .a = ref_args[1], .b = ref_args[2], .output = output } };
    }

    if (sep == null and ref_args.len == 2) {
        return .{ .ambiguous_pair = .{ .a = ref_args[0], .b = ref_args[1], .output = output } };
    }

    switch (ref_args.len) {
        0 => return .{ .git = .{
            .ref_a = "HEAD",
            .ref_b = syndiff.git.WORKTREE,
            .paths = path_args,
            .output = output,
        } },
        1 => return .{ .git = .{
            .ref_a = ref_args[0],
            .ref_b = syndiff.git.WORKTREE,
            .paths = path_args,
            .output = output,
        } },
        2 => return .{ .git = .{
            .ref_a = ref_args[0],
            .ref_b = ref_args[1],
            .paths = path_args,
            .output = output,
        } },
        else => return .{ .bad = "too many ref arguments (expected at most 2)" },
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_file_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);
    const parsed = parseArgs(argv);

    switch (parsed) {
        .help => {
            try stdout.writeAll(usage);
            try stdout.flush();
            return;
        },
        .version => {
            try stdout.writeAll(version_str);
            try stdout.flush();
            return;
        },
        .bad => |msg| {
            try stderr.print("error: {s}\n\n", .{msg});
            try stderr.writeAll(usage);
            die(stderr, stdout, .err);
        },
        .files => |f| try runFiles(arena, io, stdout, stderr, f.a, f.b, f.output),
        .git => |g| try runGit(arena, io, stdout, stderr, g.ref_a, g.ref_b, g.paths, g.output),
        .ambiguous_pair => |p| {
            if (pathExists(io, p.a) and pathExists(io, p.b)) {
                try runFiles(arena, io, stdout, stderr, p.a, p.b, p.output);
            } else {
                try runGit(arena, io, stdout, stderr, p.a, p.b, &.{}, p.output);
            }
        },
    }
}

fn runFiles(
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    a_path: []const u8,
    b_path: []const u8,
    output: OutputFormat,
) !void {
    const a_fmt = Format.fromPath(a_path);
    const b_fmt = Format.fromPath(b_path);

    if (a_fmt != b_fmt) {
        try stderr.print("error: file formats differ: {s} vs {s}\n", .{ a_path, b_path });
        die(stderr, stdout, .err);
    }
    if (!a_fmt.isSupported()) {
        try stderr.print("error: unsupported format for {s}\n", .{a_path});
        die(stderr, stdout, .err);
    }

    const a_src = readWorkingFile(arena, io, a_path) catch |err| {
        try stderr.print("error: read {s}: {s}\n", .{ a_path, @errorName(err) });
        die(stderr, stdout, .err);
    };
    const b_src = readWorkingFile(arena, io, b_path) catch |err| {
        try stderr.print("error: read {s}: {s}\n", .{ b_path, @errorName(err) });
        die(stderr, stdout, .err);
    };

    const had_changes = diffOnePair(
        arena,
        stdout,
        stderr,
        a_path,
        a_src,
        b_path,
        b_src,
        a_fmt,
        output,
    ) catch |err| {
        try stderr.print("error: {s} vs {s}: {s}\n", .{ a_path, b_path, @errorName(err) });
        die(stderr, stdout, .err);
    };

    try stdout.flush();
    die(stderr, stdout, if (had_changes) .changes_found else .no_changes);
}

fn runGit(
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    ref_a: []const u8,
    ref_b: []const u8,
    paths: []const []const u8,
    output: OutputFormat,
) !void {
    if (!syndiff.git.isInRepo(arena, io)) {
        try stderr.writeAll("error: not inside a git repository (use `syndiff --files <a> <b>` for file-pair mode)\n");
        die(stderr, stdout, .err);
    }

    if (!syndiff.git.refExists(arena, io, ref_a)) {
        try stderr.print("error: ref not found: {s}\n", .{ref_a});
        die(stderr, stdout, .err);
    }
    if (!syndiff.git.refExists(arena, io, ref_b)) {
        try stderr.print("error: ref not found: {s}\n", .{ref_b});
        die(stderr, stdout, .err);
    }

    const changed = syndiff.git.listChangedFiles(arena, io, ref_a, ref_b, paths) catch |err| {
        try stderr.print("error: git diff failed: {s}\n", .{@errorName(err)});
        die(stderr, stdout, .err);
    };

    var any_supported = false;
    var any_changes = false;
    var skipped: usize = 0;

    for (changed) |path| {
        const fmt = Format.fromPath(path);
        if (!fmt.isSupported()) {
            skipped += 1;
            continue;
        }
        any_supported = true;

        const a_src = syndiff.git.readAtRef(arena, io, ref_a, path) catch |err| switch (err) {
            error.FileNotInRef => "",
            else => {
                try stderr.print("error: read {s}@{s}: {s}\n", .{ path, refLabel(ref_a), @errorName(err) });
                die(stderr, stdout, .err);
            },
        };
        const b_src = syndiff.git.readAtRef(arena, io, ref_b, path) catch |err| switch (err) {
            error.FileNotInRef => "",
            else => {
                try stderr.print("error: read {s}@{s}: {s}\n", .{ path, refLabel(ref_b), @errorName(err) });
                die(stderr, stdout, .err);
            },
        };

        // Whole-file ADDED / DELETED at git level.
        if (a_src.len == 0 and b_src.len > 0) {
            try writeFileEvent(stdout, output, path, refLabel(ref_a), refLabel(ref_b), "new");
            any_changes = true;
            continue;
        }
        if (a_src.len > 0 and b_src.len == 0) {
            try writeFileEvent(stdout, output, path, refLabel(ref_a), refLabel(ref_b), "removed");
            any_changes = true;
            continue;
        }

        const a_label = try std.fmt.allocPrint(arena, "{s}@{s}", .{ path, refLabel(ref_a) });
        const b_label = try std.fmt.allocPrint(arena, "{s}@{s}", .{ path, refLabel(ref_b) });

        // Per-file header (text mode only).
        if (output == .text) {
            try stdout.print("=== {s} ({s} -> {s}) ===\n", .{ path, refLabel(ref_a), refLabel(ref_b) });
        }

        const had = diffOnePair(arena, stdout, stderr, a_label, a_src, b_label, b_src, fmt, output) catch |err| {
            try stderr.print("error: diff {s}: {s}\n", .{ path, @errorName(err) });
            die(stderr, stdout, .err);
        };
        if (had) any_changes = true;
    }

    // Status footer: text only. JSON/YAML are pure data streams.
    if (output == .text) {
        if (!any_supported) {
            if (changed.len == 0) {
                try stdout.writeAll("(no files changed)\n");
            } else {
                try stdout.print("(no supported files changed; {d} skipped)\n", .{skipped});
            }
        } else if (skipped > 0) {
            try stdout.print("({d} unsupported files skipped)\n", .{skipped});
        }
    }

    try stdout.flush();
    die(stderr, stdout, if (any_changes) .changes_found else .no_changes);
}

fn refLabel(ref: []const u8) []const u8 {
    return if (syndiff.git.isWorktree(ref)) "worktree" else ref;
}

fn readWorkingFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, arena, .limited(1 << 28));
}

/// Parse + diff one (path,bytes) pair. Returns true iff any changes emitted.
fn diffOnePair(
    arena: std.mem.Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    a_label: []const u8,
    a_src: []const u8,
    b_label: []const u8,
    b_src: []const u8,
    fmt: Format,
    output: OutputFormat,
) !bool {
    var a_tree = try parseBytes(arena, a_src, a_label, fmt);
    defer a_tree.deinit();
    var b_tree = try parseBytes(arena, b_src, b_label, fmt);
    defer b_tree.deinit();

    var set = try syndiff.differ.diff(arena, &a_tree, &b_tree);
    defer set.deinit(arena);

    try syndiff.differ.suppressCascade(&set, &a_tree, &b_tree, arena);
    syndiff.differ.sortByLocation(&set, &a_tree, &b_tree);

    switch (output) {
        .text => try syndiff.differ.render(&set, &a_tree, &b_tree, stdout),
        .json => try syndiff.differ.renderJson(&set, &a_tree, &b_tree, stdout),
        .yaml => try syndiff.differ.renderYaml(&set, &a_tree, &b_tree, stdout),
    }
    _ = stderr;
    return set.changes.items.len != 0;
}

/// Whole-file ADDED/DELETED events at the git level (file `new` or `removed`
/// in B vs A). Renderers vary by output format.
fn writeFileEvent(
    stdout: *Io.Writer,
    output: OutputFormat,
    path: []const u8,
    ref_a_label: []const u8,
    ref_b_label: []const u8,
    kind: []const u8, // "new" or "removed"
) !void {
    switch (output) {
        .text => {
            const upper: []const u8 = if (std.mem.eql(u8, kind, "new")) "NEW" else "REMOVED";
            try stdout.print("=== {s} ({s} {s} -> {s}) ===\n", .{ path, upper, ref_a_label, ref_b_label });
        },
        .json => {
            try stdout.writeAll("{\"kind\":\"file_");
            try stdout.writeAll(kind);
            try stdout.writeAll("\",\"path\":");
            try jsonString(stdout, path);
            try stdout.writeAll(",\"ref_a\":");
            try jsonString(stdout, ref_a_label);
            try stdout.writeAll(",\"ref_b\":");
            try jsonString(stdout, ref_b_label);
            try stdout.writeAll("}\n");
        },
        .yaml => {
            try stdout.writeAll("- kind: file_");
            try stdout.writeAll(kind);
            try stdout.writeAll("\n  path: ");
            try jsonString(stdout, path);
            try stdout.writeAll("\n  ref_a: ");
            try jsonString(stdout, ref_a_label);
            try stdout.writeAll("\n  ref_b: ");
            try jsonString(stdout, ref_b_label);
            try stdout.writeAll("\n");
        },
    }
}

fn jsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn parseBytes(
    arena: std.mem.Allocator,
    src: []const u8,
    path: []const u8,
    fmt: Format,
) !syndiff.ast.Tree {
    return switch (fmt) {
        .json => try syndiff.json_parser.parse(arena, src, path),
        .yaml => try syndiff.yaml_parser.parse(arena, src, path),
        .rust => try syndiff.rust_parser.parse(arena, src, path),
        .go => try syndiff.go_parser.parse(arena, src, path),
        .zig => blk: {
            const src_z = try arena.dupeZ(u8, src);
            break :blk try syndiff.zig_parser.parse(arena, src_z, path);
        },
        else => unreachable,
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "Format.fromPath" {
    try std.testing.expectEqual(Format.json, Format.fromPath("a.json"));
    try std.testing.expectEqual(Format.json, Format.fromPath("/x/y/A.JSON"));
    try std.testing.expectEqual(Format.zig, Format.fromPath("build.zig"));
    try std.testing.expectEqual(Format.zig, Format.fromPath("/abs/path/Foo.ZIG"));
    try std.testing.expectEqual(Format.yaml, Format.fromPath("config.yml"));
    try std.testing.expectEqual(Format.yaml, Format.fromPath("config.yaml"));
    try std.testing.expectEqual(Format.rust, Format.fromPath("foo.rs"));
    try std.testing.expectEqual(Format.go, Format.fromPath("main.go"));
    try std.testing.expectEqual(Format.unknown, Format.fromPath("README.md"));
    try std.testing.expectEqual(Format.unknown, Format.fromPath("noext"));
}

test "parseArgs: zero args -> HEAD vs WT, text output" {
    const r = parseArgs(&.{"syndiff"});
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("HEAD", r.git.ref_a);
    try std.testing.expect(syndiff.git.isWorktree(r.git.ref_b));
    try std.testing.expectEqual(@as(usize, 0), r.git.paths.len);
    try std.testing.expectEqual(OutputFormat.text, r.git.output);
}

test "parseArgs: --format=json" {
    const r = parseArgs(&.{ "syndiff", "--format=json" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(OutputFormat.json, r.git.output);
}

test "parseArgs: --format yaml (space form)" {
    const r = parseArgs(&.{ "syndiff", "HEAD~1", "--format", "yaml" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("HEAD~1", r.git.ref_a);
    try std.testing.expectEqual(OutputFormat.yaml, r.git.output);
}

test "parseArgs: -F json shorthand carries through ambiguous_pair" {
    const r = parseArgs(&.{ "syndiff", "-F", "json", "HEAD~2", "HEAD" });
    try std.testing.expect(r == .ambiguous_pair);
    try std.testing.expectEqualStrings("HEAD~2", r.ambiguous_pair.a);
    try std.testing.expectEqualStrings("HEAD", r.ambiguous_pair.b);
    try std.testing.expectEqual(OutputFormat.json, r.ambiguous_pair.output);
}

test "parseArgs: bad --format value" {
    const r = parseArgs(&.{ "syndiff", "--format=xml" });
    try std.testing.expect(r == .bad);
}

test "parseArgs: --format requires arg" {
    const r = parseArgs(&.{ "syndiff", "--format" });
    try std.testing.expect(r == .bad);
}

test "parseArgs: --help and --version" {
    try std.testing.expect(parseArgs(&.{ "syndiff", "--help" }) == .help);
    try std.testing.expect(parseArgs(&.{ "syndiff", "-h" }) == .help);
    try std.testing.expect(parseArgs(&.{ "syndiff", "--version" }) == .version);
    try std.testing.expect(parseArgs(&.{ "syndiff", "-V" }) == .version);
}

test "parseArgs: one ref -> ref vs WT" {
    const r = parseArgs(&.{ "syndiff", "HEAD~1" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("HEAD~1", r.git.ref_a);
    try std.testing.expect(syndiff.git.isWorktree(r.git.ref_b));
}

test "parseArgs: two bare args -> ambiguous_pair" {
    const r = parseArgs(&.{ "syndiff", "main", "feature/x" });
    try std.testing.expect(r == .ambiguous_pair);
    try std.testing.expectEqualStrings("main", r.ambiguous_pair.a);
    try std.testing.expectEqualStrings("feature/x", r.ambiguous_pair.b);
}

test "parseArgs: two refs with -- separator -> git mode" {
    const r = parseArgs(&.{ "syndiff", "main", "feature/x", "--" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("main", r.git.ref_a);
    try std.testing.expectEqualStrings("feature/x", r.git.ref_b);
}

test "parseArgs: -- splits refs and paths" {
    const r = parseArgs(&.{ "syndiff", "HEAD~1", "--", "src/main.zig", "src/ast.zig" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("HEAD~1", r.git.ref_a);
    try std.testing.expect(syndiff.git.isWorktree(r.git.ref_b));
    try std.testing.expectEqual(@as(usize, 2), r.git.paths.len);
    try std.testing.expectEqualStrings("src/main.zig", r.git.paths[0]);
}

test "parseArgs: --files forces file-pair mode" {
    const r = parseArgs(&.{ "syndiff", "--files", "a.json", "b.json" });
    try std.testing.expect(r == .files);
    try std.testing.expectEqualStrings("a.json", r.files.a);
    try std.testing.expectEqualStrings("b.json", r.files.b);
}

test "parseArgs: too many refs" {
    const r = parseArgs(&.{ "syndiff", "a", "b", "c" });
    try std.testing.expect(r == .bad);
}
