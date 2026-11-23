const std = @import("std");

pub const Comment = struct {
    start: usize,
    end: usize,
    line: u32,
    text: []const u8,
};

pub const Directive = struct {
    line: u32,
    all: bool,
    rule_ids: []const []const u8,

    pub fn suppresses(self: Directive, rule_id: []const u8) bool {
        if (self.all) return true;
        const family = familyOf(rule_id);
        for (self.rule_ids) |id| {
            if (std.mem.eql(u8, id, rule_id)) return true;
            if (std.mem.eql(u8, id, family)) return true;
        }
        return false;
    }
};

fn familyOf(rule_id: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, rule_id, '[')) |idx| {
        return rule_id[0..idx];
    }
    return rule_id;
}

pub fn extractDirectives(alloc: std.mem.Allocator, comments: []const Comment) ![]const Directive {
    var out = std.ArrayList(Directive).empty;
    for (comments) |comment| {
        if (try parseComment(alloc, comment)) |dir| {
            try out.append(alloc, dir);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseComment(alloc: std.mem.Allocator, comment: Comment) !?Directive {
    var body = comment.text;
    if (body.len > 0 and body[0] == '#') body = body[1..];
    body = std.mem.trim(u8, body, " \t\r\n");

    const marker_idx = findNoqaMarker(body) orelse return null;
    var rest = body[marker_idx + 4 ..];
    if (rest.len > 0 and !isBoundary(rest[0])) return null;
    rest = std.mem.trimLeft(u8, rest, " \t");
    if (rest.len > 0 and rest[0] == ':') {
        rest = std.mem.trimLeft(u8, rest[1..], " \t");
    }
    if (rest.len == 0) {
        return .{ .line = comment.line, .all = true, .rule_ids = &.{} };
    }

    var ids = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeAny(u8, rest, " \t,");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '#') break;
        if (!isRuleToken(tok)) break;
        try ids.append(alloc, tok);
    }
    if (ids.items.len == 0) {
        return .{ .line = comment.line, .all = true, .rule_ids = &.{} };
    }
    return .{
        .line = comment.line,
        .all = false,
        .rule_ids = try ids.toOwnedSlice(alloc),
    };
}

fn findNoqaMarker(s: []const u8) ?usize {
    if (s.len < 4) return null;
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const at_word_start = i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t';
        if (at_word_start and std.ascii.eqlIgnoreCase(s[i .. i + 4], "noqa")) {
            return i;
        }
    }
    return null;
}

fn isBoundary(c: u8) bool {
    return c == ':' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isRuleToken(tok: []const u8) bool {
    for (tok) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/' or c == '[' or c == ']' or c == '.' or c == ':';
        if (!ok) return false;
    }
    return true;
}

pub fn isSuppressed(
    directives: []const Directive,
    rule_id: []const u8,
    node_start_line: u32,
    field_start_line: u32,
) bool {
    for (directives) |dir| {
        const matches_line = dir.line == node_start_line or
            dir.line == field_start_line or
            (node_start_line > 1 and dir.line + 1 == node_start_line);
        if (matches_line and dir.suppresses(rule_id)) return true;
    }
    return false;
}

test "noqa parsing and targeted vs broad matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const comments = [_]Comment{
        .{ .start = 0, .end = 6, .line = 2, .text = "# noqa" },
        .{ .start = 10, .end = 45, .line = 5, .text = "# noqa: no-changed-when name[missing]" },
        .{ .start = 50, .end = 80, .line = 9, .text = "# noqa key-order custom/rule-1" },
        .{ .start = 90, .end = 110, .line = 12, .text = "# ordinary comment" },
    };
    const dirs = try extractDirectives(a, &comments);
    try std.testing.expectEqual(@as(usize, 3), dirs.len);

    try std.testing.expect(isSuppressed(dirs, "any-rule", 2, 2));
    try std.testing.expect(isSuppressed(dirs, "no-changed-when", 5, 5));
    try std.testing.expect(isSuppressed(dirs, "name[missing]", 5, 6));
    try std.testing.expect(!isSuppressed(dirs, "name[template]", 5, 5));
    try std.testing.expect(isSuppressed(dirs, "key-order[task]", 9, 10));
    try std.testing.expect(isSuppressed(dirs, "custom/rule-1", 9, 9));
    try std.testing.expect(!isSuppressed(dirs, "no-tabs", 12, 12));
}
