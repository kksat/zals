//! Indent-based YAML subset parser for Ansible playbooks.
//!
//! Sits behind the `YamlParser` seam. Handles block maps/seqs, plain and quoted
//! scalars, comments, `---` markers, and `|` / `>` block scalars. Flow
//! collections (`{}` / `[]`) are kept as scalar text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;

pub const Forest = dom.Forest;

const Line = struct {
    /// Indent of the first non-space character (the `-` if this is a seq item).
    indent: usize,
    has_dash: bool,
    /// Byte offset of the first non-space character.
    start: usize,
    /// Byte offset past the last non-newline character.
    end: usize,
    /// Text after indent and optional `- `.
    body: []const u8,
    /// Byte offset of `body`.
    body_start: usize,
};

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    lines: []const Line,
    i: usize,

    fn peek(self: *Parser) ?Line {
        if (self.i >= self.lines.len) return null;
        return self.lines[self.i];
    }

    fn bump(self: *Parser) void {
        if (self.i < self.lines.len) self.i += 1;
    }

    fn allocNode(self: *Parser, kind: dom.Kind, start: usize, end: usize) !*Node {
        const n = try self.arena.create(Node);
        n.* = .{ .kind = kind, .start = start, .end = end };
        return n;
    }

    fn dupe(self: *Parser, s: []const u8) ![]const u8 {
        return self.arena.dupe(u8, s);
    }
};

pub fn parse(allocator: Allocator, text: []const u8) !Forest {
    var forest = Forest{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .text = text,
        .roots = &.{},
    };
    errdefer forest.deinit();
    const arena = forest.arena.allocator();

    const lines = try collectLines(arena, text);
    var p = Parser{ .arena = arena, .text = text, .lines = lines, .i = 0 };

    var roots = std.array_list.Managed(*Node).init(arena);
    while (p.peek() != null) {
        const root = try parseNode(&p, 0) orelse break;
        try roots.append(root);
        // Skip a following document-end / document-start if present; collectLines
        // already dropped `---` / `...` lines, so the next node is the next doc.
    }
    forest.roots = try roots.toOwnedSlice();
    return forest;
}

fn collectLines(arena: Allocator, text: []const u8) ![]Line {
    var lines = std.array_list.Managed(Line).init(arena);
    var i: usize = 0;
    while (i < text.len) {
        const line_start = i;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        var line_end = i;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        if (i < text.len and text[i] == '\n') i += 1;

        const raw = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < raw.len and (raw[indent] == ' ' or raw[indent] == '\t')) : (indent += 1) {}
        const rest = raw[indent..];
        const trimmed = std.mem.trimRight(u8, rest, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...")) continue;

        var has_dash = false;
        var body = trimmed;
        var body_off: usize = indent;
        if (trimmed[0] == '-' and (trimmed.len == 1 or trimmed[1] == ' ' or trimmed[1] == '\t')) {
            has_dash = true;
            if (trimmed.len == 1) {
                body = &.{};
                body_off = indent + 1;
            } else {
                const after = trimmed[2..];
                const stripped = std.mem.trimLeft(u8, after, " \t");
                body = stripped;
                body_off = indent + 2 + (after.len - stripped.len);
            }
        }
        try lines.append(.{
            .indent = indent,
            .has_dash = has_dash,
            .start = line_start + indent,
            .end = line_start + indent + trimmed.len,
            .body = body,
            .body_start = line_start + body_off,
        });
    }
    return try lines.toOwnedSlice();
}

fn parseNode(p: *Parser, min_indent: usize) anyerror!?*Node {
    const line = p.peek() orelse return null;
    if (line.indent < min_indent) return null;
    if (line.has_dash) return try parseSeq(p, line.indent);
    if (keyColonPos(line.body) != null) return try parseMap(p, line.indent);
    p.bump();
    return try parseScalarFrom(p, line.body, line.body_start, line.end);
}

