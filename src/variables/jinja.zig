//! Jinja expression scanner.
//!
//! Extracts **root identifiers** from Jinja expressions (`{{ … }}`, `{% … %}`)
//! and from bare-expression bodies (the value of `when`, `loop`, and friends).
//! Only identifiers that name a variable are returned: attribute names
//! (`name` in `user.name`), filter names (`default` in `x | default(y)`), and
//! test names (`defined` in `x is defined`) are skipped, as are Jinja keywords
//! and string literals.
//!
//! Offsets are absolute byte offsets into the document, so callers can map them
//! back to LSP positions without re-scanning.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ident = struct {
    name: []const u8,
    /// Absolute byte offset of the identifier's first byte.
    start: usize,
    /// Absolute byte offset one past the identifier's last byte.
    end: usize,
};

const keywords = [_][]const u8{
    "and",      "or",        "not",      "in",       "is",
    "if",       "else",      "elif",     "endif",    "for",
    "endfor",   "set",       "endset",   "with",     "without",
    "context",  "import",    "from",     "as",       "macro",
    "endmacro", "block",     "endblock", "extends",  "include",
    "filter",   "endfilter", "raw",      "endraw",   "call",
    "endcall",  "do",        "trans",    "endtrans", "pluralize",
    "true",     "false",     "none",     "True",     "False",
    "None",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Scan a scalar's raw source text for Jinja expressions and append every root
/// identifier to `out`. `base` is the absolute offset of `raw` in the document.
pub fn scanScalar(
    allocator: Allocator,
    raw: []const u8,
    base: usize,
    out: *std.array_list.Managed(Ident),
) !void {
    return scanScalarNames(allocator, raw, base, .roots, out);
}

/// Field names read through member access, separately from root identifiers.
pub fn scanScalarFields(allocator: Allocator, raw: []const u8, base: usize, out: *std.array_list.Managed(Ident)) !void {
    return scanScalarNames(allocator, raw, base, .fields, out);
}

const Names = enum { roots, fields };

fn scanScalarNames(allocator: Allocator, raw: []const u8, base: usize, names: Names, out: *std.array_list.Managed(Ident)) !void {
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 1 < raw.len and raw[i] == '{' and raw[i + 1] == '{') {
            const body_start = i + 2;
            const rel = std.mem.indexOf(u8, raw[body_start..], "}}") orelse {
                try scanExpressionNames(allocator, raw[body_start..], base + body_start, names, out);
                return;
            };
            try scanExpressionNames(allocator, raw[body_start .. body_start + rel], base + body_start, names, out);
            i = body_start + rel + 2;
        } else if (i + 1 < raw.len and raw[i] == '{' and raw[i + 1] == '%') {
            const body_start = i + 2;
            const rel = std.mem.indexOf(u8, raw[body_start..], "%}") orelse {
                try scanExpressionNames(allocator, raw[body_start..], base + body_start, names, out);
                return;
            };
            try scanExpressionNames(allocator, raw[body_start .. body_start + rel], base + body_start, names, out);
            i = body_start + rel + 2;
        } else if (i + 1 < raw.len and raw[i] == '{' and raw[i + 1] == '#') {
            const rel = std.mem.indexOf(u8, raw[i + 2 ..], "#}") orelse return;
            i = i + 2 + rel + 2;
        } else {
            i += 1;
        }
    }
}

/// Scan a bare expression body (no `{{ }}` delimiters) for root identifiers.
pub fn scanExpression(
    allocator: Allocator,
    text: []const u8,
    base: usize,
    out: *std.array_list.Managed(Ident),
) !void {
    return scanExpressionNames(allocator, text, base, .roots, out);
}

pub fn scanExpressionFields(allocator: Allocator, text: []const u8, base: usize, out: *std.array_list.Managed(Ident)) !void {
    return scanExpressionNames(allocator, text, base, .fields, out);
}

