//! Path queries over the YAML DOM, mirroring upstream's `yamlAst` helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;

/// Find the path from the root to the deepest node containing `offset`.
/// The returned slice is allocated in `arena`.
pub fn getPathAt(arena: Allocator, root: *Node, offset: usize, inclusive: bool) !?[]*Node {
    var path = std.array_list.Managed(*Node).init(arena);
    try path.append(root);
    try walk(arena, &path, offset, inclusive);
    return try path.toOwnedSlice();
}

fn walk(arena: Allocator, path: *std.array_list.Managed(*Node), offset: usize, inclusive: bool) !void {
    const current = path.items[path.items.len - 1];
    if (current.isMap()) {
        for (current.items) |pair| {
            if (pair.key) |k| {
                if (k.contains(offset, inclusive)) {
                    try path.append(pair);
                    try path.append(k);
                    return walk(arena, path, offset, inclusive);
                }
            }
        }
        for (current.items) |pair| {
            if (pair.val) |v| {
                if (v.contains(offset, inclusive)) {
                    try path.append(pair);
                    try path.append(v);
                    return walk(arena, path, offset, inclusive);
                }
            }
        }
        for (current.items) |pair| {
            if (pair.key) |k| {
                if (pair.val) |v| {
                    if (k.end <= offset and offset < v.start) {
                        try path.append(pair);
                        try path.append(try emptyNode(arena));
                        return;
                    }
                }
            }
        }
    } else if (current.isSeq()) {
        for (current.items) |item| {
            if (item.contains(offset, inclusive)) {
                try path.append(item);
                return walk(arena, path, offset, inclusive);
            }
        }
    } else if (current.contains(offset, inclusive)) {
        return;
    }
    try path.append(try emptyNode(arena));
}

fn emptyNode(arena: Allocator) !*Node {
    const n = try arena.create(Node);
    n.* = .{ .kind = .scalar, .start = 0, .end = 0 };
    return n;
}
