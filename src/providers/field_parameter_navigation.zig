//! Protocol adapters for typed variable navigation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const navigation = @import("../queries/variable_navigation.zig");

pub fn definition(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterLocations(&subject, .definition, true);
}

pub fn implementation(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterLocations(&subject, .implementation, true);
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterHover(&subject, true);
}
