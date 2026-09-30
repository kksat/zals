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
const wv = @import("workspace_view.zig");
const RoleRef = @import("../workspace/facts.zig").RoleRef;

/// Every Role reference in the Workspace that can resolve to the same role
/// directory as the cursor. Null when the cursor is not on a role reference.
pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const own = types.Location{ .uri = cur.doc.uri, .range = cur.doc.rangeFromOffsets(ref.start, ref.end) };
    const path = try paths.uriToPath(a, cur.doc.uri);
    const declared = try yaml.collections.getRoleDeclaredCollections(cur.forest.allocator(), path, cur.path);
    const targets = util.resolveRoleAll(self, a, ref.name, path, declared);
    // Unresolved references have no identity to share, even with another
    // unresolved occurrence of the same spelling.
    if (targets.len == 0) return try a.dupe(types.Location, &.{own});

    var v = (try wv.View.forUri(self, a, cur.doc.uri)) orelse return try a.dupe(types.Location, &.{own});
    var locs = std.array_list.Managed(types.Location).init(a);
    try locs.append(own);
    for (v.files) |f| {
        if (f.facts.role_refs.len == 0) continue;
        // Build search paths once per file, not per reference. Facts already
        // retain the collections visible at each site from the index/open doc.
        const resolver = util.roleResolver(self, a, f.path, &.{});
        for (f.facts.role_refs) |r| {
            if (std.mem.eql(u8, f.uri, cur.doc.uri) and r.start == ref.start and r.end == ref.end) continue;
            if (!roleRefMatches(resolver, f.path, r, targets)) continue;
            try locs.append(try v.location(f.uri, r.start, r.end));
        }
    }
    std.mem.sort(types.Location, locs.items, {}, lessLocation);
    return try locs.toOwnedSlice();
}

/// The file's search paths are shared; each site supplies its own collections.
fn roleRefMatches(base: roles.Resolver, path: []const u8, ref: RoleRef, targets: []const []const u8) bool {
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
pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const name = try a.dupe(u8, ref.name);
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getRoleDeclaredCollections(cur.forest.allocator(), path, cur.path) catch &.{};
    const range = cur.doc.rangeFromOffsets(ref.start, ref.end);

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

/// A Role parameter under the cursor: the key, the role it is passed to,
/// and the argument-spec entry point.
pub const Parameter = struct {
    name: []const u8,
    start: usize,
    end: usize,
    role: []const u8,
    entry_point: []const u8,
};

/// Detect a Role parameter key at `path`: a key of a play's `roles:` entry
/// (or of its `vars:`), or a key under `vars:` of an
/// `include_role`/`import_role` task.
pub fn parameterAt(path: []*yaml.Node) ?Parameter {
    if (path.len < 3) return null;
    const key = path[path.len - 1];
    const pair = path[path.len - 2];
    if (!key.isScalar() or !pair.isPair() or pair.key != key) return null;
    const name = key.stringValue() orelse return null;
    const map = path[path.len - 3];
    if (!map.isMap()) return null;

    // `- role: web` entry map.
    if (roleEntry(path, path.len - 3)) |entry| {
        if (std.mem.eql(u8, name, "role") or std.mem.eql(u8, name, "name")) return null;
        if (yaml.keywords.isRoleKeyword(name)) return null;
        return .{ .name = name, .start = key.start, .end = key.end, .role = entry, .entry_point = "main" };
    }

    // A `vars:` map: of a role entry, or of an include_role/import_role task.
    if (path.len < 5) return null;
    const vars_pair = path[path.len - 4];
    if (!vars_pair.isPair()) return null;
    const vk = vars_pair.key orelse return null;
    if (!std.mem.eql(u8, vk.stringValue() orelse "", "vars")) return null;
    const owner = path[path.len - 5];
    if (!owner.isMap()) return null;
    if (roleEntry(path, path.len - 5)) |entry| {
        return .{ .name = name, .start = key.start, .end = key.end, .role = entry, .entry_point = "main" };
    }
    for (owner.items) |p| {
        const k = (p.key orelse continue).stringValue() orelse continue;
        if (!isModuleKey(k, "include_role") and !isModuleKey(k, "import_role")) continue;
        const args = p.val orelse return null;
        const role = roleArg(args, "name") orelse return null;
        const tasks_from = roleArg(args, "tasks_from");
        return .{
            .name = name,
            .start = key.start,
            .end = key.end,
            .role = role,
            .entry_point = if (tasks_from) |t| stripExt(std.fs.path.basename(t)) else "main",
        };
    }
    return null;
}

/// The role name of a `roles:` entry map at `path[i]`, or null.
fn roleEntry(path: []*yaml.Node, i: usize) ?[]const u8 {
    if (i < 2) return null;
    const seq = path[i - 1];
    const roles_pair = path[i - 2];
    if (!seq.isSeq() or !roles_pair.isPair()) return null;
    const rk = roles_pair.key orelse return null;
    if (!std.mem.eql(u8, rk.stringValue() orelse "", "roles")) return null;
    const map = path[i];
    for ([_][]const u8{ "role", "name" }) |field| {
        if (yaml.dom.findPair(map, field)) |p| {
            if (p.val) |v| if (v.stringValue()) |s| return s;
        }
    }
    return null;
}

/// `field` of `include_role` args: map form or `k=v` form.
fn roleArg(args: *yaml.Node, field: []const u8) ?[]const u8 {
    if (args.isMap()) {
        const p = yaml.dom.findPair(args, field) orelse return null;
        const v = p.val orelse return null;
        return v.stringValue();
    }
    const raw = args.stringValue() orelse return null;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |token| {
        if (token.len > field.len and std.mem.startsWith(u8, token, field) and token[field.len] == '=') {
            return std.mem.trim(u8, token[field.len + 1 ..], "\"'");
        }
    }
    return null;
}

/// Hover on a Role parameter: the unrendered option from the role's argument
/// specs, else the variable hover for that name. Null when the cursor is not
/// on a Role parameter.
pub fn parameterHover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const param = parameterAt(cur.path) orelse return null;
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getDeclaredCollections(cur.forest.allocator(), cur.path) catch &.{};
    const range = cur.doc.rangeFromOffsets(param.start, param.end);
    const name = try a.dupe(u8, param.name);
    const spec = blk: {
        const dir = util.resolveRole(self, a, param.role, path, collections) orelse break :blk null;
        break :blk try optionSpec(a, dir, param.entry_point, param.name);
    } orelse return @import("variable_hover.zig").hoverName(self, a, cur.doc.uri, name, range);
    const text = try std.fmt.allocPrint(
        a,
        "**Role parameter** `{s}` — role `{s}` (`meta/{s}`, entry point `{s}`)\n\n```yaml\n{s}\n```",
        .{ param.name, param.role, spec.file, param.entry_point, spec.yaml },
    );
    return markdown(range, text);
}

