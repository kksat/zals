//! Semantic tokens (full document).
//!
//! Mirrors upstream's `semanticTokenProvider`: play/block/role/task keywords are
//! `keyword`, module names are `class`, module option keys are `method`, and
//! everything else is `property`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const capabilities = @import("../lsp/capabilities.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const docs = @import("../services/docs.zig");
const Node = yaml.Node;

const RawToken = struct {
    line: u32,
    start: u32,
    length: u32,
    kind: u32,
    mods: u32,
};

const KeyInfo = struct {
    kind: capabilities.TokenType,
    module: ?docs.Module = null,
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
            const key = node.key orelse return;
            const info = try classifyKey(self, a, doc, key, arena);
            try emit(doc, key, info.kind, tokens);
            if (node.val) |v| {
                if (info.module) |m| {
                    try markModuleOptions(self, a, doc, v, m, tokens, arena);
                } else {
                    try walk(self, a, doc, v, tokens, arena);
                }
            }
        },
        else => {},
    }
}

fn classifyKey(self: *Server, a: Allocator, doc: *Document, key: *Node, arena: Allocator) !KeyInfo {
    const name = key.stringValue() orelse return .{ .kind = .property };

    // Reconstruct a path ending at this key by walking parents.
    var path_buf = std.array_list.Managed(*Node).init(arena);
    var n: ?*Node = key;
    while (n) |cur| {
        try path_buf.append(cur);
        n = cur.parent;
    }
    std.mem.reverse(*Node, path_buf.items);
    const path = path_buf.items;

    if (yaml.predicates.isPlayParam(arena, path, doc.uri) orelse false) {
        return .{ .kind = if (yaml.keywords.isPlayKeyword(name)) .keyword else .property };
    }
    if (yaml.predicates.isBlockParam(arena, path)) {
        return .{ .kind = if (yaml.keywords.isBlockKeyword(name)) .keyword else .property };
    }
    if (yaml.predicates.isRoleParam(arena, path)) {
        return .{ .kind = if (yaml.keywords.isRoleKeyword(name)) .keyword else .property };
    }
    if (yaml.predicates.isTaskParam(arena, path)) {
        if (yaml.keywords.isTaskKeyword(name)) return .{ .kind = .keyword };
        if (self.docs.findModule(name)) |m| return .{ .kind = .class, .module = m };
        return .{ .kind = .property };
    }
    _ = a;
    return .{ .kind = .property };
}

/// Mark the keys of a module's option map as `method`, recursing into
/// `dict`/`list` suboptions. Unknown keys fall back to `property`.
fn markModuleOptions(self: *Server, a: Allocator, doc: *Document, node: *Node, module: docs.Module, tokens: *std.array_list.Managed(RawToken), arena: Allocator) Allocator.Error!void {
    if (!node.isMap()) return markOrdinary(self, a, doc, node, tokens, arena);
    for (node.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        if (module.options.get(name)) |opt| {
            try emit(doc, key, .method, tokens);
            if (pair.val) |v| try markOptionValue(self, a, doc, v, opt, tokens, arena);
        } else {
            try markOrdinary(self, a, doc, pair, tokens, arena);
        }
    }
}

fn markOptionValue(self: *Server, a: Allocator, doc: *Document, node: *Node, opt: docs.Option, tokens: *std.array_list.Managed(RawToken), arena: Allocator) Allocator.Error!void {
    if (std.mem.eql(u8, opt.type, "dict") and node.isMap()) {
        try markSuboptions(self, a, doc, node, opt.suboptions, tokens, arena);
    } else if (std.mem.eql(u8, opt.type, "list") and node.isSeq()) {
        for (node.items) |item| {
            if (item.isMap()) {
                try markSuboptions(self, a, doc, item, opt.suboptions, tokens, arena);
            } else {
                try markOrdinary(self, a, doc, item, tokens, arena);
            }
        }
    } else {
        try markOrdinary(self, a, doc, node, tokens, arena);
    }
}

fn markSuboptions(self: *Server, a: Allocator, doc: *Document, node: *Node, subs: []const docs.Option, tokens: *std.array_list.Managed(RawToken), arena: Allocator) Allocator.Error!void {
    for (node.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        var found: ?docs.Option = null;
        for (subs) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                found = s;
                break;
            }
        }
        if (found) |opt| {
            try emit(doc, key, .method, tokens);
            if (pair.val) |v| try markOptionValue(self, a, doc, v, opt, tokens, arena);
        } else {
            try markOrdinary(self, a, doc, pair, tokens, arena);
        }
    }
}

fn markOrdinary(self: *Server, a: Allocator, doc: *Document, node: *Node, tokens: *std.array_list.Managed(RawToken), arena: Allocator) Allocator.Error!void {
    switch (node.kind) {
        .pair => {
            if (node.key) |k| try emit(doc, k, .property, tokens);
            if (node.val) |v| try markOrdinary(self, a, doc, v, tokens, arena);
        },
        .map, .seq => for (node.items) |it| try markOrdinary(self, a, doc, it, tokens, arena),
        else => {},
    }
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