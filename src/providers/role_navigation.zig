//! Role references across the Workspace and role hover (ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const RoleRef = @import("../workspace/facts.zig").RoleRef;

const Subject = @import("../queries/navigation_subject.zig").Subject;
const role_query = @import("../queries/role_navigation.zig");
pub const roleCard = role_query.roleCard;
const roleRefMatches = role_query.roleRefMatches;

pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return role_query.references(self, a, &subject);
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var subject = Subject.at(self, .{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return role_query.hover(self, a, &subject);
}

const parameters = @import("../roles/parameters.zig");
pub const Parameter = parameters.Parameter;
pub const parameterAt = parameters.parameterAt;

const navigation = @import("../queries/variable_navigation.zig");

pub fn parameterHover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterHover(&subject, false);
}

pub fn parameterDefinition(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterLocations(&subject, .definition, false);
}

pub fn parameterImplementation(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.parameterLocations(&subject, .implementation, false);
}

pub const OptionSpec = parameters.OptionSpec;
pub const optionSpec = parameters.optionSpec;
pub const optionSpecPathFrom = parameters.optionSpecPathFrom;
