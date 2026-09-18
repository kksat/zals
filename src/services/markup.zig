//! Ansible documentation markup → Markdown/HTML, mirroring `antsibull-docs`.
//!
//! Module docs embed markup like `C(/usr/bin/ansible)`, `V(pong)`, `M(foo.bar)`,
//! `I(italic)`, `L(text,url)`. Upstream renders these with `toMD(parse(text))`,
//! which produces HTML tags and escapes Markdown special characters. This module
//! reproduces that output closely enough for hover parity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const docs = @import("docs.zig");

const Command = struct {
    name: []const u8,
    params: usize,
    escaped: bool,
};

const commands = [_]Command{
    .{ .name = "I", .params = 1, .escaped = false },
    .{ .name = "B", .params = 1, .escaped = false },
    .{ .name = "M", .params = 1, .escaped = false },
    .{ .name = "U", .params = 1, .escaped = false },
    .{ .name = "L", .params = 2, .escaped = false },
    .{ .name = "R", .params = 2, .escaped = false },
    .{ .name = "C", .params = 1, .escaped = false },
    .{ .name = "P", .params = 1, .escaped = true },
    .{ .name = "E", .params = 1, .escaped = true },
    .{ .name = "V", .params = 1, .escaped = true },
    .{ .name = "O", .params = 1, .escaped = true },
    .{ .name = "RV", .params = 1, .escaped = true },
};

/// Characters escaped by antsibull-docs' `quoteMD`.
const md_special = "!\"#$%&'()*+,:;<=>?@[\\]^_`{|}~.-";

fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

const Found = struct { index: usize, cmd: *const Command };

fn findCommand(text: []const u8, from: usize) ?Found {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (i > 0 and isWord(text[i - 1])) continue;
        for (&commands) |*cmd| {
            if (i + cmd.name.len >= text.len) continue;
            if (!std.mem.startsWith(u8, text[i..], cmd.name)) continue;
            if (text[i + cmd.name.len] != '(') continue;
            return .{ .index = i, .cmd = cmd };
        }
    }
    return null;
}

const Args = struct { args: [2][]const u8, end: usize };

fn parseArgs(a: Allocator, text: []const u8, start: usize, count: usize, escaped: bool) !Args {
    var args: [2][]const u8 = .{ "", "" };
    var idx = start;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const is_last = i == count - 1;
        var buf = std.ArrayList(u8).empty;
        while (idx < text.len) {
            const c = text[idx];
            if (escaped and c == '\\' and idx + 1 < text.len) {
                try buf.append(a, text[idx + 1]);
                idx += 2;
                continue;
            }
            if (!is_last and c == ',') {
                idx += 1;
                break;
            }
            if (is_last and c == ')') {
                idx += 1;
                break;
            }
            try buf.append(a, c);
            idx += 1;
        }
        var s: []const u8 = try buf.toOwnedSlice(a);
        s = if (i == 0) std.mem.trimRight(u8, s, " ") else std.mem.trim(u8, s, " ");
        args[i] = s;
    }
    return .{ .args = args, .end = idx };
}

fn quoteMD(a: Allocator, text: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, md_special, c) != null) try buf.append(a, '\\');
        try buf.append(a, c);
    }
    return try buf.toOwnedSlice(a);
}

fn formatCommand(a: Allocator, cmd: *const Command, args: [2][]const u8) ![]const u8 {
    const n = cmd.name;
    if (std.mem.eql(u8, n, "C") or std.mem.eql(u8, n, "V") or std.mem.eql(u8, n, "E") or std.mem.eql(u8, n, "RV"))
        return std.fmt.allocPrint(a, "<code>{s}</code>", .{try quoteMD(a, args[0])});
    if (std.mem.eql(u8, n, "O"))
        return std.fmt.allocPrint(a, "<code><strong>{s}</strong></code>", .{try quoteMD(a, args[0])});
    if (std.mem.eql(u8, n, "I"))
        return std.fmt.allocPrint(a, "<em>{s}</em>", .{try quoteMD(a, args[0])});
    if (std.mem.eql(u8, n, "B"))
        return std.fmt.allocPrint(a, "<b>{s}</b>", .{try quoteMD(a, args[0])});
    if (std.mem.eql(u8, n, "M") or std.mem.eql(u8, n, "P"))
        return quoteMD(a, args[0]);
    if (std.mem.eql(u8, n, "U"))
        return std.fmt.allocPrint(a, "[{s}]({s})", .{ try quoteMD(a, args[0]), try quoteMD(a, args[0]) });
    if (std.mem.eql(u8, n, "L"))
        return std.fmt.allocPrint(a, "[{s}]({s})", .{ try quoteMD(a, args[0]), try quoteMD(a, args[1]) });
    if (std.mem.eql(u8, n, "R"))
        return quoteMD(a, args[0]);
    return quoteMD(a, args[0]);
}

