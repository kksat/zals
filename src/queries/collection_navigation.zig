//! Typed collection navigation (ADR-0032): targets, cards and name groups.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const collection_refs = @import("../workspace/collection_refs.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const Subject = @import("navigation_subject.zig").Subject;

pub const At = struct {
    name: []const u8,
    uri: []const u8,
    path: []const u8,
    range: types.Range,
};

/// The Collection reference under the cursor, or null.
pub fn refAt(context: *Context, subject: *Subject) !?At {
    const a = context.allocator;
    const path = try context.pathOf(subject.doc.uri);
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
pub fn resolve(context: *Context, name: []const u8, file_path: []const u8) !?[]const u8 {
    const a = context.allocator;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    for (try context.collectionsPaths(file_path)) |cp| {
        const dir = try std.fs.path.join(a, &.{ cp, "ansible_collections", name[0..dot], name[dot + 1 ..] });
        if (isDir(dir)) return dir;
    }
    if (context.workspaceRoot(file_path)) |root| {
        for (try context.workspaceCollections(try context.files(.{ .workspace = root }))) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.dir;
        }
    }
    return null;
}

/// Go-to-definition: `galaxy.yml`, else `MANIFEST.json`, else `README.md`.
/// `.none` when the cursor is on a Collection reference that cannot be
/// resolved.
pub const Definition = union(enum) { skip, none, location: types.Location };

pub fn definition(context: *Context, subject: *Subject) !Definition {
    const a = context.allocator;
    const at = (try refAt(context, subject)) orelse return .skip;
    const dir = (try resolve(context, at.name, at.path)) orelse return .none;
    for ([_][]const u8{ "galaxy.yml", "galaxy.yaml", "MANIFEST.json", "README.md" }) |f| {
        const p = try std.fs.path.join(a, &.{ dir, f });
        if (isFile(p)) return .{ .location = try context_mod.fileLocation(a, p) };
    }
    return .none;
}

/// Hover: `README.md`, else the unrendered `galaxy.yml`, else `MANIFEST.json`.
pub fn hover(context: *Context, subject: *Subject) !?types.Hover {
    const a = context.allocator;
    const at = (try refAt(context, subject)) orelse return null;
    const text = if (try resolve(context, at.name, at.path)) |dir|
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
pub fn references(context: *Context, subject: *Subject) !?[]const types.Location {
    const a = context.allocator;
    const at = (try refAt(context, subject)) orelse return null;
    const v = (try context.workspaceOf(subject.doc.uri)) orelse {
        const one = try a.alloc(types.Location, 1);
        one[0] = .{ .uri = at.uri, .range = at.range };
        return one;
    };
    var locs = std.array_list.Managed(types.Location).init(a);
    for (v.files) |f| {
        for (f.facts.collection_refs) |r| {
            if (std.mem.eql(u8, r.name, at.name)) try locs.append(try context.location(f.uri, r.start, r.end));
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
