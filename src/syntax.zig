//! Lightweight syntax tokenizer for terminal highlighting.
//!
//! Classifies bytes into token kinds per language, emitting ANSI-wrapped
//! output. When `enabled` is false the original bytes are written verbatim.
//! The tokenizer is forward-only and never fails — unrecognized bytes fall
//! through as `.default`.

const std = @import("std");

pub const Lang = enum {
    none,
    json,
    yaml,
    rust,
    go,
    zig,
    dart,
    javascript,
    typescript,
    java,
};

pub const TokenKind = enum {
    default,
    keyword,
    string,
    number,
    comment,
    punct,
};

pub const Theme = struct {
    enabled: bool,
    keyword: []const u8,
    string: []const u8,
    number: []const u8,
    comment: []const u8,
    punct: []const u8,
    reset: []const u8,
};

pub const default_theme: Theme = .{
    .enabled = true,
    .keyword = "\x1b[35m", // magenta
    .string = "\x1b[32m", // green
    .number = "\x1b[33m", // yellow
    .comment = "\x1b[90m", // bright black (dim)
    .punct = "\x1b[37m", // light grey
    .reset = "\x1b[0m",
};

pub const off_theme: Theme = .{
    .enabled = false,
    .keyword = "",
    .string = "",
    .number = "",
    .comment = "",
    .punct = "",
    .reset = "",
};

