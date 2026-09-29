//! Discover the Ansible files of a Workspace (ADR-0031).
//!
//! The walk starts at the Workspace root and keeps `.yml`, `.yaml`, and `.j2`
//! files. It skips hidden directories, package and virtual-environment
//! directories, and nested Workspaces (directories holding the root marker).
//! It also records every `roles/` directory and every directory that contains
//! `ansible_collections/`, for role and collection resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const roots = @import("roots.zig");

pub const Discovery = struct {
    /// Absolute paths of Ansible files.
    files: []const []const u8,
    /// Absolute paths of directories named `roles`.
    roles_dirs: []const []const u8,
    /// Absolute paths of directories that contain `ansible_collections/`.
    collection_paths: []const []const u8,
};

/// Walk `root`. `marker` is the Workspace root marker; a subdirectory holding
/// it is a nested Workspace and is skipped. Everything is allocated with
/// `allocator`, which is expected to be an arena.
pub fn discover(allocator: Allocator, root: []const u8, marker: []const u8) !Discovery {
    var w = Walker{
        .allocator = allocator,
        .marker = roots.effectiveMarker(marker),
        .files = std.array_list.Managed([]const u8).init(allocator),
        .roles_dirs = std.array_list.Managed([]const u8).init(allocator),
        .collection_paths = std.array_list.Managed([]const u8).init(allocator),
    };
    try w.walk(root, true);
    return .{
        .files = try w.files.toOwnedSlice(),
        .roles_dirs = try w.roles_dirs.toOwnedSlice(),
        .collection_paths = try w.collection_paths.toOwnedSlice(),
    };
}

/// Whether a directory named `name` is never walked.
pub fn isExcludedDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const skipped = [_][]const u8{ "node_modules", "venv", "__pycache__" };
    for (skipped) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Whether `name` is an Ansible file by extension.
pub fn isAnsibleFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".yml") or
        std.mem.endsWith(u8, name, ".yaml") or
        std.mem.endsWith(u8, name, ".j2");
}

const Walker = struct {
    allocator: Allocator,
    marker: []const u8,
    files: std.array_list.Managed([]const u8),
    roles_dirs: std.array_list.Managed([]const u8),
    collection_paths: std.array_list.Managed([]const u8),

    fn walk(self: *Walker, path: []const u8, is_root: bool) !void {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();

        if (!is_root) {
            if (exists(dir, self.marker)) return;
            // A virtual environment of any name.
            if (exists(dir, "pyvenv.cfg")) return;
        }
        if (existsDir(dir, "ansible_collections")) try self.collection_paths.append(try self.allocator.dupe(u8, path));
        if (std.mem.eql(u8, std.fs.path.basename(path), "roles") and !is_root) {
            try self.roles_dirs.append(try self.allocator.dupe(u8, path));
        }

        var subdirs = std.array_list.Managed([]const u8).init(self.allocator);
        defer subdirs.deinit();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (isExcludedDir(entry.name)) continue;
                    try subdirs.append(try std.fs.path.join(self.allocator, &.{ path, entry.name }));
                },
                .file => {
                    if (isAnsibleFile(entry.name)) {
                        try self.files.append(try std.fs.path.join(self.allocator, &.{ path, entry.name }));
                    }
                },
                .sym_link => {
                    // Follow symlinked files; symlinked directories could loop.
                    if (!isAnsibleFile(entry.name)) continue;
                    const st = dir.statFile(entry.name) catch continue;
                    if (st.kind == .file) {
                        try self.files.append(try std.fs.path.join(self.allocator, &.{ path, entry.name }));
                    }
                },
                else => {},
            }
        }
        // Deterministic order regardless of directory iteration order.
        std.mem.sort([]const u8, subdirs.items, {}, lessString);
        for (subdirs.items) |sub| try self.walk(sub, false);
    }
};

fn exists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

