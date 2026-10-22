//! Per-file Workspace symbols (ADR-0032): named plays and named tasks and
//! handlers, plus the file's shape (playbook or task file). File-level symbols
//! (collections, roles, playbooks, task files) and container names are built
//! at query time from paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const Node = yaml.Node;
const plays = yaml.plays;
const scope = @import("../variables/scope.zig");
const roles = @import("../roles/resolve.zig");

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
    const file = scope.fileKind(path, roles.enclosingRole(path)).structure();
    for (forest.roots) |root| {
        if (!root.isSeq()) continue;
        if (plays.shape(root) == .playbook) {
            shape = .playbook;
            for (root.items) |play| {
                if (!play.isMap()) continue;
                const play_name = nameOf(play) orelse "";
                if (nameNode(play)) |n| try out.append(.{ .name = try a.dupe(u8, play_name), .kind = .play, .start = n.start, .end = n.end });
                var lists = plays.taskLists(play, plays.classify(play, .{}));
                while (lists.next()) |list| {
                    try tasks(a, list.seq, if (list.handler) .handler else .task, play_name, &out);
                }
            }
        } else if (plays.shape(root) == .task_list) {
            shape = .task_file;
            try tasks(a, root, if (file.handlers) .handler else .task, "", &out);
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
        var lists = plays.taskLists(item, plays.classify(item, .{}));
        while (lists.next()) |list| try tasks(a, list.seq, kind, play, out);
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

test "Handler files use Role-relative paths, not a Workspace ancestor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var forest = try yaml.parse(a, "- name: Restart web\n  debug: msg=hi\n");
    defer forest.deinit();
    for ([_]struct { path: []const u8, kind: Kind }{
        .{ .path = "/w/roles/r/handlers/sub/more.yml", .kind = .handler },
        .{ .path = "/x/handlers/project/site.yml", .kind = .task },
        .{ .path = "/x/handlers/project/roles/r/tasks/main.yml", .kind = .task },
        .{ .path = "/w/roles/r/tasks/handlers/more.yml", .kind = .task },
    }) |case| {
        const result = try collect(a, &forest, case.path);
        try testing.expectEqual(case.kind, result.symbols[0].kind);
    }
}

test "standalone Role Handler files use the metadata-supported Role root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("standalone/meta");
    try tmp.dir.writeFile(.{ .sub_path = "standalone/meta/main.yml", .data = "" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, "standalone");
    const path = try std.fs.path.join(a, &.{ root, "handlers/sub/more.yml" });
    var forest = try yaml.parse(a, "- name: Restart web\n  debug: msg=hi\n");
    defer forest.deinit();
    const result = try collect(a, &forest, path);
    try testing.expectEqual(Kind.handler, result.symbols[0].kind);
}

test "matching is a case-insensitive substring" {
    try testing.expect(matches("Install nginx", "NGINX"));
    try testing.expect(matches("x", ""));
    try testing.expect(!matches("nginx", "apache"));
}
