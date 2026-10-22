//! Document symbols: a semantic outline for a single Ansible YAML document.
//!
//! See ADR-0027. The provider is document-scoped — it never reaches across
//! files. Classification is content-first: a map root is a variable-style map,
//! a seq root containing a play is a playbook, and any other seq root of maps
//! is a task list. The file path is used only to label handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const lsp = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const dom = yaml.dom;
const Node = yaml.Node;
const plays = yaml.plays;
const DocumentSymbol = lsp.DocumentSymbol;
const SymbolKind = lsp.SymbolKind;

/// LSP entry point for `textDocument/documentSymbol`.
pub fn documentSymbol(self: *Server, a: Allocator, params: Value) !Value {
    const td = json_util.field(params, "textDocument") orelse return empty(a);
    const uri = json_util.string(td, "uri") orelse return empty(a);
    const doc = self.documents.get(uri) orelse return empty(a);
    const syms = symbols(a, doc, uri) catch return empty(a);

    var arr = std.json.Array.init(a);
    for (syms) |s| try arr.append(try toValue(a, s));
    return .{ .array = arr };
}

fn empty(a: Allocator) !Value {
    return .{ .array = std.json.Array.init(a) };
}

/// Build the outline for `doc`. `a` must be an arena-style allocator: the
/// returned tree owns all of its strings, so the parsed forest can be freed
/// before the caller serializes.
pub fn symbols(a: Allocator, doc: *const Document, uri: []const u8) ![]DocumentSymbol {
    var forest = try yaml.parse(a, doc.bytes());
    defer forest.deinit();

    var out = std.array_list.Managed(DocumentSymbol).init(a);
    for (forest.roots) |root| try walkRoot(a, doc, root, uri, &out);
    return out.toOwnedSlice();
}

fn walkRoot(
    a: Allocator,
    doc: *const Document,
    root: *const Node,
    uri: []const u8,
    out: *std.array_list.Managed(DocumentSymbol),
) Allocator.Error!void {
    if (root.isMap()) return walkMap(a, doc, root, out);
    switch (plays.shape(root)) {
        .playbook => try walkPlaybook(a, doc, root, out),
        .task_list => try collectTasks(a, doc, root, if (isHandlersDir(uri)) .event else .object, out),
        .other => {},
    }
}

fn walkPlaybook(
    a: Allocator,
    doc: *const Document,
    seq: *const Node,
    out: *std.array_list.Managed(DocumentSymbol),
) Allocator.Error!void {
    var n: usize = 0;
    for (seq.items) |item| {
        n += 1;
        if (!item.isMap()) continue;
        var children = std.array_list.Managed(DocumentSymbol).init(a);
        try collectPlayChildren(a, doc, item, &children);
        const sel = playSelection(item) orelse item;
        try out.append(.{
            .name = try playName(a, item, n),
            .detail = try playDetail(a, item),
            .kind = .module,
            .range = rangeOf(doc, item),
            .selectionRange = rangeOf(doc, sel),
            .children = try ownedChildren(&children),
        });
    }
}

fn collectPlayChildren(
    a: Allocator,
    doc: *const Document,
    play: *const Node,
    out: *std.array_list.Managed(DocumentSymbol),
) Allocator.Error!void {
    var lists = plays.taskLists(play, plays.classify(play, .{}));
    var next = lists.next();
    for (play.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        const val = pair.val orelse continue;
        if (std.mem.eql(u8, name, "roles") and val.isSeq()) {
            try collectRoleInvocations(a, doc, val, out);
        } else if (next) |list| {
            if (val != list.seq) continue;
            try collectTasks(a, doc, list.seq, if (list.handler) .event else .object, out);
            next = lists.next();
        }
    }
}

fn collectTasks(
    a: Allocator,
    doc: *const Document,
    seq: *const Node,
    kind: SymbolKind,
    out: *std.array_list.Managed(DocumentSymbol),
) Allocator.Error!void {
    var n: usize = 0;
    for (seq.items) |item| {
        n += 1;
        if (!item.isMap()) continue;
        if (plays.classify(item, .{}).kind == .block) {
            try out.append(try blockSymbol(a, doc, item, n));
        } else {
            try out.append(try taskSymbol(a, doc, item, kind, n));
        }
    }
}

fn blockSymbol(a: Allocator, doc: *const Document, map: *const Node, n: usize) Allocator.Error!DocumentSymbol {
    var children = std.array_list.Managed(DocumentSymbol).init(a);
    var lists = plays.taskLists(map, plays.classify(map, .{}));
    while (lists.next()) |list| {
        // Preserve the outline's current Block-child labels until D3.
        try collectTasks(a, doc, list.seq, .object, &children);
    }
    const name = if (pairValue(map, "name")) |v| v.stringValue() orelse "" else "";
    const final = if (name.len > 0)
        try dup(a, name)
    else
        try std.fmt.allocPrint(a, "Block {d}", .{n});
    const sel = pairValue(map, "name") orelse pairKey(map, "block") orelse map;
    return .{
        .name = final,
        .kind = .array,
        .range = rangeOf(doc, map),
        .selectionRange = rangeOf(doc, sel),
        .children = try ownedChildren(&children),
    };
}

