//! YAML quoting normalization at the expression-scanner boundary.
//! Jinja still sees its own literal escapes unchanged. Every normalized byte
//! retains its original YAML source span, including Unicode escape spellings.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../yaml/dom.zig").Node;
const jinja = @import("jinja.zig");

pub const Names = enum { roots, fields };
const Span = struct { start: usize, end: usize };

/// Append names with original document offsets. Unchanged text is borrowed;
/// names scanned from normalized storage are copied into `a` before it is freed.
pub fn scan(a: Allocator, node: *const Node, text: []const u8, names: Names, bare: bool, out: *std.array_list.Managed(jinja.Ident)) !void {
    if (node.end > text.len or node.start > node.end) return;
    const raw = text[node.start..node.end];
    if (raw.len < 2 or (raw[0] != '\'' and raw[0] != '"') or raw[raw.len - 1] != raw[0]) {
        return scanText(a, raw, node.start, names, bare, out);
    }
    const body = raw[1 .. raw.len - 1];
    const base = node.start + 1;
    const needs_decode = if (raw[0] == '\'') std.mem.indexOf(u8, body, "''") != null else std.mem.indexOfScalar(u8, body, '\\') != null;
    if (!needs_decode) return scanText(a, body, base, names, bare, out);

    var bytes = std.array_list.Managed(u8).init(a);
    defer bytes.deinit();
    var spans = std.array_list.Managed(Span).init(a);
    defer spans.deinit();
    var i: usize = 0;
    while (i < body.len) {
        const start = i;
        var encoded: [4]u8 = undefined;
        var value: []const u8 = body[i .. i + 1];
        i += 1;
        if (raw[0] == '\'' and body[start] == '\'' and i < body.len and body[i] == '\'') {
            i += 1;
        } else if (raw[0] == '"' and body[start] == '\\') {
            // Keep incomplete/invalid editor input as raw text, rather than
            // turning a tolerant YAML parse into a failed navigation request.
            const escape = yamlEscape(body, start, &encoded) orelse return scanText(a, body, base, names, bare, out);
            i = escape.end;
            value = encoded[0..escape.len];
        }
        try bytes.appendSlice(value);
        for (value) |_| try spans.append(.{ .start = base + start, .end = base + i });
    }

    var scanned = std.array_list.Managed(jinja.Ident).init(a);
    defer scanned.deinit();
    // The scanner (including any root-context inspection) sees normalized
    // offsets throughout its scan. Translate only after that scan completes.
    try scanText(a, bytes.items, 0, names, bare, &scanned);
    for (scanned.items) |ident| {
        if (ident.start >= ident.end or ident.end > spans.items.len) continue;
        try out.append(.{
            .name = try a.dupe(u8, ident.name),
            .start = spans.items[ident.start].start,
            .end = spans.items[ident.end - 1].end,
        });
    }
}

fn scanText(a: Allocator, text: []const u8, base: usize, names: Names, bare: bool, out: *std.array_list.Managed(jinja.Ident)) !void {
    if (bare) {
        if (names == .fields) try jinja.scanExpressionFields(a, text, base, out) else try jinja.scanExpression(a, text, base, out);
    } else {
        if (names == .fields) try jinja.scanScalarFields(a, text, base, out) else try jinja.scanScalar(a, text, base, out);
    }
}

/// Decode YAML double-quoted escapes, NOT the Jinja strings they may contain.
/// Escaped physical line breaks join lines and consume following indentation.
fn yamlEscape(body: []const u8, start: usize, encoded: *[4]u8) ?struct { end: usize, len: usize } {
    if (start + 1 >= body.len) return null;
    const code = body[start + 1];
    var end = start + 2;
    if (code == '\n' or code == '\r') {
        if (code == '\r' and end < body.len and body[end] == '\n') end += 1;
        while (end < body.len and (body[end] == ' ' or body[end] == '\t')) : (end += 1) {}
        return .{ .end = end, .len = 0 };
    }
    const point: u21 = switch (code) {
        '0' => 0,
        'a' => 7,
        'b' => 8,
        't', '\t' => 9,
        'n' => 10,
        'v' => 11,
        'f' => 12,
        'r' => 13,
        'e' => 27,
        ' ', '"', '/', '\\' => code,
        'N' => 0x85,
        '_' => 0xa0,
        'L' => 0x2028,
        'P' => 0x2029,
        'x', 'u', 'U' => blk: {
            const width: usize = switch (code) {
                'x' => 2,
                'u' => 4,
                else => 8,
            };
            if (end + width > body.len) return null;
            const value = std.fmt.parseInt(u21, body[end .. end + width], 16) catch return null;
            end += width;
            break :blk value;
        },
        else => return null,
    };
    const len = std.unicode.utf8Encode(point, encoded) catch return null;
    return .{ .end = end, .len = len };
}
