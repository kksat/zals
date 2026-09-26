//! Semantic tokens for a whole document.
//!
//! Each key is classified once. The token type is a function of that kind:
//! known keywords are `keyword`, modules are `class`, schema-matched module
//! options are `method`, and everything else is `property`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const capabilities = @import("../lsp/capabilities.zig");
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const cursor = @import("../cursor.zig");
const Node = yaml.Node;

pub fn collect(a: Allocator, doc: *const Document, lookup: cursor.Docs) ![]types.AbsoluteToken {
    var opened = cursor.Doc.open(a, doc.bytes()) catch return &.{};
    defer opened.deinit();

    var tokens = std.array_list.Managed(types.AbsoluteToken).init(a);
    for (opened.forest.roots) |root| {
        try walk(&opened, doc, root, &tokens, lookup);
    }
    std.mem.sort(types.AbsoluteToken, tokens.items, {}, struct {
        fn less(_: void, x: types.AbsoluteToken, y: types.AbsoluteToken) bool {
            if (x.line != y.line) return x.line < y.line;
            return x.start < y.start;
        }
    }.less);
    return tokens.toOwnedSlice();
}

fn tokenType(cur: ?cursor.Cursor) capabilities.TokenType {
    const c = cur orelse return .property;
    return switch (c) {
        .play_keyword, .block_keyword, .role_keyword => |k| if (k.known) .keyword else .property,
        .task_keyword => |k| if (k.known) .keyword else .property,
        .module => .class,
        .module_option => |o| if (o.option != null) .method else .property,
        .role_reference, .variable => .property,
    };
}

fn walk(
    opened: *cursor.Doc,
    doc: *const Document,
    node: *Node,
    tokens: *std.array_list.Managed(types.AbsoluteToken),
    lookup: cursor.Docs,
) !void {
    switch (node.kind) {
        .map => for (node.items) |pair| try walk(opened, doc, pair, tokens, lookup),
        .seq => for (node.items) |item| try walk(opened, doc, item, tokens, lookup),
        .pair => {
            if (node.key) |key| {
                const cur = try opened.atNode(doc.uri, key, lookup);
                try emit(doc, key, tokenType(cur), tokens);
            }
            if (node.val) |v| try walk(opened, doc, v, tokens, lookup);
        },
        else => {},
    }
}

fn emit(
    doc: *const Document,
    node: *Node,
    kind: capabilities.TokenType,
    tokens: *std.array_list.Managed(types.AbsoluteToken),
) !void {
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
    });
}

const testing = std.testing;
const docs = @import("../services/docs.zig");

const One = struct { module: docs.Module };

fn oneFind(ptr: *anyopaque, _: Allocator, name: []const u8, _: []const []const u8) ?docs.Module {
    const one: *One = @ptrCast(@alignCast(ptr));
    if (std.mem.eql(u8, one.module.name, name)) return one.module;
    return null;
}
fn oneHas(ptr: *anyopaque, name: []const u8) bool {
    const one: *One = @ptrCast(@alignCast(ptr));
    return std.mem.eql(u8, one.module.name, name);
}
fn oneFqcns(_: *anyopaque, _: *std.array_list.Managed([]const u8)) !void {}

const one_vtable = cursor.Docs.VTable{
    .find_in_context = oneFind,
    .has_name = oneHas,
    .write_fqcns = oneFqcns,
};

test "hosts is a keyword token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "- hosts: all\n";
    var doc = try Document.init(testing.allocator, "file:///play.yml", "ansible", 1, src, .utf8);
    defer doc.deinit();
    const tokens = try collect(arena.allocator(), &doc, cursor.emptyDocs());
    const keyword = @intFromEnum(capabilities.TokenType.keyword);
    var saw = false;
    for (tokens) |t| {
        if (t.kind == keyword and t.length == 5) saw = true;
    }
    try testing.expect(saw);
}

test "module option is a method token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var options = std.StringHashMap(docs.Option).init(a);
    try options.put("data", .{ .name = "data", .description = "payload", .type = "str" });
    var one = One{ .module = .{
        .name = "ping",
        .description = "probe",
        .filename = "",
        .options = options,
    } };
    const lookup = cursor.Docs{ .ptr = &one, .vtable = &one_vtable };
    const src = "- ping:\n    data: 1\n";
    var doc = try Document.init(testing.allocator, "file:///play.yml", "ansible", 1, src, .utf8);
    defer doc.deinit();
    const tokens = try collect(a, &doc, lookup);
    const method = @intFromEnum(capabilities.TokenType.method);
    const class = @intFromEnum(capabilities.TokenType.class);
    var saw_method = false;
    var saw_class = false;
    for (tokens) |t| {
        if (t.kind == method and t.length == 4) saw_method = true;
        if (t.kind == class and t.length == 4) saw_class = true;
    }
    try testing.expect(saw_class);
    try testing.expect(saw_method);
}
