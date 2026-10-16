//! Typed passed-key contracts. Detection and selected-entrypoint options are
//! separate from ordinary name groups; only implementation uses callee scope.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = @import("../lsp/server.zig").Server;
const types = @import("../lsp/types.zig");
const yaml = @import("../yaml/root.zig");
const paths = @import("../paths.zig");
const variables = @import("../variables/root.zig");
const parameters = @import("../roles/parameters.zig");
const util = @import("../providers/util.zig");
const source = @import("../providers/variable_source.zig");
const callee = @import("callee_bindings.zig");
const Subject = @import("navigation_subject.zig").Subject;

pub const Context = struct {
    names: []const []const u8,
    role: []const u8,
    entry_point: []const u8,
    directories: []const []const u8,
    range: types.Range,
};

/// Nested mapping keys extend a parameter path; list elements do not. Root
/// parameter detection stays independent of ordinary occurrence recognition.
pub fn contextAt(server: *Server, a: Allocator, subject: *Subject, field: bool) !?Context {
    const forest = subject.parse(a) orelse return null;
    const path = subject.path;
    if (!field) {
        const param = parameters.parameterAt(path) orelse return null;
        const range = variables.definitions.scalarRange(path[path.len - 1], forest.text, param.name);
        return try resolve(server, a, subject, .{ .names = try a.dupe([]const u8, &.{param.name}), .role = param.role, .entry_point = param.entry_point, .directories = &.{}, .range = subject.doc.rangeFromOffsets(range.start, range.end) });
    }
    if (path.len < 2) return null;
    const key = path[path.len - 1];
    const pair = path[path.len - 2];
    if (!key.isScalar() or !pair.isPair() or pair.key != key) return null;
    for (path[0 .. path.len - 2], 0..) |node, i| {
        if (!node.isPair()) continue;
        const root_key = node.key orelse continue;
        const candidate = try a.alloc(*yaml.Node, i + 2);
        @memcpy(candidate[0 .. i + 1], path[0 .. i + 1]);
        candidate[i + 1] = root_key;
        const parameter = parameters.parameterAt(candidate) orelse continue;
        var names = std.array_list.Managed([]const u8).init(a);
        try names.append(parameter.name);
        for (path[i + 1 ..]) |child| {
            if (!child.isPair()) continue;
            try names.append((child.key orelse return null).stringValue() orelse return null);
        }
        if (names.items.len < 2) return null;
        const range = variables.definitions.scalarRange(key, forest.text, names.items[names.items.len - 1]);
        return try resolve(server, a, subject, .{ .names = try names.toOwnedSlice(), .role = parameter.role, .entry_point = parameter.entry_point, .directories = &.{}, .range = subject.doc.rangeFromOffsets(range.start, range.end) });
    }
    return null;
}

fn resolve(server: *Server, a: Allocator, subject: *Subject, context: Context) !Context {
    var result = context;
    const path = try paths.uriToPath(a, subject.doc.uri);
    const declared = try yaml.collections.getRoleDeclaredCollections(subject.forest.?.allocator(), path, subject.path);
    result.directories = util.resolveRoleAll(server, a, context.role, path, declared);
    return result;
}

/// No option means ordinary navigation may apply. Concrete implementation,
/// unlike this operation, returns an applicable empty answer for a known key.
pub fn definition(server: *Server, a: Allocator, context: Context) !?[]const types.Location {
    var files = source.ServerSource{ .server = server };
    var index = variables.Index.init(a, files.source());
    var out = std.array_list.Managed(types.Location).init(a);
    for (context.directories) |dir| {
        const spec = (try parameters.optionSpecPathFrom(a, files.source(), dir, context.entry_point, context.names)) orelse continue;
        const uri = try paths.pathToUri(a, try std.fs.path.join(a, &.{ dir, "meta", spec.file }));
        try out.append(try source.location(a, server, &index, .{ .uri = uri, .start = spec.start, .end = spec.end, .kind = .definition }));
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice();
}

pub fn implementation(server: *Server, a: Allocator, context: Context) ![]const types.Location {
    var query = callee.Query.init(server, a);
    var out = std.array_list.Managed(types.Location).init(a);
    const selector: callee.Selector = if (context.names.len == 1) .{ .root_name = context.names[0] } else .{ .full_path = context.names };
    for (context.directories) |dir| try out.appendSlice(try query.calleeBindings(dir, selector));
    return try out.toOwnedSlice();
}

pub fn hover(server: *Server, a: Allocator, context: Context) !?types.Hover {
    var files = source.ServerSource{ .server = server };
    const field = context.names.len > 1;
    // Root parameter hover historically consults the first resolved directory;
    // nested field hover tries the full resolved-directory list.
    const dirs = if (!field and context.directories.len > 0) context.directories[0..1] else context.directories;
    for (dirs) |dir| {
        const spec = (try parameters.optionSpecPathFrom(a, files.source(), dir, context.entry_point, context.names)) orelse continue;
        const name = try std.mem.join(a, ".", context.names);
        const label = if (field) "Role parameter field" else "Role parameter";
        const text = try std.fmt.allocPrint(a, "**{s}** `{s}` — role `{s}` (`meta/{s}`, entry point `{s}`)\n\n```yaml\n{s}\n```", .{ label, name, context.role, spec.file, context.entry_point, spec.yaml });
        return .{ .contents = .{ .kind = .markdown, .value = text }, .range = context.range };
    }
    return null;
}
