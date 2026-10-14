//! Typed collection navigation (ADR-0032): targets, cards and name groups.
//! Shared metadata resolution also serves unchanged completion/symbol callers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("../providers/util.zig");
const yaml = @import("../yaml/root.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");
const collection_refs = @import("../workspace/collection_refs.zig");
const wv = @import("../providers/workspace_view.zig");
const Subject = @import("navigation_subject.zig").Subject;

pub const At = struct {
    name: []const u8,
    uri: []const u8,
    path: []const u8,
    range: types.Range,
};

/// The Collection reference under the cursor, or null.
pub fn refAt(a: Allocator, subject: *Subject) !?At {
    const path = try paths.uriToPath(a, subject.doc.uri);
    const forest = subject.parse(a) orelse return null;
    for (try collection_refs.collect(a, forest, path)) |r| {
        if (r.start <= subject.offset and subject.offset <= r.end) {
            return .{ .name = r.name, .uri = subject.doc.uri, .path = path, .range = subject.doc.rangeFromOffsets(r.start, r.end) };
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

pub const Known = @import("../roles/resolve.zig").WorkspaceCollection;

/// Metadata-defined collections: the Workspace root, or any directory below
/// `ansible_collections/` within the Workspace's discovered file set.
pub fn workspaceCollections(a: Allocator, v: *wv.View) ![]const Known {
    if (v.collections) |colls| return colls;
    var out = std.array_list.Managed(Known).init(a);
    for (v.files) |f| {
        const base = std.fs.path.basename(f.path);
        if (!std.mem.eql(u8, base, "galaxy.yml") and !std.mem.eql(u8, base, "galaxy.yaml")) continue;
        const dir = std.fs.path.dirname(f.path) orelse continue;
        if (!isWorkspaceCollectionRoot(v.root, dir)) continue;
        const text = try v.text(f.uri);
        const name = galaxyName(a, text) orelse continue;
        try out.append(.{ .name = name, .dir = dir, .metadata_uri = f.uri });
    }
    const colls = try out.toOwnedSlice();
    v.collections = colls;
    return colls;
}

fn isWorkspaceCollectionRoot(root: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, root, dir)) return true;
    if (dir.len <= root.len or !std.mem.startsWith(u8, dir, root) or dir[root.len] != std.fs.path.sep) return false;
    var parts = std.mem.splitScalar(u8, dir[root.len + 1 ..], std.fs.path.sep);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "ansible_collections")) return parts.next() != null;
    }
    return false;
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

pub fn definition(self: *Server, a: Allocator, subject: *Subject) !Definition {
    const at = (try refAt(a, subject)) orelse return .skip;
    const dir = (try resolve(self, a, at.name, at.path)) orelse return .none;
    for ([_][]const u8{ "galaxy.yml", "galaxy.yaml", "MANIFEST.json", "README.md" }) |f| {
        const p = try std.fs.path.join(a, &.{ dir, f });
        if (isFile(p)) return .{ .location = try util.fileLocation(a, p) };
    }
    return .none;
}

/// Hover: `README.md`, else the unrendered `galaxy.yml`, else `MANIFEST.json`.
pub fn hover(self: *Server, a: Allocator, subject: *Subject) !?types.Hover {
    const at = (try refAt(a, subject)) orelse return null;
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
pub fn references(self: *Server, a: Allocator, subject: *Subject) !?[]const types.Location {
    const at = (try refAt(a, subject)) orelse return null;
    const v = (try subject.workspace(self, a)) orelse {
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
