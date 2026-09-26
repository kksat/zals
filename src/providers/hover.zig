//! Hover text for a classified cursor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const markup = @import("../services/markup.zig");
const cursor = @import("../cursor.zig");

pub fn format(a: Allocator, doc: *const Document, cur: ?cursor.Cursor) !?types.Hover {
    const c = cur orelse return null;
    return switch (c) {
        .play_keyword => |k| keywordHover(a, doc, k, "play"),
        .block_keyword => |k| keywordHover(a, doc, k, "block"),
        .role_keyword => |k| keywordHover(a, doc, k, "role"),
        .task_keyword => |k| blk: {
            if (!k.known) break :blk null;
            break :blk try keywordHover(a, doc, .{
                .name = k.name,
                .known = true,
                .start = k.start,
                .end = k.end,
            }, "task");
        },
        .module => |m| hoverText(doc, m.start, m.end, try markup.formatModule(a, m.module)),
        .module_option => |o| blk: {
            const opt = o.option orelse break :blk null;
            break :blk hoverText(doc, o.start, o.end, try markup.formatOption(a, opt));
        },
        .role_reference, .variable => null,
    };
}

fn keywordHover(a: Allocator, doc: *const Document, k: cursor.Keyword, label: []const u8) !?types.Hover {
    if (k.name.len == 0) return null;
    const text = yaml.keyword_docs.hover(k.name) orelse
        try std.fmt.allocPrint(a, "**{s}**\n\nAnsible {s} keyword.", .{ k.name, label });
    return hoverText(doc, k.start, k.end, text);
}

fn hoverText(doc: *const Document, start: usize, end: usize, text: []const u8) types.Hover {
    return .{
        .contents = .{ .kind = .markdown, .value = text },
        .range = doc.rangeFromOffsets(start, end),
    };
}

const testing = std.testing;

test "hover formats a play keyword without a server" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "- hosts: all\n";
    var doc = try Document.init(testing.allocator, "file:///play.yml", "ansible", 1, src, .utf8);
    defer doc.deinit();
    const off = std.mem.indexOf(u8, src, "hosts").?;
    const cur = cursor.Cursor{ .play_keyword = .{
        .name = "hosts",
        .known = true,
        .start = off,
        .end = off + "hosts".len,
    } };
    const h = (try format(arena.allocator(), &doc, cur)).?;
    try testing.expect(std.mem.indexOf(u8, h.contents.value, "list of groups") != null);
    try testing.expectEqual(types.MarkupKind.markdown, h.contents.kind);
    try testing.expectEqual(@as(u32, 0), h.range.?.start.line);
}

test "hover formats a module from the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options = std.StringHashMap(@import("../services/docs.zig").Option).init(a);
    const mod = @import("../services/docs.zig").Module{
        .name = "ping",
        .description = "probe the host",
        .filename = "/ping.py",
        .options = options,
    };
    var doc = try Document.init(testing.allocator, "file:///play.yml", "ansible", 1, "- ping:\n", .utf8);
    defer doc.deinit();
    const cur = cursor.Cursor{ .module = .{
        .name = "ping",
        .module = mod,
        .start = 2,
        .end = 6,
        .has_module = true,
        .offer_play_keywords = true,
    } };
    const h = (try format(a, &doc, cur)).?;
    try testing.expect(std.mem.indexOf(u8, h.contents.value, "probe the host") != null);
}

test "hover uses the classified option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options = std.StringHashMap(@import("../services/docs.zig").Option).init(a);
    const mod = @import("../services/docs.zig").Module{
        .name = "ping",
        .description = "probe",
        .filename = "",
        .options = options,
    };
    const opt = @import("../services/docs.zig").Option{
        .name = "child",
        .description = "inner payload",
        .type = "str",
    };
    var doc = try Document.init(testing.allocator, "file:///play.yml", "ansible", 1, "- ping:\n", .utf8);
    defer doc.deinit();
    const cur = cursor.Cursor{ .module_option = .{
        .name = "child",
        .module = mod,
        .option = opt,
        .list_options = true,
        .provided = &.{},
        .start = 0,
        .end = 5,
    } };
    const h = (try format(a, &doc, cur)).?;
    try testing.expect(std.mem.indexOf(u8, h.contents.value, "inner payload") != null);
}

test "unknown task key has no hover" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.init(testing.allocator, "file:///play.yml", "ansible", 1, "- foo:\n", .utf8);
    defer doc.deinit();
    const cur = cursor.Cursor{ .task_keyword = .{
        .name = "foo",
        .known = false,
        .start = 2,
        .end = 5,
        .has_module = false,
        .offer_play_keywords = true,
    } };
    try testing.expect(try format(arena.allocator(), &doc, cur) == null);
}
