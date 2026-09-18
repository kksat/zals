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