fn taskSymbol(
    a: Allocator,
    doc: *const Document,
    map: *const Node,
    kind: SymbolKind,
    n: usize,
) Allocator.Error!DocumentSymbol {
    const name_node = pairValue(map, "name");
    const ref = plays.module(map);
    const mod = if (ref) |m| if (m.is_key) m.node else null else null;
    const name = if (name_node) |v| v.stringValue() orelse "" else "";
    const mod_name = if (mod) |k| k.stringValue() orelse "" else "";
    const final = if (name.len > 0)
        try dup(a, name)
    else if (mod_name.len > 0)
        try dup(a, mod_name)
    else
        try std.fmt.allocPrint(a, "{s} {d}", .{ if (kind == .event) "Handler" else "Task", n });
    const sel = name_node orelse mod orelse map;
    // Only show the module as detail when it is not already the name.
    const detail: ?[]const u8 = if (mod_name.len > 0 and !std.mem.eql(u8, mod_name, final))
        try dup(a, mod_name)
    else
        null;
    return .{
        .name = final,
        .detail = detail,
        .kind = kind,
        .range = rangeOf(doc, map),
        .selectionRange = rangeOf(doc, sel),
    };
}

fn collectRoleInvocations(
    a: Allocator,
    doc: *const Document,
    seq: *const Node,
    out: *std.array_list.Managed(DocumentSymbol),
) Allocator.Error!void {
    var n: usize = 0;
    for (seq.items) |item| {
        n += 1;
        if (item.isScalar()) {
            const name = item.stringValue() orelse continue;
            if (name.len == 0) continue;
            try out.append(.{
                .name = try dup(a, name),
                .kind = .class,
                .range = rangeOf(doc, item),
                .selectionRange = rangeOf(doc, item),
            });
        } else if (item.isMap()) {
            const role_node = pairValue(item, "role");
            const name = if (role_node) |v| v.stringValue() orelse "" else "";
            const final = if (name.len > 0)
                try dup(a, name)
            else
                try std.fmt.allocPrint(a, "Role {d}", .{n});
            const sel = role_node orelse item;
            try out.append(.{
                .name = final,
                .kind = .class,
                .range = rangeOf(doc, item),
                .selectionRange = rangeOf(doc, sel),
            });
        }
    }
}

fn walkMap(
    a: Allocator,
    doc: *const Document,
    map: *const Node,
    out: *std.array_list.Managed(DocumentSymbol),
) Allocator.Error!void {
    for (map.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        try out.append(try mapSymbol(a, doc, pair, name, .variable));
    }
}

fn mapSymbol(
    a: Allocator,
    doc: *const Document,
    pair: *const Node,
    name: []const u8,
    kind: SymbolKind,
) Allocator.Error!DocumentSymbol {
    var children = std.array_list.Managed(DocumentSymbol).init(a);
    if (pair.val) |v| {
        if (v.isMap()) {
            for (v.items) |child| {
                const ck = child.key orelse continue;
                const cn = ck.stringValue() orelse continue;
                try children.append(try mapSymbol(a, doc, child, cn, .field));
            }
        }
    }
    return .{
        .name = try dup(a, name),
        .kind = kind,
        .range = rangeOf(doc, pair),
        .selectionRange = rangeOf(doc, pair.key.?),
        .children = try ownedChildren(&children),
    };
}

fn playName(a: Allocator, map: *const Node, n: usize) Allocator.Error![]const u8 {
    inline for (.{ "name", "hosts", "import_playbook" }) |key| {
        if (pairValue(map, key)) |v| {
            if (v.stringValue()) |s| {
                if (s.len > 0) return dup(a, s);
            }
        }
    }
    return std.fmt.allocPrint(a, "Play {d}", .{n});
}

fn playDetail(a: Allocator, map: *const Node) Allocator.Error!?[]const u8 {
    if (pairValue(map, "hosts")) |v| {
        if (v.stringValue()) |s| return try dup(a, s);
    }
    return null;
}

fn playSelection(map: *const Node) ?*Node {
    inline for (.{ "name", "hosts", "import_playbook" }) |key| {
        if (pairValue(map, key)) |v| return v;
    }
    return null;
}

fn pairValue(map: *const Node, name: []const u8) ?*Node {
    const pair = dom.findPair(map, name) orelse return null;
    return pair.val;
}

