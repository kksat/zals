//! Go to definition: module source files, variable definitions, and roles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const variable_navigation = @import("variable_navigation.zig");

pub const Result = union(enum) {
    none,
    location: types.Location,
    locations: []const types.Location,
};

const RoleResult = union(enum) {
    skip,
    none,
    locations: []const types.Location,
};

pub fn definition(self: *Server, a: Allocator, params: std.json.Value) !Result {
    if (try variable_navigation.locations(self, a, params, .definition)) |locs| return .{ .locations = locs };
    switch (try @import("file_navigation.zig").definition(self, a, params)) {
        .skip => {},
        .none => return .none,
        .location => |loc| return .{ .location = loc },
    }
    switch (try @import("collections.zig").definition(self, a, params)) {
        // An unresolved FQCN prefix still lets the module or role resolve.
        .skip, .none => {},
        .location => |loc| return .{ .location = loc },
    }
    switch (try roleDefinition(self, a, params)) {
        .skip => {},
        .none => return .none,
        .locations => |locs| return if (locs.len == 1) .{ .location = locs[0] } else .{ .locations = locs },
    }
    return moduleDefinition(self, a, params);
}

/// Jump from a role reference to the role's argument specs, metadata, or main
/// task file. `.none` stops the chain when the cursor is on a role-name
/// position but the role cannot be resolved.
fn roleDefinition(self: *Server, a: Allocator, params: std.json.Value) !RoleResult {
    var cur = util.parseAt(self, a, params) orelse return .skip;
    defer cur.forest.deinit();
    const arena = cur.forest.allocator();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return .skip;
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getRoleDeclaredCollections(arena, path, cur.path) catch &.{};
    var locs = std.array_list.Managed(types.Location).init(a);
    for (util.resolveRoleAll(self, a, ref.name, path, collections)) |dir| {
        const target = roles.targets.definitionTarget(a, dir) orelse continue;
        try locs.append(try util.fileLocation(a, target));
    }
    if (locs.items.len == 0) return .none;
    return .{ .locations = try locs.toOwnedSlice() };
}

fn moduleDefinition(self: *Server, a: Allocator, params: std.json.Value) !Result {
    var cur = util.parseAt(self, a, params) orelse return .none;
    defer cur.forest.deinit();
    const name = util.currentKey(cur.path) orelse return .none;
    const arena = cur.forest.allocator();
    const collections = yaml.collections.getDeclaredCollections(arena, cur.path) catch &.{};
    const mod = self.docs.findModuleInContext(arena, name, collections) orelse return .none;
    if (mod.filename.len == 0) return .none;
    return .{ .location = try util.fileLocation(a, mod.filename) };
}
