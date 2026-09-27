//! Owns all open documents. The main thread is the sole mutator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp/types.zig");
const Document = @import("document.zig").Document;
const PositionEncoding = @import("document.zig").PositionEncoding;

pub const DocumentStore = struct {
    allocator: Allocator,
    docs: std.StringHashMap(*Document),
    encoding: PositionEncoding,

    pub fn init(allocator: Allocator, encoding: PositionEncoding) DocumentStore {
        return .{
            .allocator = allocator,
            .docs = std.StringHashMap(*Document).init(allocator),
            .encoding = encoding,
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.docs.deinit();
    }

    pub fn get(self: *DocumentStore, uri: []const u8) ?*Document {
        return self.docs.get(uri);
    }

    pub fn open(
        self: *DocumentStore,
        uri: []const u8,
        language_id: []const u8,
        version: i64,
        text: []const u8,
    ) !*Document {
        if (self.docs.fetchRemove(uri)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
        const doc = try self.allocator.create(Document);
        errdefer self.allocator.destroy(doc);
        doc.* = try Document.init(self.allocator, uri, language_id, version, text, self.encoding);
        errdefer doc.deinit();
        try self.docs.put(doc.uri, doc);
        return doc;
    }

    pub fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    pub fn applyChanges(
        self: *DocumentStore,
        uri: []const u8,
        version: i64,
        changes: []const lsp.TextDocumentContentChangeEvent,
    ) !void {
        const doc = self.docs.get(uri) orelse return error.DocumentNotOpen;
        for (changes) |change| try doc.applyChange(change);
        doc.version = version;
    }

    pub fn count(self: *const DocumentStore) usize {
        return self.docs.count();
    }
};

test "open owns caller buffers and uses the store encoding" {
    var store = DocumentStore.init(std.testing.allocator, .utf8);
    defer store.deinit();
    var uri = "file:///a.yml".*;
    var text = "é".*;
    _ = try store.open(&uri, "ansible", 7, &text);
    @memset(&uri, 'x');
    @memset(&text, 'x');
    const doc = store.get("file:///a.yml").?;
    try std.testing.expectEqualStrings("é", doc.bytes());
    try std.testing.expectEqualStrings("ansible", doc.language_id);
    try std.testing.expectEqual(@as(i64, 7), doc.version);
    try std.testing.expectEqual(PositionEncoding.utf8, doc.encoding);
    try std.testing.expectEqual(lsp.Position{ .line = 0, .character = 2 }, doc.positionAt(2));
}

test "reopening a URI replaces its document without disturbing other documents" {
    var store = DocumentStore.init(std.testing.allocator, .utf16);
    defer store.deinit();
    _ = try store.open("file:///a.yml", "ansible", 1, "old\ntext");
    _ = try store.open("file:///b.yml", "yaml", 2, "other");
    _ = try store.open("file:///a.yml", "yaml", 9, "replacement");
    try std.testing.expectEqual(@as(usize, 2), store.count());
    const replaced = store.get("file:///a.yml").?;
    try std.testing.expectEqualStrings("replacement", replaced.bytes());
    try std.testing.expectEqualStrings("yaml", replaced.language_id);
    try std.testing.expectEqual(@as(i64, 9), replaced.version);
    try std.testing.expectEqual(@as(usize, 1), replaced.lineCount());
    try std.testing.expectEqualStrings("other", store.get("file:///b.yml").?.bytes());
    store.close("file:///a.yml");
    store.close("file:///a.yml");
    store.close("file:///missing.yml");
    try std.testing.expect(store.get("file:///a.yml") == null);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "change batches use the text and line index produced by preceding changes" {
    var store = DocumentStore.init(std.testing.allocator, .utf16);
    defer store.deinit();
    const uri = "file:///a.yml";
    _ = try store.open(uri, "ansible", 1, "old");
    try store.applyChanges(uri, 2, &.{
        .{ .text = "a😀\nold" },
        .{
            .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } },
            .text = "中\nnew",
        },
        .{
            .range = .{ .start = .{ .line = 2, .character = 0 }, .end = .{ .line = 2, .character = 3 } },
            .text = "last",
        },
    });
    const doc = store.get(uri).?;
    try std.testing.expectEqualStrings("a中\nnew\nlast", doc.bytes());
    try std.testing.expectEqual(@as(usize, 3), doc.lineCount());
    try std.testing.expectEqual(@as(i64, 2), doc.version);
}

test "changes require an open document and a rejected range preserves its version" {
    var store = DocumentStore.init(std.testing.allocator, .utf16);
    defer store.deinit();
    const uri = "file:///a.yml";
    try std.testing.expectError(error.DocumentNotOpen, store.applyChanges(uri, 2, &.{.{ .text = "new" }}));
    _ = try store.open(uri, "ansible", 1, "old");
    try std.testing.expectError(error.InvalidRange, store.applyChanges(uri, 2, &.{.{
        .range = .{ .start = .{ .line = 5, .character = 0 }, .end = .{ .line = 5, .character = 1 } },
        .text = "new",
    }}));
    try std.testing.expectEqualStrings("old", store.get(uri).?.bytes());
    try std.testing.expectEqual(@as(i64, 1), store.get(uri).?.version);
    store.close(uri);
    try std.testing.expectError(error.DocumentNotOpen, store.applyChanges(uri, 3, &.{}));
}
