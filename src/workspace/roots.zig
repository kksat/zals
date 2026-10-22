//! Resolve a Workspace from the filesystem.
//!
//! A Workspace is the nearest directory containing the root marker (a file or
//! a directory) at or above a start path. The default marker is `.git`. A
//! nested marker is its own Workspace. See GLOSSARY.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_marker = ".git";

pub const Set = struct {
    roots: std.array_list.Managed([]const u8),
    /// True when at least one opened path has no Workspace.
    missing: bool,

    pub fn deinit(self: *Set) void {
        for (self.roots.items) |root| self.roots.allocator.free(root);
        self.roots.deinit();
    }
};

/// A single path-segment name. Blank values, `.`, `..`, and names that
/// contain a separator fall back to `.git`.
pub fn effectiveMarker(configured: []const u8) []const u8 {
    if (configured.len == 0) return default_marker;
    if (std.mem.eql(u8, configured, ".") or std.mem.eql(u8, configured, "..")) return default_marker;
    if (std.mem.indexOfAny(u8, configured, "/\\") != null) return default_marker;
    return configured;
}

pub fn missingMessage(allocator: Allocator, marker: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "No Workspace: no {s} file or directory was found at or above an opened folder.",
        .{effectiveMarker(marker)},
    );
}

/// Directory containing the nearest `marker` at or above `start`, or null when
/// none exists. `start` may be a file or a directory. The caller frees the
/// result.
pub fn find(allocator: Allocator, start: []const u8, marker: []const u8) !?[]u8 {
    const name = effectiveMarker(marker);
    const first = (try locateStart(allocator, start)) orelse return null;
    var current = first;
    while (true) {
        if (hasMarker(current, name)) return current;
        const parent = std.fs.path.dirname(current);
        if (parent == null or parent.?.len == 0 or std.mem.eql(u8, parent.?, current)) {
            allocator.free(current);
            return null;
        }
        const next = try allocator.dupe(u8, parent.?);
        allocator.free(current);
        current = next;
    }
}

/// One Workspace per distinct marker reached from `opened`. Paths that find
/// the same directory collapse to one root. `missing` is set when any path
/// has no marker at or above it.
pub fn resolve(allocator: Allocator, opened: []const []const u8, marker: []const u8) !Set {
    var roots = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit();
    }
    var missing = false;
    for (opened) |path| {
        const root = (try find(allocator, path, marker)) orelse {
            missing = true;
            continue;
        };
        var seen = false;
        for (roots.items) |existing| {
            if (std.mem.eql(u8, existing, root)) {
                seen = true;
                break;
            }
        }
        if (seen) {
            allocator.free(root);
        } else {
            try roots.append(root);
        }
    }
    return .{ .roots = roots, .missing = missing };
}

/// The session Workspace that owns `path`: the nearest marker, when that
/// directory is one of `session_roots`. Null when the path has no marker, or
/// when the nearest marker is a nested root the session did not open.
/// The returned slice points at `session_roots` and is allocated by `allocator`.
pub fn owning(
    allocator: Allocator,
    path: []const u8,
    session_roots: []const []const u8,
    marker: []const u8,
) !?[]const []const u8 {
    const nearest = (try find(allocator, path, marker)) orelse return null;
    defer allocator.free(nearest);
    for (session_roots) |root| {
        if (std.mem.eql(u8, root, nearest)) {
            const one = try allocator.alloc([]const u8, 1);
            one[0] = root;
            return one;
        }
    }
    return null;
}

/// One session warning, after the client is ready, when a folder has no Workspace.
pub fn warnDue(enabled: bool, missing: bool, already_sent: bool, ready: bool) bool {
    return enabled and missing and !already_sent and ready;
}

/// Resolve symlinks once for Workspace ownership and membership comparisons.
/// A not-yet-existing path keeps its suffix below the nearest existing ancestor.
/// The caller frees the result.
pub fn resolvedPath(allocator: Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const parent = std.fs.path.dirname(path) orelse {
            const cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd);
            return std.fs.path.join(allocator, &.{ cwd, path });
        };
        if (std.mem.eql(u8, parent, path)) return allocator.dupe(u8, path);
        const resolved = try resolvedPath(allocator, parent);
        defer allocator.free(resolved);
        return std.fs.path.join(allocator, &.{ resolved, std.fs.path.basename(path) });
    };
}

fn locateStart(allocator: Allocator, start: []const u8) !?[]u8 {
    if (start.len == 0) return null;
    if (std.fs.cwd().openDir(start, .{})) |opened| {
        var dir = opened;
        defer dir.close();
        return try dir.realpathAlloc(allocator, ".");
    } else |_| {}

    const parent = std.fs.path.dirname(start) orelse return null;
    if (std.mem.eql(u8, parent, start)) return null;
    // A file, or a path that does not exist yet: keep walking from its parent.
    if (std.fs.cwd().openFile(start, .{})) |file| file.close() else |_| {}
    return locateStart(allocator, parent);
}

