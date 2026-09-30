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
const collection_refs = @import("../workspace/collection_refs.zig");
const wv = @import("workspace_view.zig");

pub const At = struct {
    name: []const u8,
    uri: []const u8,
    path: []const u8,
    range: types.Range,
};

/// The Collection reference under the cursor, or null.
pub fn refAt(self: *Server, a: Allocator, params: Value) !?At {
    const loc = util.cursorAt(self, params) orelse return null;
    const path = try paths.uriToPath(a, loc.doc.uri);
    var forest = yaml.parse(a, loc.doc.bytes()) catch return null;
    defer forest.deinit();
    for (try collection_refs.collect(a, &forest, path)) |r| {
        if (r.start <= loc.offset and loc.offset <= r.end) {
            return .{ .name = r.name, .uri = loc.doc.uri, .path = path, .range = loc.doc.rangeFromOffsets(r.start, r.end) };
        }
    }
    return null;
}

/// The directory of collection `name` as seen from `file_path`: the
/// collections paths in order, then a Workspace collection whose `galaxy.yml`
/// declares that namespace and name.
pub fn resolve(self: *Server, a: Allocator, name: []const u8, file_path: []const u8) !?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    const ctx = self.projectContext(a, file_path);
    for (try project_config.collectionsPaths(a, ctx, file_path)) |cp| {
        const dir = try std.fs.path.join(a, &.{ cp, "ansible_collections", name[0..dot], name[dot + 1 ..] });
        if (isDir(dir)) return dir;
    }
    if (ctx.workspace_root) |root| {
        var v = try wv.View.init(self, a, root);
        for (try workspaceCollections(a, &v)) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.dir;
        }
    }
    return null;
}

pub const Known = struct { name: []const u8, dir: []const u8 };

/// Collections declared by a `galaxy.yml` in the Workspace.
pub fn workspaceCollections(a: Allocator, v: *wv.View) ![]const Known {
    var out = std.array_list.Managed(Known).init(a);
    for (v.files) |f| {
        const base = std.fs.path.basename(f.path);
        if (!std.mem.eql(u8, base, "galaxy.yml") and !std.mem.eql(u8, base, "galaxy.yaml")) continue;
        const text = try v.text(f.uri);
        const name = galaxyName(a, text) orelse continue;
        try out.append(.{ .name = name, .dir = std.fs.path.dirname(f.path) orelse continue });
    }
    return out.toOwnedSlice();
}

/// `namespace.name` from `galaxy.yml` text.
pub fn galaxyName(a: Allocator, text: []const u8) ?[]const u8 {
    var forest = yaml.parse(a, text) catch return null;
    defer forest.deinit();
    for (forest.roots) |root| {
        if (!root.isMap()) continue;
        const ns = scalarField(root, "namespace") orelse continue;
        const n = scalarField(root, "name") orelse continue;
        return std.fmt.allocPrint(a, "{s}.{s}", .{ ns, n }) catch null;
    }
    return null;
}

fn scalarField(map: *yaml.Node, key: []const u8) ?[]const u8 {
    const p = yaml.dom.findPair(map, key) orelse return null;
    const v = p.val orelse return null;
    return v.stringValue();
}

/// Go-to-definition: `galaxy.yml`, else `MANIFEST.json`, else `README.md`.
/// `.none` when the cursor is on a Collection reference that cannot be
/// resolved.
pub const Definition = union(enum) { skip, none, location: types.Location };

pub fn definition(self: *Server, a: Allocator, params: Value) !Definition {
    const at = (try refAt(self, a, params)) orelse return .skip;
    const dir = (try resolve(self, a, at.name, at.path)) orelse return .none;
    for ([_][]const u8{ "galaxy.yml", "galaxy.yaml", "MANIFEST.json", "README.md" }) |f| {
        const p = try std.fs.path.join(a, &.{ dir, f });
        if (isFile(p)) return .{ .location = try util.fileLocation(a, p) };
    }
    return .none;
}

/// Hover: `README.md`, else the unrendered `galaxy.yml`, else `MANIFEST.json`.
pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const at = (try refAt(self, a, params)) orelse return null;
    const text = if (try resolve(self, a, at.name, at.path)) |dir|
        try card(a, at.name, dir)
    else
        try std.fmt.allocPrint(a, "**Collection** `{s}`\n\nNot found on the collections path.", .{at.name});
    return .{ .contents = .{ .kind = .markdown, .value = text }, .range = at.range };
}

pub fn card(a: Allocator, name: []const u8, dir: []const u8) ![]const u8 {
    for ([_][]const u8{ "README.md", "readme.md" }) |f| {
        if (readFile(a, &.{ dir, f })) |t| return t;
    }
    for ([_][]const u8{ "galaxy.yml", "galaxy.yaml" }) |f| {
        if (readFile(a, &.{ dir, f })) |t| {
            return std.fmt.allocPrint(a, "**Collection** `{s}` — `{s}`\n\n```yaml\n{s}\n```", .{ name, f, trimEnd(t) });
        }
    }
    if (readFile(a, &.{ dir, "MANIFEST.json" })) |t| {
        return std.fmt.allocPrint(a, "**Collection** `{s}` — `MANIFEST.json`\n\n```json\n{s}\n```", .{ name, trimEnd(t) });
    }
    return std.fmt.allocPrint(a, "**Collection** `{s}`\n\n`{s}`", .{ name, dir });
}

/// Every Collection reference in the Workspace with the same name.
pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const at = (try refAt(self, a, params)) orelse return null;
    var v = (try wv.View.forUri(self, a, at.uri)) orelse {
        const one = try a.alloc(types.Location, 1);
        one[0] = .{ .uri = at.uri, .range = at.range };
        return one;
    };
    var locs = std.array_list.Managed(types.Location).init(a);
    for (v.files) |f| {
        for (f.facts.collection_refs) |r| {
            if (std.mem.eql(u8, r.name, at.name)) try locs.append(try v.location(f.uri, r.start, r.end));
        }
    }
    return try locs.toOwnedSlice();
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

fn readFile(a: Allocator, parts: []const []const u8) ?[]const u8 {
    const p = std.fs.path.join(a, parts) catch return null;
    const f = std.fs.cwd().openFile(p, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 256 * 1024) catch null;
}

fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\r\n");
}

fn isDir(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

fn isFile(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
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
