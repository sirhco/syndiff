//! Root module of the `syndiff` package.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("ast.zig");
pub const hash = @import("hash.zig");
pub const lex = @import("lex.zig");
pub const json_parser = @import("json_parser.zig");
pub const yaml_parser = @import("yaml_parser.zig");
pub const yaml_anchor_table = @import("yaml_anchor_table.zig");
pub const rust_parser = @import("rust_parser.zig");
pub const go_parser = @import("go_parser.zig");
pub const zig_parser = @import("zig_parser.zig");
pub const dart_parser = @import("dart_parser.zig");
pub const js_parser = @import("js_parser.zig");
pub const ts_parser = @import("ts_parser.zig");
pub const java_parser = @import("java_parser.zig");
pub const csharp_parser = @import("csharp_parser.zig");
pub const differ = @import("differ.zig");
pub const git = @import("git.zig");
pub const syntax = @import("syntax.zig");
pub const line_diff = @import("line_diff.zig");
pub const signature = @import("signature.zig");
pub const sensitivity = @import("sensitivity.zig");
pub const rename = @import("rename.zig");
pub const review = @import("review.zig");
pub const test_pair = @import("test_pair.zig");
pub const symbols = @import("symbols.zig");
pub const complexity = @import("complexity.zig");

pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

test {
    std.testing.refAllDecls(@This());
    _ = ast;
    _ = hash;
    _ = lex;
    _ = json_parser;
    _ = yaml_parser;
    _ = yaml_anchor_table;
    _ = rust_parser;
    _ = go_parser;
    _ = zig_parser;
    _ = dart_parser;
    _ = js_parser;
    _ = ts_parser;
    _ = java_parser;
    _ = csharp_parser;
    _ = differ;
    _ = git;
    _ = syntax;
    _ = line_diff;
    _ = signature;
    _ = sensitivity;
    _ = rename;
    _ = review;
    _ = test_pair;
    _ = symbols;
    _ = complexity;
}
