//! Callee contracts for concrete fields inside passed role parameters.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Server = @import("../lsp/server.zig").Server;
const types = @import("../lsp/types.zig");
const yaml = @import("../yaml/root.zig");
const paths = @import("../paths.zig");
const variables = @import("../variables/root.zig");
const util = @import("util.zig");
const vs = @import("variable_source.zig");
const role_navigation = @import("role_navigation.zig");

const Context = struct {
    names: []const []const u8,
    role: []const u8,
    entry_point: []const u8,
    directories: []const []const u8,
    range: types.Range,
};

/// Walk the binding's ancestor pairs until an actual role parameter is found.
/// Only mapping keys extend its path; list elements do not identify a new field.
fn contextAt(self: *Server, a: Allocator, params: Value) !?Context {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    if (cur.path.len < 2) return null;
    const key = cur.path[cur.path.len - 1];
    const pair = cur.path[cur.path.len - 2];
    if (!key.isScalar() or !pair.isPair() or pair.key != key) return null;
    for (cur.path[0 .. cur.path.len - 2], 0..) |node, i| {
        if (!node.isPair()) continue;
        const root_key = node.key orelse continue;
        const candidate = try a.alloc(*yaml.Node, i + 2);
        @memcpy(candidate[0 .. i + 1], cur.path[0 .. i + 1]);
        candidate[i + 1] = root_key;
        const parameter = role_navigation.parameterAt(candidate) orelse continue;
        var names = std.array_list.Managed([]const u8).init(a);
        try names.append(try a.dupe(u8, parameter.name));
        for (cur.path[i + 1 ..]) |child| {
            if (!child.isPair()) continue;
            const field = (child.key orelse return null).stringValue() orelse return null;
            try names.append(try a.dupe(u8, field));
        }
        if (names.items.len < 2) return null;
        const path = try paths.uriToPath(a, cur.doc.uri);
        const declared = try yaml.collections.getRoleDeclaredCollections(cur.forest.allocator(), path, cur.path);
        const range = variables.definitions.scalarRange(key, cur.forest.text, names.items[names.items.len - 1]);
        return .{
            .names = try names.toOwnedSlice(),
            .role = try a.dupe(u8, parameter.role),
            .entry_point = try a.dupe(u8, parameter.entry_point),
            .directories = util.resolveRoleAll(self, a, parameter.role, path, declared),
            .range = cur.doc.rangeFromOffsets(range.start, range.end),
        };
    }
    return null;
}

pub fn definition(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const context = (try contextAt(self, a, params)) orelse return null;
    var source = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, source.source());
    var out = std.array_list.Managed(types.Location).init(a);
    for (context.directories) |dir| {
        const spec = (try role_navigation.optionSpecPathFrom(a, source.source(), dir, context.entry_point, context.names)) orelse continue;
        const uri = try paths.pathToUri(a, try std.fs.path.join(a, &.{ dir, "meta", spec.file }));
        try out.append(try vs.location(a, self, &index, .{ .uri = uri, .start = spec.start, .end = spec.end, .kind = .definition }));
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice();
}

/// Concrete bindings must belong to the callee and the complete passed path,
/// not merely share its final field name. An unresolved callee yields no target.
pub fn implementation(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const context = (try contextAt(self, a, params)) orelse return null;
    var source = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, source.source());
    var out = std.array_list.Managed(types.Location).init(a);
    for (context.directories) |dir| {
        const uri = try paths.pathToUri(a, try std.fs.path.join(a, &.{ dir, "tasks", "main.yml" }));
        for (try index.fieldDefinitions(a, uri, context.names[context.names.len - 1])) |def| {
            if (def.site == .argument_specs or !equalPath(def.field_path, context.names)) continue;
            try out.append(try vs.location(a, self, &index, def));
        }
    }
    return try out.toOwnedSlice();
}

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const context = (try contextAt(self, a, params)) orelse return null;
    var source = vs.ServerSource{ .server = self };
    for (context.directories) |dir| {
        const spec = (try role_navigation.optionSpecPathFrom(a, source.source(), dir, context.entry_point, context.names)) orelse continue;
        const name = try std.mem.join(a, ".", context.names);
        const text = try std.fmt.allocPrint(a, "**Role parameter field** `{s}` — role `{s}` (`meta/{s}`, entry point `{s}`)\n\n```yaml\n{s}\n```", .{ name, context.role, spec.file, context.entry_point, spec.yaml });
        return .{ .contents = .{ .kind = .markdown, .value = text }, .range = context.range };
    }
    return null;
}

fn equalPath(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}
