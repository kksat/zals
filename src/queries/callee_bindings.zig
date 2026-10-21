//! Concrete implementations of passed role inputs (ADR-0039, ADR-0042).
//! This module owns ranking and selector matching over the called Role's
//! file set; parameter/contract detection stays with the callers, and file
//! selection, load hydration, text and locations with the navigation context.

const std = @import("std");
const types = @import("../lsp/types.zig");
const view = @import("../workspace/view.zig");
const Context = @import("context.zig").Context;

pub const Selector = union(enum) {
    root_name: []const u8,
    /// Complete root-and-key path; list elements add no component.
    full_path: []const []const u8,
};

/// Concrete bindings in the resolved callee's conventional sources plus
/// one level of their explicit vars loads, never an invoker expansion.
/// Root and full-path selectors share the Role scope and load-site
/// precedence. Schema-only inputs return an empty slice.
pub fn calleeBindings(context: *Context, role_dir: []const u8, selector: Selector) ![]const types.Location {
    if (selector == .full_path and selector.full_path.len == 0) return &.{};
    const a = context.allocator;
    const set = try context.files(.{ .role = role_dir });
    const reach = set.reach.?;
    const bindings = switch (selector) {
        .root_name => |name| try view.calleeRootDefinitions(a, set.files, reach, name),
        .full_path => |names| try view.calleeFieldDefinitions(a, set.files, reach, names),
    };
    var out = std.array_list.Managed(types.Location).init(a);
    for (bindings) |binding| try out.append(try context.location(binding.uri, binding.start, binding.end));
    return try out.toOwnedSlice();
}
