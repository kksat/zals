//! Document synchronization notifications.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const types = @import("types.zig");
const Server = @import("server.zig").Server;
const providers = @import("../providers/root.zig");

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
}

pub fn didChangeWorkspaceFolders(self: *Server, params: Value) !void {
    const event = json_util.field(params, "event") orelse return;
    if (json_util.array(event, "removed")) |removed| {
        for (removed.items) |f| {
            const uri = json_util.string(f, "uri") orelse continue;
            for (self.root_uris.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing, uri)) {
                    self.allocator.free(existing);
                    _ = self.root_uris.orderedRemove(i);
                    break;
                }
            }
        }
    }
    if (json_util.array(event, "added")) |added| {
        for (added.items) |f| {
            const uri = json_util.string(f, "uri") orelse continue;
            try self.root_uris.append(try self.allocator.dupe(u8, uri));
        }
    }
}
