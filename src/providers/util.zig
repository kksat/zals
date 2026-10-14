//! Shared helpers for LSP providers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");

pub const Cursor = struct {
    doc: *Document,
    offset: usize,
    forest: yaml.Forest,
    path: []*yaml.Node,
};

pub fn cursorAt(self: *Server, params: Value) ?struct { doc: *Document, offset: usize } {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    const pos_v = json_util.field(params, "position") orelse return null;
    const pos = json_util.position(pos_v) orelse return null;
    const doc = self.documents.get(uri) orelse return null;
    const offset = doc.offsetAt(pos) orelse return null;
    return .{ .doc = doc, .offset = offset };
}

pub fn parseAt(self: *Server, a: Allocator, params: Value) ?Cursor {
    const loc = cursorAt(self, params) orelse return null;
    var forest = yaml.parse(a, loc.doc.bytes()) catch return null;
    const found: []*yaml.Node = (forest.pathAt(loc.offset, true) catch null) orelse &.{};
    return .{ .doc = loc.doc, .offset = loc.offset, .forest = forest, .path = found };
}

pub fn currentKey(path: []*yaml.Node) ?[]const u8 {
    if (path.len == 0) return null;
    const n = path[path.len - 1];
    return n.stringValue();
}

pub fn leafPair(path: []*yaml.Node) ?*yaml.Node {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i].isPair()) return path[i];
    }
    return null;
}

/// Build a `Location` pointing at the start of `path` (ADR-0009).
pub fn fileLocation(a: Allocator, path: []const u8) !types.Location {
    return .{
        .uri = try paths.pathToUri(a, path),
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        },
    };
}

/// Resolve a role name for the referencing file, using its Workspace and the
/// search paths that apply to it (ADR-0032).
pub fn resolveRole(
    self: *Server,
    a: Allocator,
    name: []const u8,
    referencing_path: []const u8,
    declared_collections: []const []const u8,
) ?[]const u8 {
    const all = resolveRoleAll(self, a, name, referencing_path, declared_collections);
    return if (all.len > 0) all[0] else null;
}

/// Every candidate directory for a role name: the one Ansible would use, or
/// all Workspace fallback matches when Ansible would find none.
pub fn resolveRoleAll(
    self: *Server,
    a: Allocator,
    name: []const u8,
    referencing_path: []const u8,
    declared_collections: []const []const u8,
) []const []const u8 {
    return roleResolver(self, a, referencing_path, declared_collections).resolveAll(name, referencing_path);
}

pub fn roleResolver(
    self: *Server,
    a: Allocator,
    referencing_path: []const u8,
    declared_collections: []const []const u8,
) roles.Resolver {
    const ctx = self.projectContext(a, referencing_path);
    const workspace_collections = if (ctx.workspace_root) |root| blk: {
        var v = @import("workspace_view.zig").View.init(self, a, root) catch break :blk &.{};
        break :blk v.workspaceCollections() catch &.{};
    } else &.{};
    return roleResolverWithCollections(self, a, referencing_path, declared_collections, workspace_collections);
}

pub fn roleResolverWithCollections(
    self: *Server,
    a: Allocator,
    referencing_path: []const u8,
    declared_collections: []const []const u8,
    workspace_collections: []const roles.resolve.WorkspaceCollection,
) roles.Resolver {
    const ctx = self.projectContext(a, referencing_path);
    return .{
        .allocator = a,
        .roles_paths = project_config.rolesPaths(a, ctx, referencing_path) catch &.{},
        .collections_paths = project_config.collectionsPaths(a, ctx, referencing_path) catch &.{},
        .workspace_collections = workspace_collections,
        .workspace_root = ctx.workspace_root,
        .workspace_roles_dirs = self.workspaceRolesDirs(ctx.workspace_root),
        .declared_collections = declared_collections,
    };
}
