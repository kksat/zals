//! Request-local navigation subjects. Candidate classifications deliberately
//! coexist: definition, references and hover have different precedence rules.
//! No docs lookup occurs while preparing a subject.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("../workspace/document.zig").Document;
const variables = @import("../variables/root.zig");
const yaml = @import("../yaml/root.zig");
const Context = @import("context.zig").Context;

pub const Position = struct { uri: []const u8, offset: usize };

/// Borrows its open document through the request's navigation context.
/// Forest storage is owned until deinit; classification names must not
/// escape the request. The owning Workspace comes from the context, which
/// prepares it lazily once per request.
pub const Subject = struct {
    doc: *Document,
    offset: usize,
    root: ?variables.Cursor = null,
    field: ?variables.Cursor = null,
    root_checked: bool = false,
    field_checked: bool = false,
    forest: ?yaml.Forest = null,
    path: []*yaml.Node = &.{},
    parsed: bool = false,

    pub fn at(context: *const Context, position: Position) ?Subject {
        const doc = context.document(position.uri) orelse return null;
        if (position.offset > doc.bytes().len) return null;
        return .{ .doc = doc, .offset = position.offset };
    }

    pub fn deinit(self: *Subject) void {
        if (self.forest) |*forest| forest.deinit();
    }

    pub fn parse(self: *Subject, a: Allocator) ?*yaml.Forest {
        if (!self.parsed) {
            self.parsed = true;
            self.forest = yaml.parse(a, self.doc.bytes()) catch return null;
            self.path = (self.forest.?.pathAt(self.offset, true) catch null) orelse &.{};
        }
        if (self.forest) |*forest| return forest;
        return null;
    }
};
