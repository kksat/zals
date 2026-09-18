//! Semantic tokens (full document).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const capabilities = @import("../lsp/capabilities.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const Node = yaml.Node;

const RawToken = struct {
    line: u32,
    start: u32,
    length: u32,
    kind: u32,
    mods: u32,
};

pub fn full(self: *Server, a: Allocator, params: Value) !Value {
    const td = json_util.field(params, "textDocument") orelse return empty(a);
    const uri = json_util.string(td, "uri") orelse return empty(a);
    const doc = self.documents.get(uri) orelse return empty(a);

    var forest = yaml.parse(a, doc.bytes()) catch return empty(a);
    defer forest.deinit();

    var tokens = std.array_list.Managed(RawToken).init(a);
    for (forest.roots) |root| {
        try walk(self, a, doc, root, &tokens, forest.allocator());
    }

    std.mem.sort(RawToken, tokens.items, {}, struct {
        fn less(_: void, x: RawToken, y: RawToken) bool {
            if (x.line != y.line) return x.line < y.line;
            return x.start < y.start;
        }
    }.less);

    var data = std.json.Array.init(a);
    var prev_line: u32 = 0;
    var prev_start: u32 = 0;
    for (tokens.items) |t| {
        const dline = t.line - prev_line;
        const dstart: u32 = if (t.line == prev_line) t.start - prev_start else t.start;
        try data.append(json_util.num(dline));
        try data.append(json_util.num(dstart));
        try data.append(json_util.num(t.length));
        try data.append(json_util.num(t.kind));
        try data.append(json_util.num(t.mods));
        prev_line = t.line;
        prev_start = t.start;
    }
    var obj = json_util.obj(a);
    try obj.put("data", .{ .array = data });
    return .{ .object = obj };
}

fn empty(a: Allocator) !Value {
    var obj = json_util.obj(a);
    try obj.put("data", .{ .array = std.json.Array.init(a) });
    return .{ .object = obj };
}

fn walk(self: *Server, a: Allocator, doc: *Document, node: *Node, tokens: *std.array_list.Managed(RawToken), arena: Allocator) !void {
    switch (node.kind) {
        .map => {
            for (node.items) |pair| try walk(self, a, doc, pair, tokens, arena);
        },
        .seq => {
            for (node.items) |item| try walk(self, a, doc, item, tokens, arena);
        },
        .pair => {
            if (node.key) |k| try markKey(self, a, doc, node, k, tokens, arena);
            if (node.val) |v| try walk(self, a, doc, v, tokens, arena);
        },
        else => {},
    }
}

fn markKey(self: *Server, a: Allocator, doc: *Document, pair: *Node, key: *Node, tokens: *std.array_list.Managed(RawToken), arena: Allocator) !void {
    const name = key.stringValue() orelse return;
    // Reconstruct a path ending at this key by walking parents.
    var path_buf = std.array_list.Managed(*Node).init(arena);
    var n: ?*Node = key;
    while (n) |cur| {
        try path_buf.append(cur);
        n = cur.parent;
    }
    std.mem.reverse(*Node, path_buf.items);
    const path = path_buf.items;

    var kind: capabilities.TokenType = .property;
    if (yaml.predicates.isPlayParam(arena, path, doc.uri) orelse false) {
        kind = if (yaml.keywords.isPlayKeyword(name)) .keyword else .property;
    } else if (yaml.predicates.isBlockParam(arena, path)) {
        kind = if (yaml.keywords.isBlockKeyword(name)) .keyword else .property;
    } else if (yaml.predicates.isRoleParam(arena, path)) {
        kind = if (yaml.keywords.isRoleKeyword(name)) .keyword else .property;
    } else if (yaml.predicates.isTaskParam(arena, path)) {
        if (yaml.keywords.isTaskKeyword(name)) {
            kind = .keyword;
        } else if (self.docs.catalog.contains(name) or self.docs.findModule(name) != null) {
            kind = .class;
        } else {
            kind = .property;
        }
    }
    _ = pair;
    try emit(doc, key, kind, tokens);
    _ = a;
}

fn emit(doc: *Document, node: *Node, kind: capabilities.TokenType, tokens: *std.array_list.Managed(RawToken)) !void {
    const start = doc.positionAt(node.start);
    const end = doc.positionAt(node.end);
    const length: u32 = if (end.line == start.line)
        end.character - start.character
    else
        end.character;
    if (length == 0) return;
    try tokens.append(.{
        .line = start.line,
        .start = start.character,
        .length = length,
        .kind = @intFromEnum(kind),
        .mods = 0,
    });
}
