//! Role references across the Workspace and role hover (ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const RoleRef = @import("../workspace/facts.zig").RoleRef;

const Subject = @import("../queries/navigation_subject.zig").Subject;
const role_query = @import("../queries/role_navigation.zig");
pub const roleCard = role_query.roleCard;
const roleRefMatches = role_query.roleRefMatches;

pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return role_query.references(self, a, &subject);
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return role_query.hover(self, a, &subject);
}

const parameters = @import("../roles/parameters.zig");
pub const Parameter = parameters.Parameter;
pub const parameterAt = parameters.parameterAt;

const navigation = @import("../queries/variable_navigation.zig");

pub fn parameterHover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterHover(&subject, false);
}

pub fn parameterDefinition(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterLocations(&subject, .definition, false);
}

pub fn parameterImplementation(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterLocations(&subject, .implementation, false);
}

pub const OptionSpec = parameters.OptionSpec;
pub const optionSpec = parameters.optionSpec;
pub const optionSpecPathFrom = parameters.optionSpecPathFrom;

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
    const params_text = try std.fmt.allocPrint(a, "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":1,\"character\":11}}}}", .{uri});
    const params = try std.json.parseFromSliceLeaky(Value, a, params_text, .{});
    const locs = (try references(&server, a, params)).?;
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

fn parameterIn(src: []const u8, needle: []const u8) !?Parameter {
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    const off = std.mem.indexOf(u8, src, needle) orelse return null;
    const p = (try yaml.getPathAt(forest.allocator(), forest.roots[0], off, true)) orelse return null;
    const found = parameterAt(p) orelse return null;
    // Copy out of the forest before it is freed.
    return .{
        .name = try testing.allocator.dupe(u8, found.name),
        .start = found.start,
        .end = found.end,
        .role = try testing.allocator.dupe(u8, found.role),
        .entry_point = try testing.allocator.dupe(u8, found.entry_point),
    };
}

fn freeParam(p: Parameter) void {
    testing.allocator.free(p.name);
    testing.allocator.free(p.role);
    testing.allocator.free(p.entry_point);
}

test "role parameter in a roles entry" {
    const p = (try parameterIn("- hosts: all\n  roles:\n    - role: web\n      app_port: 8080\n", "app_port")).?;
    defer freeParam(p);
    try testing.expectEqualStrings("app_port", p.name);
    try testing.expectEqualStrings("web", p.role);
    try testing.expectEqualStrings("main", p.entry_point);
}

test "role keyword in a roles entry is not a parameter" {
    try testing.expect((try parameterIn("- hosts: all\n  roles:\n    - role: web\n      when: x\n", "when")) == null);
    // `port` is the connection keyword, not a role parameter.
    try testing.expect((try parameterIn("- hosts: all\n  roles:\n    - role: web\n      port: 1\n", "port")) == null);
}

test "role parameter under include_role vars with tasks_from" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - ansible.builtin.include_role:
        \\        name: web
        \\        tasks_from: setup.yml
        \\      vars:
        \\        port: 8080
        \\
    ;
    const p = (try parameterIn(src, "port")).?;
    defer freeParam(p);
    try testing.expectEqualStrings("web", p.role);
    try testing.expectEqualStrings("setup", p.entry_point);
}

test "plain task vars are not role parameters" {
    const src = "- hosts: all\n  tasks:\n    - debug: msg=hi\n      vars:\n        port: 1\n";
    try testing.expect((try parameterIn(src, "port")) == null);
}

test "option spec is unrendered and dedented" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("web/meta");
    try tmp.dir.writeFile(.{ .sub_path = "web/meta/argument_specs.yml", .data = 
        \\argument_specs:
        \\  main:
        \\    options:
        \\      port:
        \\        type: int
        \\        description: Listening port
        \\      host:
        \\        type: str
        \\
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realpathAlloc(a, "web");
    const spec = (try optionSpec(a, dir, "main", "port")).?;
    try testing.expectEqualStrings("port:\n  type: int\n  description: Listening port", spec.yaml);
    try testing.expect((try optionSpec(a, dir, "main", "missing")) == null);
}
