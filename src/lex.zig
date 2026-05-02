//! Shared skim-lexer primitives reusable across language parsers.
//!
//! These helpers operate on absolute `u32` positions in a source slice and
//! advance past lexical structures (comments, strings, identifiers) without
//! producing tokens. They are intentionally small and stateless so multiple
//! parsers (Rust, Go, Dart, JS/TS, ...) can share them.
const std = @import("std");

pub const StringError = error{Unterminated};

pub const ScanResult = struct {
    start: u32,
    end: u32,
};

test "skipLineComment advances past // through end of line" {
    const src = "// ignore me\nrest";
    const pos = skipLineComment(src, 0);
    try std.testing.expectEqual(@as(u32, 12), pos);
}

/// True for characters that may begin an identifier in the supported source
/// languages: ASCII letters, `_`, and `$`. `$` is included for Dart/JS/TS.
pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_' or
        c == '$';
}

/// True for characters that may continue an identifier: identifier-start chars
/// plus ASCII digits.
pub fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// True for ASCII decimal digits.
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Advance past a `//` line comment, stopping immediately *before* the
/// terminating `\n` (or at EOF). Caller asserts `src[pos..pos+2] == "//"`.
pub fn skipLineComment(src: []const u8, pos: u32) u32 {
    std.debug.assert(pos + 2 <= src.len);
    std.debug.assert(src[pos] == '/' and src[pos + 1] == '/');
    var i: u32 = pos + 2;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    return i;
}

/// Advance past a `/* ... */` block comment, returning the position just
/// after the closing `*/`. When `nested_ok` is true, nested `/* */` pairs
/// must be balanced (Rust-style); otherwise the first `*/` terminates.
/// If the comment is unterminated the position advances to EOF.
/// Caller asserts `src[pos..pos+2] == "/*"`.
pub fn skipBlockComment(src: []const u8, pos: u32, nested_ok: bool) u32 {
    std.debug.assert(pos + 2 <= src.len);
    std.debug.assert(src[pos] == '/' and src[pos + 1] == '*');
    var i: u32 = pos + 2;
    var depth: u32 = 1;
    while (i + 1 < src.len) {
        const c = src[i];
        const n = src[i + 1];
        if (nested_ok and c == '/' and n == '*') {
            depth += 1;
            i += 2;
            continue;
        }
        if (c == '*' and n == '/') {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    // Unterminated — advance to end of input.
    return @intCast(src.len);
}

/// Advance past a `"..."` string literal with backslash escapes, returning
/// the position just after the closing quote. Caller asserts
/// `src[pos] == '"'`.
pub fn skipDoubleQuoteString(src: []const u8, pos: u32) StringError!u32 {
    std.debug.assert(pos < src.len and src[pos] == '"');
    var i: u32 = pos + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            if (i + 1 >= src.len) return error.Unterminated;
            i += 2;
            continue;
        }
        i += 1;
        if (c == '"') return i;
    }
    return error.Unterminated;
}

/// Advance past a `'...'` string literal with backslash escapes, returning
/// the position just after the closing quote. Caller asserts
/// `src[pos] == '\''`.
pub fn skipSingleQuoteString(src: []const u8, pos: u32) StringError!u32 {
    std.debug.assert(pos < src.len and src[pos] == '\'');
    var i: u32 = pos + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            if (i + 1 >= src.len) return error.Unterminated;
            i += 2;
            continue;
        }
        i += 1;
        if (c == '\'') return i;
    }
    return error.Unterminated;
}

/// Advance past a Go-style raw string `` `...` ``, returning the position
/// just after the closing backtick. No escape processing. Caller asserts
/// ``src[pos] == '`' ``.
pub fn skipBacktickRaw(src: []const u8, pos: u32) StringError!u32 {
    std.debug.assert(pos < src.len and src[pos] == '`');
    var i: u32 = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '`') return i + 1;
    }
    return error.Unterminated;
}

/// Try to scan an identifier starting at `pos`. Returns the byte range, or
/// `null` if `pos` is not at an identifier start.
pub fn scanIdent(src: []const u8, pos: u32) ?ScanResult {
    if (pos >= src.len or !isIdentStart(src[pos])) return null;
    var i: u32 = pos + 1;
    while (i < src.len and isIdentCont(src[i])) : (i += 1) {}
    return .{ .start = pos, .end = i };
}

/// True if the bytes at `pos` exactly match `word` and the next byte (if any)
/// is not an identifier-continuation byte (word-boundary check).
pub fn matchKeyword(src: []const u8, pos: u32, word: []const u8) bool {
    if (@as(usize, pos) + word.len > src.len) return false;
    if (!std.mem.eql(u8, src[pos .. pos + word.len], word)) return false;
    const next: u32 = pos + @as(u32, @intCast(word.len));
    if (next < src.len and isIdentCont(src[next])) return false;
    return true;
}

test "skipBlockComment handles nested when allowed" {
    const src = "/* outer /* inner */ still outer */after";
    const pos = skipBlockComment(src, 0, true);
    try std.testing.expectEqual(@as(u32, 35), pos);
}

test "skipBlockComment ignores nesting when disabled" {
    const src = "/* outer /* inner */ tail";
    const pos = skipBlockComment(src, 0, false);
    try std.testing.expectEqual(@as(u32, 20), pos);
}

test "skipDoubleQuoteString handles escape" {
    const src = "\"a\\\"b\"after";
    const pos = try skipDoubleQuoteString(src, 0);
    try std.testing.expectEqual(@as(u32, 6), pos);
}

test "skipBacktickRaw goes to next backtick" {
    const src = "`\nmulti\nline`tail";
    const pos = try skipBacktickRaw(src, 0);
    try std.testing.expectEqual(@as(u32, 13), pos);
}

test "scanIdent picks identifier" {
    const src = "foo_bar123 rest";
    const r = scanIdent(src, 0).?;
    try std.testing.expectEqual(@as(u32, 0), r.start);
    try std.testing.expectEqual(@as(u32, 10), r.end);
}

test "matchKeyword respects word boundary" {
    try std.testing.expect(matchKeyword("fn x", 0, "fn"));
    try std.testing.expect(!matchKeyword("fname", 0, "fn"));
}