fn scanExpressionNames(allocator: Allocator, text: []const u8, base: usize, names: Names, out: *std.array_list.Managed(Ident)) !void {
    _ = allocator;
    const Prev = enum { other, dot, pipe, is_test, plugin_name };
    var prev: Prev = .other;
    var can_subscript = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '[' and can_subscript and names == .fields) {
            const start = skipWhitespace(text, i + 1);
            if (start < text.len and (text[start] == '\'' or text[start] == '"')) {
                const end = skipString(text, start);
                const close = skipWhitespace(text, end);
                if (end > start + 1 and text[end - 1] == text[start] and close < text.len and text[close] == ']') {
                    if (!followedByCall(text, close + 1)) try out.append(.{ .name = text[start + 1 .. end - 1], .start = base + start + 1, .end = base + end - 1 });
                    i = close + 1;
                    prev = .other;
                    continue;
                }
            }
        }
        if (c == '\'' or c == '"') {
            i = skipString(text, i);
            prev = .other;
            can_subscript = true;
            continue;
        }
        if (c == '.') {
            i += 1;
            if (prev != .plugin_name) prev = .dot;
            continue;
        }
        if (c == '|') {
            i += 1;
            prev = .pipe;
            continue;
        }
        if (isIdentStart(c)) {
            var j = i;
            while (j < text.len and isIdentChar(text[j])) j += 1;
            const word = text[i..j];
            can_subscript = !isKeyword(word) and prev != .pipe and prev != .is_test and prev != .plugin_name;
            if (std.mem.eql(u8, word, "is")) {
                prev = .is_test;
            } else if (prev == .is_test and std.mem.eql(u8, word, "not")) {
                prev = .is_test;
            } else if (isKeyword(word)) {
                prev = .other;
            } else if (prev == .dot or prev == .pipe or prev == .is_test or prev == .plugin_name) {
                if (prev == .dot and names == .fields and !followedByCall(text, j)) try out.append(.{ .name = word, .start = base + i, .end = base + j });
                prev = if (prev == .dot) .other else .plugin_name;
            } else {
                if (names == .roots) try out.append(.{ .name = word, .start = base + i, .end = base + j });
                prev = .other;
            }
            i = j;
            continue;
        }
        i += 1;
        prev = .other;
        can_subscript = c == ']' or c == ')' or c == '}';
    }
}

fn followedByCall(text: []const u8, start: usize) bool {
    const next = skipWhitespace(text, start);
    return next < text.len and text[next] == '(';
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
}

fn skipString(text: []const u8, start: usize) usize {
    const quote = text[start];
    var i = start + 1;
    while (i < text.len) {
        if (text[i] == '\\' and quote == '"') {
            i += 2;
            continue;
        }
        if (text[i] == quote) return i + 1;
        i += 1;
    }
    return text.len;
}

const testing = std.testing;

fn collect(raw: []const u8) ![]Ident {
    var list = std.array_list.Managed(Ident).init(testing.allocator);
    errdefer list.deinit();
    try scanScalar(testing.allocator, raw, 0, &list);
    return list.toOwnedSlice();
}

fn collectExpr(raw: []const u8) ![]Ident {
    var list = std.array_list.Managed(Ident).init(testing.allocator);
    errdefer list.deinit();
    try scanExpression(testing.allocator, raw, 0, &list);
    return list.toOwnedSlice();
}

test "simple interpolation" {
    const ids = try collect("{{ foo }}");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("foo", ids[0].name);
    try testing.expectEqual(@as(usize, 3), ids[0].start);
    try testing.expectEqual(@as(usize, 6), ids[0].end);
}

test "attribute and filter and test names are skipped" {
    const ids = try collect("{{ user.name | default('x') is defined }}");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("user", ids[0].name);
}

test "subscript identifiers are references" {
    const ids = try collect("{{ foo[bar] }}");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("foo", ids[0].name);
    try testing.expectEqualStrings("bar", ids[1].name);
}

test "is not skips the test name" {
    const ids = try collect("{{ x is not defined }}");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("x", ids[0].name);
}

test "statement blocks" {
    const ids = try collect("{% for item in items %}{{ item }}{% endfor %}");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("item", ids[0].name);
    try testing.expectEqualStrings("items", ids[1].name);
    try testing.expectEqualStrings("item", ids[2].name);
}

test "comments are ignored" {
    const ids = try collect("{# {{ foo }} #}bar");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 0), ids.len);
}

test "bare expression" {
    const ids = try collectExpr("foo == bar and baz");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("foo", ids[0].name);
    try testing.expectEqualStrings("bar", ids[1].name);
    try testing.expectEqualStrings("baz", ids[2].name);
}

test "string literals are skipped" {
    const ids = try collectExpr("foo == 'bar' or baz == \"qux\"");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("foo", ids[0].name);
    try testing.expectEqualStrings("baz", ids[1].name);
}

test "offsets are absolute" {
    const ids = try collect("xx {{ foo }}");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(@as(usize, 6), ids[0].start);
    try testing.expectEqual(@as(usize, 9), ids[0].end);
}
