//! Definition and implementation for root variables. Both start from reads
//! or bindings and use the same ranked candidates; implementation omits
//! argument-spec declarations, which do not bind a runtime value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");
const util = @import("util.zig");
const vs = @import("variable_source.zig");
const wv = @import("workspace_view.zig");

pub const Target = enum { definition, implementation };

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
    var src = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, src.source());
    const cur = (try index.occurrenceAt(a, loc.doc.uri, loc.offset)) orelse return null;
    var out = std.array_list.Managed(types.Location).init(a);

    if (try wv.View.forUri(self, a, loc.doc.uri)) |found| {
        var v = found;
        const path = try paths.uriToPath(a, loc.doc.uri);
        const reach = try v.reachableFiles(path);
        for (try wv.view.definitions(a, v.files, cur.name, reach)) |d| {
            if (target == .implementation and d.site == .argument_specs) continue;
            try out.append(try v.location(d.uri, d.start, d.end));
        }
    } else {
        for (try index.definitions(a, loc.doc.uri, cur.name)) |d| {
            if (target == .implementation and d.site == .argument_specs) continue;
            try out.append(try vs.location(a, self, &index, d));
        }
    }
    return try out.toOwnedSlice();
}
