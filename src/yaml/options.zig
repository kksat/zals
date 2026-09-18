//! Walk a YAML path up to the Ansible task parameter that owns module options.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("dom.zig").Node;
const AncestryBuilder = @import("ancestry.zig").AncestryBuilder;
const predicates = @import("predicates.zig");
const keywords = @import("keywords.zig");

pub const TraceKind = enum { list, dict };

pub const TraceStep = struct {
    name: []const u8,
    kind: TraceKind,
};

pub const TaskParamTrace = struct {
    path: []*Node,
    trace: []TraceStep,
};

/// Search up `path` until a task-parameter key is found. `trace` records each
/// option/sub-option name and whether its value is a dict or a list.
pub fn getTaskParamPathWithTrace(arena: Allocator, start: []*Node) !?TaskParamTrace {
    var path = start;
    var trace = std.array_list.Managed(TraceStep).init(arena);
    while (!predicates.isTaskParam(arena, path)) {
        var b = AncestryBuilder.init(arena, path);
        b.parentOfKey();
        b.parent(.map);
        if (try b.getKeyPath()) |parent_key_path| {
            const parent_key = parent_key_path[parent_key_path.len - 1];
            if (parent_key.stringValue()) |name| {
                try trace.append(.{ .name = name, .kind = .dict });
                path = parent_key_path;
                continue;
            }
        }

        var b2 = AncestryBuilder.init(arena, path);
        b2.parentOfKey();
        b2.parent(.seq);
        b2.parent(.map);
        if (try b2.getKeyPath()) |parent_key_path| {
            const parent_key = parent_key_path[parent_key_path.len - 1];
            if (parent_key.stringValue()) |name| {
                try trace.append(.{ .name = name, .kind = .list });
                path = parent_key_path;
                continue;
            }
        }
        return null;
    }
    return .{ .path = path, .trace = try trace.toOwnedSlice() };
}

/// Non-keyword keys of the task map that owns `task_param_path`.
pub fn providedModuleNames(arena: Allocator, task_param_path: []*Node) ![]const []const u8 {
    var b = AncestryBuilder.init(arena, task_param_path);
    b.parent(.map);
    const map = b.get() orelse return &.{};
    var names = std.array_list.Managed([]const u8).init(arena);
    for (map.items) |pair| {
        const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
        if (!keywords.isTaskKeyword(key)) try names.append(key);
    }
    return try names.toOwnedSlice();
}

/// Scalar keys already present on the map that owns `path`.
pub fn providedKeys(arena: Allocator, path: []*Node) ![]const []const u8 {
    var b = AncestryBuilder.init(arena, path);
    b.parentOfKey();
    const map = b.get() orelse return &.{};
    return predicates.mapKeys(arena, map);
}