/// Convert one paragraph of Ansible markup to Markdown/HTML.
pub fn toMarkdown(a: Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < text.len) {
        if (findCommand(text, i)) |found| {
            if (found.index > i) try out.appendSlice(a, try quoteMD(a, text[i..found.index]));
            const parsed = try parseArgs(a, text, found.index + found.cmd.name.len + 1, found.cmd.params, found.cmd.escaped);
            try out.appendSlice(a, try formatCommand(a, found.cmd, parsed.args));
            i = parsed.end;
        } else {
            try out.appendSlice(a, try quoteMD(a, text[i..]));
            break;
        }
    }
    return try out.toOwnedSlice(a);
}

/// Format a list of paragraphs. When `as_list`, each becomes a `- ` bullet.
pub fn formatDescription(a: Allocator, items: []const []const u8, as_list: bool) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (items, 0..) |item, idx| {
        if (idx > 0) try out.append(a, '\n');
        if (as_list) try out.appendSlice(a, "- ");
        try out.appendSlice(a, try toMarkdown(a, item));
    }
    return try out.toOwnedSlice(a);
}

/// Render a module's hover documentation, mirroring upstream's `formatModule`.
pub fn formatModule(a: Allocator, mod: docs.Module) ![]const u8 {
    var sections = std.ArrayList([]const u8).empty;
    if (mod.deprecated) try sections.append(a, "**DEPRECATED**");
    if (mod.description.len > 0)
        try sections.append(a, try std.fmt.allocPrint(a, "*{s}*", .{try toMarkdown(a, mod.description)}));
    if (mod.long_description.len > 0) {
        try sections.append(a, "**Description**");
        try sections.append(a, try formatDescription(a, mod.long_description, true));
    }
    if (mod.requirements.len > 0) {
        try sections.append(a, "**Requirements**");
        try sections.append(a, try formatDescription(a, mod.requirements, true));
    }
    if (mod.notes.len > 0) {
        try sections.append(a, "**Notes**");
        try sections.append(a, try formatDescription(a, mod.notes, true));
    }
    return std.mem.join(a, "\n\n", sections.items);
}

/// Render an option's hover documentation, mirroring upstream's `formatOption`.
pub fn formatOption(a: Allocator, opt: docs.Option) ![]const u8 {
    var sections = std.ArrayList([]const u8).empty;

    var details = std.ArrayList(u8).empty;
    if (opt.required) try details.appendSlice(a, "(required)");
    if (opt.type.len > 0) {
        if (details.items.len > 0) try details.append(a, ' ');
        if (std.mem.eql(u8, opt.type, "list") and opt.elements.len > 0) {
            try details.appendSlice(a, try std.fmt.allocPrint(a, "list({s})", .{opt.elements}));
        } else {
            try details.appendSlice(a, opt.type);
        }
    }
    if (details.items.len > 0)
        try sections.append(a, try std.fmt.allocPrint(a, "`{s}`", .{details.items}));

    if (opt.description.len > 0)
        try sections.append(a, try toMarkdown(a, opt.description));

    if (opt.default) |d|
        try sections.append(a, try std.fmt.allocPrint(a, "*Default*:\n ```javascript\n{s}\n```", .{d}));

    if (opt.choices.len > 0) {
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(a, "*Choices*: [");
        for (opt.choices, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "`{s}`", .{c}));
        }
        try buf.append(a, ']');
        try sections.append(a, try buf.toOwnedSlice(a));
    }

    if (opt.aliases.len > 0) {
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(a, "*Aliases*: [");
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "`{s}`", .{opt.name}));
        for (opt.aliases) |al| {
            try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "`{s}`", .{al}));
        }
        try buf.append(a, ']');
        try sections.append(a, try buf.toOwnedSlice(a));
    }

    return std.mem.join(a, "\n\n", sections.items);
}

test "markup conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try toMarkdown(a, "returns V(pong) from C(/usr/bin/ansible)");
    try std.testing.expectEqualStrings("returns <code>pong</code> from <code>/usr/bin/ansible</code>", out);
}

test "markup escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try toMarkdown(a, "host, verify a usable python");
    try std.testing.expectEqualStrings("host\\, verify a usable python", out);
}