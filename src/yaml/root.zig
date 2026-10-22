//! YAML layer: parser interface, subset backend, DOM, and Ansible path helpers.

const std = @import("std");

pub const dom = @import("dom.zig");
pub const path = @import("path.zig");
pub const ancestry = @import("ancestry.zig");
pub const keywords = @import("keywords.zig");
pub const predicates = @import("predicates.zig");
pub const plays = @import("plays.zig");
pub const collections = @import("collections.zig");
pub const options = @import("options.zig");
pub const jsonify = @import("jsonify.zig");
pub const keyword_docs = @import("keyword_docs.zig");
pub const parser = @import("parser.zig");
pub const treesitter = @import("treesitter.zig");

pub const Node = dom.Node;
pub const Forest = dom.Forest;

/// Pluggable YAML backend behind the `YamlParser` seam (ADR-0004).
pub const Backend = enum { subset, tree_sitter };

/// Active backend. Defaults to tree-sitter; `.subset` selects the indent-based
/// fallback parser.
pub var backend: Backend = .tree_sitter;

/// Parse `text` with the active backend. If the tree-sitter backend fails for
/// any reason, fall back to the subset parser so callers always get a forest.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Forest {
    return switch (backend) {
        .subset => parser.parse(allocator, text),
        .tree_sitter => treesitter.parse(allocator, text) catch parser.parse(allocator, text),
    };
}
pub const AncestryBuilder = ancestry.AncestryBuilder;
pub const getPathAt = path.getPathAt;

test {
    @import("std").testing.refAllDecls(@This());
}
