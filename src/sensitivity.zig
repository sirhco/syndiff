//! Heuristic sensitivity tagger. Single byte-scan per change. False positives
//! are explicitly tolerated — the review agent decides relevance.

const std = @import("std");

pub const Tag = enum {
    crypto,
    auth,
    sql,
    shell,
    network,
    fs_io,
    secrets,

    pub fn name(self: Tag) []const u8 {
        return switch (self) {
            .crypto => "crypto",
            .auth => "auth",
            .sql => "sql",
            .shell => "shell",
            .network => "network",
            .fs_io => "fs_io",
            .secrets => "secrets",
        };
    }
};

pub const TagSet = std.EnumSet(Tag);

const Pattern = struct {
    needle: []const u8,
    case_insensitive: bool = false,
    /// If set, the byte before/after the needle must be a non-identifier byte.
    word_boundary: bool = false,
    tag: Tag,
};

const PATTERNS = [_]Pattern{
    .{ .needle = "sha", .word_boundary = true, .tag = .crypto },
    .{ .needle = "md5", .word_boundary = true, .tag = .crypto },
    .{ .needle = "hmac", .word_boundary = true, .tag = .crypto },
    .{ .needle = "aes", .word_boundary = true, .tag = .crypto },
    .{ .needle = "rsa", .word_boundary = true, .tag = .crypto },
    .{ .needle = "bcrypt", .tag = .crypto },
    .{ .needle = "argon2", .tag = .crypto },
    .{ .needle = "encrypt", .tag = .crypto },
    .{ .needle = "decrypt", .tag = .crypto },
    .{ .needle = "password", .case_insensitive = true, .tag = .auth },
    .{ .needle = "token", .case_insensitive = true, .word_boundary = true, .tag = .auth },
    .{ .needle = "jwt", .case_insensitive = true, .tag = .auth },
    .{ .needle = "session", .case_insensitive = true, .word_boundary = true, .tag = .auth },
    .{ .needle = "oauth", .case_insensitive = true, .tag = .auth },
    .{ .needle = "login", .case_insensitive = true, .word_boundary = true, .tag = .auth },
    .{ .needle = "permission", .case_insensitive = true, .tag = .auth },
    .{ .needle = "SELECT ", .tag = .sql },
    .{ .needle = "INSERT ", .tag = .sql },
    .{ .needle = "UPDATE ", .tag = .sql },
    .{ .needle = "DELETE ", .tag = .sql },
    .{ .needle = "DROP ", .tag = .sql },
    .{ .needle = "exec(", .tag = .shell },
    .{ .needle = "os/exec", .tag = .shell },
    .{ .needle = "subprocess", .tag = .shell },
    .{ .needle = "Runtime.getRuntime", .tag = .shell },
    .{ .needle = "http.", .tag = .network },
    .{ .needle = "fetch(", .tag = .network },
    .{ .needle = "axios", .tag = .network },
    .{ .needle = "ioutil.", .tag = .fs_io },
    .{ .needle = "WriteFile", .tag = .fs_io },
    .{ .needle = "removeAll", .tag = .fs_io },
    .{ .needle = "os.Getenv", .tag = .secrets },
    .{ .needle = "process.env.", .tag = .secrets },
    .{ .needle = "apiKey", .case_insensitive = true, .tag = .secrets },
    .{ .needle = "AWS_", .tag = .secrets },
    // Java
    .{ .needle = "MessageDigest", .tag = .crypto },
    .{ .needle = "Cipher", .tag = .crypto },
    .{ .needle = "KeyStore", .tag = .crypto },
    .{ .needle = "SecureRandom", .tag = .crypto },
    .{ .needle = "KeyPairGenerator", .tag = .crypto },
    .{ .needle = "SecretKeySpec", .tag = .crypto },
    .{ .needle = "PreparedStatement", .tag = .sql },
    .{ .needle = "Statement.execute", .tag = .sql },
    .{ .needle = "EntityManager", .tag = .sql },
    .{ .needle = "ProcessBuilder", .tag = .shell },
    .{ .needle = "Runtime.exec", .tag = .shell },
    .{ .needle = "HttpURLConnection", .tag = .network },
    .{ .needle = "URLConnection", .tag = .network },
    .{ .needle = "RestTemplate", .tag = .network },
    .{ .needle = "OkHttpClient", .tag = .network },
    .{ .needle = "FileWriter", .tag = .fs_io },
    .{ .needle = "FileOutputStream", .tag = .fs_io },
    .{ .needle = "Files.write", .tag = .fs_io },
    .{ .needle = "Files.delete", .tag = .fs_io },
    .{ .needle = "System.getenv", .tag = .secrets },
    // C# / .NET
    .{ .needle = "CryptoServiceProvider", .tag = .crypto },
    .{ .needle = "RSACryptoServiceProvider", .tag = .crypto },
    .{ .needle = "AesManaged", .tag = .crypto },
    .{ .needle = "MD5.Create", .tag = .crypto },
    .{ .needle = "SHA256.Create", .tag = .crypto },
    .{ .needle = "SecureString", .tag = .crypto },
    .{ .needle = "ClaimsPrincipal", .tag = .auth },
    .{ .needle = "IdentityUser", .tag = .auth },
    .{ .needle = "SqlCommand", .tag = .sql },
    .{ .needle = "SqlConnection", .tag = .sql },
    .{ .needle = "ExecuteNonQuery", .tag = .sql },
    .{ .needle = "ExecuteReader", .tag = .sql },
    .{ .needle = "DbContext", .tag = .sql },
    .{ .needle = "Process.Start", .tag = .shell },
    .{ .needle = "ProcessStartInfo", .tag = .shell },
    .{ .needle = "HttpClient", .tag = .network },
    .{ .needle = "WebClient", .tag = .network },
    .{ .needle = "WebRequest", .tag = .network },
    .{ .needle = "File.WriteAll", .tag = .fs_io },
    .{ .needle = "FileStream", .tag = .fs_io },
    .{ .needle = "StreamWriter", .tag = .fs_io },
    .{ .needle = "Environment.GetEnvironmentVariable", .tag = .secrets },
    .{ .needle = "ConfigurationManager", .tag = .secrets },
};