pub const OptionSpec = struct { file: []const u8, yaml: []const u8 };

/// The unrendered YAML of `argument_specs.<entry>.options.<name>` in the
/// role's `meta/argument_specs.*`, else `meta/main.*`.
pub fn optionSpec(a: Allocator, role_dir: []const u8, entry: []const u8, name: []const u8) !?OptionSpec {
    for ([_][]const u8{ "argument_specs.yml", "argument_specs.yaml", "main.yml", "main.yaml" }) |file| {
        const text = readFile(a, &.{ role_dir, "meta", file }) orelse continue;
        var forest = yaml.parse(a, text) catch continue;
        defer forest.deinit();
        for (forest.roots) |root| {
            const pair = optionPair(root, entry, name) orelse continue;
            return .{ .file = file, .yaml = try dedent(a, text, pair.start, pair.end) };
        }
    }
    return null;
}

fn optionPair(root: *yaml.Node, entry: []const u8, name: []const u8) ?*yaml.Node {
    if (!root.isMap()) return null;
    const specs = (yaml.dom.findPair(root, "argument_specs") orelse return null).val orelse return null;
    if (!specs.isMap()) return null;
    const ep = (yaml.dom.findPair(specs, entry) orelse return null).val orelse return null;
    if (!ep.isMap()) return null;
    const options = (yaml.dom.findPair(ep, "options") orelse return null).val orelse return null;
    if (!options.isMap()) return null;
    return yaml.dom.findPair(options, name);
}

/// `text[start..end]` with the start line's indentation removed from every
/// line, so the option reads as a standalone YAML block.
fn dedent(a: Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], '\n')) |i| i + 1 else 0;
    const indent = start - line_start;
    var out = std.array_list.Managed(u8).init(a);
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, text[line_start..@min(end, text.len)], " \t\r\n"), '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        var cut: usize = 0;
        while (cut < indent and cut < line.len and (line[cut] == ' ' or line[cut] == '\t')) : (cut += 1) {}
        try out.appendSlice(line[cut..]);
    }
    return out.toOwnedSlice();
}

fn isModuleKey(key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, key, name)) return true;
    return key.len > name.len + 1 and key[key.len - name.len - 1] == '.' and std.mem.endsWith(u8, key, name);
}

fn stripExt(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
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
