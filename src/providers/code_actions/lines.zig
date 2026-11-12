//! Line, indentation, comment, and YAML DOM span geometry for code-action edits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../yaml/root.zig");
const Node = yaml.Node;
const Selection = @import("model.zig").Selection;

pub const LineSpan = struct {
    start: usize,
    end: usize,
};

pub fn detectEol(text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "\r\n") != null) return "\r\n";
    return "\n";
}

pub fn spaces(a: Allocator, n: usize) ![]const u8 {
    const buf = try a.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// Start of the line containing `offset`.
pub fn lineStart(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0 and text[i - 1] != '\n') : (i -= 1) {}
    return i;
}

/// Index of the `\n` at or after `offset`, or `text.len`.
pub fn lineEnd(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i < text.len and text[i] != '\n') : (i += 1) {}
    return i;
}

/// `end` with any trailing `\n`/`\r` removed. The tree-sitter DOM can extend a
/// sequence's last map to include its trailing newline.
pub fn stripTrailingNewlines(text: []const u8, end: usize) usize {
    var e = @min(end, text.len);
    while (e > 0 and (text[e - 1] == '\n' or text[e - 1] == '\r')) : (e -= 1) {}
    return e;
}

/// The end of the run of blank lines starting at `start` (the start of a line).
pub fn blankRunEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        const le = lineEnd(text, i);
        if (!isBlankLine(text[i..le])) break;
        i = if (le < text.len) le + 1 else text.len;
    }
    return i;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// True when any line in `[start, end)` is a comment line.
pub fn hasCommentLine(text: []const u8, start: usize, end: usize) bool {
    var i = start;
    while (i < end) {
        const le = @min(lineEnd(text, i), end);
        var j = i;
        while (j < le and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
        if (j < le and text[j] == '#') return true;
        i = if (le < end) le + 1 else end;
    }
    return false;
}

/// The start of the run of comment lines directly above `first_line_start`,
/// stopping at a blank line or a non-comment line.
pub fn attachedCommentStart(text: []const u8, first_line_start: usize) usize {
    var start = first_line_start;
    while (start > 0) {
        const prev_start = lineStart(text, start - 1);
        const prev_end = lineEnd(text, prev_start);
        if (!isCommentLine(text[prev_start..prev_end])) break;
        start = prev_start;
    }
    return start;
}

fn isCommentLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i < line.len and line[i] == '#';
}

/// `text[start..end]` with up to `indent` leading whitespace characters removed
/// from each line, preserving line endings.
pub fn dedent(a: Allocator, text: []const u8, start: usize, end: usize, indent: usize) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(a);
    var i = start;
    while (i < end) {
        const le = lineEnd(text, i);
        const line_end = @min(le, end);
        var ws: usize = 0;
        while (i + ws < line_end and (text[i + ws] == ' ' or text[i + ws] == '\t')) : (ws += 1) {}
        const strip = @min(ws, indent);
        try buf.appendSlice(text[i + strip .. line_end]);
        if (le < end) try buf.append('\n');
        i = if (le < end) le + 1 else end;
    }
    return buf.toOwnedSlice();
}

pub fn lineIndent(text: []const u8, line_start: usize) usize {
    var i = line_start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i - line_start;
}

pub fn taskIndent(text: []const u8, task: *Node) usize {
    return lineIndent(text, lineStart(text, task.start));
}

pub fn lineRangeContains(text: []const u8, node: *Node, offset: usize) bool {
    const end = lineEnd(text, stripTrailingNewlines(text, contentEnd(node)));
    return lineStart(text, node.start) <= offset and offset <= end;
}

/// The end of the node's deepest content, ignoring trailing comments that the
/// tree-sitter DOM attaches to a sequence's last map.
pub fn contentEnd(node: *Node) usize {
    switch (node.kind) {
        .map => {
            var end = node.start;
            for (node.items) |pair| end = @max(end, contentEnd(pair));
            return end;
        },
        .seq => {
            var end = node.start;
            for (node.items) |item| end = @max(end, contentEnd(item));
            return end;
        },
        .pair => {
            if (node.val) |v| return contentEnd(v);
            if (node.key) |k| return k.end;
            return node.end;
        },
        else => return node.end,
    }
}

pub fn lineOf(text: []const u8, offset: usize) usize {
    var line: usize = 0;
    const clamped = @min(offset, text.len);
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    return line;
}

/// The selection's start and end lines. A selection ending at the start of a
/// line belongs to the previous line.
pub fn selectionLines(text: []const u8, sel: Selection) LineSpan {
    const start = lineOf(text, sel.start);
    var end = lineOf(text, sel.end);
    if (end > start and sel.end == lineStart(text, sel.end)) end -= 1;
    return .{ .start = start, .end = end };
}

pub fn indexOf(seq: *Node, item: *Node) ?usize {
    for (seq.items, 0..) |it, i| {
        if (it == item) return i;
    }
    return null;
}
