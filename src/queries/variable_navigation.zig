//! Root and leaf-name field navigation through one request-local search seam.
//! Owns Workspace/fallback selection, ranking, declarations, callee contracts,
//! location mapping and revision-safe descriptions. No protocol params here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");
const source = @import("../providers/variable_source.zig");
const workspace = @import("../providers/workspace_view.zig");
const presentation = @import("../providers/variable_hover.zig");
const descriptions = @import("binding_descriptions.zig");
const parameters = @import("passed_parameters.zig");
pub const Subject = @import("navigation_subject.zig").Subject;
pub const Position = @import("navigation_subject.zig").Position;
pub const Target = enum { definition, implementation };
const Group = enum { root, field };

/// Borrows the handler's request lease; owns its source cache until deinit.
/// Results are request-owned. Description values are normalized/copied before
/// cache teardown; FileSource reads retain their caller-owned-byte contract.
pub const Query = struct {
    cache: descriptions.Cache,

    pub fn init(server: *Server, a: Allocator) Query {
        return .{ .cache = descriptions.Cache.init(server, a) };
    }

    pub fn deinit(self: *Query) void {
        self.cache.deinit();
    }

    pub fn subjectAt(self: *Query, position: Position) ?Subject {
        return Subject.at(self.cache.files.server, position);
    }

    fn occurrence(self: *Query, subject: *Subject, group: Group) !?variables.Cursor {
        var index = variables.Index.init(self.cache.allocator, self.cache.source());
        if (group == .field) {
            if (!subject.field_checked) {
                subject.field = try self.bound(subject, try index.fieldOccurrenceAt(self.cache.allocator, subject.doc.uri, subject.offset));
                subject.field_checked = true;
            }
            return subject.field;
        }
        if (!subject.root_checked) {
            subject.root = try self.bound(subject, try index.occurrenceAt(self.cache.allocator, subject.doc.uri, subject.offset));
            subject.root_checked = true;
        }
        return subject.root;
    }

    /// A load-only key is a binding only when a vars load in the owning
    /// Workspace targets its file (ADR-0045). Without a session Workspace no
    /// loader is known, so the key binds nothing.
    fn bound(self: *Query, subject: *Subject, cursor: ?variables.Cursor) !?variables.Cursor {
        const found = cursor orelse return null;
        if (!found.requires_load) return found;
        const a = self.cache.allocator;
        const view = (try subject.workspace(self.cache.files.server, a)) orelse return null;
        return if (view.isLoaded(try paths.uriToPath(a, subject.doc.uri))) found else null;
    }

    /// Field before passed root parameter before ordinary root. Null skips;
    /// recognized occurrences and parameter implementations may stop with [].
    pub fn locations(self: *Query, subject: *Subject, target: Target) !?[]const types.Location {
        if (try self.fieldLocations(subject, target)) |locs| return locs;
        if (try self.parameterLocations(subject, target, false)) |locs| return locs;
        const current = (try self.occurrence(subject, .root)) orelse return null;
        return try self.namedLocations(subject, current.name, .root, target);
    }

    pub fn fieldLocations(self: *Query, subject: *Subject, target: Target) !?[]const types.Location {
        const current = (try self.occurrence(subject, .field)) orelse return null;
        if (try self.parameterLocations(subject, target, true)) |locs| return locs;
        return try self.namedLocations(subject, current.name, .field, target);
    }

    pub fn parameterLocations(self: *Query, subject: *Subject, target: Target, field: bool) !?[]const types.Location {
        const server = self.cache.files.server;
        const a = self.cache.allocator;
        const context = (try parameters.contextAt(server, a, subject, field)) orelse return null;
        return if (target == .definition) parameters.definition(server, a, context) else try parameters.implementation(server, a, context);
    }

    fn namedLocations(self: *Query, subject: *Subject, name: []const u8, group: Group, target: Target) ![]const types.Location {
        const a = self.cache.allocator;
        const server = self.cache.files.server;
        var out = std.array_list.Managed(types.Location).init(a);
        if (try subject.workspace(server, a)) |view| {
            const reachable = try view.reachableFiles(try paths.uriToPath(a, subject.doc.uri));
            const defs = if (group == .root) try workspace.view.definitions(a, view.files, name, reachable) else try workspace.view.fieldDefinitions(a, view.files, name, reachable);
            for (defs) |candidate| {
                if (target == .implementation and candidate.site == .argument_specs) continue;
                try out.append(try view.location(candidate.uri, candidate.start, candidate.end));
            }
        } else {
            var index = variables.Index.init(a, self.cache.source());
            const defs = if (group == .root) try index.definitions(a, subject.doc.uri, name) else try index.fieldDefinitions(a, subject.doc.uri, name);
            for (defs) |candidate| {
                if (target == .implementation and candidate.site == .argument_specs) continue;
                try out.append(try source.location(a, server, &index, candidate));
            }
        }
        return try out.toOwnedSlice();
    }

    /// Passed-key contracts never narrow references: ordinary root name and
    /// separate leaf-name groups include every binding/read in their scope.
    pub fn references(self: *Query, subject: *Subject, include_declaration: bool) !?[]const types.Location {
        if (try self.fieldReferences(subject, include_declaration)) |locs| return locs;
        const current = (try self.occurrence(subject, .root)) orelse return null;
        return try self.namedReferences(subject, current.name, .root, include_declaration);
    }

    pub fn fieldReferences(self: *Query, subject: *Subject, include_declaration: bool) !?[]const types.Location {
        const current = (try self.occurrence(subject, .field)) orelse return null;
        return try self.namedReferences(subject, current.name, .field, include_declaration);
    }

    fn namedReferences(self: *Query, subject: *Subject, name: []const u8, group: Group, include_declaration: bool) ![]const types.Location {
        const a = self.cache.allocator;
        const server = self.cache.files.server;
        var out = std.array_list.Managed(types.Location).init(a);
        if (try subject.workspace(server, a)) |view| {
            if (group == .root) {
                for (try workspace.view.occurrences(a, view.files, name)) |candidate| {
                    if (candidate.kind == .definition and !include_declaration) continue;
                    try out.append(try view.location(candidate.uri, candidate.start, candidate.end));
                }
            } else {
                // Preserve field traversal ordering: declarations, then reads,
                // per file. The sorted fieldOccurrences helper is NOT equivalent.
                for (view.files) |file| {
                    if (include_declaration) for (file.facts.field_defs) |def| {
                        if (std.mem.eql(u8, def.name, name)) try out.append(try view.location(file.uri, def.start, def.end));
                    };
                    for (file.facts.field_refs) |ref| {
                        if (std.mem.eql(u8, ref.name, name)) try out.append(try view.location(file.uri, ref.start, ref.end));
                    }
                }
            }
        } else {
            var index = variables.Index.init(a, self.cache.source());
            const occurrences = if (group == .root) try index.occurrences(a, subject.doc.uri, name) else try index.fieldOccurrences(a, subject.doc.uri, name);
            std.mem.sort(variables.Occurrence, occurrences, {}, source.lessOccurrence);
            for (occurrences) |candidate| {
                if (candidate.kind == .definition and !include_declaration) continue;
                try out.append(try source.location(a, server, &index, candidate));
            }
        }
        return try out.toOwnedSlice();
    }

    pub fn fieldHover(self: *Query, subject: *Subject) !?types.Hover {
        const current = (try self.occurrence(subject, .field)) orelse return null;
        if (try self.parameterHover(subject, true)) |result| return result;
        return try self.hoverName(subject, current.name, subject.doc.rangeFromOffsets(current.start, current.end), .field);
    }

    pub fn rootHover(self: *Query, subject: *Subject) !?types.Hover {
        const current = (try self.occurrence(subject, .root)) orelse return null;
        return try self.hoverName(subject, current.name, subject.doc.rangeFromOffsets(current.start, current.end), .root);
    }

    pub fn parameterHover(self: *Query, subject: *Subject, field: bool) !?types.Hover {
        const server = self.cache.files.server;
        const a = self.cache.allocator;
        const context = (try parameters.contextAt(server, a, subject, field)) orelse return null;
        if (try parameters.hover(server, a, context)) |result| return result;
        if (field) return null;
        return try self.hoverName(subject, context.names[0], context.range, .root);
    }

    pub fn hoverName(self: *Query, subject: *Subject, name: []const u8, range: types.Range, group: Group) !types.Hover {
        return self.renderBindings(subject.doc.uri, name, range, group, try subject.workspace(self.cache.files.server, self.cache.allocator));
    }

    /// Legacy named-root callers need not have the referencing document open.
    /// They still cross the same typed search/description implementation.
    pub fn namedRootHover(self: *Query, uri: []const u8, name: []const u8, range: types.Range) !types.Hover {
        var view = try workspace.View.forUri(self.cache.files.server, self.cache.allocator, uri);
        return self.renderBindings(uri, name, range, .root, if (view) |*found| found else null);
    }

    fn renderBindings(self: *Query, uri: []const u8, name: []const u8, range: types.Range, group: Group, view: ?*workspace.View) !types.Hover {
        const a = self.cache.allocator;
        var entries: []const presentation.Entry = &.{};
        var root: ?[]const u8 = null;
        if (view) |found| {
            root = found.root;
            const reachable = try found.reachableFiles(try paths.uriToPath(a, uri));
            const defs = if (group == .root) try workspace.view.definitions(a, found.files, name, reachable) else try workspace.view.fieldDefinitions(a, found.files, name, reachable);
            // Presentation selects the displayed subset before descriptions.
            entries = try presentation.workspaceEntries(a, &self.cache, defs, found.files);
        } else {
            var index = variables.Index.init(a, self.cache.source());
            const defs = if (group == .root) try index.definitions(a, uri, name) else try index.fieldDefinitions(a, uri, name);
            entries = try presentation.fallbackEntries(a, &self.cache, defs);
        }
        const text = if (entries.len == 0)
            if (group == .root) try std.fmt.allocPrint(a, "**Variable** `{s}`\n\nNo definition found in the Workspace.", .{name}) else try std.fmt.allocPrint(a, "**Variable field** `{s}`\n\nNo definition found in the searched files.", .{name})
        else if (group == .root) try presentation.render(a, name, entries, root) else try presentation.renderField(a, name, entries, root);
        return .{ .contents = .{ .kind = .markdown, .value = text }, .range = range };
    }
};