fn hasMarker(dir_path: []const u8, marker: []const u8) bool {
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return false;
    defer dir.close();
    dir.access(marker, .{}) catch return false;
    return true;
}

const testing = std.testing;

const Fix = struct {
    allocator: Allocator,
    root: []u8,

    fn init(allocator: Allocator) !Fix {
        var n: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&n));
        const root = try std.fmt.allocPrint(allocator, "/tmp/zals-ws-{x}", .{n});
        errdefer allocator.free(root);
        try std.fs.cwd().makePath(root);
        return .{ .allocator = allocator, .root = root };
    }

    fn deinit(self: *Fix) void {
        std.fs.cwd().deleteTree(self.root) catch {};
        self.allocator.free(self.root);
    }

    fn open(self: Fix) !std.fs.Dir {
        return std.fs.cwd().openDir(self.root, .{});
    }

    fn real(self: Fix, a: Allocator, rel: []const u8) ![]u8 {
        var dir = try self.open();
        defer dir.close();
        if (rel.len == 0) return dir.realpathAlloc(a, ".");
        return dir.realpathAlloc(a, rel);
    }

    fn join(self: Fix, a: Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(a, &.{ self.root, rel });
    }

    fn gitDir(self: Fix, rel: []const u8) !void {
        var dir = try self.open();
        defer dir.close();
        if (rel.len == 0) {
            try dir.makeDir(".git");
            return;
        }
        try dir.makePath(rel);
        var sub = try dir.openDir(rel, .{});
        defer sub.close();
        try sub.makeDir(".git");
    }

    fn gitFile(self: Fix, rel: []const u8) !void {
        var dir = try self.open();
        defer dir.close();
        if (rel.len != 0) try dir.makePath(rel);
        const sub_path = if (rel.len == 0)
            ".git"
        else
            try std.fs.path.join(self.allocator, &.{ rel, ".git" });
        defer if (rel.len != 0) self.allocator.free(sub_path);
        try dir.writeFile(.{ .sub_path = sub_path, .data = "gitdir: /unused\n" });
    }

    fn touch(self: Fix, rel: []const u8) !void {
        var dir = try self.open();
        defer dir.close();
        if (std.fs.path.dirname(rel)) |parent| {
            if (parent.len > 0) try dir.makePath(parent);
        }
        try dir.writeFile(.{ .sub_path = rel, .data = "" });
    }
};

fn expectWorkspace(a: Allocator, start: []const u8, expected: []const u8) !void {
    const found = (try find(a, start, default_marker)).?;
    try testing.expectEqualStrings(expected, found);
}

test "git directory above an opened subfolder" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("");
    try fix.touch("playbooks/site.yml");
    try fix.touch("roles/web/tasks/main.yml");
    const workspace = try fix.real(a, "");
    try expectWorkspace(a, try fix.join(a, "playbooks"), workspace);
    try expectWorkspace(a, try fix.join(a, "playbooks/site.yml"), workspace);

    var set = try resolve(a, &.{try fix.join(a, "playbooks")}, default_marker);
    defer set.deinit();
    try testing.expect(!set.missing);
    try testing.expectEqual(@as(usize, 1), set.roots.items.len);
    try testing.expectEqualStrings(workspace, set.roots.items[0]);
    const role = try owning(a, try fix.join(a, "roles/web/tasks/main.yml"), set.roots.items, default_marker);
    try testing.expectEqualStrings(workspace, role.?[0]);
}

test "git file marks the directory that contains it" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitFile("acme-wt");
    try fix.touch("acme-wt/site.yml");
    const workspace = try fix.real(a, "acme-wt");
    try expectWorkspace(a, try fix.join(a, "acme-wt/site.yml"), workspace);
}

test "nested git directory lies outside the parent" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("");
    try fix.gitDir("vendor/lib");
    try fix.touch("playbooks/site.yml");
    try fix.touch("vendor/lib/tasks/main.yml");
    const parent = try fix.real(a, "");
    const nested = try fix.real(a, "vendor/lib");

    try expectWorkspace(a, try fix.join(a, "playbooks/site.yml"), parent);
    try expectWorkspace(a, try fix.join(a, "vendor/lib/tasks/main.yml"), nested);

    var parent_only = try resolve(a, &.{parent}, default_marker);
    defer parent_only.deinit();
    try testing.expect(try owning(a, try fix.join(a, "vendor/lib/tasks/main.yml"), parent_only.roots.items, default_marker) == null);
    try testing.expectEqualStrings(parent, (try owning(a, try fix.join(a, "playbooks/site.yml"), parent_only.roots.items, default_marker)).?[0]);

    var both = try resolve(a, &.{ parent, nested }, default_marker);
    defer both.deinit();
    try testing.expectEqual(@as(usize, 2), both.roots.items.len);
    try testing.expectEqualStrings(nested, (try owning(a, try fix.join(a, "vendor/lib/tasks/main.yml"), both.roots.items, default_marker)).?[0]);
}

