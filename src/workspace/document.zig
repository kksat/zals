//! An open text document: UTF-8 bytes plus a line index, with position
//! conversion for the negotiated position encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp/types.zig");

pub const PositionEncoding = enum {
    utf8,
    utf16,

    pub fn unitsPerCodepoint(self: PositionEncoding, cp: u21) u32 {
        return switch (self) {
            .utf8 => utf8Len(cp),
            .utf16 => if (cp > 0xFFFF) 2 else 1,
        };
    }
};

fn utf8Len(cp: u21) u32 {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

pub const Document = struct {
    allocator: Allocator,
    uri: []const u8,
    language_id: []const u8,
    version: i64,
    text: std.array_list.Managed(u8),
    /// Byte offset of the start of each line. Always has at least one entry.
    line_starts: std.array_list.Managed(usize),
    encoding: PositionEncoding,

    pub fn init(
        allocator: Allocator,
        uri: []const u8,
        language_id: []const u8,
        version: i64,
        text: []const u8,
        encoding: PositionEncoding,
    ) !Document {
        var doc = Document{
            .allocator = allocator,
            .uri = try allocator.dupe(u8, uri),
            .language_id = try allocator.dupe(u8, language_id),
            .version = version,
            .text = std.array_list.Managed(u8).init(allocator),
            .line_starts = std.array_list.Managed(usize).init(allocator),
            .encoding = encoding,
        };
        errdefer doc.deinit();
        try doc.text.appendSlice(text);
        try doc.rebuildLineIndex();
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.uri);
        self.allocator.free(self.language_id);
        self.text.deinit();
        self.line_starts.deinit();
    }

    pub fn bytes(self: *const Document) []const u8 {
        return self.text.items;
    }

    pub fn lineCount(self: *const Document) usize {
        return self.line_starts.items.len;
    }

    fn rebuildLineIndex(self: *Document) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(0);
        for (self.text.items, 0..) |b, i| {
            if (b == '\n') try self.line_starts.append(i + 1);
        }
    }

    /// Byte range of `line`, excluding the trailing newline.
    pub fn lineRange(self: *const Document, line: usize) ?struct { start: usize, end: usize } {
        if (line >= self.line_starts.items.len) return null;
        const start = self.line_starts.items[line];
        const end = if (line + 1 < self.line_starts.items.len)
            self.line_starts.items[line + 1]
        else
            self.text.items.len;
        var e = end;
        if (e > start and self.text.items[e - 1] == '\n') e -= 1;
        if (e > start and self.text.items[e - 1] == '\r') e -= 1;
        return .{ .start = start, .end = e };
    }

    /// Convert an LSP position to a byte offset, or null if out of range.
    pub fn offsetAt(self: *const Document, pos: lsp.Position) ?usize {
        const line = pos.line;
        if (line >= self.line_starts.items.len) return null;
        const range = self.lineRange(line) orelse return null;
        var offset = range.start;
        var units: u32 = 0;
        while (offset < range.end and units < pos.character) {
            const cp_len = std.unicode.utf8ByteSequenceLength(self.text.items[offset]) catch 1;
            const cp = std.unicode.utf8Decode(self.text.items[offset .. offset + cp_len]) catch 0xFFFD;
            units += self.encoding.unitsPerCodepoint(cp);
            offset += cp_len;
        }
        return offset;
    }

    /// Convert a byte offset to an LSP position.
    pub fn positionAt(self: *const Document, offset: usize) lsp.Position {
        const clamped = @min(offset, self.text.items.len);
        var lo: usize = 0;
        var hi: usize = self.line_starts.items.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (self.line_starts.items[mid] <= clamped) lo = mid else hi = mid;
        }
        const line_start = self.line_starts.items[lo];
        var units: u32 = 0;
        var i = line_start;
        while (i < clamped) {
            const cp_len = std.unicode.utf8ByteSequenceLength(self.text.items[i]) catch 1;
            const cp = std.unicode.utf8Decode(self.text.items[i .. i + cp_len]) catch 0xFFFD;
            units += self.encoding.unitsPerCodepoint(cp);
            i += cp_len;
        }
        return .{ .line = @intCast(lo), .character = units };
    }

    pub fn rangeFromOffsets(self: *const Document, start: usize, end: usize) lsp.Range {
        return .{ .start = self.positionAt(start), .end = self.positionAt(end) };
    }

    /// Apply an incremental change. A null range replaces the whole document.
    pub fn applyChange(self: *Document, change: lsp.TextDocumentContentChangeEvent) !void {
        if (change.range) |range| {
            const start = self.offsetAt(range.start) orelse return error.InvalidRange;
            const end = self.offsetAt(range.end) orelse return error.InvalidRange;
            if (end < start) return error.InvalidRange;
            try self.text.replaceRange(start, end - start, change.text);
        } else {
            self.text.clearRetainingCapacity();
            try self.text.appendSlice(change.text);
        }
        try self.rebuildLineIndex();
    }
};

