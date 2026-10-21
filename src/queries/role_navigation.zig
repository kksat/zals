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
    const v = (try subject.workspace(self, a)) orelse return try a.dupe(types.Location, &.{own});
    const ws_collections = try v.workspaceCollections();
    const targets = util.roleResolverWithCollections(self, a, path, declared, ws_collections).resolveAll(ref.name, path);
    // Unresolved references have no identity to share, even with another
    // unresolved occurrence of the same spelling.
    if (targets.len == 0) return try a.dupe(types.Location, &.{own});

    var locs = std.array_list.Managed(types.Location).init(a);
    try locs.append(own);
    for (v.files) |f| {
        if (f.facts.role_refs.len == 0) continue;
        // Build search paths once per file, not per reference. Facts already
        // retain the collections visible at each site from the index/open doc.
        const resolver = util.roleResolverWithCollections(self, a, f.path, &.{}, ws_collections);
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

    const dir = resolveRoleForSubject(self, a, subject, name, path, collections) orelse {
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

fn resolveRoleAllForSubject(
    self: *Server,
    a: Allocator,
    subject: *Subject,
    name: []const u8,
    referencing_path: []const u8,
    declared_collections: []const []const u8,
) []const []const u8 {
    if (subject.workspace(self, a) catch null) |v| {
        const ws_collections = v.workspaceCollections() catch &.{};
        return util.roleResolverWithCollections(self, a, referencing_path, declared_collections, ws_collections).resolveAll(name, referencing_path);
    }
    return util.resolveRoleAll(self, a, name, referencing_path, declared_collections);
}

fn resolveRoleForSubject(
    self: *Server,
    a: Allocator,
    subject: *Subject,
    name: []const u8,
    referencing_path: []const u8,
    declared_collections: []const []const u8,
) ?[]const u8 {
    const all = resolveRoleAllForSubject(self, a, subject, name, referencing_path, declared_collections);
    return if (all.len > 0) all[0] else null;
}

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
    for (resolveRoleAllForSubject(self, a, subject, ref.name, path, collections)) |dir| {
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
    for (resolveRoleAllForSubject(self, a, subject, ref.name, path, collections)) |dir| {
        const target = roles.targets.implementationTarget(a, dir) orelse continue;
        try locs.append(try util.fileLocation(a, target));
    }
    if (locs.items.len == 0) return null;
    return try locs.toOwnedSlice();
}

const testing = std.testing;

fn testFacts(a: Allocator, path: []const u8, text: []const u8) ![]const RoleRef {
    return (try @import("../workspace/facts.zig").extract(a, path, text)).role_refs;
}

test "role references distinguish same-name roles and join short/FQCN aliases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("collections/ansible_collections/ns/one/roles/web/tasks");
    try tmp.dir.makePath("collections/ansible_collections/ns/two/roles/web/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const cp = try std.fs.path.join(a, &.{ root, "collections" });
    const path = try std.fs.path.join(a, &.{ root, "site.yml" });
    const refs = try testFacts(a, path,
        \\- hosts: all
        \\  collections: [ns.one]
        \\  roles: [web]
        \\- hosts: all
        \\  collections: [ns.two]
        \\  roles: [web]
        \\- hosts: all
        \\  roles: [ns.one.web]
        \\
    );
    try testing.expectEqual(@as(usize, 3), refs.len);
    const base = roles.Resolver{ .allocator = a, .collections_paths = &.{cp}, .workspace_root = root };
    var query = base;
    query.declared_collections = refs[0].declared_collections;
    const targets = query.resolveAll(refs[0].name, path);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expect(roleRefMatches(base, path, refs[0], targets));
    try testing.expect(!roleRefMatches(base, path, refs[1], targets));
    try testing.expect(roleRefMatches(base, path, refs[2], targets));
}

test "requirements collections are install dependencies, not role resolution context" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("collections/ansible_collections/ns/one/roles/web/tasks");
    try tmp.dir.makePath("roles/web/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const cp = try std.fs.path.join(a, &.{ root, "collections" });
    const rp = try std.fs.path.join(a, &.{ root, "roles" });
    const req_path = try std.fs.path.join(a, &.{ root, "requirements.yml" });
    const play_path = try std.fs.path.join(a, &.{ root, "site.yml" });
    const req = (try testFacts(a, req_path,
        \\collections: [ns.one]
        \\roles: [web]
        \\
    ))[0];
    const play_refs = try testFacts(a, play_path,
        \\- hosts: all
        \\  collections: [ns.one]
        \\  roles: [web]
        \\- hosts: all
        \\  roles: [web]
        \\
    );
    try testing.expectEqual(@as(usize, 0), req.declared_collections.len);
    const base = roles.Resolver{ .allocator = a, .roles_paths = &.{rp}, .collections_paths = &.{cp}, .workspace_root = root };
    var query = base;
    query.declared_collections = req.declared_collections;
    const targets = query.resolveAll(req.name, req_path);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ rp, "web" }), targets[0]);
    try testing.expect(!roleRefMatches(base, play_path, play_refs[0], targets));
    try testing.expect(roleRefMatches(base, play_path, play_refs[1], targets));
}