test "nested git file lies outside the parent" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("");
    try fix.gitFile("vendor/lib");
    try fix.touch("vendor/lib/tasks/main.yml");
    const parent = try fix.real(a, "");
    const nested = try fix.real(a, "vendor/lib");

    try expectWorkspace(a, try fix.join(a, "vendor/lib"), nested);
    var parent_only = try resolve(a, &.{parent}, default_marker);
    defer parent_only.deinit();
    try testing.expect(try owning(a, try fix.join(a, "vendor/lib/tasks/main.yml"), parent_only.roots.items, default_marker) == null);

    var opened = try resolve(a, &.{try fix.join(a, "vendor/lib")}, default_marker);
    defer opened.deinit();
    try testing.expectEqualStrings(nested, opened.roots.items[0]);
}

test "two folders under one git are one workspace" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("");
    try fix.touch("playbooks/site.yml");
    try fix.touch("roles/web/tasks/main.yml");
    var set = try resolve(a, &.{
        try fix.join(a, "playbooks"),
        try fix.join(a, "roles"),
    }, default_marker);
    defer set.deinit();
    try testing.expect(!set.missing);
    try testing.expectEqual(@as(usize, 1), set.roots.items.len);
    try testing.expectEqualStrings(try fix.real(a, ""), set.roots.items[0]);
}

test "two git directories are two workspaces" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("acme");
    try fix.gitDir("other");
    var set = try resolve(a, &.{
        try fix.join(a, "acme"),
        try fix.join(a, "other"),
    }, default_marker);
    defer set.deinit();
    try testing.expect(!set.missing);
    try testing.expectEqual(@as(usize, 2), set.roots.items.len);
    try testing.expectEqualStrings(try fix.real(a, "acme"), set.roots.items[0]);
    try testing.expectEqualStrings(try fix.real(a, "other"), set.roots.items[1]);
}

test "no git has no workspace" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.touch("site.yml");
    try testing.expect(try find(a, try fix.join(a, "site.yml"), default_marker) == null);
    var set = try resolve(a, &.{try fix.join(a, "")}, default_marker);
    defer set.deinit();
    try testing.expect(set.missing);
    try testing.expectEqual(@as(usize, 0), set.roots.items.len);
}

test "worktree git file is its own workspace beside the main checkout" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("acme");
    try fix.gitFile("acme-wt");
    try fix.touch("acme-wt/site.yml");
    const worktree = try fix.real(a, "acme-wt");
    try expectWorkspace(a, try fix.join(a, "acme-wt/site.yml"), worktree);

    var set = try resolve(a, &.{
        try fix.join(a, "acme"),
        try fix.join(a, "acme-wt"),
    }, default_marker);
    defer set.deinit();
    try testing.expectEqual(@as(usize, 2), set.roots.items.len);
    try testing.expectEqualStrings(try fix.real(a, "acme"), set.roots.items[0]);
    try testing.expectEqualStrings(worktree, set.roots.items[1]);
}

test "opening the git directory itself resolves to its parent" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("");
    try expectWorkspace(a, try fix.join(a, ".git"), try fix.real(a, ""));
}

test "custom marker replaces .git" {
    const gpa = testing.allocator;
    var fix = try Fix.init(gpa);
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try fix.gitDir("");
    try fix.touch("playbooks/ansible.cfg");
    try fix.touch("playbooks/site.yml");
    try fix.touch("roles/web/tasks/main.yml");
    const repo = try fix.real(a, "");
    const playbooks = try fix.real(a, "playbooks");
    const site = try fix.join(a, "playbooks/site.yml");
    const role = try fix.join(a, "roles/web/tasks/main.yml");

    try testing.expectEqualStrings(repo, (try find(a, site, default_marker)).?);
    try testing.expectEqualStrings(playbooks, (try find(a, site, "ansible.cfg")).?);
    try testing.expectEqualStrings(repo, (try find(a, role, default_marker)).?);
    try testing.expect(try find(a, role, "ansible.cfg") == null);
}

test "blank or path marker falls back to .git" {
    try testing.expectEqualStrings(default_marker, effectiveMarker(""));
    try testing.expectEqualStrings(default_marker, effectiveMarker("."));
    try testing.expectEqualStrings(default_marker, effectiveMarker(".."));
    try testing.expectEqualStrings(default_marker, effectiveMarker("foo/bar"));
    try testing.expectEqualStrings("ansible.cfg", effectiveMarker("ansible.cfg"));
    try testing.expectEqualStrings(".ansible-lint", effectiveMarker(".ansible-lint"));
}

test "missing workspace warning is one session notice" {
    try testing.expect(warnDue(true, true, false, true));
    try testing.expect(!warnDue(false, true, false, true));
    try testing.expect(!warnDue(true, false, false, true));
    try testing.expect(!warnDue(true, true, true, true));
    try testing.expect(!warnDue(true, true, false, false));
}