fn pairKey(map: *const Node, name: []const u8) ?*Node {
    const pair = dom.findPair(map, name) orelse return null;
    return pair.key;
}

fn rangeOf(doc: *const Document, node: *const Node) lsp.Range {
    return doc.rangeFromOffsets(node.start, node.end);
}

fn dup(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return a.dupe(u8, s);
}

fn ownedChildren(list: *std.array_list.Managed(DocumentSymbol)) Allocator.Error!?[]const DocumentSymbol {
    if (list.items.len == 0) return null;
    return try list.toOwnedSlice();
}

fn isHandlersDir(uri: []const u8) bool {
    var path = uri;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    const dir = std.fs.path.dirname(path) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(dir), "handlers");
}

fn toValue(a: Allocator, sym: DocumentSymbol) Allocator.Error!Value {
    var o = json_util.obj(a);
    try o.put("name", json_util.str(sym.name));
    if (sym.detail) |d| try o.put("detail", json_util.str(d));
    try o.put("kind", json_util.num(@intFromEnum(sym.kind)));
    try o.put("range", try rangeValue(a, sym.range));
    try o.put("selectionRange", try rangeValue(a, sym.selectionRange));
    if (sym.children) |kids| {
        var arr = std.json.Array.init(a);
        for (kids) |k| try arr.append(try toValue(a, k));
        try o.put("children", .{ .array = arr });
    }
    return .{ .object = o };
}

fn rangeValue(a: Allocator, r: lsp.Range) Allocator.Error!Value {
    var o = json_util.obj(a);
    try o.put("start", try positionValue(a, r.start));
    try o.put("end", try positionValue(a, r.end));
    return .{ .object = o };
}

fn positionValue(a: Allocator, p: lsp.Position) Allocator.Error!Value {
    var o = json_util.obj(a);
    try o.put("line", json_util.num(p.line));
    try o.put("character", json_util.num(p.character));
    return .{ .object = o };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn outline(a: Allocator, src: []const u8, uri: []const u8) ![]DocumentSymbol {
    var doc = try Document.init(a, uri, "ansible", 1, src, .utf16);
    return symbols(a, &doc, uri);
}

test "playbook outline: play, roles, tasks, handlers, block" {
    const src =
        \\- name: Demo play
        \\  hosts: all
        \\  roles:
        \\    - role: demo
        \\      app_port: 7070
        \\  tasks:
        \\    - name: Install
        \\      ansible.builtin.package:
        \\        name: nginx
        \\    - block:
        \\        - name: Nested
        \\          ansible.builtin.debug:
        \\      rescue:
        \\        - name: Recover
        \\          ansible.builtin.debug:
        \\  handlers:
        \\    - name: Restart
        \\      ansible.builtin.service:
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///play.yml");

    try testing.expectEqual(@as(usize, 1), syms.len);
    const play = syms[0];
    try testing.expectEqualStrings("Demo play", play.name);
    try testing.expectEqualStrings("all", play.detail.?);
    try testing.expectEqual(SymbolKind.module, play.kind);

    const kids = play.children.?;
    try testing.expectEqual(@as(usize, 4), kids.len);

    try testing.expectEqualStrings("demo", kids[0].name);
    try testing.expectEqual(SymbolKind.class, kids[0].kind);

    try testing.expectEqualStrings("Install", kids[1].name);
    try testing.expectEqualStrings("ansible.builtin.package", kids[1].detail.?);
    try testing.expectEqual(SymbolKind.object, kids[1].kind);

    try testing.expectEqualStrings("Block 2", kids[2].name);
    try testing.expectEqual(SymbolKind.array, kids[2].kind);
    try testing.expectEqual(@as(usize, 2), kids[2].children.?.len);
    try testing.expectEqualStrings("Nested", kids[2].children.?[0].name);
    try testing.expectEqualStrings("Recover", kids[2].children.?[1].name);

    try testing.expectEqualStrings("Restart", kids[3].name);
    try testing.expectEqual(SymbolKind.event, kids[3].kind);
}

test "task file: module-key fallback and no play" {
    const src =
        \\- ansible.builtin.package:
        \\    name: nginx
        \\- name: Named
        \\  ansible.builtin.debug:
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///roles/demo/tasks/main.yml");

    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("ansible.builtin.package", syms[0].name);
    try testing.expect(syms[0].detail == null);
    try testing.expectEqual(SymbolKind.object, syms[0].kind);
    try testing.expectEqualStrings("Named", syms[1].name);
    try testing.expectEqualStrings("ansible.builtin.debug", syms[1].detail.?);
}

test "handlers file labels tasks as handlers" {
    const src =
        \\- ansible.builtin.service:
        \\    name: nginx
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///roles/demo/handlers/main.yml");

    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("ansible.builtin.service", syms[0].name);
    try testing.expectEqual(SymbolKind.event, syms[0].kind);
}

test "vars file: nested maps become fields" {
    const src =
        \\app:
        \\  port: 8080
        \\  name: demo
        \\plain: 1
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///roles/demo/vars/main.yml");

    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("app", syms[0].name);
    try testing.expectEqual(SymbolKind.variable, syms[0].kind);
    try testing.expectEqual(@as(usize, 2), syms[0].children.?.len);
    try testing.expectEqualStrings("port", syms[0].children.?[0].name);
    try testing.expectEqual(SymbolKind.field, syms[0].children.?[0].kind);
    try testing.expectEqualStrings("plain", syms[1].name);
    try testing.expect(syms[1].children == null);
}

test "meta file uses the generic map model" {
    const src =
        \\galaxy_info:
        \\  author: zals
        \\argument_specs:
        \\  main:
        \\    options:
        \\      app_name:
        \\        type: str
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///roles/demo/meta/main.yml");

    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("galaxy_info", syms[0].name);
    try testing.expectEqualStrings("argument_specs", syms[1].name);
    const main = syms[1].children.?[0];
    try testing.expectEqualStrings("main", main.name);
    const options = main.children.?[0];
    try testing.expectEqualStrings("options", options.name);
    try testing.expectEqualStrings("app_name", options.children.?[0].name);
}

test "unclassifiable sequence yields no symbols" {
    const src =
        \\- one
        \\- two
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///list.yml");
    try testing.expectEqual(@as(usize, 0), syms.len);
}

test "import_playbook is a play-level entry" {
    const src =
        \\- import_playbook: other.yml
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///site.yml");
    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("other.yml", syms[0].name);
    try testing.expectEqual(SymbolKind.module, syms[0].kind);
}

test "selectionRange is contained by range" {
    const src =
        \\- name: Demo play
        \\  hosts: all
        \\  tasks:
        \\    - name: Install
        \\      ansible.builtin.package:
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try outline(a, src, "file:///play.yml");
    const play = syms[0];
    try testing.expect(play.range.start.line <= play.selectionRange.start.line);
    try testing.expect(play.range.end.line >= play.selectionRange.end.line);
    const task = play.children.?[0];
    try testing.expect(task.range.start.line <= task.selectionRange.start.line);
    try testing.expect(task.range.end.line >= task.selectionRange.end.line);
}

test "fixture playbook outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const uri = "file://test/fixtures/playbook.yml";
    const bytes = try std.fs.cwd().readFileAlloc(a, "test/fixtures/playbook.yml", 1 << 20);
    const syms = try outline(a, bytes, uri);

    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("Demo play", syms[0].name);
    try testing.expectEqualStrings("all", syms[0].detail.?);

    const kids = syms[0].children.?;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqualStrings("demo", kids[0].name);
    try testing.expectEqual(SymbolKind.class, kids[0].kind);
    try testing.expectEqualStrings("Use play and role vars", kids[1].name);
    try testing.expectEqualStrings("ansible.builtin.debug", kids[1].detail.?);
}