fn parseSeq(p: *Parser, indent: usize) anyerror!*Node {
    const first = p.peek() orelse return error.UnexpectedEof;
    const seq = try p.allocNode(.seq, first.start, first.end);
    var items = std.array_list.Managed(*Node).init(p.arena);
    while (p.peek()) |line| {
        if (line.indent != indent or !line.has_dash) break;
        const item = try parseSeqItem(p);
        item.parent = seq;
        try items.append(item);
        seq.end = item.end;
    }
    seq.items = try items.toOwnedSlice();
    return seq;
}

fn parseSeqItem(p: *Parser) anyerror!*Node {
    const line = p.peek() orelse return error.UnexpectedEof;
    p.bump();
    if (line.body.len == 0) {
        const child = try parseNode(p, line.indent + 1) orelse
            try p.allocNode(.scalar, line.end, line.end);
        return child;
    }
    if (keyColonPos(line.body) != null) {
        return parseMapStartingAt(p, line, contentIndent(line));
    }
    return try parseScalarFrom(p, line.body, line.body_start, line.end);
}

fn contentIndent(line: Line) usize {
    return line.body_start - (line.start - line.indent);
}

fn parseMap(p: *Parser, indent: usize) anyerror!*Node {
    const first = p.peek() orelse return error.UnexpectedEof;
    return parseMapStartingAt(p, first, indent);
}

fn parseMapStartingAt(p: *Parser, first: Line, indent: usize) anyerror!*Node {
    const map = try p.allocNode(.map, first.start, first.end);
    var pairs = std.array_list.Managed(*Node).init(p.arena);

    // Consume `first` if it is still the current peek.
    if (p.peek()) |cur| {
        if (cur.start == first.start) p.bump();
    }

    var line = first;
    while (true) {
        const pair = try parsePair(p, line, indent) orelse break;
        pair.parent = map;
        try pairs.append(pair);
        map.end = pair.end;

        const next = p.peek() orelse break;
        if (next.indent != indent or next.has_dash) break;
        line = next;
        p.bump();
    }
    map.items = try pairs.toOwnedSlice();
    return map;
}

fn parsePair(p: *Parser, line: Line, indent: usize) anyerror!?*Node {
    const colon = keyColonPos(line.body) orelse {
        // A colon-less line at map indent is an incomplete key with no value
        // (e.g. `ansible.builtin.` while typing). Upstream's YAML parser keeps
        // it as a pair with a null value.
        if (line.body.len == 0 or line.body[0] == '#') return null;
        const key_node = try parseScalarFrom(p, line.body, line.body_start, line.end);
        const pair = try p.allocNode(.pair, key_node.start, key_node.end);
        pair.key = key_node;
        key_node.parent = pair;
        const empty = try emptyScalar(p, line.end);
        empty.parent = pair;
        pair.val = empty;
        return pair;
    };
    const key_raw = std.mem.trimRight(u8, line.body[0..colon], " \t");
    const key_node = try parseScalarFrom(p, key_raw, line.body_start, line.body_start + key_raw.len);

    const pair = try p.allocNode(.pair, key_node.start, key_node.end);
    pair.key = key_node;
    key_node.parent = pair;

    const after = std.mem.trimLeft(u8, line.body[colon + 1 ..], " \t");
    const after_off = line.body_start + colon + 1 + (line.body[colon + 1 ..].len - after.len);

    var value: *Node = undefined;
    if (after.len == 0 or after[0] == '#') {
        if (p.peek()) |next| {
            if (next.indent > indent) {
                value = try parseNode(p, next.indent) orelse
                    try emptyScalar(p, line.end);
            } else {
                value = try emptyScalar(p, line.end);
            }
        } else {
            value = try emptyScalar(p, line.end);
        }
    } else if (after[0] == '|' or after[0] == '>') {
        value = try parseBlockScalar(p, after_off, after, indent);
    } else {
        const comment = unquotedHash(after);
        const scalar_text = if (comment) |c| std.mem.trimRight(u8, after[0..c], " \t") else after;
        value = try parseScalarFrom(p, scalar_text, after_off, after_off + scalar_text.len);
    }
    value.parent = pair;
    pair.val = value;
    pair.end = value.end;
    return pair;
}