fn existsDir(dir: std.fs.Dir, name: []const u8) bool {
    var sub = dir.openDir(name, .{}) catch return false;
    sub.close();
    return true;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

const Tree = struct {
    root: []u8,

    fn init() !Tree {
        var n: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&n));
        const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zals-discover-{x}", .{n});
        try std.fs.cwd().makePath(root);
        return .{ .root = root };
    }

    fn deinit(self: *Tree) void {
        std.fs.cwd().deleteTree(self.root) catch {};
        testing.allocator.free(self.root);
    }

    fn touch(self: Tree, rel: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.root, .{});
        defer dir.close();
        if (std.fs.path.dirname(rel)) |parent| try dir.makePath(parent);
        try dir.writeFile(.{ .sub_path = rel, .data = "" });
    }

    fn mkdir(self: Tree, rel: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.root, .{});
        defer dir.close();
        try dir.makePath(rel);
    }
};

fn hasSuffix(list: []const []const u8, suffix: []const u8) bool {
    for (list) |p| if (std.mem.endsWith(u8, p, suffix)) return true;
    return false;
}

test "discovers Ansible files and skips excluded directories" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.mkdir(".git");
    try tree.touch("playbooks/site.yml");
    try tree.touch("roles/web/tasks/main.yaml");
    try tree.touch("roles/web/templates/app.conf.j2");
    try tree.touch("README.md");
    try tree.touch(".github/workflows/ci.yml");
    try tree.touch(".venv/lib/python3.12/site-packages/x/conf.yml");
    try tree.touch("node_modules/pkg/conf.yml");
    try tree.touch("venv/conf.yml");
    try tree.touch("env-custom/pyvenv.cfg");
    try tree.touch("env-custom/lib/conf.yml");
    try tree.touch("vendor/lib/.git");
    try tree.touch("vendor/lib/tasks/main.yml");

    const d = try discover(a, tree.root, ".git");
    try testing.expectEqual(@as(usize, 3), d.files.len);
    try testing.expect(hasSuffix(d.files, "/playbooks/site.yml"));
    try testing.expect(hasSuffix(d.files, "/roles/web/tasks/main.yaml"));
    try testing.expect(hasSuffix(d.files, "/roles/web/templates/app.conf.j2"));
    try testing.expectEqual(@as(usize, 1), d.roles_dirs.len);
    try testing.expect(std.mem.endsWith(u8, d.roles_dirs[0], "/roles"));
}

test "records collection paths and nested roles directories" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.touch("collections/ansible_collections/acme/web/galaxy.yml");
    try tree.touch("collections/ansible_collections/acme/web/roles/nginx/tasks/main.yml");
    try tree.touch("infra/roles/db/tasks/main.yml");

    const d = try discover(a, tree.root, ".git");
    try testing.expectEqual(@as(usize, 1), d.collection_paths.len);
    try testing.expect(std.mem.endsWith(u8, d.collection_paths[0], "/collections"));
    try testing.expectEqual(@as(usize, 2), d.roles_dirs.len);
    try testing.expect(hasSuffix(d.roles_dirs, "/acme/web/roles"));
    try testing.expect(hasSuffix(d.roles_dirs, "/infra/roles"));
    try testing.expect(hasSuffix(d.files, "/acme/web/galaxy.yml"));
}

test "a custom root marker also bounds nested workspaces" {
    var tree = try Tree.init();
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tree.touch("ansible.cfg");
    try tree.touch("site.yml");
    try tree.touch("sub/ansible.cfg");
    try tree.touch("sub/play.yml");

    const d = try discover(a, tree.root, "ansible.cfg");
    try testing.expectEqual(@as(usize, 1), d.files.len);
    try testing.expect(hasSuffix(d.files, "/site.yml"));
}

test "excluded directory names" {
    try testing.expect(isExcludedDir(".venv"));
    try testing.expect(isExcludedDir(".git"));
    try testing.expect(isExcludedDir("node_modules"));
    try testing.expect(isExcludedDir("venv"));
    try testing.expect(!isExcludedDir("roles"));
    try testing.expect(!isExcludedDir("ansible_collections"));
}
