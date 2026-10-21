//! The semantic navigation interface. Protocol callers supply a typed subject
//! and encode the answer; applicability, precedence and docs fallback live here.
//! Internal typed domain operations never call JSON-taking providers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = @import("../lsp/server.zig").Server;
const types = @import("../lsp/types.zig");
const variable_query = @import("variable_navigation.zig");
const files = @import("file_navigation.zig");
const collections = @import("collection_navigation.zig");
const roles = @import("role_navigation.zig");
const yaml = @import("../yaml/root.zig");
const cursor = @import("../cursor.zig");
const hover_format = @import("cursor_hover.zig");
const util = @import("../providers/util.zig");
pub const Position = @import("navigation_subject.zig").Position;
pub const Subject = @import("navigation_subject.zig").Subject;

/// Shape is part of the semantic answer: variable targets stay arrays even
/// when singleton; role singleton and file/collection/module targets are scalar.
pub const Definition = union(enum) {
    none,
    location: types.Location,
    locations: []const types.Location,
};

/// One request's navigation owner, borrowing the existing handler-owned lease.
/// Call deinit on each subject and then this query. Results live in the request
/// allocator; no source-cache bytes or forest storage escape into hover text.
pub const Query = struct {
    bindings: variable_query.Query,

    pub fn init(server: *Server, a: Allocator) Query {
        return .{ .bindings = variable_query.Query.init(server, a) };
    }

    pub fn deinit(self: *Query) void {
        self.bindings.deinit();
    }

    pub fn subjectAt(self: *Query, position: Position) ?Subject {
        return Subject.at(self.bindings.cache.files.server, position);
    }

    /// Definition: fields/parameters/roots, file, collection, role, module.
    /// Recognized empty bindings stop. Missing files/roles stop; unresolved
    /// collections intentionally continue so an FQCN's role/module can resolve.
    pub fn definition(self: *Query, subject: *Subject) !Definition {
        const server = self.bindings.cache.files.server;
        const a = self.bindings.cache.allocator;
        if (try self.bindings.locations(subject, .definition)) |locs| return .{ .locations = locs };
        switch (try files.definition(server, a, subject)) {
            .skip => {},
            .none => return .none,
            .location => |loc| return .{ .location = loc },
        }
        switch (try collections.definition(server, a, subject)) {
            .skip, .none => {},
            .location => |loc| return .{ .location = loc },
        }
        switch (try roles.definition(server, a, subject)) {
            .skip => {},
            .none => return .none,
            .locations => |locs| return if (locs.len == 1) .{ .location = locs[0] } else .{ .locations = locs },
        }
        const forest = subject.parse(a) orelse return .none;
        const name = util.currentKey(subject.path) orelse return .none;
        const declared = yaml.collections.getDeclaredCollections(forest.allocator(), subject.path) catch &.{};
        const lib = try server.docsForUri(a, subject.doc.uri);
        const mod = lib.findModuleInContext(forest.allocator(), name, declared) orelse return .none;
        if (mod.filename.len == 0) return .none;
        return .{ .location = try util.fileLocation(a, mod.filename) };
    }

    /// Implementation has no collection/file/module fallback. Passed keys
    /// retain applicable-empty callee answers, never caller-wide name fallback.
    pub fn implementation(self: *Query, subject: *Subject) !?[]const types.Location {
        if (try self.bindings.locations(subject, .implementation)) |locs| return locs;
        return roles.implementation(self.bindings.cache.files.server, self.bindings.cache.allocator, subject);
    }

    /// References prioritize collection, role, file, field, root. Contracts
    /// affect target selection but never narrow root/leaf-name reference groups.
    pub fn references(self: *Query, subject: *Subject, include_declaration: bool) !?[]const types.Location {
        const server = self.bindings.cache.files.server;
        const a = self.bindings.cache.allocator;
        if (try collections.references(server, a, subject)) |locs| return locs;
        if (try roles.references(server, a, subject)) |locs| return locs;
        if (try files.references(server, a, subject)) |locs| return locs;
        return self.bindings.references(subject, include_declaration);
    }

    /// Navigation-only hover terminates before contextual module catalog
    /// loading (which may shell out when cold). subjectAt/classification never
    /// need docs. Keyword/module formatting is the last, lazy fallback.
    pub fn hover(self: *Query, subject: *Subject) !?types.Hover {
        const server = self.bindings.cache.files.server;
        const a = self.bindings.cache.allocator;
        if (try self.bindings.fieldHover(subject)) |result| return result;
        if (try collections.hover(server, a, subject)) |result| return result;
        if (try roles.hover(server, a, subject)) |result| return result;
        if (try self.bindings.parameterHover(subject, false)) |result| return result;
        if (try self.bindings.rootHover(subject)) |result| return result;
        const forest = subject.parse(a) orelse return null;
        const lib = try server.docsForUri(a, subject.doc.uri);
        const current = try cursor.classify(forest, subject.doc.uri, subject.path, subject.offset, cursor.fromLibrary(lib));
        return hover_format.format(a, subject.doc, current);
    }
};
