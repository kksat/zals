//! Go to implementation: open a role's main task file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");

pub fn implementation(self: *Server, a: Allocator, params: std.json.Value) !?types.Location {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const arena = cur.forest.allocator();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getDeclaredCollections(arena, cur.path) catch &.{};
    const dir = util.resolveRole(self, a, ref.name, path, collections) orelse return null;
    const target = roles.targets.implementationTarget(a, dir) orelse return null;
    return try util.fileLocation(a, target);
}
