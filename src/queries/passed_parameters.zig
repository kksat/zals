//! Typed passed-key contracts. Detection and selected-entrypoint options are
//! separate from ordinary name groups; only implementation uses callee scope.
const std = @import("std");
const types = @import("../lsp/types.zig");
const yaml = @import("../yaml/root.zig");
const paths = @import("../paths.zig");
const variables = @import("../variables/root.zig");
const parameters = @import("../roles/parameters.zig");
const callee = @import("callee_bindings.zig");
const Context = @import("context.zig").Context;
const Subject = @import("navigation_subject.zig").Subject;

/// A passed key with its called Role, selected entry point and the Role
/// directories that name resolves to from the referencing file.
pub const Passed = struct {
    names: []const []const u8,
    role: []const u8,
    entry_point: []const u8,
    directories: []const []const u8,
    range: types.Range,
};

/// Nested mapping keys extend a parameter path; list elements do not. Root
/// parameter detection stays independent of ordinary occurrence recognition.
pub fn contextAt(context: *Context, subject: *Subject, field: bool) !?Passed {
    const a = context.allocator;
    const forest = subject.parse(a) orelse return null;
    const path = subject.path;
    if (!field) {
        const param = parameters.parameterAt(path) orelse return null;
        return try resolve(context, subject, .{ .names = try a.dupe([]const u8, &.{param.name}), .role = param.role, .entry_point = param.entry_point, .directories = &.{}, .range = subject.doc.rangeFromOffsets(param.start, param.end) });
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
        return try resolve(context, subject, .{ .names = try names.toOwnedSlice(), .role = parameter.role, .entry_point = parameter.entry_point, .directories = &.{}, .range = subject.doc.rangeFromOffsets(range.start, range.end) });
    }
    return null;
}

fn resolve(context: *Context, subject: *Subject, passed: Passed) !Passed {
    var result = passed;
    const path = try context.pathOf(subject.doc.uri);
    const declared = try yaml.collections.getRoleDeclaredCollections(subject.forest.?.allocator(), path, subject.path);
    result.directories = context.resolveRoles(passed.role, path, declared);
    return result;
}

/// No option means ordinary navigation may apply. Concrete implementation,
/// unlike this operation, returns an applicable empty answer for a known key.
pub fn definition(context: *Context, passed: Passed) !?[]const types.Location {
    const a = context.allocator;
    var out = std.array_list.Managed(types.Location).init(a);
    for (passed.directories) |dir| {
        const spec = (try parameters.optionSpecPathFrom(a, context.source(), dir, passed.entry_point, passed.names)) orelse continue;
        const uri = try paths.pathToUri(a, try std.fs.path.join(a, &.{ dir, "meta", spec.file }));
        try out.append(try context.location(uri, spec.start, spec.end));
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice();
}

pub fn implementation(context: *Context, passed: Passed) ![]const types.Location {
    var out = std.array_list.Managed(types.Location).init(context.allocator);
    const selector: callee.Selector = if (passed.names.len == 1) .{ .root_name = passed.names[0] } else .{ .full_path = passed.names };
    for (passed.directories) |dir| try out.appendSlice(try callee.calleeBindings(context, dir, selector));
    return try out.toOwnedSlice();
}

pub fn hover(context: *Context, passed: Passed) !?types.Hover {
    const a = context.allocator;
    const field = passed.names.len > 1;
    // Root parameter hover historically consults the first resolved directory;
    // nested field hover tries the full resolved-directory list.
    const dirs = if (!field and passed.directories.len > 0) passed.directories[0..1] else passed.directories;
    for (dirs) |dir| {
        const spec = (try parameters.optionSpecPathFrom(a, context.source(), dir, passed.entry_point, passed.names)) orelse continue;
        const name = try std.mem.join(a, ".", passed.names);
        const label = if (field) "Role parameter field" else "Role parameter";
        const text = try std.fmt.allocPrint(a, "**{s}** `{s}` — role `{s}` (`meta/{s}`, entry point `{s}`)\n\n```yaml\n{s}\n```", .{ label, name, passed.role, spec.file, passed.entry_point, spec.yaml });
        return .{ .contents = .{ .kind = .markdown, .value = text }, .range = passed.range };
    }
    return null;
}
