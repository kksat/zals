//! Server glue for workspace-wide queries: the Workspace's files with open
//! documents layered over the index, and offset-to-`Location` mapping
//! (ADR-0031, ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const paths = @import("../paths.zig");
const facts_mod = @import("../workspace/facts.zig");
const discover = @import("../workspace/discover.zig");
pub const view = @import("../workspace/view.zig");

pub const File = view.File;

pub const View = struct {
    server: *Server,
    a: Allocator,
    root: []const u8,
    files: []const File,
    texts: std.StringHashMap([]const u8),

    /// The files of the Workspace rooted at `root`. Open documents replace
    /// their indexed copy, so unsaved edits win.
    pub fn init(server: *Server, a: Allocator, root: []const u8) !View {
        var open = std.StringHashMap(*Document).init(a);
        var it = server.documents.docs.valueIterator();
        while (it.next()) |doc| {
            const p = paths.uriToPath(a, doc.*.uri) catch continue;
            if (!under(p, root)) continue;
            if (!discover.isAnsibleFile(std.fs.path.basename(p))) continue;
            try open.put(p, doc.*);
        }

        var files = std.array_list.Managed(File).init(a);
        for (try server.indexEntries(a, root)) |e| {
            if (open.fetchRemove(e.path)) |kv| {
                try files.append(try fromDocument(a, kv.key, kv.value));
            } else {
                try files.append(.{ .path = e.path, .uri = try paths.pathToUri(a, e.path), .facts = e.facts });
            }
        }
        var rest = open.iterator();
        while (rest.next()) |kv| try files.append(try fromDocument(a, kv.key_ptr.*, kv.value_ptr.*));

        return .{
            .server = server,
            .a = a,
            .root = root,
            .files = try files.toOwnedSlice(),
            .texts = std.StringHashMap([]const u8).init(a),
        };
    }

    /// The Workspace view for the file at `uri`, or null when it has no
    /// session Workspace.
    pub fn forUri(server: *Server, a: Allocator, uri: []const u8) !?View {
        const path = try paths.uriToPath(a, uri);
        const root = server.workspaceRootFor(a, path) orelse return null;
        return try init(server, a, root);
    }

    pub fn location(self: *View, uri: []const u8, start: usize, end: usize) !types.Location {
        if (self.server.documents.get(uri)) |doc| {
            return .{ .uri = uri, .range = doc.rangeFromOffsets(start, end) };
        }
        const body = try self.text(uri);
        var doc = try Document.init(self.a, uri, "ansible", 0, body, self.server.encoding);
        defer doc.deinit();
        return .{ .uri = uri, .range = doc.rangeFromOffsets(start, end) };
    }

    /// Text of `uri`: the open document, else the file on disk (cached).
    pub fn text(self: *View, uri: []const u8) ![]const u8 {
        if (self.server.documents.get(uri)) |doc| return doc.bytes();
        if (self.texts.get(uri)) |t| return t;
        const path = try paths.uriToPath(self.a, uri);
        const t = readFile(self.a, path) orelse "";
        try self.texts.put(uri, t);
        return t;
    }
};

fn fromDocument(a: Allocator, path: []const u8, doc: *Document) !File {
    return .{ .path = path, .uri = doc.uri, .facts = try facts_mod.extract(a, path, doc.bytes()) };
}

fn under(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 16 * 1024 * 1024) catch null;
}
