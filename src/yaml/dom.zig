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

/// A parsed YAML source with arena-owned nodes and query paths. `text` is
/// borrowed: the caller must keep its bytes alive and unchanged until deinit.
/// Produced by any `YamlParser` backend.
pub const Forest = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    roots: []*Node,
    /// Document starts in source order, parallel to `roots`. Unlike root ranges,
    /// these include a document's opening marker (or directives, when parsed).
    document_starts: []const usize,

    /// Select a document and find its cursor path, allocated for forest lifetime.
    /// `inclusive` includes descendant end positions, as in the root-level helper.
    /// Leading gaps select the first document; other gaps and trailing whitespace
    /// (including EOF) select the preceding document until the next recorded start.
    /// Markers follow the backend's document starts, not content-root containment:
    /// an opening marker selects its document, and a closing marker remains with
    /// the document containing it. Empty documents retain their own roots.
    /// Missing descendants retain editor placeholders. No roots or an offset past
    /// the source returns null; `inclusive` does not change document selection.
    pub fn pathAt(self: *Forest, offset: usize, inclusive: bool) !?[]*Node {
        if (self.roots.len == 0 or offset > self.text.len) return null;
        var selected: usize = 0;
        for (self.document_starts, 0..) |start, i| {
            if (start > offset) break;
            selected = i;
        }
        return @import("path.zig").getPathAt(self.allocator(), self.roots[selected], offset, inclusive);
    }

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
