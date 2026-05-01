//! Thin wrapper around the `git` CLI. SynDiff shells out rather than parsing
//! `.git/` directly — keeps the binary tiny and benefits from git's full ref
//! resolution (HEAD, HEAD~3, origin/main, abbreviated SHAs, etc.).
//!
//! Sentinel `WORKTREE` (empty string) means "read from the filesystem at the
//! current working directory" — equivalent to git's working-tree-vs-ref diff.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    GitFailed,
    NotARepo,
    FileNotInRef,
} || std.process.RunError || std.mem.Allocator.Error;

/// Empty ref string == working tree (filesystem).
pub const WORKTREE: []const u8 = "";

pub fn isWorktree(ref: []const u8) bool {
    return ref.len == 0;
}

/// True iff cwd is inside a git repo.
pub fn isInRepo(gpa: std.mem.Allocator, io: Io) bool {
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
    }) catch return false;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// True iff `ref` resolves to something git knows about.
pub fn refExists(gpa: std.mem.Allocator, io: Io, ref: []const u8) bool {
    if (isWorktree(ref)) return true;
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--verify", "--quiet", ref },
    }) catch return false;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Returns owned slice of newline-tokenized paths reported by
/// `git diff --name-only`. Caller frees each path and the outer slice.
pub fn listChangedFiles(
    gpa: std.mem.Allocator,
    io: Io,
    ref_a: []const u8,
    ref_b: []const u8,
    path_filter: []const []const u8,
) Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, "git");
    try argv.append(gpa, "diff");
    try argv.append(gpa, "--name-only");
    // `git diff` semantics:
    //   git diff <a> <b>     — between two refs
    //   git diff <a>         — working tree vs <a>
    //   git diff             — working tree vs index (HEAD-ish)
    if (!isWorktree(ref_a)) try argv.append(gpa, ref_a);
    if (!isWorktree(ref_b)) try argv.append(gpa, ref_b);

    if (path_filter.len > 0) {
        try argv.append(gpa, "--");
        for (path_filter) |p| try argv.append(gpa, p);
    }

    const r = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(r.stderr);
    errdefer gpa.free(r.stdout);

    switch (r.term) {
        .exited => |code| if (code != 0) {
            gpa.free(r.stdout);
            return error.GitFailed;
        },
        else => {
            gpa.free(r.stdout);
            return error.GitFailed;
        },
    }

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    var it = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const dup = try gpa.dupe(u8, trimmed);
        try paths.append(gpa, dup);
    }
    gpa.free(r.stdout);

    return paths.toOwnedSlice(gpa);
}

/// Read file contents at a git ref. WORKTREE reads from the filesystem.
/// Returns owned bytes; caller frees.
pub fn readAtRef(
    gpa: std.mem.Allocator,
    io: Io,
    ref: []const u8,
    path: []const u8,
) Error![]u8 {
    if (isWorktree(ref)) {
        const cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(io, path, gpa, .limited(1 << 28)) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotInRef,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GitFailed,
        };
        return bytes;
    }

    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ ref, path });
    defer gpa.free(spec);

    const r = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "show", spec },
        .stdout_limit = .limited(1 << 28),
    });
    defer gpa.free(r.stderr);

    switch (r.term) {
        .exited => |code| if (code != 0) {
            gpa.free(r.stdout);
            return error.FileNotInRef;
        },
        else => {
            gpa.free(r.stdout);
            return error.GitFailed;
        },
    }

    return r.stdout;
}

/// Free the slice returned by `listChangedFiles`.
pub fn freePaths(gpa: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}
