//! Collects `collections:` declarations visible from a module path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;
const AncestryBuilder = @import("ancestry.zig").AncestryBuilder;

fn appendForMap(_arena: Allocator, out: *std.array_list.Managed([]const u8), map: *const Node) !void {
    _ = _arena;
    const pair = dom.findPair(map, "collections") orelse return;
    const value = pair.val orelse return;
    if (!value.isSeq()) return;
    for (value.items) |item| {
        if (item.stringValue()) |s| try out.append(s);
    }
}

fn isBlockRescueAlways(key: []const u8) bool {
    return std.mem.eql(u8, key, "block") or
        std.mem.eql(u8, key, "rescue") or
        std.mem.eql(u8, key, "always");
}

/// Collections declared at the task, block, and play levels for `module_path`.
pub fn getDeclaredCollections(arena: Allocator, module_path: []*Node) ![]const []const u8 {
    var declared = std.array_list.Managed([]const u8).init(arena);

    var b = AncestryBuilder.init(arena, module_path);
    b.parent(.map);
    if (b.get()) |task_params| try appendForMap(arena, &declared, task_params);

    var b2 = AncestryBuilder.init(arena, module_path);
    b2.parent(.map);
    var path = b2.getPath() orelse return dedupe(arena, declared.items);

    while (true) {
        var b3 = AncestryBuilder.init(arena, path);
        b3.parent(.seq);
        b3.parent(.map);
        const key = b3.getStringKey() orelse break;
        if (!isBlockRescueAlways(key)) break;
        if (b3.get()) |m| try appendForMap(arena, &declared, m);
        path = b3.getPath() orelse break;
    }

    var b4 = AncestryBuilder.init(arena, path);
    b4.parent(.seq);
    b4.parent(.map);
    if (b4.get()) |play_params| try appendForMap(arena, &declared, play_params);

    return dedupe(arena, declared.items);
}

fn dedupe(arena: Allocator, items: []const []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    for (items) |item| {
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, item)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(item);
    }
    return try out.toOwnedSlice();
}
