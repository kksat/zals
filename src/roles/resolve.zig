//! Resolve a role name to its directory on disk.
//!
//! Resolution is on-demand (no startup pre-scan). The search order mirrors how
//! Ansible finds roles, minus inventory/execution-environment specifics:
//!
//! 1. FQCN (`ns.coll.role`) → each collections path.
//! 2. Short name → playbook-adjacent `roles/` (walking up), then
//!    `DEFAULT_ROLES_PATH`, then workspace-root `roles/`, then each declared
//!    collection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AnsibleConfig = @import("../services/ansible_config.zig").AnsibleConfig;

pub const Resolver = struct {
    allocator: Allocator,
    config: *AnsibleConfig,
    /// Workspace root directories (filesystem paths, not URIs).
    workspace_roots: []const []const u8 = &.{},
    /// Collections declared in the referencing play/task (`collections:`).
    declared_collections: []const []const u8 = &.{},

    /// The role directory for `name`, or null when it cannot be found.
    pub fn resolve(self: Resolver, name: []const u8, referencing_path: []const u8) ?[]const u8 {
        if (name.len == 0) return null;
        if (std.mem.indexOfScalar(u8, name, '.') != null) return self.resolveFqcn(name);

        if (self.resolveAdjacent(name, referencing_path)) |dir| return dir;
        for (self.config.rolesPath()) |rp| {
            const expanded = self.expandHome(rp) orelse continue;
            const found = self.tryDir(&.{ expanded, name });
            if (std.mem.startsWith(u8, rp, "~/")) self.allocator.free(expanded);
            if (found) |dir| return dir;
        }
        for (self.workspace_roots) |root| {
            if (self.tryDir(&.{ root, "roles", name })) |dir| return dir;
        }
        for (self.declared_collections) |coll| {
            if (self.resolveCollection(coll, name)) |dir| return dir;
        }
        return null;
    }

    fn resolveAdjacent(self: Resolver, name: []const u8, referencing_path: []const u8) ?[]const u8 {
        var dir = std.fs.path.dirname(referencing_path) orelse return null;
        while (true) {
            if (self.tryDir(&.{ dir, "roles", name })) |found| return found;
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
        for (self.config.collectionsPaths()) |cp| {
            if (self.tryDir(&.{ cp, "ansible_collections", ns, coll, "roles", role })) |dir| return dir;
        }
        return null;
    }

    fn resolveCollection(self: Resolver, collection: []const u8, name: []const u8) ?[]const u8 {
        const dot = std.mem.indexOfScalar(u8, collection, '.') orelse return null;
        const ns = collection[0..dot];
        const coll = collection[dot + 1 ..];
        if (ns.len == 0 or coll.len == 0) return null;
        for (self.config.collectionsPaths()) |cp| {
            if (self.tryDir(&.{ cp, "ansible_collections", ns, coll, "roles", name })) |dir| return dir;
        }
        return null;
    }

    fn tryDir(self: Resolver, parts: []const []const u8) ?[]const u8 {
        const path = std.fs.path.join(self.allocator, parts) catch return null;
        if (!isDir(path)) {
            self.allocator.free(path);
            return null;
        }
        return path;
    }

    /// Expand a leading `~/` against `$HOME` (or `%USERPROFILE%` on Windows).
    fn expandHome(self: Resolver, path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, "~/")) return path;
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch
            std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch return null;
        return std.fs.path.join(self.allocator, &.{ home, path[2..] }) catch null;
    }
};

fn isDir(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

const testing = std.testing;

fn testConfig(a: Allocator) AnsibleConfig {
    return .{
        .allocator = a,
        .runner = undefined,
        .arena = std.heap.ArenaAllocator.init(a),
        .loaded = true,
    };
}

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

    var cfg = testConfig(aa);
    defer cfg.arena.deinit();

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{ .allocator = aa, .config = &cfg };
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
    var cfg = testConfig(aa);
    defer cfg.arena.deinit();
    cfg.roles_path = &.{external};

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{ .allocator = aa, .config = &cfg };
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
    var cfg = testConfig(aa);
    defer cfg.arena.deinit();
    cfg.collections_paths = &.{collections};

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{ .allocator = aa, .config = &cfg };
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
    var cfg = testConfig(aa);
    defer cfg.arena.deinit();
    cfg.collections_paths = &.{collections};

    const playbook = try std.fs.path.join(aa, &.{ root, "playbook.yml" });
    const resolver = Resolver{
        .allocator = aa,
        .config = &cfg,
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

    var cfg = testConfig(aa);
    defer cfg.arena.deinit();

    const resolver = Resolver{ .allocator = aa, .config = &cfg };
    try testing.expect(resolver.resolve("nope", "/tmp/playbook.yml") == null);
}
