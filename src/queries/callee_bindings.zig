//! Concrete implementations of passed role inputs (ADR-0039, ADR-0042).
//! This module owns source selection, one-level dependency hydration, ranking
//! and selector matching; parameter/contract detection stays with the
//! callers, and file overlay, text and locations with the navigation context.

const std = @import("std");
const types = @import("../lsp/types.zig");
const facts = @import("../workspace/facts.zig");
const discover = @import("../workspace/discover.zig");
const view = @import("../workspace/view.zig");
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");
const Context = @import("context.zig").Context;

pub const Selector = union(enum) {
    root_name: []const u8,
    /// Complete root-and-key path; list elements add no component.
    full_path: []const []const u8,
};

/// Concrete bindings in the resolved callee's conventional sources plus
/// one level of their explicit vars loads, never an invoker expansion.
/// Root and full-path selectors share indexed source reuse and load-site
/// precedence. Schema-only inputs return an empty slice. Non-Workspace or
/// not-yet-indexed callees retain filesystem discovery and its ordering.
pub fn calleeBindings(context: *Context, role_dir: []const u8, selector: Selector) ![]const types.Location {
    if (selector == .full_path and selector.full_path.len == 0) return &.{};
    const a = context.allocator;
    const scope_path = try std.fs.path.join(a, &.{ role_dir, "tasks", "main.yml" });
    if (context.workspaceRoot(scope_path)) |root| {
        if (try indexedBindings(context, root, role_dir, selector)) |locations| return locations;
    }
    return try filesystemBindings(context, try paths.pathToUri(a, scope_path), selector);
}

fn indexedBindings(context: *Context, root: []const u8, role_dir: []const u8, selector: Selector) !?[]const types.Location {
    const a = context.allocator;
    // Borrow a directory-local file list, not a whole-Workspace list sorted
    // only to discard unrelated entries. Conventional-source filtering stays here.
    var files = std.array_list.Managed(view.File).init(a);
    for (try context.filesWithin(root, role_dir)) |file| {
        if (view.isCalleeSource(file.path, role_dir)) try files.append(file);
    }

    // Freeze both conventional scope and original load provenance BEFORE
    // hydration. A dependency's own loads never extend this one-level set.
    const set = (try view.calleeFiles(a, files.items, role_dir)) orelse return null;
    try hydrate(context, root, &files, set);
    const bindings = switch (selector) {
        .root_name => |name| try view.calleeRootDefinitions(a, files.items, set, name),
        .full_path => |names| try view.calleeFieldDefinitions(a, files.items, set, names),
    };
    var out = std.array_list.Managed(types.Location).init(a);
    for (bindings) |binding| try out.append(try context.location(binding.uri, binding.start, binding.end));
    return try out.toOwnedSlice();
}

fn hydrate(context: *Context, root: []const u8, files: *std.array_list.Managed(view.File), set: view.Reachability) !void {
    const a = context.allocator;
    var loaded = std.StringHashMap(void).init(a);
    for (set.loads) |load| {
        if (loaded.contains(load.path)) continue;
        try loaded.put(load.path, {});
        const existing = view.find(files.items, load.path);
        // A load target binds its load-only keys (ADR-0045).
        if (discover.isAnsibleFile(std.fs.path.basename(load.path))) {
            if (existing != null) {
                for (files.items) |*file| {
                    if (std.mem.eql(u8, file.path, load.path)) file.facts = try file.facts.loaded(a);
                }
                continue;
            }
            if (try context.workspaceFile(root, load.path)) |found| {
                var file = found;
                file.facts = try file.facts.loaded(a);
                try files.append(file);
                continue;
            }
        }
        const uri = try paths.pathToUri(a, load.path);
        const body = (try context.text(uri)) orelse continue;
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

fn filesystemBindings(context: *Context, uri: []const u8, selector: Selector) ![]const types.Location {
    const a = context.allocator;
    var index = variables.Index.init(a, context.source());
    const bindings = switch (selector) {
        .root_name => |name| try index.definitions(a, uri, name),
        .full_path => |names| try index.fieldDefinitions(a, uri, names[names.len - 1]),
    };
    var out = std.array_list.Managed(types.Location).init(a);
    for (bindings) |binding| {
        if (binding.site == .argument_specs) continue;
        if (selector == .full_path and !equalPath(binding.field_path, selector.full_path)) continue;
        try out.append(try context.location(binding.uri, binding.start, binding.end));
    }
    return try out.toOwnedSlice();
}

fn equalPath(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}
