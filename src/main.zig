//! CLI entry point. Parses argv into one of:
//!   - `.help` / `.version`           — single-shot, exit 0
//!   - `.files`                       — explicit file-pair diff
//!   - `.git`                         — multi-file diff via shelled-out git
//!   - `.ambiguous_pair`              — 2 args, mode resolved by checking disk
//!   - `.bad`                         — usage error, exit 2
//!
//! Output format (text/json/yaml), color (auto/always/never), and change-kind
//! filter (`--only`) are uniform across both files and git modes; runners
//! thread them through to `differ.render*` via `RenderOptions`.

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
    \\  --format, -F text|json|yaml|review-json
    \\                                   Output format (default: text).
    \\  --review                         Emit enriched NDJSON for LLM review tools
    \\                                   (alias: --format review-json).
    \\  --color auto|always|never        Color in text output. auto = TTY only.
    \\  --no-color                       Alias for --color=never.
    \\  --only KINDS                     Comma-separated change kinds to keep:
    \\                                     added, deleted, modified, moved
    \\  --group-by symbol                Review-mode only: nest stmt-level
    \\                                     changes under their enclosing
    \\                                     fn/method record as `sub_changes`.
    \\  --complexity cyclomatic|stmt_count
    \\                                   Review-mode only: select the algorithm
    \\                                     used for `complexity_delta`. Default
    \\                                     cyclomatic (decision-point + 1, fn
    \\                                     level). `stmt_count` is the legacy
    \\                                     pre-Phase-6 proxy (direct stmt
    \\                                     children of the changed node).
    \\  --files <a> <b>                  Force file-pair mode.
    \\  --help, -h                       Show this help.
    \\  --version, -V                    Show version.
    \\
    \\Format dispatch is by extension:
    \\  .json              supported
    \\  .yaml, .yml        supported (block-style subset)
    \\  .zig               supported (top-level decls + fn-body stmts)
    \\  .rs                supported (top-level items + fn-body stmts)
    \\  .go                supported (top-level decls + fn-body stmts)
    \\  .dart              supported (top-level decls, class members, fn-body stmts)
    \\  .js, .mjs, .cjs    supported (top-level decls, class methods, fn-body stmts)
    \\  .ts, .tsx, .mts, .cts  supported (interfaces, types, enums, namespaces)
    \\  .java              supported (top-level decls, class members, fn-body stmts)
    \\  .cs                supported (namespaces, classes, properties, methods, fn-body stmts)
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
    review_json,

    fn parse(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "yaml")) return .yaml;
        if (std.mem.eql(u8, s, "review-json")) return .review_json;
        return null;
    }
};

const ColorMode = enum {
    auto,
    always,
    never,

    fn parse(s: []const u8) ?ColorMode {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "always")) return .always;
        if (std.mem.eql(u8, s, "never")) return .never;
        return null;
    }
};

fn parseKindFilter(spec: []const u8) ?syndiff.differ.KindFilter {
    var f: syndiff.differ.KindFilter = syndiff.differ.KindFilter.none;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    var any = false;
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " ");
        if (tok.len == 0) continue;
        any = true;
        if (std.mem.eql(u8, tok, "added")) {
            f.added = true;
        } else if (std.mem.eql(u8, tok, "deleted")) {
            f.deleted = true;
        } else if (std.mem.eql(u8, tok, "modified")) {
            f.modified = true;
        } else if (std.mem.eql(u8, tok, "moved")) {
            f.moved = true;
        } else return null;
    }
    if (!any) return null;
    return f;
}

fn langFor(fmt: Format) syndiff.syntax.Lang {
    return switch (fmt) {
        .json => .json,
        .yaml => .yaml,
        .rust => .rust,
        .go => .go,
        .zig => .zig,
        .dart => .dart,
        .javascript => .javascript,
        .typescript => .typescript,
        .java => .java,
        .csharp => .csharp,
        .unknown => .none,
    };
}

