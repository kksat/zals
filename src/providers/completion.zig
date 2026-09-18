//! Completion and completionItem/resolve.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const Server = @import("../lsp/server.zig").Server;
const yaml = @import("../yaml/root.zig");
const util = @import("util.zig");

pub fn complete(self: *Server, a: Allocator, params: Value) !Value {
    var cur = util.parseAt(self, a, params) orelse return emptyList(a);
    defer cur.forest.deinit();

    var items = std.json.Array.init(a);
    const arena = cur.forest.allocator();
    const path = cur.path;

    if (path.len > 0 and (yaml.predicates.isPlayParam(arena, path, cur.doc.uri) orelse false)) {
        try addKeywords(&items, a, &yaml.keywords.play_keywords, 14);
    } else if (path.len > 0 and yaml.predicates.isBlockParam(arena, path)) {
        try addKeywords(&items, a, &yaml.keywords.block_keywords, 14);
    } else if (path.len > 0 and yaml.predicates.isRoleParam(arena, path)) {
        try addKeywords(&items, a, &yaml.keywords.role_keywords, 14);
    } else if (path.len > 0 and yaml.predicates.isTaskParam(arena, path)) {
        try addKeywords(&items, a, &yaml.keywords.task_keywords, 14);
        if (yaml.predicates.isPlayParam(arena, path, cur.doc.uri) == null) {
            try addPlayWithoutTask(&items, a);
        }
        const modules = yaml.options.providedModuleNames(arena, path) catch &.{};
        if (modules.len == 0) {
            try addKeywords(&items, a, &[_][]const u8{"block"}, 14);
            try addModules(self, &items, a);
        }
    } else if (try addOptions(self, &items, a, arena, path)) {
        // module options filled
    } else {
        try addKeywords(&items, a, &yaml.keywords.task_keywords, 14);
        try addModules(self, &items, a);
    }

    var list = json_util.obj(a);
    try list.put("isIncomplete", json_util.booleanValue(false));
    try list.put("items", .{ .array = items });
    return .{ .object = list };
}

pub fn resolve(self: *Server, a: Allocator, params: Value) !Value {
    const label = json_util.string(params, "label") orelse return params;
    if (self.docs.findModule(label) orelse self.docs.findModuleInContext(a, label, &.{})) |mod| {
        var doc = json_util.obj(a);
        try doc.put("kind", json_util.str("markdown"));
        try doc.put("value", json_util.str(mod.description));
        var obj = switch (params) {
            .object => |o| o,
            else => json_util.obj(a),
        };
        try obj.put("detail", json_util.str(mod.name));
        try obj.put("documentation", .{ .object = doc });
        return .{ .object = obj };
    }
    if (yaml.keyword_docs.hover(label)) |text| {
        var doc = json_util.obj(a);
        try doc.put("kind", json_util.str("markdown"));
        try doc.put("value", json_util.str(text));
        var obj = switch (params) {
            .object => |o| o,
            else => json_util.obj(a),
        };
        try obj.put("documentation", .{ .object = doc });
        return .{ .object = obj };
    }
    return params;
}

fn addOptions(self: *Server, items: *std.json.Array, a: Allocator, arena: Allocator, path: []*yaml.Node) !bool {
    const traced = (try yaml.options.getTaskParamPathWithTrace(arena, path)) orelse return false;
    if (traced.trace.len == 0) return false;
    const last = traced.trace[traced.trace.len - 1];
    if (last.kind != .dict) return false;

    const collections = yaml.collections.getDeclaredCollections(arena, traced.path) catch &.{};
    const module_key = util.currentKey(traced.path) orelse return false;

    const mod = if (std.mem.eql(u8, module_key, "args")) blk: {
        const names = yaml.options.providedModuleNames(arena, traced.path) catch break :blk null;
        for (names) |n| {
            if (self.docs.findModuleInContext(arena, n, collections)) |m| break :blk m;
        }
        break :blk null;
    } else self.docs.findModuleInContext(arena, module_key, collections);

    const module = mod orelse return false;
    const provided = yaml.options.providedKeys(arena, path) catch &.{};

    var it = module.options.iterator();
    while (it.next()) |e| {
        const opt = e.value_ptr.*;
        var skip = false;
        for (provided) |p| {
            if (std.mem.eql(u8, p, opt.name)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        var item = json_util.obj(a);
        try item.put("label", json_util.str(opt.name));
        try item.put("kind", json_util.num(10)); // property
        try item.put("detail", json_util.str(opt.type));
        try item.put("insertText", json_util.str(opt.name));
        if (opt.description.len > 0) {
            var doc = json_util.obj(a);
            try doc.put("kind", json_util.str("markdown"));
            try doc.put("value", json_util.str(opt.description));
            try item.put("documentation", .{ .object = doc });
        }
        try items.append(.{ .object = item });
    }
    return true;
}

fn emptyList(a: Allocator) !Value {
    var list = json_util.obj(a);
    try list.put("isIncomplete", json_util.booleanValue(false));
    try list.put("items", .{ .array = std.json.Array.init(a) });
    return .{ .object = list };
}

fn addKeywords(items: *std.json.Array, a: Allocator, names: []const []const u8, kind: i64) !void {
    for (names) |name| {
        var item = json_util.obj(a);
        try item.put("label", json_util.str(name));
        try item.put("kind", json_util.num(kind));
        try item.put("insertText", json_util.str(name));
        try items.append(.{ .object = item });
    }
}

fn addPlayWithoutTask(items: *std.json.Array, a: Allocator) !void {
    for (yaml.keywords.play_keywords) |name| {
        if (!yaml.keywords.isTaskKeyword(name)) {
            var item = json_util.obj(a);
            try item.put("label", json_util.str(name));
            try item.put("kind", json_util.num(14));
            try item.put("insertText", json_util.str(name));
            try items.append(.{ .object = item });
        }
    }
}

fn addModules(self: *Server, items: *std.json.Array, a: Allocator) !void {
    var it = self.docs.catalog.iterator();
    var n: usize = 0;
    while (it.next()) |e| {
        if (n >= 500) break;
        n += 1;
        var item = json_util.obj(a);
        try item.put("label", json_util.str(e.key_ptr.*));
        try item.put("kind", json_util.num(7)); // class
        try item.put("detail", json_util.str(e.value_ptr.description));
        try items.append(.{ .object = item });
    }
}
