//! Find references for Ansible variables across the Workspace (ADR-0025,
//! ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const navigation = @import("../queries/variable_navigation.zig");

pub fn references(self: *Server, a: Allocator, params: std.json.Value) !?[]const types.Location {
    if (try @import("collections.zig").references(self, a, params)) |locs| return locs;
    if (try @import("role_navigation.zig").references(self, a, params)) |locs| return locs;
    if (try @import("file_navigation.zig").references(self, a, params)) |locs| return locs;
    if (try @import("field_navigation.zig").references(self, a, params)) |locs| return locs;

    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    const context = json_util.field(params, "context") orelse std.json.Value.null;
    return query.references(&subject, json_util.boolean(context, "includeDeclaration") orelse false);
}
