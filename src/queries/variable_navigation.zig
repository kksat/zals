//! Root and leaf-name field navigation through one request-local search seam.
//! Owns Workspace/fallback selection, ranking, declarations, callee contracts
//! and revision-safe descriptions. No protocol params here.
const std = @import("std");
const types = @import("../lsp/types.zig");
const variables = @import("../variables/root.zig");
const view = @import("../workspace/view.zig");
const presentation = @import("variable_hover.zig");
const descriptions = @import("binding_descriptions.zig");
const parameters = @import("passed_parameters.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
pub const Subject = @import("navigation_subject.zig").Subject;
pub const Position = @import("navigation_subject.zig").Position;
pub const Target = enum { definition, implementation };
const Group = enum { root, field };

/// Borrows the request's navigation context; owns its description cache
/// until deinit. Results are request-owned. Description values are
/// normalized/copied before cache teardown.
pub const Query = struct {
    context: *Context,
    cache: descriptions.Cache,

    pub fn init(context: *Context) Query {
        return .{ .context = context, .cache = descriptions.Cache.init(context) };
    }

    pub fn deinit(self: *Query) void {
        self.cache.deinit();
    }

    pub fn subjectAt(self: *Query, position: Position) ?Subject {
        return Subject.at(self.context, position);
    }

    /// The subject's occurrence, from its document's facts: the same
    /// extraction the Workspace overlay uses, so no second parse.
    fn occurrence(self: *Query, subject: *Subject, group: Group) !?variables.Cursor {
        if (group == .field) {
            if (!subject.field_checked) {
                const found = if (try self.context.documentFacts(subject.doc.uri)) |facts| view.fieldOccurrenceAt(facts, subject.offset) else null;
                subject.field = try self.bound(subject, found);
                subject.field_checked = true;
            }
            return subject.field;
        }
        if (!subject.root_checked) {
            const found = if (try self.context.documentFacts(subject.doc.uri)) |facts| view.occurrenceAt(facts, subject.offset) else null;
            subject.root = try self.bound(subject, found);
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
        const ws = (try self.context.workspaceOf(subject.doc.uri)) orelse return null;
        return if (ws.isLoaded(try self.context.pathOf(subject.doc.uri))) found else null;
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
        const passed = (try parameters.contextAt(self.context, subject, field)) orelse return null;
        return if (target == .definition) parameters.definition(self.context, passed) else try parameters.implementation(self.context, passed);
    }

    fn namedLocations(self: *Query, subject: *Subject, name: []const u8, group: Group, target: Target) ![]const types.Location {
        const context = self.context;
        const a = context.allocator;
        var out = std.array_list.Managed(types.Location).init(a);
        for (try self.definitions(subject.doc.uri, name, group)) |candidate| {
            if (target == .implementation and candidate.site == .argument_specs) continue;
            try out.append(try context.location(candidate.uri, candidate.start, candidate.end));
        }
        return try out.toOwnedSlice();
    }

    /// Reachable definitions ranked first, then the rest of the file set.
    fn definitions(self: *Query, uri: []const u8, name: []const u8, group: Group) ![]view.Occurrence {
        const context = self.context;
        const a = context.allocator;
        const set = try context.searchFiles(uri);
        const reachable = try context.reachableFiles(set, try context.pathOf(uri));
        return if (group == .root) try view.definitions(a, set.files, name, reachable) else try view.fieldDefinitions(a, set.files, name, reachable);
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
        const context = self.context;
        const a = context.allocator;
        const set = try context.searchFiles(subject.doc.uri);
        var out = std.array_list.Managed(types.Location).init(a);
        if (group == .root) {
            for (try view.occurrences(a, set.files, name)) |candidate| {
                if (candidate.kind == .definition and !include_declaration) continue;
                try out.append(try context.location(candidate.uri, candidate.start, candidate.end));
            }
        } else {
            // Preserve field traversal ordering: declarations, then reads,
            // per file. The sorted fieldOccurrences helper is NOT equivalent.
            for (set.files) |file| {
                if (include_declaration) for (file.facts.field_defs) |def| {
                    if (std.mem.eql(u8, def.name, name)) try out.append(try context.location(file.uri, def.start, def.end));
                };
                for (file.facts.field_refs) |ref| {
                    if (std.mem.eql(u8, ref.name, name)) try out.append(try context.location(file.uri, ref.start, ref.end));
                }
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
        const passed = (try parameters.contextAt(self.context, subject, field)) orelse return null;
        if (try parameters.hover(self.context, passed)) |result| return result;
        if (field) return null;
        return try self.hoverName(subject, passed.names[0], passed.range, .root);
    }

    fn hoverName(self: *Query, subject: *Subject, name: []const u8, range: types.Range, group: Group) !types.Hover {
        const a = self.context.allocator;
        const set = try self.context.searchFiles(subject.doc.uri);
        const defs = try self.definitions(subject.doc.uri, name, group);
        // Presentation selects the displayed subset before descriptions.
        const entries = try presentation.bindingEntries(a, &self.cache, defs, set.files);
        // Only a Workspace shortens displayed paths.
        const root = if (set.scope == .workspace) set.root else null;
        const text = if (entries.len == 0)
            if (group == .root) try std.fmt.allocPrint(a, "**Variable** `{s}`\n\nNo definition found in the Workspace.", .{name}) else try std.fmt.allocPrint(a, "**Variable field** `{s}`\n\nNo definition found in the searched files.", .{name})
        else if (group == .root) try presentation.render(a, name, entries, root) else try presentation.renderField(a, name, entries, root);
        return .{ .contents = .{ .kind = .markdown, .value = text }, .range = range };
    }
};
