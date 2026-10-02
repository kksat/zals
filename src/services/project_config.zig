//! Per-file Ansible search paths (ADR-0032).
//!
//! Role and collection resolution need `roles_path` and `collections_path` for
//! the file being edited. They come, in Ansible's precedence, from the
//! environment (`ANSIBLE_ROLES_PATH`, `ANSIBLE_COLLECTIONS_PATH`), then the
//! nearest `ansible.cfg` at or above the file (or `ANSIBLE_CONFIG`), then the
//! cached `ansible-config dump`. The selected virtual environment and the
//! Workspace's own `ansible_collections/` directories add collection paths.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Ansible's default role search paths, appended after `roles_path`.
pub const default_roles_paths = [_][]const u8{ "~/.ansible/roles", "/usr/share/ansible/roles", "/etc/ansible/roles" };

/// Environment lookup, injectable for tests. Returns an owned copy or null.
pub const Env = *const fn (allocator: Allocator, name: []const u8) ?[]u8;

pub fn processEnv(allocator: Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

pub const Context = struct {
    /// Workspace root owning the file, or null.
    workspace_root: ?[]const u8 = null,
    /// Selected virtual environment (absolute, or relative to the Workspace
    /// root). Empty disables the venv lookup.
    venv: []const u8 = ".venv",
    /// `DEFAULT_ROLES_PATH` from `ansible-config dump`.
    dump_roles: []const []const u8 = &.{},
    /// `COLLECTIONS_PATHS` from `ansible-config dump`.
    dump_collections: []const []const u8 = &.{},
    /// Directories in the Workspace that contain `ansible_collections/`.
    workspace_collections: []const []const u8 = &.{},
    env: Env = processEnv,
};

pub const Values = struct {
    roles_path: ?[]const []const u8 = null,
    collections_path: ?[]const []const u8 = null,
};

/// The `ansible.cfg` that applies to `file_path`: `ANSIBLE_CONFIG` when set,
/// else the nearest one at or above the file's directory, stopping at the
/// Workspace root.
pub fn nearestConfig(a: Allocator, ctx: Context, file_path: []const u8) !?[]const u8 {
    if (ctx.env(a, "ANSIBLE_CONFIG")) |p| {
        if (p.len > 0 and isFile(p)) return p;
    }
    var dir = std.fs.path.dirname(file_path) orelse return null;
    while (true) {
        const candidate = try std.fs.path.join(a, &.{ dir, "ansible.cfg" });
        if (isFile(candidate)) return candidate;
        if (ctx.workspace_root) |root| {
            if (std.mem.eql(u8, dir, root)) return null;
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

/// Parse `[defaults]` `roles_path` and `collections_path(s)` from INI text.
/// Relative entries resolve against `cfg_dir`.
pub fn parseConfig(a: Allocator, text: []const u8, cfg_dir: []const u8, env: Env) !Values {
    var values = Values{};
    var in_defaults = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_defaults = std.mem.eql(u8, std.mem.trim(u8, line[1..end], " \t"), "defaults");
            continue;
        }
        if (!in_defaults) continue;
        const sep = std.mem.indexOfAny(u8, line, "=:") orelse continue;
        const key = std.mem.trim(u8, line[0..sep], " \t");
        const value = stripInlineComment(std.mem.trim(u8, line[sep + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "roles_path")) {
            values.roles_path = try splitPaths(a, value, cfg_dir, env);
        } else if (std.mem.eql(u8, key, "collections_path") or std.mem.eql(u8, key, "collections_paths")) {
            values.collections_path = try splitPaths(a, value, cfg_dir, env);
        }
    }
    return values;
}

/// Values from the `ansible.cfg` that applies to `file_path`.
pub fn configValues(a: Allocator, ctx: Context, file_path: []const u8) !Values {
    const cfg = (try nearestConfig(a, ctx, file_path)) orelse return .{};
    const text = readFile(a, cfg) orelse return .{};
    return parseConfig(a, text, std.fs.path.dirname(cfg) orelse ".", ctx.env);
}

/// Role search paths for `file_path`: `ANSIBLE_ROLES_PATH`, else the config's
/// `roles_path`, else the dumped `DEFAULT_ROLES_PATH`; then Ansible's defaults.
pub fn rolesPaths(a: Allocator, ctx: Context, file_path: []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(a);
    if (try envPaths(a, ctx, "ANSIBLE_ROLES_PATH")) |p| {
        try appendAll(&out, p);
    } else if ((try configValues(a, ctx, file_path)).roles_path) |p| {
        try appendAll(&out, p);
    } else {
        for (ctx.dump_roles) |p| try appendUnique(&out, try expandHome(a, p, ctx.env));
    }
    for (default_roles_paths) |p| try appendUnique(&out, try expandHome(a, p, ctx.env));
    return out.toOwnedSlice();
}

/// Collection search paths for `file_path`, in resolution order: the adjacent
/// `collections/` directory, the configured paths, the selected virtual
/// environment's root and `site-packages`, then the Workspace's collection directories.
/// Each entry is a directory that contains (or may contain)
/// `ansible_collections/`.
pub fn collectionsPaths(a: Allocator, ctx: Context, file_path: []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(a);
    if (std.fs.path.dirname(file_path)) |dir| {
        const adjacent = try std.fs.path.join(a, &.{ dir, "collections" });
        if (isDir(adjacent)) try appendUnique(&out, adjacent);
    }
    if (try envPaths(a, ctx, "ANSIBLE_COLLECTIONS_PATH")) |p| {
        try appendAll(&out, p);
    } else if (try envPaths(a, ctx, "ANSIBLE_COLLECTIONS_PATHS")) |p| {
        try appendAll(&out, p);
    } else if ((try configValues(a, ctx, file_path)).collections_path) |p| {
        try appendAll(&out, p);
    } else {
        for (ctx.dump_collections) |p| try appendUnique(&out, try expandHome(a, p, ctx.env));
    }
    if (try venvRoot(a, ctx)) |venv| {
        if (hasCollections(a, venv)) try appendUnique(&out, venv);
    }
    try appendAll(&out, try venvSitePackagesPaths(a, ctx));
    for (ctx.workspace_collections) |p| try appendUnique(&out, p);
    return out.toOwnedSlice();
}

fn venvRoot(a: Allocator, ctx: Context) !?[]const u8 {
    if (ctx.venv.len == 0) return null;
    if (std.fs.path.isAbsolute(ctx.venv)) return try a.dupe(u8, ctx.venv);
    const root = ctx.workspace_root orelse return null;
    return try std.fs.path.join(a, &.{ root, ctx.venv });
}

/// `site-packages` of the selected virtual environment when it contains
/// `ansible_collections/`, or null.
pub fn venvSitePackages(a: Allocator, ctx: Context) !?[]const u8 {
    const paths = try venvSitePackagesPaths(a, ctx);
    return if (paths.len > 0) paths[0] else null;
}

fn venvSitePackagesPaths(a: Allocator, ctx: Context) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(a);
    const venv = (try venvRoot(a, ctx)) orelse return &.{};
    // Windows layout, then POSIX layouts in deterministic order.
    const win = try std.fs.path.join(a, &.{ venv, "Lib", "site-packages" });
    if (hasCollections(a, win)) try appendUnique(&out, win);

    const lib = try std.fs.path.join(a, &.{ venv, "lib" });
    var dir = std.fs.cwd().openDir(lib, .{ .iterate = true }) catch return out.toOwnedSlice();
    defer dir.close();
    var names = std.array_list.Managed([]const u8).init(a);
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, "python")) continue;
        try names.append(try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessString);
    for (names.items) |name| {
        const sp = try std.fs.path.join(a, &.{ lib, name, "site-packages" });
        if (hasCollections(a, sp)) try appendUnique(&out, sp);
    }
    return out.toOwnedSlice();
}

