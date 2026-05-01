//! Root module of the `syndiff` package.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("ast.zig");
pub const hash = @import("hash.zig");
pub const json_parser = @import("json_parser.zig");
pub const yaml_parser = @import("yaml_parser.zig");
pub const zig_parser = @import("zig_parser.zig");
pub const differ = @import("differ.zig");
pub const git = @import("git.zig");

pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

test {
    std.testing.refAllDecls(@This());
    _ = ast;
    _ = hash;
    _ = json_parser;
    _ = yaml_parser;
    _ = zig_parser;
    _ = differ;
    _ = git;
}
