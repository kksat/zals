//! Protocol adapters for typed variable navigation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const navigation = @import("../queries/variable_navigation.zig");
const json_util = @import("../lsp/json_util.zig");

pub fn locations(self: *Server, a: Allocator, params: Value, target: navigation.Target) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.fieldLocations(&subject, target);
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.fieldHover(&subject);
}

pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    const context = json_util.field(params, "context") orelse Value.null;
    return query.fieldReferences(&subject, json_util.boolean(context, "includeDeclaration") orelse false);
}
