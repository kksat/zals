//! Per-file Workspace symbols (ADR-0032): named plays and named tasks and
//! handlers, plus the file's shape (playbook or task file). File-level symbols
//! (collections, roles, playbooks, task files) and container names are built
//! at query time from paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const Node = yaml.Node;

pub const Kind = enum { play, task, handler };

pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    /// Name of the enclosing play for tasks and handlers in a playbook.
    play: []const u8 = "",
    start: usize,
    end: usize,
};

pub const Shape = enum { other, playbook, task_file };

pub const Result = struct {
    shape: Shape = .other,
    symbols: []const Symbol = &.{},
};

pub fn collect(a: Allocator, forest: *const yaml.Forest, path: []const u8) !Result {
    var out = std.array_list.Managed(Symbol).init(a);
    var shape: Shape = .other;
    const in_handlers = std.mem.indexOf(u8, path, "/handlers/") != null;
    for (forest.roots) |root| {
        if (!root.isSeq()) continue;
        if (isPlaybook(root)) {
            shape = .playbook;
            for (root.items) |play| {
                if (!play.isMap()) continue;
                const play_name = nameOf(play) orelse "";
                if (nameNode(play)) |n| try out.append(.{ .name = try a.dupe(u8, play_name), .kind = .play, .start = n.start, .end = n.end });
                for (play.items) |pair| {
                    const key = (pair.key orelse continue).stringValue() orelse continue;
                    const val = pair.val orelse continue;
                    if (!val.isSeq()) continue;
                    if (std.mem.eql(u8, key, "handlers")) {
                        try tasks(a, val, .handler, play_name, &out);
                    } else if (std.mem.eql(u8, key, "tasks") or std.mem.eql(u8, key, "pre_tasks") or std.mem.eql(u8, key, "post_tasks")) {
                        try tasks(a, val, .task, play_name, &out);
                    }
                }
            }
        } else if (hasMapItem(root)) {
            shape = .task_file;
            try tasks(a, root, if (in_handlers) .handler else .task, "", &out);
        }
    }
    return .{ .shape = shape, .symbols = try out.toOwnedSlice() };
}

fn tasks(a: Allocator, seq: *Node, kind: Kind, play: []const u8, out: *std.array_list.Managed(Symbol)) !void {
    for (seq.items) |item| {
        if (!item.isMap()) continue;
        if (nameNode(item)) |n| {
            try out.append(.{ .name = try a.dupe(u8, n.stringValue().?), .kind = kind, .play = try a.dupe(u8, play), .start = n.start, .end = n.end });
        }
        for ([_][]const u8{ "block", "rescue", "always" }) |section| {
            const p = yaml.dom.findPair(item, section) orelse continue;
            if (p.val) |v| if (v.isSeq()) try tasks(a, v, kind, play, out);
        }
    }
}

fn nameNode(map: *Node) ?*Node {
    const p = yaml.dom.findPair(map, "name") orelse return null;
    const v = p.val orelse return null;
    const s = v.stringValue() orelse return null;
    if (s.len == 0) return null;
    return v;
}

fn nameOf(map: *Node) ?[]const u8 {
    return (nameNode(map) orelse return null).stringValue();
}

fn isPlaybook(seq: *Node) bool {
    for (seq.items) |item| {
        if (!item.isMap()) continue;
        for (item.items) |pair| {
            const name = (pair.key orelse continue).stringValue() orelse continue;
            if (yaml.keywords.isPlayExclusiveKeyword(name) or std.mem.eql(u8, name, "import_playbook")) return true;
        }
    }
    return false;
}

fn hasMapItem(seq: *Node) bool {
    for (seq.items) |item| if (item.isMap()) return true;
    return false;
}

/// Case-insensitive substring match; an empty query matches everything.
pub fn matches(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > name.len) return false;
    var i: usize = 0;
    while (i + query.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + query.len], query)) return true;
    }
    return false;
}

const testing = std.testing;

test "playbook symbols carry their play" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\- name: Configure web
        \\  hosts: web
        \\  tasks:
        \\    - name: Open firewall
        \\      debug: msg=hi
        \\    - block:
        \\        - name: Nested
        \\          debug: msg=hi
        \\    - debug: msg=unnamed
        \\  handlers:
        \\    - name: Restart nginx
        \\      debug: msg=hi
        \\
    ;
    var forest = try yaml.parse(a, text);
    defer forest.deinit();
    const r = try collect(a, &forest, "/w/site.yml");
    try testing.expectEqual(Shape.playbook, r.shape);
    try testing.expectEqual(@as(usize, 4), r.symbols.len);
    try testing.expectEqual(Kind.play, r.symbols[0].kind);
    try testing.expectEqualStrings("Open firewall", r.symbols[1].name);
    try testing.expectEqualStrings("Configure web", r.symbols[1].play);
    try testing.expectEqualStrings("Nested", r.symbols[2].name);
    try testing.expectEqual(Kind.handler, r.symbols[3].kind);
}

test "task files in handlers/ hold handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var forest = try yaml.parse(a, "- name: Restart nginx\n  service: name=nginx state=restarted\n");
    defer forest.deinit();
    const r = try collect(a, &forest, "/w/roles/nginx/handlers/main.yml");
    try testing.expectEqual(Shape.task_file, r.shape);
    try testing.expectEqual(Kind.handler, r.symbols[0].kind);
}

test "matching is a case-insensitive substring" {
    try testing.expect(matches("Install nginx", "NGINX"));
    try testing.expect(matches("x", ""));
    try testing.expect(!matches("nginx", "apache"));
}
