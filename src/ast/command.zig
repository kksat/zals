const std = @import("std");

pub const CommandAnalysis = struct {
    first_word: []const u8 = "",
    basename: []const u8 = "",
    second_word: []const u8 = "",
    words: []const []const u8 = &.{},
    has_inline_env_var: bool = false,
    has_shell_metachar: bool = false,
    has_pipe: bool = false,
    has_pipefail: bool = false,
    has_multiline: bool = false,
};

pub fn analyze(alloc: std.mem.Allocator, raw: []const u8) !CommandAnalysis {
    var result = CommandAnalysis{};
    if (raw.len == 0) return result;
    result.has_multiline = std.mem.indexOfScalar(u8, std.mem.trim(u8, raw, " \t\r\n"), '\n') != null;

    var tokens = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var has_pipe = false;
    var has_meta = false;

    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\r' or raw[i] == '\n')) : (i += 1) {}
        if (i >= raw.len) break;
        if (raw[i] == '#') {
            while (i < raw.len and raw[i] != '\n') : (i += 1) {}
            continue;
        }

        const start = i;
        in_single = false;
        in_double = false;
        escaped = false;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (!in_single and c == '\\') {
                escaped = true;
                continue;
            }
            if (!in_double and c == '\'') {
                in_single = !in_single;
                continue;
            }
            if (!in_single and c == '"') {
                in_double = !in_double;
                continue;
            }
            if (!in_single and !in_double) {
                if (c == ' ' or c == '\t' or c == '\r' or c == '\n') break;
                if (c == '|') {
                    if (i + 1 < raw.len and raw[i + 1] == '|') {
                        has_meta = true;
                    } else if (i > 0 and raw[i - 1] == '|') {
                        has_meta = true;
                    } else {
                        has_pipe = true;
                        has_meta = true;
                    }
                } else if (c == '&' or c == ';' or c == '<' or c == '>' or c == '$' or c == '`' or c == '*' or c == '?' or c == '[' or c == ']' or c == '~' or c == '(' or c == ')') {
                    has_meta = true;
                }
            } else if (in_double and (c == '$' or c == '`')) {
                has_meta = true;
            }
        }
        const tok = raw[start..i];
        if (tok.len > 0) try tokens.append(alloc, tok);
    }

    result.has_pipe = has_pipe;
    result.has_shell_metachar = has_meta;
    result.has_pipefail = containsPipefail(raw);

    var cmd_idx: usize = 0;
    while (cmd_idx < tokens.items.len and isEnvAssignment(tokens.items[cmd_idx])) : (cmd_idx += 1) {
        result.has_inline_env_var = true;
    }

    if (cmd_idx < tokens.items.len) {
        const first = stripQuotes(tokens.items[cmd_idx]);
        result.first_word = first;
        result.basename = std.fs.path.basename(first);
    }
    if (cmd_idx + 1 < tokens.items.len) {
        result.second_word = stripQuotes(tokens.items[cmd_idx + 1]);
    }
    result.words = try tokens.toOwnedSlice(alloc);
    return result;
}

fn isEnvAssignment(tok: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return false;
    if (eq == 0) return false;
    const key = tok[0..eq];
    if (!(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn stripQuotes(tok: []const u8) []const u8 {
    if (tok.len >= 2 and ((tok[0] == '\'' and tok[tok.len - 1] == '\'') or (tok[0] == '"' and tok[tok.len - 1] == '"'))) {
        return tok[1 .. tok.len - 1];
    }
    return tok;
}

fn containsPipefail(raw: []const u8) bool {
    if (std.mem.indexOf(u8, raw, "set -o pipefail") != null) return true;
    if (std.mem.indexOf(u8, raw, "set -eo pipefail") != null) return true;
    if (std.mem.indexOf(u8, raw, "set -euo pipefail") != null) return true;
    if (std.mem.indexOf(u8, raw, "set -uo pipefail") != null) return true;
    if (std.mem.indexOf(u8, raw, "pipefail") != null and std.mem.indexOf(u8, raw, "set ") != null) return true;
    return false;
}

test "command analysis detects env vars, pipes, pipefail, and basename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r1 = try analyze(a, "FOO=1 /usr/bin/git status");
    try std.testing.expect(r1.has_inline_env_var);
    try std.testing.expectEqualStrings("git", r1.basename);
    try std.testing.expectEqualStrings("status", r1.second_word);
    try std.testing.expect(!r1.has_pipe);

    const r2 = try analyze(a, "cat /etc/passwd | grep root");
    try std.testing.expect(r2.has_pipe);
    try std.testing.expect(r2.has_shell_metachar);
    try std.testing.expect(!r2.has_pipefail);

    const r3 = try analyze(a, "set -o pipefail\ncat /etc/passwd | grep root");
    try std.testing.expect(r3.has_pipe);
    try std.testing.expect(r3.has_pipefail);

    const r4 = try analyze(a, "echo 'a | b'");
    try std.testing.expect(!r4.has_pipe);
    try std.testing.expect(!r4.has_shell_metachar);
}
