//! Protocol adapters for semantic navigation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const file_query = @import("../queries/file_navigation.zig");
const Subject = @import("../queries/navigation_subject.zig").Subject;

pub const At = file_query.At;
pub const Definition = file_query.Definition;

pub fn refAt(self: *Server, a: Allocator, params: Value) !?At {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return file_query.refAt(self, a, &subject);
}

pub fn definition(self: *Server, a: Allocator, params: Value) !Definition {
    const loc = util.cursorAt(self, params) orelse return .skip;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return .skip;
    defer subject.deinit();
    return file_query.definition(self, a, &subject);
}

pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return file_query.references(self, a, &subject);
}
