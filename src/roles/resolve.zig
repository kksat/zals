//! Resolve a role name to its directory on disk (ADR-0032).
//!
//! Resolution is on-demand. The order copies `ansible-playbook`:
//!
//! 1. FQCN (`ns.coll.role`, two or more dots) → each collections path.
//! 2. Declared `collections:` → each collection's `roles/<name>`.
//! 3. Sibling role: `<role dir>/../<name>` when the reference is in a role.
//! 4. `<dir>/roles/<name>`, walking up from the referencing file to the
//!    Workspace root.
//! 5. Each `roles_path` entry (Ansible's defaults are appended there).
//! 6. Editor fallback: any other `roles/<name>` in the Workspace.
//!
//! A name with one dot (`namespace.role`) is a Galaxy role and resolves as a
//! short name.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Conventional role subdirectories.
pub const role_subdirs = [_][]const u8{ "tasks", "handlers", "defaults", "vars", "meta", "templates", "files", "library" };

/// Metadata-defined collection directories belonging to the referencing Workspace.
pub const WorkspaceCollection = struct { name: []const u8, dir: []const u8, metadata_uri: []const u8 };

pub const Resolver = struct {
    allocator: Allocator,
    /// Role search paths for the referencing file, already expanded
    /// (`project_config.rolesPaths`).
    roles_paths: []const []const u8 = &.{},
    /// Collection search paths for the referencing file
    /// (`project_config.collectionsPaths`).
    collections_paths: []const []const u8 = &.{},
    /// Workspace collection identities read from metadata (including open edits).
    workspace_collections: []const WorkspaceCollection = &.{},
    /// Root of the Workspace that owns the referencing file. The adjacent
    /// `roles/` walk stops there.
    workspace_root: ?[]const u8 = null,
    /// Every `roles/` directory in the Workspace, for the editor fallback.
    workspace_roles_dirs: []const []const u8 = &.{},
    /// Collections declared in the referencing play/task (`collections:`).
    declared_collections: []const []const u8 = &.{},

    /// The role directory Ansible would use for `name`, else the first
    /// Workspace fallback match, else null.
    pub fn resolve(self: Resolver, name: []const u8, referencing_path: []const u8) ?[]const u8 {
        const all = self.resolveAll(name, referencing_path);
        return if (all.len > 0) all[0] else null;
    }

    /// The first match of steps 1–5 as a one-element slice. When none
    /// matches, every step-6 match, nearest to the referencing file first.
    pub fn resolveAll(self: Resolver, name: []const u8, referencing_path: []const u8) []const []const u8 {
        if (name.len == 0) return &.{};
        if (self.resolveAnsible(name, referencing_path)) |dir| return self.one(dir);
        if (dotCount(name) >= 2) return &.{};
        return self.fallback(name, referencing_path);
    }

    fn resolveAnsible(self: Resolver, name: []const u8, referencing_path: []const u8) ?[]const u8 {
        if (dotCount(name) >= 2) return self.resolveFqcn(name);
        for (self.declared_collections) |coll| {
            if (self.resolveCollection(coll, name)) |dir| return dir;
        }
        if (enclosingRole(referencing_path)) |role_dir| {
            if (std.fs.path.dirname(role_dir)) |parent| {
                if (self.tryDir(&.{ parent, name })) |dir| return dir;
            }
        }
        if (self.resolveAdjacent(name, referencing_path)) |dir| return dir;
        for (self.roles_paths) |rp| {
            if (self.tryDir(&.{ rp, name })) |dir| return dir;
        }
        return null;
    }

    fn resolveAdjacent(self: Resolver, name: []const u8, referencing_path: []const u8) ?[]const u8 {
        var dir = std.fs.path.dirname(referencing_path) orelse return null;
        while (true) {
            if (self.tryDir(&.{ dir, "roles", name })) |found| return found;
            if (self.workspace_root) |root| {
                if (std.mem.eql(u8, dir, root)) return null;
            }
            const parent = std.fs.path.dirname(dir) orelse return null;
            if (parent.len == 0 or std.mem.eql(u8, parent, dir)) return null;
            dir = parent;
        }
    }

    fn resolveFqcn(self: Resolver, name: []const u8) ?[]const u8 {
        const first = std.mem.indexOfScalar(u8, name, '.') orelse return null;
        const rest = name[first + 1 ..];
        const second = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const ns = name[0..first];
        const coll = rest[0..second];
        const role = rest[second + 1 ..];
        if (ns.len == 0 or coll.len == 0 or role.len == 0) return null;
        if (std.mem.indexOfScalar(u8, role, '.') != null) return null;
        return self.resolveCollection(name[0 .. first + 1 + second], role);
    }

    fn resolveCollection(self: Resolver, collection: []const u8, name: []const u8) ?[]const u8 {
        const dot = std.mem.indexOfScalar(u8, collection, '.') orelse return null;
        const ns = collection[0..dot];
        const coll = collection[dot + 1 ..];
        if (ns.len == 0 or coll.len == 0) return null;
        for (self.collections_paths) |cp| {
            if (self.tryDir(&.{ cp, "ansible_collections", ns, coll, "roles", name })) |dir| return dir;
        }
        // Editor source checkouts may use dotted or arbitrary directory names.
        for (self.workspace_collections) |c| {
            if (!std.mem.eql(u8, c.name, collection)) continue;
            if (self.tryDir(&.{ c.dir, "roles", name })) |dir| return dir;
        }
        return null;
    }

    fn fallback(self: Resolver, name: []const u8, referencing_path: []const u8) []const []const u8 {
        var out = std.array_list.Managed([]const u8).init(self.allocator);
        for (self.workspace_roles_dirs) |rd| {
            const dir = self.tryDir(&.{ rd, name }) orelse continue;
            out.append(dir) catch continue;
        }
        const Ctx = struct {
            ref: []const u8,
            fn less(ctx: @This(), x: []const u8, y: []const u8) bool {
                const px = commonPrefix(ctx.ref, x);
                const py = commonPrefix(ctx.ref, y);
                if (px != py) return px > py;
                return std.mem.order(u8, x, y) == .lt;
            }
        };
        std.mem.sort([]const u8, out.items, Ctx{ .ref = referencing_path }, Ctx.less);
        return out.toOwnedSlice() catch &.{};
    }

    fn one(self: Resolver, dir: []const u8) []const []const u8 {
        const out = self.allocator.alloc([]const u8, 1) catch return &.{};
        out[0] = dir;
        return out;
    }

    fn tryDir(self: Resolver, parts: []const []const u8) ?[]const u8 {
        const path = std.fs.path.join(self.allocator, parts) catch return null;
        if (!isDir(path)) {
            self.allocator.free(path);
            return null;
        }
        return path;
    }
};