test "fixture role files outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tasks_uri = "file://test/fixtures/roles/demo/tasks/main.yml";
    const tasks_bytes = try std.fs.cwd().readFileAlloc(a, "test/fixtures/roles/demo/tasks/main.yml", 1 << 20);
    const tasks = try outline(a, tasks_bytes, tasks_uri);
    try testing.expectEqual(@as(usize, 4), tasks.len);
    try testing.expectEqualStrings("Show the app", tasks[0].name);
    try testing.expectEqualStrings("Register a fact", tasks[1].name);
    try testing.expectEqualStrings("Use the fact", tasks[2].name);
    try testing.expectEqualStrings("Loop with a custom var", tasks[3].name);

    const vars_uri = "file://test/fixtures/roles/demo/vars/main.yml";
    const vars_bytes = try std.fs.cwd().readFileAlloc(a, "test/fixtures/roles/demo/vars/main.yml", 1 << 20);
    const vars = try outline(a, vars_bytes, vars_uri);
    try testing.expectEqual(@as(usize, 2), vars.len);
    try testing.expectEqualStrings("app_port", vars[0].name);
    try testing.expectEqual(SymbolKind.variable, vars[0].kind);

    const meta_uri = "file://test/fixtures/roles/demo/meta/main.yml";
    const meta_bytes = try std.fs.cwd().readFileAlloc(a, "test/fixtures/roles/demo/meta/main.yml", 1 << 20);
    const meta = try outline(a, meta_bytes, meta_uri);
    try testing.expectEqual(@as(usize, 2), meta.len);
    try testing.expectEqualStrings("galaxy_info", meta[0].name);
    try testing.expectEqualStrings("argument_specs", meta[1].name);
}