const Format = enum {
    json,
    yaml,
    zig,
    rust,
    go,
    dart,
    javascript,
    typescript,
    java,
    csharp,
    unknown,

    fn fromPath(path: []const u8) Format {
        if (std.ascii.endsWithIgnoreCase(path, ".json")) return .json;
        if (std.ascii.endsWithIgnoreCase(path, ".zig")) return .zig;
        if (std.ascii.endsWithIgnoreCase(path, ".yaml")) return .yaml;
        if (std.ascii.endsWithIgnoreCase(path, ".yml")) return .yaml;
        if (std.ascii.endsWithIgnoreCase(path, ".rs")) return .rust;
        if (std.ascii.endsWithIgnoreCase(path, ".go")) return .go;
        if (std.ascii.endsWithIgnoreCase(path, ".dart")) return .dart;
        if (std.ascii.endsWithIgnoreCase(path, ".tsx")) return .typescript;
        if (std.ascii.endsWithIgnoreCase(path, ".mts")) return .typescript;
        if (std.ascii.endsWithIgnoreCase(path, ".cts")) return .typescript;
        if (std.ascii.endsWithIgnoreCase(path, ".ts")) return .typescript;
        if (std.ascii.endsWithIgnoreCase(path, ".mjs")) return .javascript;
        if (std.ascii.endsWithIgnoreCase(path, ".cjs")) return .javascript;
        if (std.ascii.endsWithIgnoreCase(path, ".js")) return .javascript;
        if (std.ascii.endsWithIgnoreCase(path, ".java")) return .java;
        if (std.ascii.endsWithIgnoreCase(path, ".cs")) return .csharp;
        return .unknown;
    }

    fn isSupported(self: Format) bool {
        return switch (self) {
            .json, .yaml, .zig, .rust, .go, .dart, .javascript, .typescript, .java, .csharp => true,
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

const CommonOpts = struct {
    output: OutputFormat = .text,
    color: ColorMode = .auto,
    filter: syndiff.differ.KindFilter = .all,
    /// `--group-by symbol`: in review-mode output, collapse `*_stmt` changes
    /// into nested `sub_changes` arrays under their enclosing fn/method
    /// record. Default off — preserves byte-identical legacy output.
    group_by_symbol: bool = false,
    /// `--complexity cyclomatic|stmt_count`: select complexity algorithm.
    /// Default cyclomatic (decision-point + 1). `stmt_count` is the legacy
    /// pre-Phase-6 proxy.
    complexity_method: syndiff.review.ComplexityMethod = .cyclomatic,
};

const Args = union(enum) {
    help,
    version,
    files: struct { a: []const u8, b: []const u8, common: CommonOpts },
    git: struct {
        ref_a: []const u8,
        ref_b: []const u8,
        paths: []const []const u8,
        common: CommonOpts,
    },
    ambiguous_pair: struct { a: []const u8, b: []const u8, common: CommonOpts },
    bad: []const u8,
};

fn parseComplexityMethod(s: []const u8) ?syndiff.review.ComplexityMethod {
    if (std.mem.eql(u8, s, "cyclomatic")) return .cyclomatic;
    if (std.mem.eql(u8, s, "stmt_count")) return .stmt_count;
    return null;
}

fn parseArgs(raw: []const []const u8) Args {
    if (raw.len < 2) {
        return .{ .git = .{
            .ref_a = "HEAD",
            .ref_b = syndiff.git.WORKTREE,
            .paths = &.{},
            .common = .{},
        } };
    }

    const args = raw[1..];

    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return .help;
        if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-V")) return .version;
    }

    var buf: [64][]const u8 = undefined;
    if (args.len > buf.len) return .{ .bad = "too many arguments" };
    var n: usize = 0;
    var common: CommonOpts = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // --format X / --format=X / -F X
        if (std.mem.eql(u8, a, "--format") or std.mem.eql(u8, a, "-F")) {
            if (i + 1 >= args.len) return .{ .bad = "--format requires an argument" };
            i += 1;
            common.output = OutputFormat.parse(args[i]) orelse return .{ .bad = "invalid --format value (expected text|json|yaml|review-json)" };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--format=")) {
            common.output = OutputFormat.parse(a["--format=".len..]) orelse return .{ .bad = "invalid --format value (expected text|json|yaml|review-json)" };
            continue;
        }
        // --review (shortcut for --format=review-json)
        if (std.mem.eql(u8, a, "--review")) {
            common.output = .review_json;
            continue;
        }
        // --color X / --color=X
        if (std.mem.eql(u8, a, "--color")) {
            if (i + 1 >= args.len) return .{ .bad = "--color requires an argument" };
            i += 1;
            common.color = ColorMode.parse(args[i]) orelse return .{ .bad = "invalid --color value (expected auto|always|never)" };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--color=")) {
            common.color = ColorMode.parse(a["--color=".len..]) orelse return .{ .bad = "invalid --color value (expected auto|always|never)" };
            continue;
        }
        if (std.mem.eql(u8, a, "--no-color")) {
            common.color = .never;
            continue;
        }
        // --only K1,K2,...
        if (std.mem.eql(u8, a, "--only")) {
            if (i + 1 >= args.len) return .{ .bad = "--only requires a comma-separated list" };
            i += 1;
            common.filter = parseKindFilter(args[i]) orelse return .{ .bad = "invalid --only value (use added,deleted,modified,moved)" };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--only=")) {
            common.filter = parseKindFilter(a["--only=".len..]) orelse return .{ .bad = "invalid --only value (use added,deleted,modified,moved)" };
            continue;
        }
        // --group-by symbol / --group-by=symbol — only "symbol" is supported.
        if (std.mem.eql(u8, a, "--group-by")) {
            if (i + 1 >= args.len) return .{ .bad = "--group-by requires an argument" };
            i += 1;
            if (!std.mem.eql(u8, args[i], "symbol")) return .{ .bad = "invalid --group-by value (only 'symbol' supported)" };
            common.group_by_symbol = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--group-by=")) {
            const v = a["--group-by=".len..];
            if (!std.mem.eql(u8, v, "symbol")) return .{ .bad = "invalid --group-by value (only 'symbol' supported)" };
            common.group_by_symbol = true;
            continue;
        }
        // --complexity cyclomatic|stmt_count / --complexity=...
        if (std.mem.eql(u8, a, "--complexity")) {
            if (i + 1 >= args.len) return .{ .bad = "--complexity requires an argument" };
            i += 1;
            common.complexity_method = parseComplexityMethod(args[i]) orelse return .{ .bad = "invalid --complexity value (expected cyclomatic|stmt_count)" };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--complexity=")) {
            const v = a["--complexity=".len..];
            common.complexity_method = parseComplexityMethod(v) orelse return .{ .bad = "invalid --complexity value (expected cyclomatic|stmt_count)" };
            continue;
        }
        buf[n] = a;
        n += 1;
    }

    const filtered = buf[0..n];

    var sep: ?usize = null;
    for (filtered, 0..) |a, j| {
        if (std.mem.eql(u8, a, "--")) {
            sep = j;
            break;
        }
    }
    const ref_args = if (sep) |s| filtered[0..s] else filtered;
    const path_args: []const []const u8 = if (sep) |s| filtered[s + 1 ..] else &.{};

    if (ref_args.len >= 1 and std.mem.eql(u8, ref_args[0], "--files")) {
        if (ref_args.len != 3) return .{ .bad = "--files requires exactly 2 paths" };
        return .{ .files = .{ .a = ref_args[1], .b = ref_args[2], .common = common } };
    }

    if (sep == null and ref_args.len == 2) {
        return .{ .ambiguous_pair = .{ .a = ref_args[0], .b = ref_args[1], .common = common } };
    }

    switch (ref_args.len) {
        0 => return .{ .git = .{
            .ref_a = "HEAD",
            .ref_b = syndiff.git.WORKTREE,
            .paths = path_args,
            .common = common,
        } },
        1 => return .{ .git = .{
            .ref_a = ref_args[0],
            .ref_b = syndiff.git.WORKTREE,
            .paths = path_args,
            .common = common,
        } },
        2 => return .{ .git = .{
            .ref_a = ref_args[0],
            .ref_b = ref_args[1],
            .paths = path_args,
            .common = common,
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
        .files => |f| try runFiles(arena, io, stdout, stderr, f.a, f.b, f.common),
        .git => |g| try runGit(arena, io, stdout, stderr, g.ref_a, g.ref_b, g.paths, g.common),
        .ambiguous_pair => |p| {
            if (pathExists(io, p.a) and pathExists(io, p.b)) {
                try runFiles(arena, io, stdout, stderr, p.a, p.b, p.common);
            } else {
                try runGit(arena, io, stdout, stderr, p.a, p.b, &.{}, p.common);
            }
        },
    }
}

fn resolveTheme(io: Io, color: ColorMode) syndiff.syntax.Theme {
    const enable = switch (color) {
        .always => true,
        .never => false,
        .auto => blk: {
            const stdout_file = std.Io.File.stdout();
            break :blk stdout_file.isTty(io) catch false;
        },
    };
    return if (enable) syndiff.syntax.default_theme else syndiff.syntax.off_theme;
}

fn runFiles(
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    a_path: []const u8,
    b_path: []const u8,
    common: CommonOpts,
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

    const theme = resolveTheme(io, common.color);
    const had_changes = diffOnePair(
        arena,
        stdout,
        stderr,
        a_path,
        a_src,
        b_path,
        b_src,
        a_fmt,
        common.output,
        theme,
        common.filter,
        common.group_by_symbol,
        common.complexity_method,
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
    common: CommonOpts,
) !void {
    const theme = resolveTheme(io, common.color);
    const output = common.output;
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

    if (output == .review_json) {
        var run = try syndiff.review.Run.init(arena, stdout);
        defer run.deinit();
        run.group_by_symbol = common.group_by_symbol;
        run.complexity_method = common.complexity_method;

        for (changed) |path| {
            try run.recordChangedPath(path);
            const fmt = Format.fromPath(path);
            if (!fmt.isSupported()) continue;

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

            if (a_src.len == 0 and b_src.len > 0) {
                try writeFileEvent(stdout, output, path, refLabel(ref_a), refLabel(ref_b), "new");
                continue;
            }
            if (a_src.len > 0 and b_src.len == 0) {
                try writeFileEvent(stdout, output, path, refLabel(ref_a), refLabel(ref_b), "removed");
                continue;
            }

            const a_label = try std.fmt.allocPrint(arena, "{s}@{s}", .{ path, refLabel(ref_a) });
            const b_label = try std.fmt.allocPrint(arena, "{s}@{s}", .{ path, refLabel(ref_b) });

            var a_tree = try parseBytes(arena, a_src, a_label, fmt);
            defer a_tree.deinit();
            var b_tree = try parseBytes(arena, b_src, b_label, fmt);
            defer b_tree.deinit();

            var set = try syndiff.differ.diff(arena, &a_tree, &b_tree);
            defer set.deinit(arena);
            try syndiff.differ.suppressCascade(&set, &a_tree, &b_tree, arena);
            syndiff.differ.sortByLocation(&set, &a_tree, &b_tree);

            try run.addFilePair(&a_tree, &b_tree, &set);
        }

        try run.finish();
        try stdout.flush();
        die(stderr, stdout, if (run.totalChanges() > 0) .changes_found else .no_changes);
    }

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

        const had = diffOnePair(arena, stdout, stderr, a_label, a_src, b_label, b_src, fmt, output, theme, common.filter, common.group_by_symbol, common.complexity_method) catch |err| {
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
    theme: syndiff.syntax.Theme,
    kind_filter: syndiff.differ.KindFilter,
    group_by_symbol: bool,
    complexity_method: syndiff.review.ComplexityMethod,
) !bool {
    var a_tree = try parseBytes(arena, a_src, a_label, fmt);
    defer a_tree.deinit();
    var b_tree = try parseBytes(arena, b_src, b_label, fmt);
    defer b_tree.deinit();

    var set = try syndiff.differ.diff(arena, &a_tree, &b_tree);
    defer set.deinit(arena);

    try syndiff.differ.suppressCascade(&set, &a_tree, &b_tree, arena);
    syndiff.differ.sortByLocation(&set, &a_tree, &b_tree);
    syndiff.differ.filter(&set, kind_filter);

    const opts: syndiff.differ.RenderOptions = .{
        .theme = if (output == .text) theme else syndiff.syntax.off_theme,
        .lang = langFor(fmt),
        .gpa = arena, // enables line-level diff inside MODIFIED bodies
    };

    switch (output) {
        .text => try syndiff.differ.render(&set, &a_tree, &b_tree, stdout, opts),
        .json => try syndiff.differ.renderJson(&set, &a_tree, &b_tree, stdout),
        .yaml => try syndiff.differ.renderYaml(&set, &a_tree, &b_tree, stdout),
        .review_json => try syndiff.review.renderReviewJsonOpts(
            arena,
            &set,
            &a_tree,
            &b_tree,
            stdout,
            .{ .group_by_symbol = group_by_symbol, .complexity_method = complexity_method },
        ),
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
        .json, .review_json => {
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
        .dart => try syndiff.dart_parser.parse(arena, src, path),
        .javascript => try syndiff.js_parser.parse(arena, src, path),
        .typescript => try syndiff.ts_parser.parse(arena, src, path),
        .java => try syndiff.java_parser.parse(arena, src, path),
        .csharp => try syndiff.csharp_parser.parse(arena, src, path),
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
    try std.testing.expectEqual(Format.dart, Format.fromPath("main.dart"));
    try std.testing.expectEqual(Format.javascript, Format.fromPath("foo.js"));
    try std.testing.expectEqual(Format.javascript, Format.fromPath("module.mjs"));
    try std.testing.expectEqual(Format.javascript, Format.fromPath("legacy.cjs"));
    try std.testing.expectEqual(Format.typescript, Format.fromPath("foo.ts"));
    try std.testing.expectEqual(Format.typescript, Format.fromPath("Component.tsx"));
    try std.testing.expectEqual(Format.typescript, Format.fromPath("module.mts"));
    try std.testing.expectEqual(Format.typescript, Format.fromPath("legacy.cts"));
    try std.testing.expectEqual(Format.unknown, Format.fromPath("README.md"));
    try std.testing.expectEqual(Format.unknown, Format.fromPath("noext"));
}

test "parseArgs: zero args -> HEAD vs WT, text output" {
    const r = parseArgs(&.{"syndiff"});
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("HEAD", r.git.ref_a);
    try std.testing.expect(syndiff.git.isWorktree(r.git.ref_b));
    try std.testing.expectEqual(@as(usize, 0), r.git.paths.len);
    try std.testing.expectEqual(OutputFormat.text, r.git.common.output);
}

test "parseArgs: --format=json" {
    const r = parseArgs(&.{ "syndiff", "--format=json" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(OutputFormat.json, r.git.common.output);
}

test "parseArgs: --format yaml (space form)" {
    const r = parseArgs(&.{ "syndiff", "HEAD~1", "--format", "yaml" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqualStrings("HEAD~1", r.git.ref_a);
    try std.testing.expectEqual(OutputFormat.yaml, r.git.common.output);
}

test "parseArgs: -F json shorthand carries through ambiguous_pair" {
    const r = parseArgs(&.{ "syndiff", "-F", "json", "HEAD~2", "HEAD" });
    try std.testing.expect(r == .ambiguous_pair);
    try std.testing.expectEqualStrings("HEAD~2", r.ambiguous_pair.a);
    try std.testing.expectEqualStrings("HEAD", r.ambiguous_pair.b);
    try std.testing.expectEqual(OutputFormat.json, r.ambiguous_pair.common.output);
}

test "parseArgs: bad --format value" {
    const r = parseArgs(&.{ "syndiff", "--format=xml" });
    try std.testing.expect(r == .bad);
}

test "parseArgs: --color=never sets common.color" {
    const r = parseArgs(&.{ "syndiff", "--color=never" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(ColorMode.never, r.git.common.color);
}

test "parseArgs: --no-color shortcut" {
    const r = parseArgs(&.{ "syndiff", "--no-color" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(ColorMode.never, r.git.common.color);
}

test "parseArgs: --color bad value" {
    const r = parseArgs(&.{ "syndiff", "--color=blink" });
    try std.testing.expect(r == .bad);
}

test "parseArgs: --only added,modified" {
    const r = parseArgs(&.{ "syndiff", "--only=added,modified" });
    try std.testing.expect(r == .git);
    try std.testing.expect(r.git.common.filter.added);
    try std.testing.expect(r.git.common.filter.modified);
    try std.testing.expect(!r.git.common.filter.deleted);
    try std.testing.expect(!r.git.common.filter.moved);
}

test "parseArgs: --only with bad kind" {
    const r = parseArgs(&.{ "syndiff", "--only=bogus" });
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

test "parseArgs: --review sets format to review_json" {
    const r = parseArgs(&.{ "syndiff", "--review" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(OutputFormat.review_json, r.git.common.output);
}

test "parseArgs: --format=review-json" {
    const r = parseArgs(&.{ "syndiff", "--format=review-json" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(OutputFormat.review_json, r.git.common.output);
}

test "parseArgs: --group-by symbol" {
    const r = parseArgs(&.{ "syndiff", "--review", "--group-by", "symbol" });
    try std.testing.expect(r == .git);
    try std.testing.expect(r.git.common.group_by_symbol);
}

test "parseArgs: --group-by=symbol equals form" {
    const r = parseArgs(&.{ "syndiff", "--review", "--group-by=symbol" });
    try std.testing.expect(r == .git);
    try std.testing.expect(r.git.common.group_by_symbol);
}

test "parseArgs: --group-by with bad value" {
    const r = parseArgs(&.{ "syndiff", "--group-by=function" });
    try std.testing.expect(r == .bad);
}

test "parseArgs: default group_by_symbol is false" {
    const r = parseArgs(&.{ "syndiff", "--review" });
    try std.testing.expect(r == .git);
    try std.testing.expect(!r.git.common.group_by_symbol);
}

test "parseArgs: default complexity_method is cyclomatic" {
    const r = parseArgs(&.{ "syndiff", "--review" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(syndiff.review.ComplexityMethod.cyclomatic, r.git.common.complexity_method);
}

test "parseArgs: --complexity stmt_count" {
    const r = parseArgs(&.{ "syndiff", "--review", "--complexity", "stmt_count" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(syndiff.review.ComplexityMethod.stmt_count, r.git.common.complexity_method);
}

test "parseArgs: --complexity=cyclomatic equals form" {
    const r = parseArgs(&.{ "syndiff", "--review", "--complexity=cyclomatic" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(syndiff.review.ComplexityMethod.cyclomatic, r.git.common.complexity_method);
}

test "parseArgs: --complexity with bad value" {
    const r = parseArgs(&.{ "syndiff", "--complexity=foo" });
    try std.testing.expect(r == .bad);
}
