//! Structural predicates over YAML paths, ported from upstream's `yamlAst`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;
const AncestryBuilder = @import("ancestry.zig").AncestryBuilder;
const keywords = @import("keywords.zig");

fn isTasksKey(key: []const u8) bool {
    const set = [_][]const u8{ "tasks", "pre_tasks", "post_tasks", "block", "rescue", "always", "handlers" };
    for (set) |s| if (std.mem.eql(u8, s, key)) return true;
    return false;
}

/// Keys of a map node (scalar keys only).
pub fn mapKeys(arena: Allocator, map: *const Node) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(arena);
    for (map.items) |pair| {
        if (pair.key) |k| {
            if (k.stringValue()) |s| try list.append(s);
        }
    }
    return try list.toOwnedSlice();
}

/// Whether the path points at a parameter key of an Ansible task.
pub fn isTaskParam(arena: Allocator, path: []*Node) bool {
    var b = AncestryBuilder.init(arena, path);
    b.parentOfKey();
    b.parent(.seq);
    const task_list_path = b.getPath() orelse return false;

    if (isPlayParam(arena, path, null) orelse false) return false;
    if (isBlockParam(arena, path)) return false;
    if (isRoleParam(arena, path)) return false;

    if (task_list_path.len == 1) return true;

    var b2 = AncestryBuilder.init(arena, task_list_path);
    b2.parent(.map);
    const key = b2.getStringKey() orelse return false;
    return isTasksKey(key);
}

/// Whether the path points at an Ansible play. Returns null when uncertain.
pub fn isPlayParam(arena: Allocator, path: []*Node, file_uri: ?[]const u8) ?bool {
    var b = AncestryBuilder.init(arena, path);
    b.parentOfKey();
    b.parent(.seq);
    const at_root = if (b.getPath()) |p| p.len == 1 else false;
    if (!at_root) return false;

    var b2 = AncestryBuilder.init(arena, path);
    b2.parentOfKey();
    const map_node = b2.get() orelse return null;
    const keys = mapKeys(arena, map_node) catch return null;
    for (keys) |k| {
        if (keywords.isPlayExclusiveKeyword(k)) return true;
    }
    if (file_uri) |uri| {
        if (isInRoleTasks(uri)) return false;
    }
    return null;
}

fn isInRoleTasks(uri: []const u8) bool {
    // Matches /roles/<name>/tasks/
    const marker = "/roles/";
    const idx = std.mem.indexOf(u8, uri, marker) orelse return false;
    const rest = uri[idx + marker.len ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    return std.mem.startsWith(u8, rest[slash..], "/tasks/");
}

/// Whether the path points at one of Ansible's block parameter keys.
pub fn isBlockParam(arena: Allocator, path: []*Node) bool {
    var b = AncestryBuilder.init(arena, path);
    b.parentOfKey();
    const map_node = b.get() orelse return false;
    b.parent(.seq);
    if (b.get() == null) return false;
    const keys = mapKeys(arena, map_node) catch return false;
    for (keys) |k| if (std.mem.eql(u8, k, "block")) return true;
    return false;
}

/// Whether the path points at one of Ansible's role parameter keys.
pub fn isRoleParam(arena: Allocator, path: []*Node) bool {
    var b = AncestryBuilder.init(arena, path);
    b.parentOfKey();
    b.parent(.seq);
    b.parent(.map);
    const key = b.getStringKey() orelse return false;
    return std.mem.eql(u8, key, "roles");
}

test "isTaskParam in playbook" {
    const parser = @import("parser.zig");
    const getPathAt = @import("path.zig").getPathAt;
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: ping
        \\      ping:
        \\
    ;
    var forest = try parser.parse(std.testing.allocator, src);
    defer forest.deinit();
    const arena = forest.allocator();
    const ping_off = std.mem.indexOf(u8, src, "ping:").?;
    const path = (try getPathAt(arena, forest.roots[0], ping_off, true)).?;
    try std.testing.expect(isTaskParam(arena, path));
    try std.testing.expect(!(isPlayParam(arena, path, "file:///play.yml") orelse false));
}

test "isPlayParam at play root" {
    const parser = @import("parser.zig");
    const getPathAt = @import("path.zig").getPathAt;
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - ping:
        \\
    ;
    var forest = try parser.parse(std.testing.allocator, src);
    defer forest.deinit();
    const arena = forest.allocator();
    const hosts_off = std.mem.indexOf(u8, src, "hosts:").?;
    const path = (try getPathAt(arena, forest.roots[0], hosts_off, true)).?;
    try std.testing.expect(isPlayParam(arena, path, "file:///play.yml") orelse false);
}
