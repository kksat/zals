//! Role/playbook scope: locating the role root, enumerating its files, and
//! resolving `vars_files`/`include_vars` targets (ADR-0024).

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../yaml/dom.zig");
const Node = dom.Node;
const definitions = @import("definitions.zig");
const source_mod = @import("source.zig");
const file_refs = @import("../workspace/file_refs.zig");
const FileSource = source_mod.FileSource;

pub const FileKind = definitions.FileKind;

const conventional_dirs = [_][]const u8{ "defaults", "vars", "tasks", "handlers", "templates", "meta" };

pub const uriToPath = @import("../paths.zig").uriToPath;
pub const pathToUri = @import("../paths.zig").pathToUri;

/// The nearest ancestor directory that contains a conventional role subdir, or
/// null when the file is not inside a role.
pub fn roleRoot(allocator: Allocator, source: FileSource, path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(path) orelse return null;
    while (true) {
        if (hasConventionalDir(allocator, source, dir) and isRoleRoot(allocator, source, dir)) {
            return allocator.dupe(u8, dir) catch null;
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

fn hasConventionalDir(allocator: Allocator, source: FileSource, dir: []const u8) bool {
    const entries = source.listDir(allocator, dir) catch return false;
    for (entries) |e| {
        if (!e.is_dir) continue;
        for (conventional_dirs) |name| {
            if (std.mem.eql(u8, e.name, name)) return true;
        }
    }
    return false;
}

fn isRoleRoot(allocator: Allocator, source: FileSource, dir: []const u8) bool {
    if (std.fs.path.dirname(dir)) |parent| {
        if (std.mem.eql(u8, std.fs.path.basename(parent), "roles")) return true;
    }
    for ([_][]const u8{ "main.yml", "main.yaml" }) |name| {
        const meta = std.fs.path.join(allocator, &.{ dir, "meta", name }) catch continue;
        const uri = pathToUri(allocator, meta) catch continue;
        if (source.read(allocator, uri) catch null) |text| {
            allocator.free(text);
            return true;
        }
    }
    return false;
}

/// Only files in a known Role's conventional directories are Role metadata,
/// defaults, or vars. A playbook's `vars/` directory is a loaded vars file.
pub fn fileKind(path: []const u8, role_root: ?[]const u8) FileKind {
    const role = role_root orelse return .general;
    const dir = std.fs.path.dirname(path) orelse return .general;
    if (!std.mem.eql(u8, std.fs.path.dirname(dir) orelse return .general, role)) return .general;
    const parent = std.fs.path.basename(dir);
    if (std.mem.eql(u8, parent, "defaults")) return .role_defaults;
    if (std.mem.eql(u8, parent, "vars")) return .role_vars;
    if (std.mem.eql(u8, parent, "meta")) return .role_meta;
    return .general;
}

/// Every `.yml`/`.yaml`/`.j2` file under the role's conventional directories.
/// Paths are allocated with `allocator` (expected to be an arena).
pub fn enumerateFiles(allocator: Allocator, source: FileSource, root: []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    for (conventional_dirs) |name| {
        const dir = std.fs.path.join(allocator, &.{ root, name }) catch continue;
        try walkDir(allocator, source, dir, &out);
    }
    return out.toOwnedSlice();
}

fn walkDir(
    allocator: Allocator,
    source: FileSource,
    dir: []const u8,
    out: *std.array_list.Managed([]const u8),
) !void {
    const entries = source.listDir(allocator, dir) catch return;
    for (entries) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const full = std.fs.path.join(allocator, &.{ dir, entry.name }) catch continue;
        if (entry.is_dir) {
            try walkDir(allocator, source, full, out);
        } else if (hasYamlExt(entry.name)) {
            try out.append(full);
        }
    }
}

fn hasYamlExt(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".yml") or
        std.mem.endsWith(u8, name, ".yaml") or
        std.mem.endsWith(u8, name, ".j2");
}

/// A reachable vars file and the construct that loaded it. Two sites may
/// load the same file; navigation keeps one definition and ranks it using the
/// highest-precedence reachable load.
pub const VarFileLoad = struct {
    path: []const u8,
    site: definitions.Site,
};

/// `vars_files` and `include_vars` targets with their source kind, resolved
/// like file navigation: from the source file, its Role vars directory, then
/// the Workspace root.
pub fn varFileLoads(allocator: Allocator, forest: *const dom.Forest, file_path: []const u8, root: ?[]const u8) ![]const VarFileLoad {
    var out = std.array_list.Managed(VarFileLoad).init(allocator);
    for (forest.roots) |node| try walkTargets(allocator, node, file_path, root, &out);
    return out.toOwnedSlice();
}

/// Absolute paths without provenance, for callers that only need the file set.
pub fn varFileTargets(allocator: Allocator, forest: *const dom.Forest, file_path: []const u8, root: ?[]const u8) ![]const []const u8 {
    const loads = try varFileLoads(allocator, forest, file_path, root);
    const paths = try allocator.alloc([]const u8, loads.len);
    for (loads, 0..) |load, i| paths[i] = load.path;
    return paths;
}

fn walkTargets(
    allocator: Allocator,
    node: *const Node,
    file_path: []const u8,
    root: ?[]const u8,
    out: *std.array_list.Managed(VarFileLoad),
) !void {
    switch (node.kind) {
        .map => {
            for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
                const val = pair.val orelse continue;
                if (std.mem.eql(u8, key, "vars_files")) {
                    try addTargets(allocator, val, file_path, root, out);
                } else if (isModuleKey(key, "include_vars")) {
                    try addIncludeVars(allocator, val, file_path, root, out);
                }
                try walkTargets(allocator, val, file_path, root, out);
            }
        },
        .seq => for (node.items) |item| try walkTargets(allocator, item, file_path, root, out),
        else => {},
    }
}