const json_keywords = [_][]const u8{ "true", "false", "null" };
const yaml_keywords = [_][]const u8{ "true", "false", "null", "yes", "no", "True", "False", "Null", "YES", "NO" };
const rust_keywords = [_][]const u8{
    "as", "async", "await", "break", "const", "continue", "crate", "dyn",
    "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
    "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
    "self", "Self", "static", "struct", "super", "trait", "true", "type",
    "union", "unsafe", "use", "where", "while", "macro_rules",
};
const go_keywords = [_][]const u8{
    "break", "case", "chan", "const", "continue", "default", "defer",
    "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
    "interface", "map", "package", "range", "return", "select", "struct",
    "switch", "type", "var", "true", "false", "nil", "iota",
};
const zig_keywords = [_][]const u8{
    "addrspace",   "align",    "allowzero", "and",        "anyframe", "anytype",
    "asm",         "async",    "await",     "break",      "callconv", "catch",
    "comptime",    "const",    "continue",  "defer",      "else",     "enum",
    "errdefer",    "error",    "export",    "extern",     "fn",       "for",
    "if",          "inline",   "noalias",   "noinline",   "nosuspend", "opaque",
    "or",          "orelse",   "packed",    "pub",        "resume",   "return",
    "linksection", "struct",   "suspend",   "switch",     "test",     "threadlocal",
    "try",         "union",    "unreachable","usingnamespace","var",   "volatile",
    "while",       "true",     "false",     "null",       "undefined",
};
const dart_keywords = [_][]const u8{
    "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class",
    "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else",
    "enum", "export", "extends", "extension", "external", "factory", "false", "final",
    "finally", "for", "Function", "get", "hide", "if", "implements", "import", "in",
    "interface", "is", "late", "library", "mixin", "new", "null", "of", "on", "operator",
    "part", "required", "rethrow", "return", "set", "show", "static", "super", "switch",
    "sync", "this", "throw", "true", "try", "typedef", "var", "void", "while", "with", "yield",
};
const js_keywords = [_][]const u8{
    "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
    "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
    "from", "function", "get", "if", "import", "in", "instanceof", "let", "new", "null",
    "of", "return", "set", "static", "super", "switch", "this", "throw", "true", "try",
    "typeof", "undefined", "var", "void", "while", "with", "yield",
};
const ts_keywords = [_][]const u8{
    "abstract", "any", "as", "asserts", "async", "await", "bigint", "boolean", "break",
    "case", "catch", "class", "const", "constructor", "continue", "debugger", "declare",
    "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally",
    "for", "from", "function", "get", "global", "if", "implements", "import", "in",
    "infer", "instanceof", "interface", "is", "keyof", "let", "module", "namespace",
    "never", "new", "null", "number", "object", "of", "package", "private", "protected",
    "public", "readonly", "require", "return", "set", "static", "string", "super",
    "switch", "symbol", "this", "throw", "true", "try", "type", "typeof", "undefined",
    "unique", "unknown", "value", "var", "void", "while", "with", "yield",
};
const java_keywords = [_][]const u8{
    "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
    "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
    "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int",
    "interface", "long", "native", "new", "package", "private", "protected", "public",
    "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
    "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false",
    "null", "var", "yield", "record", "sealed", "permits", "non-sealed",
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn keywordsFor(lang: Lang) []const []const u8 {
    return switch (lang) {
        .json => &json_keywords,
        .yaml => &yaml_keywords,
        .rust => &rust_keywords,
        .go => &go_keywords,
        .zig => &zig_keywords,
        .dart => &dart_keywords,
        .javascript => &js_keywords,
        .typescript => &ts_keywords,
        .java => &java_keywords,
        .none => &.{},
    };
}

fn isKeyword(lang: Lang, word: []const u8) bool {
    for (keywordsFor(lang)) |kw| {
        if (std.mem.eql(u8, kw, word)) return true;
    }
    return false;
}

const LineCommentStyle = enum { none, double_slash, hash, double_backslash };
const BlockCommentStyle = enum { none, c_style };

fn lineCommentStyleFor(lang: Lang) LineCommentStyle {
    return switch (lang) {
        .yaml => .hash,
        .rust, .go => .double_slash,
        .zig => .double_slash,
        .dart, .javascript, .typescript, .java => .double_slash,
        .json, .none => .none,
    };
}

fn blockCommentStyleFor(lang: Lang) BlockCommentStyle {
    return switch (lang) {
        .rust, .go, .dart, .javascript, .typescript, .java => .c_style,
        else => .none,
    };
}

fn writeColored(w: *std.Io.Writer, theme: Theme, kind: TokenKind, bytes: []const u8) !void {
    if (!theme.enabled or kind == .default) {
        try w.writeAll(bytes);
        return;
    }
    const code: []const u8 = switch (kind) {
        .keyword => theme.keyword,
        .string => theme.string,
        .number => theme.number,
        .comment => theme.comment,
        .punct => theme.punct,
        .default => "",
    };
    if (code.len == 0) {
        try w.writeAll(bytes);
        return;
    }
    try w.writeAll(code);
    try w.writeAll(bytes);
    try w.writeAll(theme.reset);
}

/// Forward-scan tokenize and emit colored output.
pub fn writeHighlighted(
    lang: Lang,
    src: []const u8,
    writer: *std.Io.Writer,
    theme: Theme,
) !void {
    if (!theme.enabled or lang == .none) {
        try writer.writeAll(src);
        return;
    }

    const line_style = lineCommentStyleFor(lang);
    const block_style = blockCommentStyleFor(lang);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        // Line comment.
        if (line_style != .none and i + 1 < src.len) {
            const ok = switch (line_style) {
                .double_slash => c == '/' and src[i + 1] == '/',
                .hash => c == '#',
                .double_backslash => c == '\\' and src[i + 1] == '\\',
                .none => false,
            };
            if (ok or (line_style == .hash and c == '#')) {
                const start = i;
                while (i < src.len and src[i] != '\n') i += 1;
                try writeColored(writer, theme, .comment, src[start..i]);
                continue;
            }
        }

        // Block comment.
        if (block_style == .c_style and c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            if (i + 1 < src.len) i += 2;
            try writeColored(writer, theme, .comment, src[start..i]);
            continue;
        }

        // Strings.
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1;
                    continue;
                }
                if (src[i] == '"') {
                    i += 1;
                    break;
                }
                if (src[i] == '\n' and lang != .json) break; // unterminated
            }
            try writeColored(writer, theme, .string, src[start..i]);
            continue;
        }
        if ((lang == .go) and c == '`') {
            const start = i;
            i += 1;
            while (i < src.len and src[i] != '`') i += 1;
            if (i < src.len) i += 1;
            try writeColored(writer, theme, .string, src[start..i]);
            continue;
        }
        if ((lang == .yaml) and c == '\'') {
            const start = i;
            i += 1;
            while (i < src.len and src[i] != '\'') i += 1;
            if (i < src.len) i += 1;
            try writeColored(writer, theme, .string, src[start..i]);
            continue;
        }
        if ((lang == .dart or lang == .javascript or lang == .typescript) and c == '\'') {
            const start = i;
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1;
                    continue;
                }
                if (src[i] == '\'') {
                    i += 1;
                    break;
                }
                if (src[i] == '\n') break;
            }
            try writeColored(writer, theme, .string, src[start..i]);
            continue;
        }
        if ((lang == .javascript or lang == .typescript) and c == '`') {
            const start = i;
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1;
                    continue;
                }
                if (src[i] == '`') {
                    i += 1;
                    break;
                }
            }
            try writeColored(writer, theme, .string, src[start..i]);
            continue;
        }
        if ((lang == .rust or lang == .go) and c == '\'') {
            // Char/rune literal — short scan. For Rust, may be a lifetime;
            // skip detection: if 'X' (3 bytes) form, emit as string.
            if (i + 2 < src.len and src[i + 2] == '\'') {
                try writeColored(writer, theme, .string, src[i .. i + 3]);
                i += 3;
                continue;
            }
            // Else fall through.
        }

        // Numbers.
        if (isDigit(c) or (c == '-' and i + 1 < src.len and isDigit(src[i + 1]))) {
            const start = i;
            if (c == '-') i += 1;
            while (i < src.len) : (i += 1) {
                const d = src[i];
                if (!(isDigit(d) or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-' or d == 'x' or d == 'X' or d == '_' or
                    (d >= 'a' and d <= 'f') or (d >= 'A' and d <= 'F')))
                {
                    break;
                }
                // Stop at second `-` if it's not part of exponent.
                if (d == '-' and i > start + 1 and src[i - 1] != 'e' and src[i - 1] != 'E') break;
            }
            try writeColored(writer, theme, .number, src[start..i]);
            continue;
        }

        // Identifiers / keywords.
        if (isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < src.len and isIdentCont(src[i])) i += 1;
            const word = src[start..i];
            const kind: TokenKind = if (isKeyword(lang, word)) .keyword else .default;
            try writeColored(writer, theme, kind, word);
            continue;
        }

        // Default: single byte, no color.
        try writer.writeByte(c);
        i += 1;
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn highlightToString(lang: Lang, src: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHighlighted(lang, src, &w, default_theme);
    return testing.allocator.dupe(u8, buf[0..w.end]);
}

test "no highlighting when theme disabled" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHighlighted(.rust, "fn main() {}", &w, off_theme);
    try testing.expectEqualStrings("fn main() {}", buf[0..w.end]);
}

test "no highlighting when lang is none" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHighlighted(.none, "fn main() {}", &w, default_theme);
    try testing.expectEqualStrings("fn main() {}", buf[0..w.end]);
}

test "rust keywords colored" {
    const out = try highlightToString(.rust, "fn x() {}");
    defer testing.allocator.free(out);
    // Should contain magenta start code around `fn`.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[35m") != null);
}

test "json strings and numbers colored" {
    const out = try highlightToString(.json, "{\"k\":42}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[32m") != null); // string
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[33m") != null); // number
}

test "comments colored" {
    const out = try highlightToString(.rust, "// hi\nfn x() {}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[90m") != null);
}

test "go raw string colored" {
    const out = try highlightToString(.go, "var s = `raw {} string`");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[32m") != null);
}