test "ambiguous fallback matches any shared target, not just first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("apps/roles/db/tasks");
    try tmp.dir.makePath("infra/roles/db/tasks");
    try tmp.dir.makePath("apps/playbooks");
    try tmp.dir.makePath("infra/playbooks");
    try tmp.dir.makePath("other");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const apps = try std.fs.path.join(a, &.{ root, "apps", "roles" });
    const infra = try std.fs.path.join(a, &.{ root, "infra", "roles" });
    const unknown_path = try std.fs.path.join(a, &.{ root, "other", "site.yml" });
    const apps_path = try std.fs.path.join(a, &.{ root, "apps", "playbooks", "site.yml" });
    const infra_path = try std.fs.path.join(a, &.{ root, "infra", "playbooks", "site.yml" });
    const base = roles.Resolver{ .allocator = a, .workspace_root = root, .workspace_roles_dirs = &.{ apps, infra } };
    const ref = (try testFacts(a, unknown_path, "- hosts: all\n  roles: [db]\n"))[0];
    const fallback = base.resolveAll(ref.name, unknown_path);
    try testing.expectEqual(@as(usize, 2), fallback.len);
    try testing.expect(roleRefMatches(base, apps_path, ref, fallback));
    try testing.expect(roleRefMatches(base, infra_path, ref, fallback));
    const apps_only = base.resolveAll(ref.name, apps_path);
    try testing.expectEqual(@as(usize, 1), apps_only.len);
    try testing.expect(!roleRefMatches(base, infra_path, ref, apps_only));
}

test "unresolved role reference returns only its own location" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const path = try std.fs.path.join(a, &.{ root, "site.yml" });
    const uri = try paths.pathToUri(a, path);
    var server = try Server.init(testing.allocator, @import("../lsp/transport.zig").Transport.init(std.fs.File.stdin(), std.fs.File.stdout()));
    defer server.deinit();
    _ = try server.documents.open(uri, "ansible", 1, "- hosts: all\n  roles: [missing, missing]\n");
    var subject = Subject.at(&server, .{ .uri = uri, .offset = "- hosts: all\n  roles: [m".len }).?;
    defer subject.deinit();
    const locs = (try references(&server, a, &subject)).?;
    try testing.expectEqual(@as(usize, 1), locs.len);
    try testing.expectEqualStrings(uri, locs[0].uri);
    try testing.expectEqual(@as(u32, 10), locs[0].range.start.character);
    // Even an unresolved candidate may not join a resolved query.
    const base = roles.Resolver{ .allocator = a };
    const candidate = (try testFacts(a, path, "- hosts: all\n  roles: [missing]\n"))[0];
    try testing.expect(!roleRefMatches(base, path, candidate, &.{"/some/role"}));
}

test "role card prefers README, then argument specs, then metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("web/meta");
    try tmp.dir.writeFile(.{ .sub_path = "web/meta/main.yml", .data = "galaxy_info:\n  author: me\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realpathAlloc(a, "web");

    var card = try roleCard(a, "web", dir);
    try testing.expect(std.mem.indexOf(u8, card, "meta/main.yml") != null);
    try testing.expect(std.mem.indexOf(u8, card, "author: me") != null);

    try tmp.dir.writeFile(.{ .sub_path = "web/meta/argument_specs.yml", .data = "argument_specs: {}\n" });
    card = try roleCard(a, "web", dir);
    try testing.expect(std.mem.indexOf(u8, card, "argument_specs: {}") != null);

    try tmp.dir.writeFile(.{ .sub_path = "web/README.md", .data = "# Web role\n" });
    card = try roleCard(a, "web", dir);
    try testing.expectEqualStrings("# Web role\n", card);
}

test "role card falls back to the path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bare/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realpathAlloc(a, "bare");
    const card = try roleCard(a, "bare", dir);
    try testing.expect(std.mem.indexOf(u8, card, dir) != null);
}