/// The role directory that contains `path`: the parent of the nearest
/// ancestor named like a conventional role subdirectory, when that parent sits
/// in a `roles/` directory or has `meta/main.yml`/`.yaml`. Null outside a role.
pub fn enclosingRole(path: []const u8) ?[]const u8 {
    return enclosingRoleWith(path, isRoleDir);
}

/// Ownership knowable from the path alone: a conventional subdirectory of
/// roles/<name>. Document-scoped callers must not read standalone Role metadata.
pub fn enclosingRoleFromPath(path: []const u8) ?[]const u8 {
    return enclosingRoleWith(path, isRolePath);
}

fn enclosingRoleWith(path: []const u8, comptime accepts: fn ([]const u8) bool) ?[]const u8 {
    var dir = std.fs.path.dirname(path) orelse return null;
    while (true) {
        const base = std.fs.path.basename(dir);
        for (role_subdirs) |sub| {
            if (!std.mem.eql(u8, base, sub)) continue;
            const role_dir = std.fs.path.dirname(dir) orelse return null;
            if (accepts(role_dir)) return role_dir;
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

fn isRolePath(dir: []const u8) bool {
    const parent = std.fs.path.dirname(dir) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(parent), "roles");
}

fn isRoleDir(dir: []const u8) bool {
    if (isRolePath(dir)) return true;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "main.yml", "main.yaml" }) |name| {
        const meta = std.fmt.bufPrint(&buf, "{s}/meta/{s}", .{ dir, name }) catch continue;
        const f = std.fs.cwd().openFile(meta, .{}) catch continue;
        f.close();
        return true;
    }
    return false;
}

fn dotCount(name: []const u8) usize {
    return std.mem.count(u8, name, ".");
}

fn commonPrefix(x: []const u8, y: []const u8) usize {
    const n = @min(x.len, y.len);
    var i: usize = 0;
    while (i < n and x[i] == y[i]) : (i += 1) {}
    return i;
}

fn isDir(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

const testing = std.testing;

test "resolve playbook-adjacent role" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("roles/demo/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "roles/demo/tasks/main.yml", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{ .allocator = aa };
    const dir = resolver.resolve("demo", playbook).?;
    const expected = try std.fs.path.join(aa, &.{ root, "roles", "demo" });
    try testing.expectEqualStrings(expected, dir);
}

test "resolve from roles_path" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("external/demo/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "external/demo/tasks/main.yml", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const external = try std.fs.path.join(aa, &.{ root, "external" });

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{ .allocator = aa, .roles_paths = &.{external} };
    const dir = resolver.resolve("demo", playbook).?;
    const expected = try std.fs.path.join(aa, &.{ external, "demo" });
    try testing.expectEqualStrings(expected, dir);
}

test "resolve FQCN from collections path" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("collections/ansible_collections/ns/coll/roles/demo/tasks");
    try tmp.dir.writeFile(.{
        .sub_path = "collections/ansible_collections/ns/coll/roles/demo/tasks/main.yml",
        .data = "",
    });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const collections = try std.fs.path.join(aa, &.{ root, "collections" });

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{ .allocator = aa, .collections_paths = &.{collections} };
    const dir = resolver.resolve("ns.coll.demo", playbook).?;
    const expected = try std.fs.path.join(aa, &.{
        collections, "ansible_collections", "ns", "coll", "roles", "demo",
    });
    try testing.expectEqualStrings(expected, dir);
}

