//! Semantic YAML DOM.
//!
//! Mirrors the shape of the `yaml` npm package's AST that upstream's helpers
//! operate on: a `Map` holds `Pair` items, a `Seq` holds nodes, a `Pair` has a
//! `key` and a `val`, and a `Scalar` has a string `value`. Every node carries
//! byte offsets into the source text.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { scalar, map, seq, pair, alias };

pub const Node = struct {
    kind: Kind,
    /// Inclusive start byte offset.
    start: usize,
    /// Exclusive end byte offset.
    end: usize,
    parent: ?*Node = null,
    /// Scalar value (unquoted, unescaped) or alias target name.
    value: ?[]const u8 = null,
    /// Map: pairs. Seq: items.
    items: []*Node = &.{},
    /// Pair key.
    key: ?*Node = null,
    /// Pair value.
    val: ?*Node = null,

    pub fn isScalar(self: *const Node) bool {
        return self.kind == .scalar;
    }
    pub fn isMap(self: *const Node) bool {
        return self.kind == .map;
    }
    pub fn isSeq(self: *const Node) bool {
        return self.kind == .seq;
    }
    pub fn isPair(self: *const Node) bool {
        return self.kind == .pair;
    }

    /// Scalar value as a string, if this is a scalar.
    pub fn stringValue(self: *const Node) ?[]const u8 {
        return if (self.kind == .scalar) self.value else null;
    }

    pub fn contains(self: *const Node, offset: usize, inclusive: bool) bool {
        return self.start <= offset and (self.end > offset or (inclusive and self.end >= offset));
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: ?*Node,
    text: []const u8,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }
};

/// A parsed YAML source: an arena owning the nodes, the source text, and one
/// root node per YAML document. Produced by any `YamlParser` backend.
pub const Forest = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    roots: []*Node,

    pub fn deinit(self: *Forest) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Forest) Allocator {
        return self.arena.allocator();
    }
};

/// Keys of a map node, in order, for scalar keys only.
pub fn mapKeys(allocator: Allocator, map: *const Node) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (map.items) |pair| {
        if (pair.key) |k| {
            if (k.stringValue()) |s| try list.append(s);
        }
    }
    return list.toOwnedSlice();
}

/// Find the pair in `map` whose key equals `name`.
pub fn findPair(map: *const Node, name: []const u8) ?*Node {
    for (map.items) |pair| {
        if (pair.key) |k| {
            if (k.stringValue()) |s| {
                if (std.mem.eql(u8, s, name)) return pair;
            }
        }
    }
    return null;
}