pub fn tag(haystack: []const u8) TagSet {
    var set = TagSet.initEmpty();
    for (PATTERNS) |p| {
        if (matches(haystack, p)) set.insert(p.tag);
    }
    return set;
}

fn matches(haystack: []const u8, p: Pattern) bool {
    if (p.case_insensitive) {
        return indexOfCaseInsensitive(haystack, p.needle, p.word_boundary) != null;
    } else {
        return indexOfExact(haystack, p.needle, p.word_boundary) != null;
    }
}

fn indexOfExact(haystack: []const u8, needle: []const u8, word_boundary: bool) ?usize {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            if (!word_boundary) return i;
            const left_ok = i == 0 or !isIdent(haystack[i - 1]);
            const right_ok = i + needle.len == haystack.len or !isIdent(haystack[i + needle.len]);
            if (left_ok and right_ok) return i;
        }
    }
    return null;
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8, word_boundary: bool) ?usize {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            if (!word_boundary) return i;
            const left_ok = i == 0 or !isIdent(haystack[i - 1]);
            const right_ok = i + needle.len == haystack.len or !isIdent(haystack[i + needle.len]);
            if (left_ok and right_ok) return i;
        }
    }
    return null;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "auth + crypto detection" {
    const t = tag("func login(password string) { hmac.New(sha256.New, key) }");
    try std.testing.expect(t.contains(.auth));
    try std.testing.expect(t.contains(.crypto));
    try std.testing.expect(!t.contains(.sql));
}

test "no false positive: 'shadowed' does not trigger crypto via 'sha'" {
    const t = tag("var shadowed = 1");
    try std.testing.expect(!t.contains(.crypto));
}

test "sql case-sensitive: 'SELECT FROM' tags sql" {
    const t = tag("db.Query(\"SELECT * FROM users\")");
    try std.testing.expect(t.contains(.sql));
}

test "sql: lowercase 'select' does NOT tag (intentional)" {
    const t = tag("user.select(filter)");
    try std.testing.expect(!t.contains(.sql));
}