test "resolve short name via declared collection" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("collections/ansible_collections/ns/coll/roles/demo/tasks");
    try tmp.dir.writeFile(.{
        .sub_path = "collections/ansible_collections/ns/coll/roles/demo/tasks/main.yml",
        .data = "",
    });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const collections = try std.fs.path.join(aa, &.{ root, "collections" });

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{
        .allocator = aa,
        .collections_paths = &.{collections},
        .declared_collections = &.{"ns.coll"},
    };
    const dir = resolver.resolve("demo", playbook).?;
    const expected = try std.fs.path.join(aa, &.{
        collections, "ansible_collections", "ns", "coll", "roles", "demo",
    });
    try testing.expectEqualStrings(expected, dir);
}

test "unresolved role returns null" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const resolver = Resolver{ .allocator = aa };
    try testing.expect(resolver.resolve("nope", "/tmp/playbook.yml") == null);
}

test "galaxy role name resolves as a short name" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("galaxy/geerlingguy.nginx/tasks");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const galaxy = try std.fs.path.join(aa, &.{ root, "galaxy" });
    const playbook = try std.fs.path.join(aa, &.{ root, "site.yml" });
    const resolver = Resolver{ .allocator = aa, .roles_paths = &.{galaxy}, .workspace_root = root };
    const dir = resolver.resolve("geerlingguy.nginx", playbook).?;
    try testing.expectEqualStrings(try std.fs.path.join(aa, &.{ galaxy, "geerlingguy.nginx" }), dir);
}

test "declared collection wins over adjacent roles" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("roles/demo/tasks");
    try tmp.dir.makePath("collections/ansible_collections/ns/coll/roles/demo/tasks");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const collections = try std.fs.path.join(aa, &.{ root, "collections" });
    const playbook = try std.fs.path.join(aa, &.{ root, "site.yml" });
    const resolver = Resolver{
        .allocator = aa,
        .collections_paths = &.{collections},
        .declared_collections = &.{"ns.coll"},
        .workspace_root = root,
    };
    const dir = resolver.resolve("demo", playbook).?;
    try testing.expect(std.mem.indexOf(u8, dir, "ansible_collections") != null);
}

test "sibling role wins over roles_path" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("roles/web/meta");
    try tmp.dir.makePath("roles/common/tasks");
    try tmp.dir.makePath("elsewhere/common/tasks");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const meta = try std.fs.path.join(aa, &.{ root, "roles", "web", "meta", "main.yml" });
    const elsewhere = try std.fs.path.join(aa, &.{ root, "elsewhere" });
    const resolver = Resolver{ .allocator = aa, .roles_paths = &.{elsewhere}, .workspace_root = root };
    const dir = resolver.resolve("common", meta).?;
    try testing.expectEqualStrings(try std.fs.path.join(aa, &.{ root, "roles", "common" }), dir);
}

test "adjacent walk stops at the Workspace root" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("roles/demo/tasks");
    try tmp.dir.makePath("ws/playbooks");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const ws = try std.fs.path.join(aa, &.{ root, "ws" });
    const playbook = try std.fs.path.join(aa, &.{ ws, "playbooks", "site.yml" });
    const resolver = Resolver{ .allocator = aa, .workspace_root = ws };
    try testing.expect(resolver.resolve("demo", playbook) == null);
}

test "workspace fallback returns every match, nearest first" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("infra/roles/db/tasks");
    try tmp.dir.makePath("apps/roles/db/tasks");
    try tmp.dir.makePath("apps/playbooks");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const infra = try std.fs.path.join(aa, &.{ root, "infra", "roles" });
    const apps = try std.fs.path.join(aa, &.{ root, "apps", "roles" });
    const other = try std.fs.path.join(aa, &.{ root, "other", "site.yml" });
    const resolver = Resolver{
        .allocator = aa,
        .workspace_root = root,
        .workspace_roles_dirs = &.{ infra, apps },
    };
    const all = resolver.resolveAll("db", other);
    try testing.expectEqual(@as(usize, 2), all.len);

    // From apps/playbooks, the adjacent walk finds apps/roles/db first.
    const from_apps = try std.fs.path.join(aa, &.{ root, "apps", "playbooks", "site.yml" });
    const first = resolver.resolveAll("db", from_apps);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings(try std.fs.path.join(aa, &.{ apps, "db" }), first[0]);
}

test "path-only Role ownership needs no metadata reads" {
    try testing.expectEqualStrings("/w/roles/web", enclosingRoleFromPath("/w/roles/web/handlers/sub/x.yml").?);
    try testing.expectEqualStrings("/w/roles/web", enclosingRoleFromPath("/w/roles/web/tasks/handlers/x.yml").?);
    try testing.expect(enclosingRoleFromPath("/x/handlers/project/site.yml") == null);
}

test "enclosing role" {
    try testing.expectEqualStrings("/w/roles/web", enclosingRole("/w/roles/web/tasks/sub/x.yml").?);
    try testing.expect(enclosingRole("/nowhere-zals/tasks/x.yml") == null);
}
