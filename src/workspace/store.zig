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
