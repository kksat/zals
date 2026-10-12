//! Role references across the Workspace and role hover (ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("../providers/util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const Subject = @import("navigation_subject.zig").Subject;
const RoleRef = @import("../workspace/facts.zig").RoleRef;

/// Every Role reference in the Workspace that can resolve to the same role
/// directory as the cursor. Null when the cursor is not on a role reference.
pub fn references(self: *Server, a: Allocator, subject: *Subject) !?[]const types.Location {
    const forest = subject.parse(a) orelse return null;
    const ref = roles.reference.detect(subject.path, forest.text) orelse return null;
    const own = types.Location{ .uri = subject.doc.uri, .range = subject.doc.rangeFromOffsets(ref.start, ref.end) };
    const path = try paths.uriToPath(a, subject.doc.uri);
    const declared = try yaml.collections.getRoleDeclaredCollections(forest.allocator(), path, subject.path);
    const targets = util.resolveRoleAll(self, a, ref.name, path, declared);
    // Unresolved references have no identity to share, even with another
    // unresolved occurrence of the same spelling.
    if (targets.len == 0) return try a.dupe(types.Location, &.{own});

    const v = (try subject.workspace(self, a)) orelse return try a.dupe(types.Location, &.{own});
    var locs = std.array_list.Managed(types.Location).init(a);
    try locs.append(own);
    for (v.files) |f| {
        if (f.facts.role_refs.len == 0) continue;
        // Build search paths once per file, not per reference. Facts already
        // retain the collections visible at each site from the index/open doc.
        const resolver = util.roleResolver(self, a, f.path, &.{});
        for (f.facts.role_refs) |r| {
            if (std.mem.eql(u8, f.uri, subject.doc.uri) and r.start == ref.start and r.end == ref.end) continue;
            if (!roleRefMatches(resolver, f.path, r, targets)) continue;
            try locs.append(try v.location(f.uri, r.start, r.end));
        }
    }
    std.mem.sort(types.Location, locs.items, {}, lessLocation);
    return try locs.toOwnedSlice();
}

/// The file's search paths are shared; each site supplies its own collections.
pub fn roleRefMatches(base: roles.Resolver, path: []const u8, ref: RoleRef, targets: []const []const u8) bool {
    var resolver = base;
    resolver.declared_collections = ref.declared_collections;
    return overlaps(targets, resolver.resolveAll(ref.name, path));
}

fn overlaps(left: []const []const u8, right: []const []const u8) bool {
    for (left) |x| for (right) |y| {
        if (std.mem.eql(u8, x, y)) return true;
    };
    return false;
}

/// Hover on a role reference: the role's `README.md`, else its unrendered
/// argument specs, else its unrendered `meta/main.yml`, else its name and
/// resolved path. Null when the cursor is not on a role reference.
pub fn hover(self: *Server, a: Allocator, subject: *Subject) !?types.Hover {
    const forest = subject.parse(a) orelse return null;
    const ref = roles.reference.detect(subject.path, forest.text) orelse return null;
    const name = try a.dupe(u8, ref.name);
    const path = try paths.uriToPath(a, subject.doc.uri);
    const collections = yaml.collections.getRoleDeclaredCollections(forest.allocator(), path, subject.path) catch &.{};
    const range = subject.doc.rangeFromOffsets(ref.start, ref.end);

    const dir = util.resolveRole(self, a, name, path, collections) orelse {
        return markdown(range, try std.fmt.allocPrint(a, "**Role** `{s}`\n\nNot found on the role search path.", .{name}));
    };
    return markdown(range, try roleCard(a, name, dir));
}

/// Markdown for a resolved role directory.
pub fn roleCard(a: Allocator, name: []const u8, dir: []const u8) ![]const u8 {
    for ([_][]const u8{ "README.md", "readme.md", "Readme.md" }) |readme| {
        if (readFile(a, &.{ dir, readme })) |text| return text;
    }
    for ([_][]const u8{ "argument_specs.yml", "argument_specs.yaml", "main.yml", "main.yaml" }) |meta| {
        if (readFile(a, &.{ dir, "meta", meta })) |text| {
            return std.fmt.allocPrint(a, "**Role** `{s}` — `meta/{s}`\n\n```yaml\n{s}\n```", .{ name, meta, trimEnd(text) });
        }
    }
    return std.fmt.allocPrint(a, "**Role** `{s}`\n\n`{s}`", .{ name, dir });
}

fn markdown(range: types.Range, text: []const u8) types.Hover {
    return .{ .contents = .{ .kind = .markdown, .value = text }, .range = range };
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

fn lessLocation(_: void, x: types.Location, y: types.Location) bool {
    const order = std.mem.order(u8, x.uri, y.uri);
    if (order != .eq) return order == .lt;
    if (x.range.start.line != y.range.start.line) return x.range.start.line < y.range.start.line;
    return x.range.start.character < y.range.start.character;
}

pub const RoleResult = union(enum) { skip, none, locations: []const types.Location };

/// Jump from a role reference to the role's argument specs, metadata, or main
/// task file. `.none` stops the chain when the cursor is on a role-name
/// position but the role cannot be resolved.
pub fn definition(self: *Server, a: Allocator, subject: *Subject) !RoleResult {
    const forest = subject.parse(a) orelse return .skip;
    const arena = forest.allocator();
    const ref = roles.reference.detect(subject.path, forest.text) orelse return .skip;
    const path = try paths.uriToPath(a, subject.doc.uri);
    const collections = yaml.collections.getRoleDeclaredCollections(arena, path, subject.path) catch &.{};
    var locs = std.array_list.Managed(types.Location).init(a);
    for (util.resolveRoleAll(self, a, ref.name, path, collections)) |dir| {
        const target = roles.targets.definitionTarget(a, dir) orelse continue;
        try locs.append(try util.fileLocation(a, target));
    }
    if (locs.items.len == 0) return .none;
    return .{ .locations = try locs.toOwnedSlice() };
}

pub fn implementation(self: *Server, a: Allocator, subject: *Subject) !?[]const types.Location {
    const forest = subject.parse(a) orelse return null;
    const arena = forest.allocator();
    const ref = roles.reference.detect(subject.path, forest.text) orelse return null;
    const path = try paths.uriToPath(a, subject.doc.uri);
    const collections = yaml.collections.getRoleDeclaredCollections(arena, path, subject.path) catch &.{};
    var locs = std.array_list.Managed(types.Location).init(a);
    for (util.resolveRoleAll(self, a, ref.name, path, collections)) |dir| {
        const target = roles.targets.implementationTarget(a, dir) orelse continue;
        try locs.append(try util.fileLocation(a, target));
    }
    if (locs.items.len == 0) return null;
    return try locs.toOwnedSlice();
}
