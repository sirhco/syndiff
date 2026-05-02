//! Microbenchmarks for parsers and the differ.
//!
//! Usage: `zig build bench` (run via the `bench` step in build.zig).
//! Produces a one-line-per-scenario summary on stdout:
//!
//!   <scenario> <bytes> <ns> <MB/s>

const std = @import("std");
const Io = std.Io;

const ast = @import("ast.zig");
const json_parser = @import("json_parser.zig");
const yaml_parser = @import("yaml_parser.zig");
const rust_parser = @import("rust_parser.zig");
const go_parser = @import("go_parser.zig");
const zig_parser = @import("zig_parser.zig");
const dart_parser = @import("dart_parser.zig");
const js_parser = @import("js_parser.zig");
const ts_parser = @import("ts_parser.zig");
const differ = @import("differ.zig");

fn genJson(gpa: std.mem.Allocator, n_keys: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '{');
    var i: u32 = 0;
    while (i < n_keys) : (i += 1) {
        if (i != 0) try buf.append(gpa, ',');
        var tmp: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "\"k{d}\":{d}", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    try buf.append(gpa, '}');
    return buf.toOwnedSlice(gpa);
}

fn genYaml(gpa: std.mem.Allocator, n_keys: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < n_keys) : (i += 1) {
        var tmp: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "k{d}: {d}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genGo(gpa: std.mem.Allocator, n_fns: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "package x\n\n");
    var i: u32 = 0;
    while (i < n_fns) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "func F{d}(a int) int {{ return a + {d} }}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genRust(gpa: std.mem.Allocator, n_fns: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < n_fns) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "pub fn f{d}(a: i32) -> i32 {{ a + {d} }}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genZig(gpa: std.mem.Allocator, n_fns: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < n_fns) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "pub fn f{d}(a: i32) i32 {{ return a + {d}; }}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genDart(gpa: std.mem.Allocator, n_fns: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < n_fns) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "int f{d}(int a) {{ return a + {d}; }}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genJs(gpa: std.mem.Allocator, n_fns: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < n_fns) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "function f{d}(a) {{ return a + {d}; }}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genTs(gpa: std.mem.Allocator, n_fns: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < n_fns) : (i += 1) {
        var tmp: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "function f{d}(a: number): number {{ return a + {d}; }}\n", .{ i, i });
        try buf.appendSlice(gpa, s);
    }
    return buf.toOwnedSlice(gpa);
}

fn genZigZ(gpa: std.mem.Allocator, n_fns: u32) ![:0]u8 {
    const bytes = try genZig(gpa, n_fns);
    defer gpa.free(bytes);
    const z = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(z, bytes);
    return z;
}

const ITERATIONS_DEFAULT: u32 = 5;

fn report(w: *Io.Writer, name: []const u8, bytes: usize, ns: u64) !void {
    const mb_per_s: f64 = if (ns == 0) 0.0 else (@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns))) * 1000.0;
    try w.print("{s: <32} {d: >10} bytes  {d: >10} ns  {d: >8.2} MB/s\n", .{ name, bytes, ns, mb_per_s });
}

/// Run `fn_to_bench(input)` `iter` times, return min ns.
fn benchMin(comptime Ctx: type, ctx: Ctx, comptime f: fn (Ctx) anyerror!void, iter: u32, io: Io) !u64 {
    var best: i96 = std.math.maxInt(i96);
    var k: u32 = 0;
    while (k < iter) : (k += 1) {
        const start = Io.Clock.Timestamp.now(io, .awake);
        try f(ctx);
        const end = Io.Clock.Timestamp.now(io, .awake);
        const ns = start.raw.durationTo(end.raw).nanoseconds;
        if (ns < best) best = ns;
    }
    return @intCast(best);
}

const ParseJsonCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseJson(c: ParseJsonCtx) !void {
    var t = try json_parser.parse(c.gpa, c.src, "bench.json");
    t.deinit();
}

const ParseYamlCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseYaml(c: ParseYamlCtx) !void {
    var t = try yaml_parser.parse(c.gpa, c.src, "bench.yaml");
    t.deinit();
}

const ParseGoCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseGo(c: ParseGoCtx) !void {
    var t = try go_parser.parse(c.gpa, c.src, "bench.go");
    t.deinit();
}

const ParseRustCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseRust(c: ParseRustCtx) !void {
    var t = try rust_parser.parse(c.gpa, c.src, "bench.rs");
    t.deinit();
}

const ParseZigCtx = struct {
    gpa: std.mem.Allocator,
    src: [:0]const u8,
};

fn runParseZig(c: ParseZigCtx) !void {
    var t = try zig_parser.parse(c.gpa, c.src, "bench.zig");
    t.deinit();
}

const ParseDartCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseDart(c: ParseDartCtx) !void {
    var t = try dart_parser.parse(c.gpa, c.src, "bench.dart");
    t.deinit();
}

const ParseJsCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseJs(c: ParseJsCtx) !void {
    var t = try js_parser.parse(c.gpa, c.src, "bench.js");
    t.deinit();
}

const ParseTsCtx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
};

fn runParseTs(c: ParseTsCtx) !void {
    var t = try ts_parser.parse(c.gpa, c.src, "bench.ts");
    t.deinit();
}

const DiffJsonCtx = struct {
    gpa: std.mem.Allocator,
    a_src: []const u8,
    b_src: []const u8,
};

fn runDiffJson(c: DiffJsonCtx) !void {
    var a = try json_parser.parse(c.gpa, c.a_src, "a.json");
    defer a.deinit();
    var b = try json_parser.parse(c.gpa, c.b_src, "b.json");
    defer b.deinit();

    var set = try differ.diff(c.gpa, &a, &b);
    defer set.deinit(c.gpa);
    try differ.suppressCascade(&set, &a, &b, c.gpa);
    differ.sortByLocation(&set, &a, &b);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file.interface;

    try stdout.print("# syndiff microbenchmarks (best of {d} runs)\n\n", .{ITERATIONS_DEFAULT});

    const sizes = [_]u32{ 100, 1000, 10000 };

    // JSON parse
    for (sizes) |n| {
        const src = try genJson(arena, n);
        const ns = try benchMin(ParseJsonCtx, .{ .gpa = arena, .src = src }, runParseJson, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "json parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // YAML parse
    for (sizes) |n| {
        const src = try genYaml(arena, n);
        const ns = try benchMin(ParseYamlCtx, .{ .gpa = arena, .src = src }, runParseYaml, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "yaml parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // Go parse
    for (sizes) |n| {
        const src = try genGo(arena, n);
        const ns = try benchMin(ParseGoCtx, .{ .gpa = arena, .src = src }, runParseGo, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "go parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // Rust parse
    for (sizes) |n| {
        const src = try genRust(arena, n);
        const ns = try benchMin(ParseRustCtx, .{ .gpa = arena, .src = src }, runParseRust, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "rust parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // Zig parse
    for (sizes) |n| {
        const src = try genZigZ(arena, n);
        const ns = try benchMin(ParseZigCtx, .{ .gpa = arena, .src = src }, runParseZig, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "zig parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // Dart parse
    for (sizes) |n| {
        const src = try genDart(arena, n);
        const ns = try benchMin(ParseDartCtx, .{ .gpa = arena, .src = src }, runParseDart, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "dart parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // JavaScript parse
    for (sizes) |n| {
        const src = try genJs(arena, n);
        const ns = try benchMin(ParseJsCtx, .{ .gpa = arena, .src = src }, runParseJs, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "js parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // TypeScript parse
    for (sizes) |n| {
        const src = try genTs(arena, n);
        const ns = try benchMin(ParseTsCtx, .{ .gpa = arena, .src = src }, runParseTs, ITERATIONS_DEFAULT, io);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "ts parse n={d}", .{n});
        try report(stdout, name, src.len, ns);
    }
    try stdout.writeByte('\n');

    // JSON diff (same content — exercises hash maps).
    for (sizes) |n| {
        const src = try genJson(arena, n);
        const ns = try benchMin(
            DiffJsonCtx,
            .{ .gpa = arena, .a_src = src, .b_src = src },
            runDiffJson,
            ITERATIONS_DEFAULT,
            io,
        );
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "json diff n={d} (no changes)", .{n});
        try report(stdout, name, src.len * 2, ns);
    }

    try stdout.flush();
}
