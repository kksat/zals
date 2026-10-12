//! Ordinary root-variable definition and implementation queries. The query
//! owns occurrence detection, Workspace/fallback selection, ranked search,
//! schema filtering and source-span conversion; protocol dispatch stays in
//! the provider.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");
const source = @import("../providers/variable_source.zig");
const workspace = @import("../providers/workspace_view.zig");

pub const Position = struct {
    uri: []const u8,
    offset: usize,
};

pub const Target = enum { definition, implementation };

/// A request-local semantic query bound to the real open-buffer/filesystem
/// adapter. The handler's WorkspaceIndex.QueryLease keeps indexed facts and
/// discovery inputs stable; this owner neither acquires nor releases a lease.
/// Results and temporary storage belong to the request allocator. Do not
/// retain the query or its borrowed inputs beyond the request.
pub const Query = struct {
    allocator: Allocator,
    files: source.ServerSource,

    /// Bind production dependencies once; callers do not select storage or
    /// coordinate Workspace reads. All subsequent input is semantic and typed.
    pub fn init(server: *Server, a: Allocator) Query {
        return .{ .allocator = a, .files = .{ .server = server } };
    }

    /// Reads and bindings share ranked targets. Definition includes schema
    /// declarations and elsewhere Workspace candidates; implementation omits
    /// only schema declarations, preserving the remaining order. Null means
    /// inapplicable; an empty slice means a root occurrence without targets.
    pub fn locations(self: *Query, position: Position, target: Target) !?[]const types.Location {
        const a = self.allocator;
        var index = variables.Index.init(a, self.files.source());
        const current = (try index.occurrenceAt(a, position.uri, position.offset)) orelse return null;
        var out = std.array_list.Managed(types.Location).init(a);

        if (try workspace.View.forUri(self.files.server, a, position.uri)) |found| {
            var view = found;
            const path = try paths.uriToPath(a, position.uri);
            const reachable = try view.reachableFiles(path);
            for (try workspace.view.definitions(a, view.files, current.name, reachable)) |candidate| {
                if (target == .implementation and candidate.site == .argument_specs) continue;
                try out.append(try view.location(candidate.uri, candidate.start, candidate.end));
            }
        } else {
            for (try index.definitions(a, position.uri, current.name)) |candidate| {
                if (target == .implementation and candidate.site == .argument_specs) continue;
                try out.append(try source.location(a, self.files.server, &index, candidate));
            }
        }
        return try out.toOwnedSlice();
    }
};
