//! Hover: keywords, modules, and module options.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const Server = @import("../lsp/server.zig").Server;
const yaml = @import("../yaml/root.zig");
const markup = @import("../services/markup.zig");
const util = @import("util.zig");

pub fn hover(self: *Server, a: Allocator, params: Value) !Value {
    var cur = util.parseAt(self, a, params) orelse return Value.null;
    defer cur.forest.deinit();
    const name = util.currentKey(cur.path) orelse return Value.null;
    if (name.len == 0) return Value.null;
    const arena = cur.forest.allocator();
    const path = cur.path;

    var text: []const u8 = undefined;
    if (yaml.predicates.isPlayParam(arena, path, cur.doc.uri) orelse false) {
        text = yaml.keyword_docs.hover(name) orelse try std.fmt.allocPrint(a, "**{s}**\n\nAnsible play keyword.", .{name});
    } else if (yaml.predicates.isBlockParam(arena, path)) {
        text = yaml.keyword_docs.hover(name) orelse try std.fmt.allocPrint(a, "**{s}**\n\nAnsible block keyword.", .{name});
    } else if (yaml.predicates.isRoleParam(arena, path)) {
        text = yaml.keyword_docs.hover(name) orelse try std.fmt.allocPrint(a, "**{s}**\n\nAnsible role keyword.", .{name});
    } else if (yaml.predicates.isTaskParam(arena, path)) {
        if (yaml.keywords.isTaskKeyword(name)) {
            text = yaml.keyword_docs.hover(name) orelse try std.fmt.allocPrint(a, "**{s}**\n\nAnsible task keyword.", .{name});
        } else {
            const collections = yaml.collections.getDeclaredCollections(arena, path) catch &.{};
            const mod = self.docs.findModuleInContext(arena, name, collections) orelse return Value.null;
            text = try markup.formatModule(a, mod);
        }
    } else if (optionHover(self, a, arena, path, name)) |t| {
        text = t;
    } else {
        return Value.null;
    }

    var contents = json_util.obj(a);
    try contents.put("kind", json_util.str("markdown"));
    try contents.put("value", json_util.str(text));
    var result = json_util.obj(a);
    try result.put("contents", .{ .object = contents });

    // Range of the hovered key, matching upstream's `getOrigRange`.
    const key_node = path[path.len - 1];
    const start = cur.doc.positionAt(key_node.start);
    const end = cur.doc.positionAt(key_node.end);
    var range = json_util.obj(a);
    try range.put("start", try positionValue(a, start));
    try range.put("end", try positionValue(a, end));
    try result.put("range", .{ .object = range });
    return .{ .object = result };
}

fn positionValue(a: Allocator, p: @import("../lsp/types.zig").Position) !Value {
    var o = json_util.obj(a);
    try o.put("line", json_util.num(p.line));
    try o.put("character", json_util.num(p.character));
    return .{ .object = o };
}

fn optionHover(self: *Server, a: Allocator, arena: Allocator, path: []*yaml.Node, name: []const u8) ?[]const u8 {
    const traced = (yaml.options.getTaskParamPathWithTrace(arena, path) catch return null) orelse return null;
    const collections = yaml.collections.getDeclaredCollections(arena, traced.path) catch &.{};
    const module_key = util.currentKey(traced.path) orelse return null;
    const mod = self.docs.findModuleInContext(arena, module_key, collections) orelse return null;
    const opt = mod.options.get(name) orelse return null;
    return markup.formatOption(a, opt) catch null;
}