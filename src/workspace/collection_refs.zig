//! Collection references (ADR-0032, `GLOSSARY.md`).
//!
//! Sites: a `collections:` entry (play, block, task, role metadata,
//! `requirements.yml`, inline execution-environment requirements); a
//! `galaxy.yml` `dependencies:` key; and the collection part of an FQCN in a
//! module key, role reference, runtime `redirect:`, or `action_groups` entry.
//! A requirements entry that names a git, url, file, or dir source is not one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const Node = yaml.Node;
const role_reference = @import("../roles/reference.zig");

pub const Span = struct {
    /// `namespace.collection`.
    name: []const u8,
    start: usize,
    end: usize,
};

pub fn collect(a: Allocator, forest: *const yaml.Forest, path: []const u8) ![]Span {
    var out = std.array_list.Managed(Span).init(a);
    var path_stack = std.array_list.Managed(*Node).init(a);
    defer path_stack.deinit();
    var ctx = Ctx{ .a = a, .text = forest.text, .out = &out, .path = &path_stack };
    const base = std.fs.path.basename(path);
    const is_galaxy = std.mem.eql(u8, base, "galaxy.yml") or std.mem.eql(u8, base, "galaxy.yaml");
    for (forest.roots) |r| {
        if (is_galaxy and r.isMap()) {
            if (yaml.dom.findPair(r, "dependencies")) |p| {
                if (p.val) |deps| if (deps.isMap()) for (deps.items) |dep| {
                    if (dep.key) |k| try ctx.addWhole(k);
                };
            }
        }
        try ctx.walk(r, false);
    }
    std.mem.sort(Span, out.items, {}, lessStart);
    return out.toOwnedSlice();
}

/// Whether `name` is a well-formed `namespace.collection`.
pub fn isCollectionName(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return false;
    return isIdent(name[0..dot]) and isIdent(name[dot + 1 ..]);
}

/// The `namespace.collection` prefix of an FQCN with at least three
/// segments, or null.
pub fn fqcnPrefix(name: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, name, first + 1, '.') orelse return null;
    if (second + 1 >= name.len) return null;
    const prefix = name[0..second];
    if (!isCollectionName(prefix)) return null;
    for (name[second + 1 ..]) |c| if (!(isIdentChar(c) or c == '.')) return null;
    return prefix;
}

const Ctx = struct {
    a: Allocator,
    text: []const u8,
    out: *std.array_list.Managed(Span),
    path: *std.array_list.Managed(*Node),

    /// `in_task_list`: `node` is an item of a sequence, so its keys may be
    /// module keys.
    fn walk(self: *Ctx, node: *Node, in_task_list: bool) !void {
        try self.path.append(node);
        defer _ = self.path.pop();
        switch (node.kind) {
            .map => for (node.items) |pair| {
                const key_node = pair.key orelse continue;
                const key = key_node.stringValue() orelse "";
                if (in_task_list and fqcnPrefix(key) != null and !yaml.keywords.isTaskKeyword(key)) {
                    try self.addPrefix(key_node, key);
                }
                const val = pair.val orelse continue;
                if (std.mem.eql(u8, key, "collections") and val.isSeq()) {
                    for (val.items) |item| try self.entry(item);
                } else if (std.mem.eql(u8, key, "redirect") and val.isScalar()) {
                    if (val.stringValue()) |s| if (fqcnPrefix(s) != null) try self.addPrefix(val, s);
                } else if (std.mem.eql(u8, key, "action_groups") and val.isMap()) {
                    for (val.items) |group| {
                        const members = group.val orelse continue;
                        if (!members.isSeq()) continue;
                        for (members.items) |m| {
                            if (m.stringValue()) |s| if (fqcnPrefix(s) != null) try self.addPrefix(m, s);
                        }
                    }
                }
                try self.path.append(pair);
                defer _ = self.path.pop();
                try self.walk(val, false);
            },
            .seq => for (node.items) |item| {
                try self.walk(item, true);
            },
            .pair => {},
            .scalar => try self.roleFqcn(),
            else => {},
        }
    }

    /// A role reference that is an FQCN contributes its collection prefix.
    fn roleFqcn(self: *Ctx) !void {
        const ref = role_reference.detect(self.path.items, self.text) orelse return;
        const prefix = fqcnPrefix(ref.name) orelse return;
        try self.append(prefix, ref.start);
    }

    /// A `collections:` entry: a string, or a map with `name:`.
    fn entry(self: *Ctx, item: *Node) !void {
        if (item.isScalar()) return self.addWhole(item);
        if (!item.isMap()) return;
        if (yaml.dom.findPair(item, "type")) |t| {
            if (t.val) |v| if (v.stringValue()) |kind| {
                if (!std.mem.eql(u8, kind, "galaxy")) return;
            };
        }
        const p = yaml.dom.findPair(item, "name") orelse return;
        if (p.val) |v| try self.addWhole(v);
    }

    fn addWhole(self: *Ctx, node: *Node) !void {
        const s = node.stringValue() orelse return;
        if (!isCollectionName(s)) return;
        const raw = if (node.end <= self.text.len and node.start <= node.end) self.text[node.start..node.end] else return;
        const off = std.mem.indexOf(u8, raw, s) orelse return;
        try self.append(s, node.start + off);
    }

    fn addPrefix(self: *Ctx, node: *Node, full: []const u8) !void {
        const prefix = fqcnPrefix(full) orelse return;
        const raw = if (node.end <= self.text.len and node.start <= node.end) self.text[node.start..node.end] else return;
        const off = std.mem.indexOf(u8, raw, full) orelse return;
        try self.append(prefix, node.start + off);
    }

    fn append(self: *Ctx, name: []const u8, start: usize) !void {
        for (self.out.items) |existing| if (existing.start == start) return;
        try self.out.append(.{ .name = try self.a.dupe(u8, name), .start = start, .end = start + name.len });
    }
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!isIdentChar(c)) return false;
    return true;
}

