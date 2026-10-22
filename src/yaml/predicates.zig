//! Cursor-path adapters over the Ansible structure classifier.

const Allocator = @import("std").mem.Allocator;
const scope = @import("../variables/scope.zig");
const roles = @import("../roles/resolve.zig");
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
    const file: plays.File = if (file_uri) |uri| blk: {
        const path_name = scope.uriToPath(arena, uri) catch break :blk .{};
        break :blk scope.fileKind(path_name, roles.enclosingRoleFromPath(path_name)).structure();
    } else .{};
    const class = plays.classify(map, file);
    if (class.ambiguous) return null;
    return class.kind == .play or class.kind == .playbook_import;
}

pub fn isBlockParam(arena: Allocator, path: []*Node) bool {
    const map = keyMap(arena, path) orelse return false;
    return plays.classify(map, .{}).kind == .block and dom.findPair(map, "block") != null;
}

pub fn isRoleParam(arena: Allocator, path: []*Node) bool {
    return plays.classify(keyMap(arena, path) orelse return false, .{}).kind == .role_invocation;
}
