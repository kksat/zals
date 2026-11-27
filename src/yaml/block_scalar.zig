const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Chomp = enum { clip, strip, keep };

pub const Rendered = struct {
    value: []const u8,
    content_end: usize,
};

const Line = struct {
    text: []const u8,
    indent: usize,
    empty: bool,
    ws_over: bool,
};

pub fn render(allocator: Allocator, text: []const u8, header_start: usize, parent_col: usize) !Rendered {
    var header_end = header_start;
    while (header_end < text.len and text[header_end] != '\n') : (header_end += 1) {}
    const header = text[header_start..header_end];
    const folded = header.len > 0 and header[0] == '>';
    var chomp: Chomp = .clip;
    var indicator: ?usize = null;
    for (header[1..]) |c| {
        if (c == '-') {
            chomp = .strip;
        } else if (c == '+') {
            chomp = .keep;
        } else if (indicator == null and c >= '0' and c <= '9') {
            indicator = c - '0';
        } else break;
    }

    var pos = if (header_end < text.len) header_end + 1 else header_end;
    var content_indent: ?usize = if (indicator) |n| parent_col + n else null;
    var lines = std.ArrayList(Line).empty;
    var last_content_index: ?usize = null;
    var last_content_end: usize = pos;
    var scan_end = pos;

    while (pos < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        var line = text[pos..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const next_pos = if (line_end < text.len) line_end + 1 else text.len;

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
        const blank = indent == line.len;
        if (blank) {
            const ws_over = content_indent != null and line.len > content_indent.?;
            try lines.append(allocator, .{ .text = line, .indent = indent, .empty = !ws_over, .ws_over = ws_over });
            if (ws_over) {
                last_content_index = lines.items.len - 1;
                last_content_end = pos + line.len;
            }
        } else {
            if (content_indent == null) content_indent = indent;
            if (indent < content_indent.?) {
                scan_end = pos;
                break;
            }
            try lines.append(allocator, .{ .text = line, .indent = indent, .empty = false, .ws_over = false });
            last_content_index = lines.items.len - 1;
            last_content_end = pos + line.len;
        }
        pos = next_pos;
        scan_end = pos;
    }

    var trailing: usize = 0;
    var i = last_content_end;
    while (i < scan_end) : (i += 1) {
        if (text[i] == '\n') trailing += 1;
    }

    var buf = std.ArrayList(u8).empty;
    if (lines.items.len > 0) {
        const indent = content_indent orelse 0;
        const stripped = struct {
            fn f(line: Line, at: usize) []const u8 {
                return if (line.text.len > at) line.text[at..] else "";
            }
        }.f;
        if (!folded) {
            const upto = (last_content_index orelse 0) + 1;
            for (lines.items[0..upto], 0..) |line, idx| {
                if (idx > 0) try buf.append(allocator, '\n');
                try buf.appendSlice(allocator, stripped(line, indent));
            }
        } else {
            const upto = (last_content_index orelse 0) + 1;
            try buf.appendSlice(allocator, stripped(lines.items[0], indent));
            var pending: usize = 0;
            var prev_more = lines.items[0].indent > indent;
            for (lines.items[1..upto]) |line| {
                if (line.empty) {
                    pending += 1;
                    continue;
                }
                const more = line.ws_over or line.indent > indent;
                if (pending > 0) {
                    var n = pending + @as(usize, if (more) 1 else 0);
                    while (n > 0) : (n -= 1) try buf.append(allocator, '\n');
                } else if (more or prev_more) {
                    try buf.append(allocator, '\n');
                } else {
                    try buf.append(allocator, ' ');
                }
                try buf.appendSlice(allocator, stripped(line, indent));
                pending = 0;
                prev_more = more;
            }
        }
    }

    switch (chomp) {
        .strip => {},
        .clip => if (trailing > 0) try buf.append(allocator, '\n'),
        .keep => {
            var n = trailing;
            while (n > 0) : (n -= 1) try buf.append(allocator, '\n');
        },
    }

    return .{ .value = try buf.toOwnedSlice(allocator), .content_end = scan_end };
}

test "literal chomping" {
    const a = std.testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "k: |\n  one\n", .want = "one\n" },
        .{ .src = "k: |\n  one\n\n\n", .want = "one\n" },
        .{ .src = "k: |-\n  one\n\n", .want = "one" },
        .{ .src = "k: |+\n  one\n", .want = "one\n" },
        .{ .src = "k: |+\n  one\n\n", .want = "one\n\n" },
        .{ .src = "k: |+\n  one\n\n\n", .want = "one\n\n\n" },
        .{ .src = "k: |+\n  one\n\n\nj: 2\n", .want = "one\n\n\n" },
        .{ .src = "k: |\n  one\n   \n", .want = "one\n \n" },
        .{ .src = "k: |\n  a\n\n  b\n", .want = "a\n\nb\n" },
        .{ .src = "k: |\n  a\n  \n  b\n", .want = "a\n\nb\n" },
        .{ .src = "k: |+\n  one", .want = "one" },
        .{ .src = "k: |\n  one", .want = "one" },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (cases) |case| {
        const r = try render(arena.allocator(), case.src, 3, 0);
        try std.testing.expectEqualStrings(case.want, r.value);
    }
}

test "folded rules" {
    const a = std.testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "k: >\n  one two\n  three\n", .want = "one two three\n" },
        .{ .src = "k: >\n  para one\n\n  para two\n", .want = "para one\npara two\n" },
        .{ .src = "k: >\n  para one\n\n\n  para two\n", .want = "para one\n\npara two\n" },
        .{ .src = "k: >\n  para\n   more indented\n  back\n", .want = "para\n more indented\nback\n" },
        .{ .src = "k: >\n  a\n\n   ind\n  b\n", .want = "a\n\n ind\nb\n" },
        .{ .src = "k: >-\n  a\n\n  b\n", .want = "a\nb" },
        .{ .src = "k: >+\n  a\n\n", .want = "a\n\n" },
        .{ .src = "k: >+\n  a\n\n  b\n", .want = "a\nb\n" },
        .{ .src = "k: >\n  a  \n  b\n", .want = "a   b\n" },
        .{ .src = "k: >\n  a\n   \n  b\n", .want = "a\n \nb\n" },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (cases) |case| {
        const r = try render(arena.allocator(), case.src, 3, 0);
        try std.testing.expectEqualStrings(case.want, r.value);
    }
}

test "indentation indicator" {
    const a = std.testing.allocator;
    const cases = [_]struct { src: []const u8, col: usize, want: []const u8 }{
        .{ .src = "k: |2\n    text\n", .col = 0, .want = "  text\n" },
        .{ .src = "k: |2\n      text\n    more\n", .col = 2, .want = "  text\nmore\n" },
        .{ .src = "- |2\n   text\n", .col = 0, .want = " text\n" },
        .{ .src = "k:\n  - |2\n     x\n", .col = 2, .want = " x\n" },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (cases) |case| {
        const at = std.mem.indexOfScalar(u8, case.src, '|').?;
        const r = try render(arena.allocator(), case.src, at, case.col);
        try std.testing.expectEqualStrings(case.want, r.value);
    }
}
