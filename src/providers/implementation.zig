//! Go to implementation: open a role's main task file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");

/// The main task file of every role the reference can resolve to: the one
/// Ansible would run, or every Workspace fallback match (ADR-0032).
pub fn implementation(self: *Server, a: Allocator, params: std.json.Value) !?[]const types.Location {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const arena = cur.forest.allocator();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getRoleDeclaredCollections(arena, path, cur.path) catch &.{};
    var locs = std.array_list.Managed(types.Location).init(a);
    for (util.resolveRoleAll(self, a, ref.name, path, collections)) |dir| {
        const target = roles.targets.implementationTarget(a, dir) orelse continue;
        try locs.append(try util.fileLocation(a, target));
    }
    if (locs.items.len == 0) return null;
    return try locs.toOwnedSlice();
}