fn envPaths(a: Allocator, ctx: Context, name: []const u8) !?[]const []const u8 {
    const value = ctx.env(a, name) orelse return null;
    if (value.len == 0) return null;
    return try splitPaths(a, value, null, ctx.env);
}

/// Split an `os.pathsep`-separated list. Relative entries resolve against
/// `base` when given.
fn splitPaths(a: Allocator, value: []const u8, base: ?[]const u8, env: Env) ![]const []const u8 {
    const sep: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    var out = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, value, sep);
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\"'");
        if (entry.len == 0) continue;
        const expanded = try expandHome(a, entry, env);
        const resolved = if (base != null and !std.fs.path.isAbsolute(expanded))
            try std.fs.path.resolve(a, &.{ base.?, expanded })
        else
            expanded;
        try appendUnique(&out, resolved);
    }
    return out.toOwnedSlice();
}

/// Expand a leading `~/` against `$HOME` (or `%USERPROFILE%`).
pub fn expandHome(a: Allocator, path: []const u8, env: Env) ![]const u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/")) return a.dupe(u8, path);
    const home = env(a, "HOME") orelse env(a, "USERPROFILE") orelse return a.dupe(u8, path);
    if (path.len <= 2) return home;
    return std.fs.path.join(a, &.{ home, path[2..] });
}

