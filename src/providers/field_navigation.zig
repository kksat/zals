//! Name-based navigation for fields read through Jinja member access.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const variables = @import("../variables/root.zig");
const util = @import("util.zig");
const vs = @import("variable_source.zig");
const wv = @import("workspace_view.zig");
const json_util = @import("../lsp/json_util.zig");
const paths = @import("../paths.zig");
const descriptions = @import("../queries/binding_descriptions.zig");

pub fn locations(self: *Server, a: Allocator, params: Value, target: @import("variable_navigation.zig").Target) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var source = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, source.source());
    const cur = (try index.fieldOccurrenceAt(a, loc.doc.uri, loc.offset)) orelse return null;
    const parameters = @import("field_parameter_navigation.zig");
    if (target == .definition) {
        if (try parameters.definition(self, a, params)) |found| return found;
    } else if (try parameters.implementation(self, a, params)) |found| return found;
    var out = std.array_list.Managed(types.Location).init(a);
    if (try wv.View.forUri(self, a, loc.doc.uri)) |found| {
        var view = found;
        const reachable = try view.reachableFiles(try paths.uriToPath(a, loc.doc.uri));
        for (try wv.view.fieldDefinitions(a, view.files, cur.name, reachable)) |def| {
            if (target == .implementation and def.site == .argument_specs) continue;
            try out.append(try view.location(def.uri, def.start, def.end));
        }
    } else {
        for (try index.fieldDefinitions(a, loc.doc.uri, cur.name)) |def| {
            if (target == .implementation and def.site == .argument_specs) continue;
            try out.append(try vs.location(a, self, &index, def));
        }
    }
    return try out.toOwnedSlice();
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var cache = descriptions.Cache.init(self, a);
    defer cache.deinit();
    var index = variables.Index.init(a, cache.source());
    const cur = (try index.fieldOccurrenceAt(a, loc.doc.uri, loc.offset)) orelse return null;
    if (try @import("field_parameter_navigation.zig").hover(self, a, params)) |found| return found;
    const variable_hover = @import("variable_hover.zig");
    var entries: []const variable_hover.Entry = &.{};
    var root: ?[]const u8 = null;
    if (try wv.View.forUri(self, a, loc.doc.uri)) |found| {
        var view = found;
        root = view.root;
        const reachable = try view.reachableFiles(try paths.uriToPath(a, loc.doc.uri));
        entries = try variable_hover.workspaceEntries(a, &cache, try wv.view.fieldDefinitions(a, view.files, cur.name, reachable), view.files);
    } else {
        entries = try variable_hover.fallbackEntries(a, &cache, try index.fieldDefinitions(a, loc.doc.uri, cur.name));
    }
    const text = if (entries.len == 0)
        try std.fmt.allocPrint(a, "**Variable field** `{s}`\n\nNo definition found in the searched files.", .{cur.name})
    else
        try variable_hover.renderField(a, cur.name, entries, root);
    return .{ .contents = .{ .kind = .markdown, .value = text }, .range = loc.doc.rangeFromOffsets(cur.start, cur.end) };
}

pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const loc = util.cursorAt(self, params) orelse return null;
    var source = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, source.source());
    const cur = (try index.fieldOccurrenceAt(a, loc.doc.uri, loc.offset)) orelse return null;
    const context = json_util.field(params, "context") orelse Value.null;
    const include_declaration = json_util.boolean(context, "includeDeclaration") orelse false;
    var out = std.array_list.Managed(types.Location).init(a);
    if (try wv.View.forUri(self, a, loc.doc.uri)) |found| {
        var view = found;
        for (view.files) |file| {
            if (include_declaration) for (file.facts.field_defs) |def| {
                if (std.mem.eql(u8, def.name, cur.name)) try out.append(try view.location(file.uri, def.start, def.end));
            };
            for (file.facts.field_refs) |ref| {
                if (std.mem.eql(u8, ref.name, cur.name)) try out.append(try view.location(file.uri, ref.start, ref.end));
            }
        }
    } else {
        const occurrences = try index.fieldOccurrences(a, loc.doc.uri, cur.name);
        std.mem.sort(variables.Occurrence, occurrences, {}, vs.lessOccurrence);
        for (occurrences) |occurrence| {
            if (occurrence.kind == .definition and !include_declaration) continue;
            try out.append(try vs.location(a, self, &index, occurrence));
        }
    }
    return try out.toOwnedSlice();
}
