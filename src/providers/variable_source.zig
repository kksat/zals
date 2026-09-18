//! Shared plumbing for the variable providers: the real `FileSource` (open
//! documents first, then disk) and occurrence-to-`Location` conversion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const variables = @import("../variables/root.zig");

/// `FileSource` backed by the server's open documents and the filesystem.
pub const ServerSource = struct {
    server: *Server,

    pub fn source(self: *ServerSource) variables.FileSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn read(ptr: *anyopaque, allocator: Allocator, uri: []const u8) anyerror!?[]const u8 {
        const self: *ServerSource = @ptrCast(@alignCast(ptr));
        if (self.server.documents.get(uri)) |doc| {
            return try allocator.dupe(u8, doc.bytes());
        }
        const path = try variables.scope.uriToPath(allocator, uri);
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        return file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch null;
    }

    fn listDir(ptr: *anyopaque, allocator: Allocator, path: []const u8) anyerror![]const variables.DirEntry {
        _ = ptr;
        var out = std.array_list.Managed(variables.DirEntry).init(allocator);
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return out.toOwnedSlice();
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            try out.append(.{
                .name = try allocator.dupe(u8, entry.name),
                .is_dir = entry.kind == .directory,
            });
        }
        return out.toOwnedSlice();
    }

    const vtable = variables.FileSource.VTable{ .read = read, .listDir = listDir };
};

/// Convert an occurrence to an LSP `Location`, using the open document's
/// position mapping when available and a temporary one otherwise.
pub fn location(
    a: Allocator,
    server: *Server,
    index: *variables.Index,
    o: variables.Occurrence,
) !Value {
    var range: types.Range = undefined;
    if (server.documents.get(o.uri)) |doc| {
        range = doc.rangeFromOffsets(o.start, o.end);
    } else {
        const text = (try index.fileText(a, o.uri)) orelse "";
        var doc = try Document.init(a, o.uri, "ansible", 0, text, server.encoding);
        defer doc.deinit();
        range = doc.rangeFromOffsets(o.start, o.end);
    }

    var loc = json_util.obj(a);
    try loc.put("uri", json_util.str(o.uri));
    var r = json_util.obj(a);
    try r.put("start", posValue(a, range.start));
    try r.put("end", posValue(a, range.end));
    try loc.put("range", .{ .object = r });
    return .{ .object = loc };
}

fn posValue(a: Allocator, p: types.Position) Value {
    var o = json_util.obj(a);
    o.put("line", json_util.num(p.line)) catch {};
    o.put("character", json_util.num(p.character)) catch {};
    return .{ .object = o };
}

/// Deterministic ordering: by URI, then byte offset.
pub fn lessOccurrence(_: void, x: variables.Occurrence, y: variables.Occurrence) bool {
    const order = std.mem.order(u8, x.uri, y.uri);
    if (order == .lt) return true;
    if (order == .gt) return false;
    return x.start < y.start;
}
