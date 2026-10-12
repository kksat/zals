//! Protocol dispatch for variable definition and implementation. Fields and
//! passed role parameters keep priority over the ordinary root-variable query.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const root_navigation = @import("../queries/root_navigation.zig");

pub const Target = root_navigation.Target;

/// Null means the cursor is not on a variable. An empty slice means it is a
/// variable but has no matching bindings (or no concrete implementation).
pub fn locations(self: *Server, a: Allocator, params: std.json.Value, target: Target) !?[]const types.Location {
    if (try @import("field_navigation.zig").locations(self, a, params, target)) |locs| return locs;
    const role_navigation = @import("role_navigation.zig");
    if (target == .definition) {
        if (try role_navigation.parameterDefinition(self, a, params)) |locs| return locs;
    } else {
        if (try role_navigation.parameterImplementation(self, a, params)) |locs| return locs;
    }
    const loc = util.cursorAt(self, params) orelse return null;
    var query = root_navigation.Query.init(self, a);
    return query.locations(.{ .uri = loc.doc.uri, .offset = loc.offset }, target);
}
