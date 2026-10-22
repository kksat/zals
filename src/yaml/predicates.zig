//! Cursor-path adapters over the Ansible structure classifier.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;
const AncestryBuilder = @import("ancestry.zig").AncestryBuilder;
const plays = @import("plays.zig");

pub const mapKeys = dom.mapKeys;

fn keyMap(arena: Allocator, path: []*Node) ?*Node {
    var b = AncestryBuilder.init(arena, path);
    b.parentOfKey();
    return b.get();
}

/// Whether the path points at a parameter key of an Ansible Task.
pub fn isTaskParam(arena: Allocator, path: []*Node) bool {
    const map = keyMap(arena, path) orelse return false;
    return switch (plays.classify(map, .{}).kind) {
        .task => true,
        // Preserve the cursor's rescue/always-only gap (D6).
        .block => dom.findPair(map, "block") == null,
        else => false,
    };
}

/// Whether the path points at a Play or playbook import. Unknown task-file
/// roots are uncertain, allowing completion to offer Play keywords too.
pub fn isPlayParam(arena: Allocator, path: []*Node, file_uri: ?[]const u8) ?bool {
    const map = keyMap(arena, path) orelse return false;
    const class = plays.classify(map, .{ .role_tasks = if (file_uri) |uri| isInRoleTasks(uri) else false });
    if (class.ambiguous) return null;
    return class.kind == .play or class.kind == .playbook_import;
}

fn isInRoleTasks(uri: []const u8) bool {
    const marker = "/roles/";
    const idx = std.mem.indexOf(u8, uri, marker) orelse return false;
    const rest = uri[idx + marker.len ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    return std.mem.startsWith(u8, rest[slash..], "/tasks/");
}

pub fn isBlockParam(arena: Allocator, path: []*Node) bool {
    const map = keyMap(arena, path) orelse return false;
    return plays.classify(map, .{}).kind == .block and dom.findPair(map, "block") != null;
}

pub fn isRoleParam(arena: Allocator, path: []*Node) bool {
    return plays.classify(keyMap(arena, path) orelse return false, .{}).kind == .role_invocation;
}
