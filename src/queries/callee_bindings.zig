//! Concrete implementations of passed role inputs (ADR-0039, ADR-0042).
//! The query owns source selection, one-level dependency hydration, ranking,
//! selector matching and source locations; parameter/contract detection stays
//! with the callers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = @import("../lsp/server.zig").Server;
const types = @import("../lsp/types.zig");
const document_mod = @import("../workspace/document.zig");
const Document = document_mod.Document;
const LineIndex = document_mod.LineIndex;
const facts = @import("../workspace/facts.zig");
const discover = @import("../workspace/discover.zig");
const view = @import("../workspace/view.zig");
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");
const source = @import("../providers/variable_source.zig");

pub const Selector = union(enum) {
    root_name: []const u8,
    /// Complete root-and-key path; list elements add no component.
    full_path: []const []const u8,
};

/// Request-local query bound to the real open-buffer/filesystem source.
/// The handler owns the lazy WorkspaceIndex.QueryLease; this query never
/// acquires a lease or mutates the index. Results and temporary storage belong
/// to the request allocator and must not outlive the request.
pub const Query = struct {
    allocator: Allocator,
    files: source.ServerSource,
    texts: std.StringHashMap(?[]const u8),
    line_indices: std.StringHashMap(LineIndex),

    pub fn init(server: *Server, a: Allocator) Query {
        return .{
            .allocator = a,
            .files = .{ .server = server },
            .texts = std.StringHashMap(?[]const u8).init(a),
            .line_indices = std.StringHashMap(LineIndex).init(a),
        };
    }

    /// Concrete bindings in the resolved callee's conventional sources plus
    /// one level of their explicit vars loads, never an invoker expansion.
    /// Root and full-path selectors share indexed source reuse and load-site
    /// precedence. Schema-only inputs return an empty slice. Non-Workspace or
    /// not-yet-indexed callees retain filesystem discovery and its ordering.
    pub fn calleeBindings(self: *Query, role_dir: []const u8, selector: Selector) ![]const types.Location {
        if (selector == .full_path and selector.full_path.len == 0) return &.{};
        const a = self.allocator;
        const scope_path = try std.fs.path.join(a, &.{ role_dir, "tasks", "main.yml" });
        if (self.files.server.workspaceRootFor(a, scope_path)) |root| {
            if (try self.indexedBindings(root, role_dir, selector)) |locations| return locations;
        }
        return try self.filesystemBindings(try paths.pathToUri(a, scope_path), selector);
    }

    fn indexedBindings(self: *Query, root: []const u8, role_dir: []const u8, selector: Selector) !?[]const types.Location {
        const a = self.allocator;
        const server = self.files.server;
        var open = std.StringHashMap(*Document).init(a);
        var docs = server.documents.docs.valueIterator();
        while (docs.next()) |doc| {
            const path = paths.uriToPath(a, doc.*.uri) catch continue;
            if (!discover.isWorkspaceFile(path)) continue;
            if (!discover.belongsToWorkspace(root, path, server.settings.root_marker)) continue;
            try open.put(path, doc.*);
        }

        // Borrow a directory-local sorted list, not a whole-Workspace list
        // sorted only to discard unrelated entries. The index still owns
        // freshness/lease preparation; conventional-source filtering stays here.
        var files = std.array_list.Managed(view.File).init(a);
        for (try server.index.entriesWithin(a, root, role_dir)) |entry| {
            if (!view.isCalleeSource(entry.path, role_dir)) continue;
            const file = if (open.get(entry.path)) |doc|
                try self.fromDocument(root, entry.path, doc)
            else
                view.File{ .path = entry.path, .uri = try paths.pathToUri(a, entry.path), .facts = entry.facts };
            try files.append(file);
        }
        var rest = open.iterator();
        while (rest.next()) |item| {
            const path = item.key_ptr.*;
            if (!view.isCalleeSource(path, role_dir) or view.find(files.items, path) != null) continue;
            try files.append(try self.fromDocument(root, path, item.value_ptr.*));
        }

        // Freeze both conventional scope and original load provenance BEFORE
        // hydration. A dependency's own loads never extend this one-level set.
        const set = (try view.calleeFiles(a, files.items, role_dir)) orelse return null;
        try self.hydrate(root, &files, set, &open);
        const bindings = switch (selector) {
            .root_name => |name| try view.calleeRootDefinitions(a, files.items, set, name),
            .full_path => |names| try view.calleeFieldDefinitions(a, files.items, set, names),
        };
        var out = std.array_list.Managed(types.Location).init(a);
        for (bindings) |binding| try out.append(try self.location(binding.uri, binding.start, binding.end));
        return try out.toOwnedSlice();
    }

    fn fromDocument(self: *Query, root: []const u8, path: []const u8, doc: *Document) !view.File {
        return .{ .path = path, .uri = doc.uri, .facts = try facts.extractIn(self.allocator, root, path, doc.bytes()) };
    }

    fn hydrate(self: *Query, root: []const u8, files: *std.array_list.Managed(view.File), set: view.Reachability, open: *const std.StringHashMap(*Document)) !void {
        const a = self.allocator;
        var loaded = std.StringHashMap(void).init(a);
        for (set.loads) |load| {
            if (loaded.contains(load.path)) continue;
            try loaded.put(load.path, {});
            const existing = view.find(files.items, load.path);
            if (discover.isAnsibleFile(std.fs.path.basename(load.path))) {
                if (existing != null) continue;
                if (open.get(load.path)) |doc| {
                    try files.append(try self.fromDocument(root, load.path, doc));
                    continue;
                }
                if (self.files.server.index.get(load.path)) |entry| {
                    if (std.mem.eql(u8, entry.root, root)) {
                        try files.append(.{ .path = entry.path, .uri = try paths.pathToUri(a, entry.path), .facts = entry.facts });
                        continue;
                    }
                }
            }
            const uri = try paths.pathToUri(a, load.path);
            const body = (try self.text(uri)) orelse continue;
            const dependency = try facts.extractDependencyIn(a, root, load.path, body);
            if (existing != null) {
                // Normal non-Ansible source-candidate facts are deliberately
                // empty. Only this explicit load authorizes their hydration.
                for (files.items) |*file| {
                    if (std.mem.eql(u8, file.path, load.path)) file.facts = dependency;
                }
            } else {
                try files.append(.{ .path = load.path, .uri = uri, .facts = dependency });
            }
        }
    }

    fn filesystemBindings(self: *Query, uri: []const u8, selector: Selector) ![]const types.Location {
        const a = self.allocator;
        var index = variables.Index.init(a, self.files.source());
        const bindings = switch (selector) {
            .root_name => |name| try index.definitions(a, uri, name),
            .full_path => |names| try index.fieldDefinitions(a, uri, names[names.len - 1]),
        };
        var out = std.array_list.Managed(types.Location).init(a);
        for (bindings) |binding| {
            if (binding.site == .argument_specs) continue;
            if (selector == .full_path and !equalPath(binding.field_path, selector.full_path)) continue;
            try out.append(try self.location(binding.uri, binding.start, binding.end));
        }
        return try out.toOwnedSlice();
    }

    fn text(self: *Query, uri: []const u8) !?[]const u8 {
        if (self.files.server.documents.get(uri)) |doc| return doc.bytes();
        if (self.texts.get(uri)) |cached| return cached;
        const body = try self.files.source().read(self.allocator, uri);
        try self.texts.put(uri, body);
        return body;
    }

    fn location(self: *Query, uri: []const u8, start: usize, end: usize) !types.Location {
        if (self.files.server.documents.get(uri)) |doc| return .{ .uri = uri, .range = doc.rangeFromOffsets(start, end) };
        const idx = if (self.line_indices.get(uri)) |cached| cached else blk: {
            const body = (try self.text(uri)) orelse "";
            const built = try LineIndex.init(self.allocator, body, self.files.server.encoding);
            try self.line_indices.put(uri, built);
            break :blk built;
        };
        return .{ .uri = uri, .range = idx.rangeFromOffsets(start, end) };
    }
};

fn equalPath(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}
