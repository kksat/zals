//! Port of upstream's `AncestryBuilder`, which walks a path array upward while
//! asserting node types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;
const Kind = dom.Kind;

pub const AncestryBuilder = struct {
    arena: Allocator,
    path: []*Node,
    index: isize,

    const invalid = std.math.minInt(isize);

    pub fn init(arena: Allocator, path: []*Node) AncestryBuilder {
        const idx: isize = if (path.len == 0) -1 else @intCast(path.len - 1);
        return .{ .arena = arena, .path = path, .index = idx };
    }

    pub fn get(self: *AncestryBuilder) ?*Node {
        if (self.index < 0 or self.index >= self.path.len) return null;
        return self.path[@intCast(self.index)];
    }

    /// Move up one level. Pairs are skipped unless `kind` is `.pair`.
    pub fn parent(self: *AncestryBuilder, kind: ?Kind) void {
        self.index -= 1;
        if (self.get()) |n| {
            if (n.isPair() and (kind == null or kind.? != .pair)) self.index -= 1;
        }
        if (kind) |k| {
            const n = self.get() orelse {
                self.index = invalid;
                return;
            };
            if (n.kind != k) self.index = invalid;
        }
    }

    /// Move up past a pair to the map that owns the current key.
    pub fn parentOfKey(self: *AncestryBuilder) void {
        const node = self.get();
        self.parent(.pair);
        const pair_node = self.get();
        if (pair_node != null and pair_node.?.isPair() and pair_node.?.key == node) {
            self.parent(.map);
        } else {
            self.index = invalid;
        }
    }

    /// Key of the pair one level below the current position.
    pub fn getStringKey(self: *AncestryBuilder) ?[]const u8 {
        const i = self.index + 1;
        if (i < 0 or i >= self.path.len) return null;
        const node = self.path[@intCast(i)];
        if (!node.isPair()) return null;
        const k = node.key orelse return null;
        return k.stringValue();
    }

    /// Value of the pair one level below the current position.
    pub fn getValue(self: *AncestryBuilder) ?*Node {
        const i = self.index + 1;
        if (i < 0 or i >= self.path.len) return null;
        const node = self.path[@intCast(i)];
        if (!node.isPair()) return null;
        return node.val;
    }

    pub fn getPath(self: *AncestryBuilder) ?[]*Node {
        if (self.index < 0) return null;
        return self.path[0..@intCast(self.index + 1)];
    }

    /// Path up to the current position, plus the pair and key one level down.
    pub fn getKeyPath(self: *AncestryBuilder) !?[]*Node {
        if (self.index < 0) return null;
        const i = self.index + 1;
        if (i >= self.path.len) return null;
        const node = self.path[@intCast(i)];
        if (!node.isPair()) return null;
        const k = node.key orelse return null;
        var out = std.array_list.Managed(*Node).init(self.arena);
        try out.appendSlice(self.path[0..@intCast(self.index + 1)]);
        try out.append(node);
        try out.append(k);
        return try out.toOwnedSlice();
    }
};
