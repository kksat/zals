//! Go to implementation: open a role's main task file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");

pub fn implementation(self: *Server, a: Allocator, params: Value) !Value {
    var cur = util.parseAt(self, a, params) orelse return Value.null;
    defer cur.forest.deinit();
    const arena = cur.forest.allocator();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return Value.null;
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getDeclaredCollections(arena, cur.path) catch &.{};
    const dir = util.resolveRole(self, a, ref.name, path, collections) orelse return Value.null;
    const target = roles.targets.implementationTarget(a, dir) orelse return Value.null;
    return try util.fileLocation(a, target);
}