fn emptyScalar(p: *Parser, at: usize) !*Node {
    const n = try p.allocNode(.scalar, at, at);
    n.value = "";
    return n;
}

fn parseBlockScalar(p: *Parser, start: usize, header: []const u8, parent_indent: usize) !*Node {
    const folded = header.len > 0 and header[0] == '>';
    const strip = std.mem.indexOfScalar(u8, header, '-') != null;
    const keep = std.mem.indexOfScalar(u8, header, '+') != null;
    var buf = std.array_list.Managed(u8).init(p.arena);
    var end = start;
    while (p.peek()) |line| {
        if (line.indent <= parent_indent and !line.has_dash) break;
        if (buf.items.len > 0) try buf.append(if (folded) ' ' else '\n');
        try buf.appendSlice(p.text[line.start..line.end]);
        end = line.end;
        p.bump();
    }
    // Clip chomping keeps a single trailing newline; `-` strips it, `+` keeps all.
    if (!strip) try buf.append('\n');
    if (keep) try buf.append('\n');
    const n = try p.allocNode(.scalar, start, end);
    n.value = try buf.toOwnedSlice();
    return n;
}

fn parseScalarFrom(p: *Parser, raw: []const u8, start: usize, end: usize) !*Node {
    const n = try p.allocNode(.scalar, start, end);
    n.value = try p.dupe(unquote(raw));
    return n;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')) {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

/// Index of the mapping `:` in `body`, or null.
fn keyColonPos(body: []const u8) ?usize {
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (quote != 0) {
            if (c == quote and (quote != '"' or i == 0 or body[i - 1] != '\\')) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#') return null;
        if (c == ':') {
            // Mapping key only when `:` ends the token or is followed by space/comment.
            // Bare URLs like `http://example.com` are scalars, not keys.
            if (i + 1 == body.len or body[i + 1] == ' ' or body[i + 1] == '\t' or body[i + 1] == '#')
                return i;
        }
    }
    return null;
}

fn unquotedHash(s: []const u8) ?usize {
    var quote: u8 = 0;
    for (s, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#') return i;
    }
    return null;
}

test "parse simple playbook" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: ping
        \\      ping:
        \\
    ;
    var forest = try parse(std.testing.allocator, src);
    defer forest.deinit();
    try std.testing.expectEqual(@as(usize, 1), forest.roots.len);
    const root = forest.roots[0];
    try std.testing.expect(root.isSeq());
    try std.testing.expectEqual(@as(usize, 1), root.items.len);
    const play = root.items[0];
    try std.testing.expect(play.isMap());
    const hosts = dom.findPair(play, "hosts") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("all", hosts.val.?.stringValue().?);
    const tasks = dom.findPair(play, "tasks") orelse return error.TestExpectedEqual;
    try std.testing.expect(tasks.val.?.isSeq());
    const task = tasks.val.?.items[0];
    try std.testing.expect(task.isMap());
    try std.testing.expect(dom.findPair(task, "name") != null);
    try std.testing.expect(dom.findPair(task, "ping") != null);
}

test "parse nested maps and quoted keys" {
    const src =
        \\foo:
        \\  bar: "baz"
        \\  qux: 1
        \\
    ;
    var forest = try parse(std.testing.allocator, src);
    defer forest.deinit();
    const root = forest.roots[0];
    try std.testing.expect(root.isMap());
    const foo = dom.findPair(root, "foo").?;
    try std.testing.expect(foo.val.?.isMap());
    try std.testing.expectEqualStrings("baz", dom.findPair(foo.val.?, "bar").?.val.?.stringValue().?);
}

test "URL scalars are not mapping keys" {
    const src =
        \\- http://example.com
        \\- name: ping
        \\
    ;
    var forest = try parse(std.testing.allocator, src);
    defer forest.deinit();
    const root = forest.roots[0];
    try std.testing.expect(root.isSeq());
    try std.testing.expect(root.items[0].isScalar());
    try std.testing.expectEqualStrings("http://example.com", root.items[0].stringValue().?);
    try std.testing.expect(root.items[1].isMap());
}
