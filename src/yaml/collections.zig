//! Collects `collections:` declarations visible from a module path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;
const plays = @import("plays.zig");
const AncestryBuilder = @import("ancestry.zig").AncestryBuilder;

fn appendForMap(_arena: Allocator, out: *std.array_list.Managed([]const u8), map: *const Node) !void {
    _ = _arena;
    const pair = dom.findPair(map, "collections") orelse return;
    const value = pair.val orelse return;
    if (!value.isSeq()) return;
    for (value.items) |item| {
        if (item.stringValue()) |s| try out.append(s);
    }
}

fn isBlockRescueAlways(key: []const u8) bool {
    return std.mem.eql(u8, key, "block") or
        std.mem.eql(u8, key, "rescue") or
        std.mem.eql(u8, key, "always");
}

/// Collections visible at a role-name site. Only play, task/block, and role
/// metadata maps declare resolution context; a root `collections:` in a
/// requirements file instead lists packages to install. Read from nearest to
/// farthest so local declarations take precedence.
pub fn getRoleDeclaredCollections(arena: Allocator, file_path: []const u8, path: []*Node) ![]const []const u8 {
    var declared = std.array_list.Managed([]const u8).init(arena);
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (declarationMap(file_path, path, i)) try appendForMap(arena, &declared, path[i]);
    }
    return dedupe(arena, declared.items);
}

fn declarationMap(file_path: []const u8, path: []*Node, i: usize) bool {
    const filename = std.fs.path.basename(file_path);
    if (std.mem.eql(u8, filename, "requirements.yml") or std.mem.eql(u8, filename, "requirements.yaml")) return false;
    const map = path[i];
    if (!map.isMap()) return false;
    if (i == 0) return roleMetadata(file_path);
    if (!path[i - 1].isSeq()) return false;
    // Plays are top-level sequence maps. A bare task file is also a sequence,
    // but only a task that invokes a role can contain a role-name site there.
    if (i == 1) return dom.findPair(map, "hosts") != null or roleModuleMap(map);
    if (i < 2 or !path[i - 2].isPair()) return false;
    const key = (path[i - 2].key orelse return false).stringValue() orelse return false;
    for ([_][]const u8{ "tasks", "pre_tasks", "post_tasks", "handlers", "block", "rescue", "always" }) |task_key| {
        if (std.mem.eql(u8, key, task_key)) return true;
    }
    return false;
}

fn roleModuleMap(map: *const Node) bool {
    for (map.items) |pair| {
        const key = (pair.key orelse continue).stringValue() orelse continue;
        for ([_][]const u8{ "include_role", "import_role" }) |module| {
            if (plays.isAction(key, module)) return true;
        }
    }
    return false;
}

fn roleMetadata(file_path: []const u8) bool {
    const parent = std.fs.path.dirname(file_path) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(parent), "meta")) return false;
    const name = std.fs.path.basename(file_path);
    return std.mem.eql(u8, name, "main.yml") or std.mem.eql(u8, name, "main.yaml");
}

/// Collections declared at the task, block, and play levels for `module_path`.
pub fn getDeclaredCollections(arena: Allocator, module_path: []*Node) ![]const []const u8 {
    var declared = std.array_list.Managed([]const u8).init(arena);

    var b = AncestryBuilder.init(arena, module_path);
    b.parent(.map);
    if (b.get()) |task_params| try appendForMap(arena, &declared, task_params);

    var b2 = AncestryBuilder.init(arena, module_path);
    b2.parent(.map);
    var path = b2.getPath() orelse return dedupe(arena, declared.items);

    while (true) {
        var b3 = AncestryBuilder.init(arena, path);
        b3.parent(.seq);
        b3.parent(.map);
        const key = b3.getStringKey() orelse break;
        if (!isBlockRescueAlways(key)) break;
        if (b3.get()) |m| try appendForMap(arena, &declared, m);
        path = b3.getPath() orelse break;
    }

    var b4 = AncestryBuilder.init(arena, path);
    b4.parent(.seq);
    b4.parent(.map);
    if (b4.get()) |play_params| try appendForMap(arena, &declared, play_params);

    return dedupe(arena, declared.items);
}

fn dedupe(arena: Allocator, items: []const []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    for (items) |item| {
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, item)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(item);
    }
    return try out.toOwnedSlice();
}
