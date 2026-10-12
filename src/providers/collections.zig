//! Collection navigation (ADR-0032): go-to-definition, hover, completion, and
//! find-references for Collection references.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");
const wv = @import("workspace_view.zig");

const collection_query = @import("../queries/collection_navigation.zig");
const Subject = @import("../queries/navigation_subject.zig").Subject;
pub const At = collection_query.At;
pub const Known = collection_query.Known;
pub const Definition = collection_query.Definition;
pub const resolve = collection_query.resolve;
pub const workspaceCollections = collection_query.workspaceCollections;
pub const galaxyName = collection_query.galaxyName;
pub const card = collection_query.card;

pub fn refAt(self: *Server, a: Allocator, params: Value) !?At {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return collection_query.refAt(a, &subject);
}

pub fn definition(self: *Server, a: Allocator, params: Value) !Definition {
    const loc = util.cursorAt(self, params) orelse return .skip;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return .skip;
    defer subject.deinit();
    return collection_query.definition(self, a, &subject);
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return collection_query.hover(self, a, &subject);
}

pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return collection_query.references(self, a, &subject);
}

/// Completion at a site that lists collections: every Workspace and
/// Installed collection. Null when the cursor is not at such a site.
pub fn completion(self: *Server, a: Allocator, params: Value) !?[]const types.CompletionItem {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const path = try paths.uriToPath(a, cur.doc.uri);
    if (!isListingSite(cur.path, path)) return null;

    var seen = std.StringHashMap(void).init(a);
    var items = std.array_list.Managed(types.CompletionItem).init(a);
    const ctx = self.projectContext(a, path);
    for (try project_config.collectionsPaths(a, ctx, path)) |cp| {
        const base = try std.fs.path.join(a, &.{ cp, "ansible_collections" });
        var nsdir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch continue;
        defer nsdir.close();
        var it = nsdir.iterate();
        while (it.next() catch null) |ns| {
            if (ns.kind != .directory or ns.name[0] == '.') continue;
            var colldir = nsdir.openDir(ns.name, .{ .iterate = true }) catch continue;
            defer colldir.close();
            var cit = colldir.iterate();
            while (cit.next() catch null) |coll| {
                if (coll.kind != .directory or coll.name[0] == '.') continue;
                const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ ns.name, coll.name });
                if (seen.contains(name)) continue;
                try seen.put(name, {});
                try items.append(.{ .label = name, .kind = .module, .detail = try std.fs.path.join(a, &.{ base, ns.name, coll.name }) });
            }
        }
    }
    if (ctx.workspace_root) |root| {
        var v = try wv.View.init(self, a, root);
        for (try workspaceCollections(a, &v)) |c| {
            if (seen.contains(c.name)) continue;
            try seen.put(c.name, {});
            try items.append(.{ .label = c.name, .kind = .module, .detail = c.dir });
        }
    }
    std.mem.sort(types.CompletionItem, items.items, {}, lessItem);
    return try items.toOwnedSlice();
}

/// Whether the cursor path is a `collections:` entry (string or `name:`), or
/// a `galaxy.yml` `dependencies:` key.
pub fn isListingSite(path: []*yaml.Node, file_path: []const u8) bool {
    const n = path.len;
    if (n < 3) return false;
    // `collections:` string entry.
    if (path[n - 2].isSeq() and keyIs(path[n - 3], "collections")) return true;
    // `collections:` map entry `name:` value.
    if (n >= 5 and keyIs(path[n - 2], "name") and path[n - 2].val == path[n - 1] and
        path[n - 3].isMap() and path[n - 4].isSeq() and keyIs(path[n - 5], "collections")) return true;
    // `galaxy.yml` `dependencies:` key.
    const base = std.fs.path.basename(file_path);
    if (!std.mem.eql(u8, base, "galaxy.yml") and !std.mem.eql(u8, base, "galaxy.yaml")) return false;
    return n >= 4 and path[n - 2].isPair() and path[n - 2].key == path[n - 1] and
        path[n - 3].isMap() and keyIs(path[n - 4], "dependencies");
}

fn keyIs(node: *yaml.Node, key: []const u8) bool {
    if (!node.isPair()) return false;
    const k = node.key orelse return false;
    return std.mem.eql(u8, k.stringValue() orelse "", key);
}

fn lessItem(_: void, x: types.CompletionItem, y: types.CompletionItem) bool {
    return std.mem.order(u8, x.label, y.label) == .lt;
}

const testing = std.testing;

fn siteAt(src: []const u8, needle: []const u8, file: []const u8) !bool {
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    const off = std.mem.indexOf(u8, src, needle).?;
    const p = (try yaml.getPathAt(forest.allocator(), forest.roots[0], off, true)).?;
    return isListingSite(p, file);
}

test "listing sites" {
    try testing.expect(try siteAt("- hosts: all\n  collections:\n    - comm\n", "comm", "/w/site.yml"));
    try testing.expect(try siteAt("collections:\n  - name: comm\n", "comm", "/w/requirements.yml"));
    try testing.expect(try siteAt("dependencies:\n  comm: '1'\n", "comm", "/w/galaxy.yml"));
    try testing.expect(!try siteAt("dependencies:\n  - comm\n", "comm", "/w/roles/r/meta/main.yml"));
    try testing.expect(!try siteAt("- hosts: all\n  tasks:\n    - debug: msg=comm\n", "comm", "/w/site.yml"));
}

test "galaxy name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("acme.web", galaxyName(arena.allocator(), "namespace: acme\nname: web\nversion: 1.0.0\n").?);
}
