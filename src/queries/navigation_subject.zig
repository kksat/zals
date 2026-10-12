//! Request-local navigation subjects. Candidate classifications deliberately
//! coexist: definition, references and hover have different precedence rules.
//! No docs lookup occurs while preparing a subject.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const variables = @import("../variables/root.zig");
const yaml = @import("../yaml/root.zig");
const workspace_view = @import("../providers/workspace_view.zig");

pub const Position = struct { uri: []const u8, offset: usize };

/// Borrows its open document and the handler's lease. Forest storage is owned
/// until deinit; classification names must not escape the request. Workspace
/// preparation is lazy, and even an absent Workspace is cached.
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
    view: ?workspace_view.View = null,
    workspace_checked: bool = false,

    pub fn at(server: *Server, position: Position) ?Subject {
        const doc = server.documents.get(position.uri) orelse return null;
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

    pub fn workspace(self: *Subject, server: *Server, a: Allocator) !?*workspace_view.View {
        if (!self.workspace_checked) {
            self.view = try workspace_view.View.forUri(server, a, self.doc.uri);
            self.workspace_checked = true;
        }
        if (self.view) |*view| return view;
        return null;
    }
};