test "line index and utf-16 positions" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "file:///t.yml", "ansible", 1, "a\nbb\nccc", .utf16);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.lineCount());
    try std.testing.expectEqual(@as(usize, 0), doc.offsetAt(.{ .line = 0, .character = 0 }).?);
    try std.testing.expectEqual(@as(usize, 2), doc.offsetAt(.{ .line = 1, .character = 0 }).?);
    try std.testing.expectEqual(@as(usize, 5), doc.offsetAt(.{ .line = 2, .character = 0 }).?);
    const pos = doc.positionAt(5);
    try std.testing.expectEqual(@as(u32, 2), pos.line);
    try std.testing.expectEqual(@as(u32, 0), pos.character);
}

test "incremental change" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "file:///t.yml", "ansible", 1, "hello", .utf8);
    defer doc.deinit();
    try doc.applyChange(.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .text = "hi",
    });
    try std.testing.expectEqualStrings("hi", doc.bytes());
}

test "unicode positions round trip in both negotiated encodings" {
    // ASCII, two-byte, three-byte, and astral-plane characters.
    const text = "aé中😀z\nΩ";
    const offsets = [_]usize{ 0, 1, 3, 6, 10, 11, 12, 14 };
    const utf16_columns = [_]u32{ 0, 1, 2, 3, 5, 6, 0, 1 };
    const utf8_columns = [_]u32{ 0, 1, 3, 6, 10, 11, 0, 2 };
    for ([_]PositionEncoding{ .utf8, .utf16 }) |encoding| {
        var doc = try Document.init(std.testing.allocator, "file:///unicode.yml", "ansible", 1, text, encoding);
        defer doc.deinit();
        for (offsets, 0..) |offset, i| {
            const expected = lsp.Position{
                .line = if (i < 6) 0 else 1,
                .character = if (encoding == .utf8) utf8_columns[i] else utf16_columns[i],
            };
            try std.testing.expectEqual(expected, doc.positionAt(offset));
            try std.testing.expectEqual(offset, doc.offsetAt(expected).?);
        }
        try std.testing.expectEqual(lsp.Range{
            .start = .{ .line = 0, .character = if (encoding == .utf8) 6 else 3 },
            .end = .{ .line = 0, .character = if (encoding == .utf8) 10 else 5 },
        }, doc.rangeFromOffsets(6, 10));
    }
}

test "crlf line ranges exclude terminators and retain the final empty line" {
    var doc = try Document.init(std.testing.allocator, "file:///t.yml", "ansible", 1, "a\r\n\r\n中\r\n", .utf16);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 4), doc.lineCount());
    const starts = [_]usize{ 0, 3, 5, 10 };
    const ends = [_]usize{ 1, 3, 8, 10 };
    for (starts, ends, 0..) |start, end, line| {
        const range = doc.lineRange(line).?;
        try std.testing.expectEqual(start, range.start);
        try std.testing.expectEqual(end, range.end);
        // LSP columns beyond the line are clamped before CRLF.
        try std.testing.expectEqual(end, doc.offsetAt(.{ .line = @intCast(line), .character = 100 }).?);
    }
    try std.testing.expect(doc.lineRange(4) == null);
    try std.testing.expect(doc.offsetAt(.{ .line = 4, .character = 0 }) == null);
    try std.testing.expectEqual(lsp.Position{ .line = 3, .character = 0 }, doc.positionAt(100));
}

