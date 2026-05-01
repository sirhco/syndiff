//! Step 2 placeholder. Parses JSON source into an `ast.Tree`.

const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    NotImplemented,
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8, path: []const u8) ParseError!ast.Tree {
    _ = gpa;
    _ = source;
    _ = path;
    return error.NotImplemented;
}
