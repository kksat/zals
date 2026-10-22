//! Document synchronization notifications.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const types = @import("types.zig");
const Server = @import("server.zig").Server;
const providers = @import("../providers/root.zig");
const paths = @import("../paths.zig");

pub fn didOpen(self: *Server, a: Allocator, params: Value) !void {
    const td = json_util.field(params, "textDocument") orelse return;
    const uri = json_util.string(td, "uri") orelse return;
    const language_id = json_util.string(td, "languageId") orelse "ansible";
    const version = json_util.integer(td, "version") orelse 0;
    const text = json_util.string(td, "text") orelse "";
    _ = try self.documents.open(uri, language_id, version, text);
    providers.validation.publish(self, a, uri) catch {};
}

pub fn didChange(self: *Server, params: Value) !void {
    const td = json_util.field(params, "textDocument") orelse return;
    const uri = json_util.string(td, "uri") orelse return;
    const version = json_util.integer(td, "version") orelse 0;
    const changes = json_util.array(params, "contentChanges") orelse return;

    var events = std.array_list.Managed(types.TextDocumentContentChangeEvent).init(self.allocator);
    defer events.deinit();
    for (changes.items) |c| {
        const text = json_util.string(c, "text") orelse "";
        const range = if (json_util.field(c, "range")) |r| json_util.range(r) else null;
        try events.append(.{ .range = range, .text = text });
    }
    try self.documents.applyChanges(uri, version, events.items);
}

pub fn didClose(self: *Server, params: Value) !void {
    const td = json_util.field(params, "textDocument") orelse return;
    const uri = json_util.string(td, "uri") orelse return;
    self.documents.close(uri);
}

pub fn didSave(self: *Server, a: Allocator, params: Value) !void {
    const td = json_util.field(params, "textDocument") orelse return;
    const uri = json_util.string(td, "uri") orelse return;
    providers.validation.publish(self, a, uri) catch {};
    const path = paths.uriToPath(a, uri) catch return;
    self.reindexPath(a, path);
}

/// Re-index or drop the files named by a watched-file event (ADR-0031).
pub fn didChangeWatchedFiles(self: *Server, a: Allocator, params: Value) !void {
    const changes = json_util.array(params, "changes") orelse return;
    for (changes.items) |c| {
        const uri = json_util.string(c, "uri") orelse continue;
        const kind = json_util.integer(c, "type") orelse 2;
        const path = paths.uriToPath(a, uri) catch continue;
        if (kind == 3) {
            self.index.remove(path);
        } else {
            self.reindexPath(a, path);
        }
    }
}

pub fn didChangeWorkspaceFolders(self: *Server, a: Allocator, params: Value) !void {
    const event = json_util.field(params, "event") orelse return;
    var removed = std.array_list.Managed([]const u8).init(a);
    var added = std.array_list.Managed([]const u8).init(a);
    if (json_util.array(event, "removed")) |items| {
        for (items.items) |f| {
            if (json_util.string(f, "uri")) |uri| try removed.append(uri);
        }
    }
    if (json_util.array(event, "added")) |items| {
        for (items.items) |f| {
            if (json_util.string(f, "uri")) |uri| try added.append(uri);
        }
    }
    try self.applySession(a, .{ .folders_changed = .{ .removed = removed.items, .added = added.items } });
}