test "utf-16 edit replaces an astral character without splitting utf-8 bytes" {
    var doc = try Document.init(std.testing.allocator, "file:///t.yml", "ansible", 1, "a😀z", .utf16);
    defer doc.deinit();
    try doc.applyChange(.{
        .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } },
        .text = "中\nnext",
    });
    try std.testing.expectEqualStrings("a中\nnextz", doc.bytes());
    try std.testing.expectEqual(@as(usize, 2), doc.lineCount());
    try std.testing.expectEqual(@as(usize, 5), doc.offsetAt(.{ .line = 1, .character = 0 }).?);
    try std.testing.expectEqual(lsp.Position{ .line = 1, .character = 5 }, doc.positionAt(doc.bytes().len));
}

test "multiline deletion and insertion rebuild the line index" {
    var doc = try Document.init(std.testing.allocator, "file:///t.yml", "ansible", 1, "first\r\nsecond\r\nthird", .utf8);
    defer doc.deinit();
    try doc.applyChange(.{
        .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 2, .character = 2 } },
        .text = "",
    });
    try std.testing.expectEqualStrings("fiird", doc.bytes());
    try std.testing.expectEqual(@as(usize, 1), doc.lineCount());
    try doc.applyChange(.{
        .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 2 } },
        .text = "\nnew\n",
    });
    try std.testing.expectEqualStrings("fi\nnew\nird", doc.bytes());
    try std.testing.expectEqual(@as(usize, 3), doc.lineCount());
    try std.testing.expectEqual(@as(usize, 7), doc.offsetAt(.{ .line = 2, .character = 0 }).?);
}

test "full replacement handles an empty document and discards stale lines" {
    var doc = try Document.init(std.testing.allocator, "file:///t.yml", "ansible", 1, "one\ntwo\n", .utf16);
    defer doc.deinit();
    try doc.applyChange(.{ .text = "" });
    try std.testing.expectEqualStrings("", doc.bytes());
    try std.testing.expectEqual(@as(usize, 1), doc.lineCount());
    try std.testing.expectEqual(lsp.Position{ .line = 0, .character = 0 }, doc.positionAt(100));
    try doc.applyChange(.{ .text = "new\ntext" });
    try std.testing.expectEqualStrings("new\ntext", doc.bytes());
    try std.testing.expectEqual(@as(usize, 2), doc.lineCount());
    try std.testing.expectEqual(@as(usize, 4), doc.offsetAt(.{ .line = 1, .character = 0 }).?);
}

test "invalid edit ranges leave the text and line index unchanged" {
    var doc = try Document.init(std.testing.allocator, "file:///t.yml", "ansible", 1, "one\ntwo", .utf16);
    defer doc.deinit();
    const ranges = [_]lsp.Range{
        .{ .start = .{ .line = 2, .character = 0 }, .end = .{ .line = 2, .character = 1 } },
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 2, .character = 0 } },
        .{ .start = .{ .line = 1, .character = 1 }, .end = .{ .line = 0, .character = 1 } },
    };
    for (ranges) |range| {
        try std.testing.expectError(error.InvalidRange, doc.applyChange(.{ .range = range, .text = "bad" }));
        try std.testing.expectEqualStrings("one\ntwo", doc.bytes());
        try std.testing.expectEqual(@as(usize, 2), doc.lineCount());
        try std.testing.expectEqual(@as(usize, 4), doc.offsetAt(.{ .line = 1, .character = 0 }).?);
    }
}
