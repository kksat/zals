//! Shared helpers for LSP providers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");

pub fn currentKey(path: []*yaml.Node) ?[]const u8 {
    if (path.len == 0) return null;
    const n = path[path.len - 1];
    return n.stringValue();
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
