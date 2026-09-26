//! Completion candidates for a classified cursor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const yaml = @import("../yaml/root.zig");
const cursor = @import("../cursor.zig");

pub const Resolved = struct {
    detail: ?[]const u8 = null,
    documentation: ?types.MarkupContent = null,
};

pub fn list(a: Allocator, cur: ?cursor.Cursor, lookup: cursor.Docs) !types.CompletionList {
    var items = std.array_list.Managed(types.CompletionItem).init(a);
    if (cur) |c| {
        switch (c) {
            .play_keyword => try addKeywords(&items, &yaml.keywords.play_keywords),
            .block_keyword => try addKeywords(&items, &yaml.keywords.block_keywords),
            .role_keyword => try addKeywords(&items, &yaml.keywords.role_keywords),
            .task_keyword => |t| try addTask(&items, a, lookup, t.has_module, t.offer_play_keywords),
            .module => |m| try addTask(&items, a, lookup, m.has_module, m.offer_play_keywords),
            .module_option => |o| {
                if (o.list_options) try addOptions(&items, o) else try addFallback(&items, a, lookup);
            },
            // A value that is not a keyword context used to fall through to
            // the same default list.
            .role_reference, .variable => try addFallback(&items, a, lookup),
        }
    } else {
        try addFallback(&items, a, lookup);
    }
    return .{ .items = try items.toOwnedSlice() };
}

pub fn resolve(a: Allocator, label: []const u8, lookup: cursor.Docs) Resolved {
    if (lookup.findInContext(a, label, &.{})) |mod| {
        return .{
            .detail = mod.name,
            .documentation = .{ .kind = .markdown, .value = mod.description },
        };
    }
    if (yaml.keyword_docs.hover(label)) |text| {
        return .{ .documentation = .{ .kind = .markdown, .value = text } };
    }
    return .{};
}

fn addTask(
    items: *std.array_list.Managed(types.CompletionItem),
    a: Allocator,
    lookup: cursor.Docs,
    has_module: bool,
    offer_play_keywords: bool,
) !void {
    try addKeywords(items, &yaml.keywords.task_keywords);
    if (offer_play_keywords) try addPlayWithoutTask(items);
    if (!has_module) {
        const block = [_][]const u8{"block"};
        try addKeywords(items, &block);
        try addModules(items, a, lookup);
    }
}

fn addFallback(
    items: *std.array_list.Managed(types.CompletionItem),
    a: Allocator,
    lookup: cursor.Docs,
) !void {
    try addKeywords(items, &yaml.keywords.task_keywords);
    try addModules(items, a, lookup);
}

fn addOptions(items: *std.array_list.Managed(types.CompletionItem), o: cursor.OptionAt) !void {
    var it = o.module.options.iterator();
    while (it.next()) |e| {
        const opt = e.value_ptr.*;
        var skip = false;
        for (o.provided) |p| {
            if (std.mem.eql(u8, p, opt.name)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        try items.append(.{
            .label = opt.name,
            .kind = .property,
            .detail = opt.type,
            .documentation = if (opt.description.len > 0)
                .{ .kind = .markdown, .value = opt.description }
            else
                null,
            .insertText = opt.name,
        });
    }
}

fn addKeywords(items: *std.array_list.Managed(types.CompletionItem), names: []const []const u8) !void {
    for (names) |name| {
        try items.append(.{
            .label = name,
            .kind = .keyword,
            .insertText = name,
        });
    }
}

fn addPlayWithoutTask(items: *std.array_list.Managed(types.CompletionItem)) !void {
    for (yaml.keywords.play_keywords) |name| {
        if (!yaml.keywords.isTaskKeyword(name)) {
            try items.append(.{
                .label = name,
                .kind = .keyword,
                .insertText = name,
            });
        }
    }
}

fn addModules(
    items: *std.array_list.Managed(types.CompletionItem),
    a: Allocator,
    lookup: cursor.Docs,
) !void {
    var names = std.array_list.Managed([]const u8).init(a);
    try lookup.writeFqcns(&names);
    for (names.items) |fqcn| {
        var detail: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, fqcn, '.')) |dot| {
            if (std.mem.lastIndexOfScalar(u8, fqcn[0..dot], '.')) |dot2| {
                detail = fqcn[0..dot2];
            }
        }
        try items.append(.{
            .label = fqcn,
            .kind = .class,
            .detail = detail,
        });
    }
}

const testing = std.testing;

test "completion lists play keywords from a cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cur = cursor.Cursor{ .play_keyword = .{
        .name = "ho",
        .known = false,
        .start = 0,
        .end = 0,
    } };
    const result = try list(arena.allocator(), cur, cursor.emptyDocs());
    try testing.expect(hasLabel(result.items, "hosts"));
    try testing.expect(!hasLabel(result.items, "ansible.builtin.ping"));
}

test "completion lists remaining module options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var options = std.StringHashMap(@import("../services/docs.zig").Option).init(a);
    try options.put("data", .{ .name = "data", .description = "payload", .type = "str" });
    try options.put("other", .{ .name = "other", .description = "", .type = "int" });
    const mod = @import("../services/docs.zig").Module{
        .name = "ping",
        .description = "probe",
        .filename = "",
        .options = options,
    };
    const cur = cursor.Cursor{ .module_option = .{
        .name = "data",
        .module = mod,
        .option = options.get("data"),
        .list_options = true,
        .provided = &.{"data"},
        .start = 0,
        .end = 4,
    } };
    const result = try list(a, cur, cursor.emptyDocs());
    try testing.expect(hasLabel(result.items, "other"));
    try testing.expect(!hasLabel(result.items, "data"));
    try testing.expectEqual(types.CompletionItemKind.property, result.items[0].kind.?);
}

fn hasLabel(items: []const types.CompletionItem, label: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.label, label)) return true;
    return false;
}
