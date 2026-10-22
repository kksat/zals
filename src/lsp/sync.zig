//! Document synchronization notifications.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const types = @import("types.zig");
const Server = @import("server.zig").Server;
const providers = @import("../providers/root.zig");
const paths = @import("../paths.zig");
const workspace_session = @import("../workspace/session.zig");

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
            const resolved = workspace_session.resolvedPath(a, path) catch continue;
            self.index.remove(resolved);
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

test "saved and watched symlink paths use the snapshot's resolved membership" {
    const testing = std.testing;
    const Transport = @import("transport.zig").Transport;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("workspace/.git");
    try tmp.dir.symLink("workspace", "linked", .{ .is_directory = true });
    const output = try tmp.dir.createFile("messages", .{ .read = true });
    defer output.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realpathAlloc(a, ".");
    const root = try tmp.dir.realpathAlloc(a, "workspace");
    const path = try std.fs.path.join(a, &.{ root, "site.yml" });
    const uri = try paths.pathToUri(a, try std.fs.path.join(a, &.{ base, "linked/site.yml" }));
    var server = try Server.init(testing.allocator, Transport.init(output, output), null);
    defer server.deinit();
    server.settings.validation_enabled = false;
    try server.applySession(a, .{ .initialize = .{ .folders = &.{try paths.pathToUri(a, root)}, .config = .{} } });
    var td = json_util.obj(a);
    try td.put("uri", json_util.str(uri));
    var saved = json_util.obj(a);
    try saved.put("textDocument", .{ .object = td });
    try tmp.dir.writeFile(.{ .sub_path = "workspace/site.yml", .data = "- hosts: all\n  vars: {saved_value: true}\n" });
    try didSave(&server, a, .{ .object = saved });
    try testing.expectEqualStrings("saved_value", server.index.get(path).?.facts.var_defs[0].name);

    // Deleted files still resolve through the existing symlinked ancestor.
    try tmp.dir.deleteFile("workspace/site.yml");
    var change = json_util.obj(a);
    try change.put("uri", json_util.str(uri));
    try change.put("type", json_util.num(3));
    var changes = std.json.Array.init(a);
    try changes.append(.{ .object = change });
    var watched = json_util.obj(a);
    try watched.put("changes", .{ .array = changes });
    try didChangeWatchedFiles(&server, a, .{ .object = watched });
    try testing.expect(server.index.get(path) == null);

    // A newly created nested marker excludes the file without a session event.
    try tmp.dir.makePath("workspace/nested/.git");
    try tmp.dir.writeFile(.{ .sub_path = "workspace/nested/site.yml", .data = "- hosts: all\n" });
    server.reindexPath(a, try std.fs.path.join(a, &.{ base, "linked/nested/site.yml" }));
    try testing.expectEqual(@as(usize, 0), server.index.count());
}
