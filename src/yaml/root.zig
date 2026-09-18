//! YAML layer: parser interface, subset backend, DOM, and Ansible path helpers.

pub const dom = @import("dom.zig");
pub const path = @import("path.zig");
pub const ancestry = @import("ancestry.zig");
pub const keywords = @import("keywords.zig");
pub const predicates = @import("predicates.zig");
pub const collections = @import("collections.zig");
pub const options = @import("options.zig");
pub const jsonify = @import("jsonify.zig");
pub const keyword_docs = @import("keyword_docs.zig");
pub const parser = @import("parser.zig");

pub const Node = dom.Node;
pub const Forest = parser.Forest;
pub const parse = parser.parse;
pub const AncestryBuilder = ancestry.AncestryBuilder;
pub const getPathAt = path.getPathAt;

test {
    @import("std").testing.refAllDecls(@This());
}