fn addTargets(
    allocator: Allocator,
    val: *const Node,
    file_path: []const u8,
    root: ?[]const u8,
    out: *std.array_list.Managed(VarFileLoad),
) !void {
    if (val.isScalar()) {
        if (val.stringValue()) |s| try appendResolved(allocator, s, file_path, root, .vars_files, out);
    } else if (val.isSeq()) {
        for (val.items) |item| {
            if (item.stringValue()) |s| try appendResolved(allocator, s, file_path, root, .vars_files, out);
        }
    }
}

fn addIncludeVars(
    allocator: Allocator,
    val: *const Node,
    file_path: []const u8,
    root: ?[]const u8,
    out: *std.array_list.Managed(VarFileLoad),
) !void {
    if (val.isScalar()) {
        if (val.stringValue()) |s| {
            if (includeVarsPath(s)) |target| try appendResolved(allocator, target, file_path, root, .include_vars, out);
        }
    } else if (val.isMap()) {
        // A `name:` prefix namespaces the loaded variables; deferred (ADR-0024).
        if (dom.findPair(val, "name") != null) return;
        if (dom.findPair(val, "file")) |p| {
            if (p.val) |v| {
                if (v.stringValue()) |s| try appendResolved(allocator, s, file_path, root, .include_vars, out);
            }
        }
    }
}

fn includeVarsPath(s: []const u8) ?[]const u8 {
    var file: ?[]const u8 = null;
    var other_key_value = false;
    var tokens = std.mem.tokenizeAny(u8, s, " \t");
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, "name=")) return null;
        if (std.mem.startsWith(u8, token, "file=")) {
            file = std.mem.trim(u8, token["file=".len..], "\"'");
        } else if (std.mem.indexOfScalar(u8, token, '=') != null) {
            other_key_value = true;
        }
    }
    if (file) |path| return path;
    if (other_key_value) return null;
    return s;
}