fn stripInlineComment(value: []const u8) []const u8 {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if ((value[i] == '#' or value[i] == ';') and (i == 0 or value[i - 1] == ' ' or value[i - 1] == '\t')) {
            return std.mem.trim(u8, value[0..i], " \t");
        }
    }
    return value;
}

fn appendAll(out: *std.array_list.Managed([]const u8), items: []const []const u8) !void {
    for (items) |p| try appendUnique(out, p);
}

fn appendUnique(out: *std.array_list.Managed([]const u8), path: []const u8) !void {
    for (out.items) |existing| if (std.mem.eql(u8, existing, path)) return;
    try out.append(path);
}

fn hasCollections(a: Allocator, dir: []const u8) bool {
    const p = std.fs.path.join(a, &.{ dir, "ansible_collections" }) catch return false;
    return isDir(p);
}

fn isDir(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

fn isFile(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    const st = f.stat() catch return false;
    return st.kind == .file;
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 1 << 20) catch null;
}

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

const testing = std.testing;

fn noEnv(_: Allocator, _: []const u8) ?[]u8 {
    return null;
}

fn fakeEnv(a: Allocator, name: []const u8) ?[]u8 {
    if (std.mem.eql(u8, name, "HOME")) return a.dupe(u8, "/home/u") catch null;
    if (std.mem.eql(u8, name, "ANSIBLE_ROLES_PATH")) return a.dupe(u8, "/env/roles:~/more") catch null;
    return null;
}

const Tree = struct {
    root: []u8,

    fn init() !Tree {
        var n: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&n));
        const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zals-cfg-{x}", .{n});
        try std.fs.cwd().makePath(root);
        return .{ .root = root };
    }

    fn deinit(self: *Tree) void {
        std.fs.cwd().deleteTree(self.root) catch {};
        testing.allocator.free(self.root);
    }

    fn write(self: Tree, rel: []const u8, data: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.root, .{});
        defer dir.close();
        if (std.fs.path.dirname(rel)) |parent| try dir.makePath(parent);
        try dir.writeFile(.{ .sub_path = rel, .data = data });
    }

    fn mkdir(self: Tree, rel: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.root, .{});
        defer dir.close();
        try dir.makePath(rel);
    }

    fn path(self: Tree, a: Allocator, rel: []const u8) ![]const u8 {
        return std.fs.path.join(a, &.{ self.root, rel });
    }
};