fn lessStart(_: void, x: Span, y: Span) bool {
    return x.start < y.start;
}

const testing = std.testing;

fn names(a: Allocator, text: []const u8, path: []const u8) ![]const []const u8 {
    var forest = try yaml.parse(a, text);
    defer forest.deinit();
    const spans = try collect(a, &forest, path);
    const out = try a.alloc([]const u8, spans.len);
    for (spans, 0..) |s, i| {
        try testing.expectEqualStrings(s.name, text[s.start..s.end]);
        out[i] = s.name;
    }
    return out;
}

test "play collections, module FQCN, and role FQCN" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\- hosts: all
        \\  collections:
        \\    - community.general
        \\  roles:
        \\    - acme.web.nginx
        \\  tasks:
        \\    - community.general.slack:
        \\        msg: hi
        \\    - sysctl:
        \\        name: net.ipv4.ip_forward
        \\
    ;
    const got = try names(a, text, "/w/site.yml");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("community.general", got[0]);
    try testing.expectEqualStrings("acme.web", got[1]);
    try testing.expectEqualStrings("community.general", got[2]);
}

test "requirements entries skip non-galaxy sources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\collections:
        \\  - community.general
        \\  - name: ansible.posix
        \\    version: ">=1.0"
        \\  - name: https://github.com/x/y.git
        \\    type: git
        \\
    ;
    const got = try names(a, text, "/w/requirements.yml");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("ansible.posix", got[1]);
}

test "galaxy dependencies and runtime redirects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const galaxy = "namespace: acme\nname: web\ndependencies:\n  community.general: '>=8.0.0'\n";
    const g = try names(a, galaxy, "/w/galaxy.yml");
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqualStrings("community.general", g[0]);

    const runtime =
        \\plugin_routing:
        \\  modules:
        \\    old:
        \\      redirect: acme.web.new
        \\action_groups:
        \\  web:
        \\    - acme.web.new
        \\
    ;
    const r = try names(a, runtime, "/w/meta/runtime.yml");
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("acme.web", r[0]);
}

test "collection name shapes" {
    try testing.expect(isCollectionName("community.general"));
    try testing.expect(!isCollectionName("community"));
    try testing.expect(!isCollectionName("a.b.c"));
    try testing.expectEqualStrings("acme.web", fqcnPrefix("acme.web.nginx").?);
    try testing.expect(fqcnPrefix("geerlingguy.nginx") == null);
}
