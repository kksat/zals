//! Shared helpers for LSP providers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");

pub const Cursor = struct {
    doc: *Document,
    offset: usize,
    forest: yaml.Forest,
    path: []*yaml.Node,
};

pub fn cursorAt(self: *Server, params: Value) ?struct { doc: *Document, offset: usize } {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    const pos_v = json_util.field(params, "position") orelse return null;
    const pos = json_util.position(pos_v) orelse return null;
    const doc = self.documents.get(uri) orelse return null;
    const offset = doc.offsetAt(pos) orelse return null;
    return .{ .doc = doc, .offset = offset };
}

pub fn parseAt(self: *Server, a: Allocator, params: Value) ?Cursor {
    const loc = cursorAt(self, params) orelse return null;
    var forest = yaml.parse(a, loc.doc.bytes()) catch return null;
    var found: []*yaml.Node = &.{};
    for (forest.roots) |root| {
        if (yaml.getPathAt(forest.allocator(), root, loc.offset, true) catch null) |p| {
            found = p;
            break;
        }
    }
    return .{ .doc = loc.doc, .offset = loc.offset, .forest = forest, .path = found };
}

pub fn currentKey(path: []*yaml.Node) ?[]const u8 {
    if (path.len == 0) return null;
    const n = path[path.len - 1];
    return n.stringValue();
}

pub fn leafPair(path: []*yaml.Node) ?*yaml.Node {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i].isPair()) return path[i];
    }
    return null;
}