test "parse roles_path and collections_path from [defaults]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\[galaxy]
        \\roles_path = /ignored
        \\[defaults]
        \\roles_path = ./custom_roles:../common/roles:/abs  ; comment
        \\collections_paths = ~/collections
        \\
    ;
    const v = try parseConfig(a, text, "/acme/apps", fakeEnv);
    try testing.expectEqual(@as(usize, 3), v.roles_path.?.len);
    try testing.expectEqualStrings("/acme/apps/custom_roles", v.roles_path.?[0]);
    try testing.expectEqualStrings("/acme/common/roles", v.roles_path.?[1]);
    try testing.expectEqualStrings("/abs", v.roles_path.?[2]);
    try testing.expectEqualStrings("/home/u/collections", v.collections_path.?[0]);
}

test "nearest ansible.cfg walks up and stops at the Workspace root" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.write("ansible.cfg", "[defaults]\nroles_path = root_roles\n");
    try tree.write("apps/ansible.cfg", "[defaults]\nroles_path = ./custom_roles\n");
    try tree.write("apps/playbooks/site.yml", "");
    try tree.write("infra/site.yml", "");

    const ctx = Context{ .workspace_root = tree.root, .env = noEnv };
    const apps = try rolesPaths(a, ctx, try tree.path(a, "apps/playbooks/site.yml"));
    try testing.expectEqualStrings(try tree.path(a, "apps/custom_roles"), apps[0]);
    const infra = try rolesPaths(a, ctx, try tree.path(a, "infra/site.yml"));
    try testing.expectEqualStrings(try tree.path(a, "root_roles"), infra[0]);
    // Ansible's defaults follow.
    try testing.expectEqualStrings("/usr/share/ansible/roles", infra[infra.len - 2]);
}

test "environment overrides ansible.cfg" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.write("ansible.cfg", "[defaults]\nroles_path = root_roles\n");
    const ctx = Context{ .workspace_root = tree.root, .env = fakeEnv };
    const paths = try rolesPaths(a, ctx, try tree.path(a, "site.yml"));
    try testing.expectEqualStrings("/env/roles", paths[0]);
    try testing.expectEqualStrings("/home/u/more", paths[1]);
}

test "dump values apply without config or environment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = Context{ .workspace_root = "/nowhere", .dump_roles = &.{"/dumped/roles"}, .env = noEnv };
    const paths = try rolesPaths(a, ctx, "/nowhere/site.yml");
    try testing.expectEqualStrings("/dumped/roles", paths[0]);
}

test "collections paths include adjacent, venv, and workspace collections" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.mkdir("playbooks/collections/ansible_collections");
    try tree.mkdir(".venv-216/lib/python3.12/site-packages/ansible_collections/community/general");
    try tree.mkdir(".venv/lib/python3.11/site-packages/ansible_collections");
    try tree.write("playbooks/site.yml", "");

    const ws = try tree.path(a, "collections");
    const ctx = Context{
        .workspace_root = tree.root,
        .venv = ".venv-216",
        .dump_collections = &.{"/dumped"},
        .workspace_collections = &.{ws},
        .env = noEnv,
    };
    const paths = try collectionsPaths(a, ctx, try tree.path(a, "playbooks/site.yml"));
    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expectEqualStrings(try tree.path(a, "playbooks/collections"), paths[0]);
    try testing.expectEqualStrings("/dumped", paths[1]);
    try testing.expectEqualStrings(try tree.path(a, ".venv-216/lib/python3.12/site-packages"), paths[2]);
    try testing.expectEqualStrings(ws, paths[3]);
}

test "only the selected venv is used" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.mkdir("env-a/lib/python3.12/site-packages/ansible_collections");
    const none = try venvSitePackages(a, .{ .workspace_root = tree.root, .env = noEnv });
    try testing.expect(none == null);
    const picked = try venvSitePackages(a, .{ .workspace_root = tree.root, .venv = "env-a", .env = noEnv });
    try testing.expectEqualStrings(try tree.path(a, "env-a/lib/python3.12/site-packages"), picked.?);
}