fn appendResolved(
    allocator: Allocator,
    target: []const u8,
    file_path: []const u8,
    root: ?[]const u8,
    site: definitions.Site,
    out: *std.array_list.Managed(VarFileLoad),
) !void {
    if (target.len == 0 or std.mem.indexOf(u8, target, "{{") != null or std.mem.indexOf(u8, target, "{%") != null) return;
    const path = try file_refs.resolveTarget(allocator, .vars_file, target, file_path, root);
    try out.append(.{ .path = path, .site = site });
}

fn isModuleKey(key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, key, name)) return true;
    if (key.len > name.len + 1 and key[key.len - name.len - 1] == '.') {
        return std.mem.endsWith(u8, key, name);
    }
    return false;
}

const testing = std.testing;
const yaml = @import("../yaml/root.zig");

test "file kind is based on the actual Role root, not the directory name alone" {
    try testing.expectEqual(FileKind.role_defaults, fileKind("/w/roles/r/defaults/main.yml", "/w/roles/r"));
    try testing.expectEqual(FileKind.role_vars, fileKind("/w/roles/r/vars/main.yml", "/w/roles/r"));
    try testing.expectEqual(FileKind.role_meta, fileKind("/w/roles/r/meta/main.yml", "/w/roles/r"));
    try testing.expectEqual(FileKind.general, fileKind("/w/roles/r/tasks/main.yml", "/w/roles/r"));
    try testing.expectEqual(FileKind.general, fileKind("/w/playbooks/vars/release.yml", null));
}

test "vars_files and include_vars targets" {
    const src =
        \\- hosts: all
        \\  vars_files:
        \\    - vars/a.yml
        \\    - /abs/b.yml
        \\  tasks:
        \\    - include_vars: vars/c.yml
        \\    - include_vars:
        \\        file: vars/d.yml
        \\    - include_vars:
        \\        file: vars/e.yml
        \\        name: prefixed
        \\
    ;
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const targets = try varFileTargets(arena.allocator(), &forest, "/base/site.yml", null);
    try testing.expectEqual(@as(usize, 4), targets.len);
    try testing.expectEqualStrings("/base/vars/a.yml", targets[0]);
    try testing.expectEqualStrings("/abs/b.yml", targets[1]);
    try testing.expectEqualStrings("/base/vars/c.yml", targets[2]);
    try testing.expectEqualStrings("/base/vars/d.yml", targets[3]);

    const loads = try varFileLoads(arena.allocator(), &forest, "/base/site.yml", null);
    try testing.expectEqual(definitions.Site.vars_files, loads[0].site);
    try testing.expectEqual(definitions.Site.include_vars, loads[2].site);
    try testing.expectEqual(definitions.Site.include_vars, loads[3].site);
}

test "key-value include_vars loads use Workspace-root fallback and skip namespaced vars" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("playbooks/vars");
    try tmp.dir.makePath("negative");
    try tmp.dir.writeFile(.{ .sub_path = "playbooks/vars/runtime.yml", .data = "flag: true\n" });
    try tmp.dir.writeFile(.{ .sub_path = "playbooks/vars/release.yml", .data = "flag: false\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const path = try std.fs.path.join(a, &.{ root, "negative", "play.yml" });
    var forest = try yaml.parse(a,
        \\- hosts: all
        \\  vars_files: playbooks/vars/release.yml
        \\  tasks:
        \\    - include_vars: file=playbooks/vars/runtime.yml
        \\    - include_vars: "file=playbooks/vars/runtime.yml name=hidden"
        \\
    );
    defer forest.deinit();
    const loads = try varFileLoads(a, &forest, path, root);
    try testing.expectEqual(@as(usize, 2), loads.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "playbooks/vars/release.yml" }), loads[0].path);
    try testing.expectEqual(definitions.Site.vars_files, loads[0].site);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "playbooks/vars/runtime.yml" }), loads[1].path);
    try testing.expectEqual(definitions.Site.include_vars, loads[1].site);
}
