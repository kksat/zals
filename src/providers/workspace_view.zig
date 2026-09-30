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
const roles = @import("../roles/root.zig");
const util = @import("util.zig");
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
                try files.append(try fromDocument(a, root, kv.key, kv.value));
            } else {
                try files.append(.{ .path = e.path, .uri = try paths.pathToUri(a, e.path), .facts = e.facts });
            }
        }
        var rest = open.iterator();
        while (rest.next()) |kv| try files.append(try fromDocument(a, root, kv.key_ptr.*, kv.value_ptr.*));

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

    /// A role's invoking files are selected by resolved directory, not its
    /// basename. Each reference uses its own declared collections and the
    /// referencing file's configured search paths.
    pub fn reachableFiles(self: *View, path: []const u8) !view.Reachability {
        const role_dir = roles.resolve.enclosingRole(path);
        var invokers = std.array_list.Managed([]const u8).init(self.a);
        if (role_dir) |target| {
            for (self.files) |f| {
                if (f.facts.role_refs.len == 0) continue;
                const base = util.roleResolver(self.server, self.a, f.path, &.{});
                for (f.facts.role_refs) |ref| {
                    if (!roleRefResolvesTo(base, f.path, ref, target)) continue;
                    try invokers.append(f.path);
                    break;
                }
            }
        }
        return view.reachableFiles(self.a, self.files, path, role_dir, invokers.items);
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

fn fromDocument(a: Allocator, root: []const u8, path: []const u8, doc: *Document) !File {
    return .{ .path = path, .uri = doc.uri, .facts = try facts_mod.extractIn(a, root, path, doc.bytes()) };
}

fn roleRefResolvesTo(base: roles.Resolver, file_path: []const u8, ref: facts_mod.RoleRef, target: []const u8) bool {
    var resolver = base;
    resolver.declared_collections = ref.declared_collections;
    for (resolver.resolveAll(ref.name, file_path)) |dir| {
        if (std.mem.eql(u8, dir, target)) return true;
    }
    return false;
}

fn under(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 16 * 1024 * 1024) catch null;
}

const testing = std.testing;

test "variable reachability joins short and FQCN role aliases, not colliding basenames" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ansible_collections/ns/first/roles/notify/tasks");
    try tmp.dir.makePath("ansible_collections/ns/second/roles/notify/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const first = try std.fs.path.join(a, &.{ root, "ansible_collections/ns/first/roles/notify" });
    const second = try std.fs.path.join(a, &.{ root, "ansible_collections/ns/second/roles/notify" });
    const play_first = try std.fs.path.join(a, &.{ root, "first.yml" });
    const play_second = try std.fs.path.join(a, &.{ root, "second.yml" });
    const play_alias = try std.fs.path.join(a, &.{ root, "alias.yml" });
    const first_ref = (try facts_mod.extract(a, play_first, "- hosts: all\n  collections: [ns.first]\n  roles: [notify]\n")).role_refs[0];
    const second_ref = (try facts_mod.extract(a, play_second, "- hosts: all\n  collections: [ns.second]\n  roles: [notify]\n")).role_refs[0];
    const alias_ref = (try facts_mod.extract(a, play_alias, "- hosts: all\n  roles: [ns.first.notify]\n")).role_refs[0];
    const resolver = roles.Resolver{ .allocator = a, .collections_paths = &.{root}, .workspace_root = root };
    try testing.expect(roleRefResolvesTo(resolver, play_first, first_ref, first));
    try testing.expect(!roleRefResolvesTo(resolver, play_first, first_ref, second));
    try testing.expect(roleRefResolvesTo(resolver, play_second, second_ref, second));
    try testing.expect(!roleRefResolvesTo(resolver, play_second, second_ref, first));
    try testing.expect(roleRefResolvesTo(resolver, play_alias, alias_ref, first));
}
