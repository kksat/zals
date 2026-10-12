//! tree-sitter-yaml backend for the `YamlParser` seam (ADR-0004).
//!
//! Parses with the vendored tree-sitter runtime + tree-sitter-yaml grammar and
//! lowers the concrete syntax tree into the same `dom.Node` shape produced by
//! the indent-based subset parser, so every consumer is backend-agnostic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_yaml() *const c.TSLanguage;

pub fn parse(allocator: Allocator, text: []const u8) !dom.Forest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parser = c.ts_parser_new() orelse return error.ParserInit;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, tree_sitter_yaml())) return error.LanguageMismatch;
    const tree = c.ts_parser_parse_string(parser, null, text.ptr, @intCast(text.len)) orelse
        return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    const root = c.ts_tree_root_node(tree);
    // tree-sitter is error-tolerant, but an error tree can lose the document
    // structure entirely. Fall back to the subset parser in that case.
    if (c.ts_node_has_error(root)) return error.ParseError;
    var roots = std.ArrayList(*Node).empty;
    var document_starts = std.ArrayList(usize).empty;
    const n = c.ts_node_named_child_count(root);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const child = c.ts_node_named_child(root, i);
        if (isType(child, "document")) {
            if (try convert(a, text, child)) |node| {
                try roots.append(a, node);
                // The document range includes markers/directives that its
                // lowered content root does not necessarily contain.
                try document_starts.append(a, start(child));
            }
        }
    }

    return .{
        .arena = arena,
        .text = text,
        .roots = try roots.toOwnedSlice(a),
        .document_starts = try document_starts.toOwnedSlice(a),
    };
}

fn typeName(node: c.TSNode) []const u8 {
    return std.mem.span(c.ts_node_type(node));
}

fn isType(node: c.TSNode, name: []const u8) bool {
    return std.mem.eql(u8, typeName(node), name);
}

fn start(node: c.TSNode) usize {
    return c.ts_node_start_byte(node);
}

fn end(node: c.TSNode) usize {
    return c.ts_node_end_byte(node);
}

fn isMeta(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "comment") or
        std.mem.eql(u8, ty, "anchor") or
        std.mem.eql(u8, ty, "tag");
}

/// Convert the first content child of a wrapper node (`document`, `block_node`,
/// `flow_node`, `block_sequence_item`).
fn convertChild(a: Allocator, text: []const u8, node: c.TSNode) !?*Node {
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        if (isMeta(typeName(ch))) continue;
        if (try convert(a, text, ch)) |out| return out;
    }
    // Empty document / null value: an empty scalar spanning the node.
    const out = try a.create(Node);
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = "" };
    return out;
}

fn convert(a: Allocator, text: []const u8, node: c.TSNode) anyerror!?*Node {
    const ty = typeName(node);
    if (std.mem.eql(u8, ty, "document") or
        std.mem.eql(u8, ty, "block_node") or
        std.mem.eql(u8, ty, "flow_node") or
        std.mem.eql(u8, ty, "block_sequence_item"))
        return convertChild(a, text, node);
    if (std.mem.eql(u8, ty, "block_mapping") or std.mem.eql(u8, ty, "flow_mapping"))
        return convertMap(a, text, node);
    if (std.mem.eql(u8, ty, "block_sequence") or std.mem.eql(u8, ty, "flow_sequence"))
        return convertSeq(a, text, node);
    if (std.mem.eql(u8, ty, "block_mapping_pair") or std.mem.eql(u8, ty, "flow_pair"))
        return convertPair(a, text, node);
    if (std.mem.eql(u8, ty, "plain_scalar")) return convertPlain(a, text, node);
    if (std.mem.eql(u8, ty, "single_quote_scalar")) return convertSingle(a, text, node);
    if (std.mem.eql(u8, ty, "double_quote_scalar")) return convertDouble(a, text, node);
    if (std.mem.eql(u8, ty, "block_scalar")) return convertBlockScalar(a, text, node);
    if (std.mem.eql(u8, ty, "alias")) return convertAlias(a, text, node);
    return null;
}

fn convertMap(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const out = try a.create(Node);
    out.* = .{ .kind = .map, .start = start(node), .end = end(node) };
    var items = std.ArrayList(*Node).empty;
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "block_mapping_pair") or std.mem.eql(u8, ty, "flow_pair")) {
            try items.append(a, try convertPair(a, text, ch));
        } else if (std.mem.eql(u8, ty, "flow_node") or std.mem.eql(u8, ty, "block_node")) {
            // Flow mapping bare key with no value.
            if (try convert(a, text, ch)) |k| {
                const p = try a.create(Node);
                p.* = .{ .kind = .pair, .start = k.start, .end = k.end, .key = k };
                k.parent = p;
                try items.append(a, p);
            }
        }
    }
    out.items = try items.toOwnedSlice(a);
    for (out.items) |it| it.parent = out;
    return out;
}

fn convertSeq(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const out = try a.create(Node);
    out.* = .{ .kind = .seq, .start = start(node), .end = end(node) };
    var items = std.ArrayList(*Node).empty;
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "block_sequence_item")) {
            if (try convertChild(a, text, ch)) |it| try items.append(a, it);
        } else if (std.mem.eql(u8, ty, "flow_node") or std.mem.eql(u8, ty, "block_node")) {
            if (try convert(a, text, ch)) |it| try items.append(a, it);
        }
    }
    out.items = try items.toOwnedSlice(a);
    for (out.items) |it| it.parent = out;
    return out;
}

fn convertPair(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const out = try a.create(Node);
    out.* = .{ .kind = .pair, .start = start(node), .end = end(node) };
    const key_ts = c.ts_node_child_by_field_name(node, "key", 3);
    const val_ts = c.ts_node_child_by_field_name(node, "value", 5);
    if (!c.ts_node_is_null(key_ts)) {
        out.key = try convert(a, text, key_ts);
        if (out.key) |k| k.parent = out;
    }
    if (!c.ts_node_is_null(val_ts)) {
        out.val = try convert(a, text, val_ts);
        if (out.val) |v| v.parent = out;
    }
    return out;
}

fn convertPlain(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const out = try a.create(Node);
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node) };
    var raw = text[start(node)..end(node)];
    if (c.ts_node_named_child_count(node) > 0) {
        const ch = c.ts_node_named_child(node, 0);
        raw = text[start(ch)..end(ch)];
    }
    out.value = std.mem.trim(u8, raw, " \t\r\n");
    return out;
}

fn convertSingle(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const raw = text[start(node)..end(node)];
    var inner = raw;
    if (inner.len >= 2 and inner[0] == '\'' and inner[inner.len - 1] == '\'')
        inner = inner[1 .. inner.len - 1];
    const buf = try a.alloc(u8, inner.len);
    var j: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
            buf[j] = '\'';
            j += 1;
            i += 1;
        } else {
            buf[j] = inner[i];
            j += 1;
        }
    }
    const out = try a.create(Node);
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = buf[0..j] };
    return out;
}

fn convertDouble(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const raw = text[start(node)..end(node)];
    var inner = raw;
    if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"')
        inner = inner[1 .. inner.len - 1];
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] != '\\' or i + 1 >= inner.len) {
            try buf.append(a, inner[i]);
            continue;
        }
        i += 1;
        const esc = inner[i];
        switch (esc) {
            'n' => try buf.append(a, '\n'),
            't' => try buf.append(a, '\t'),
            'r' => try buf.append(a, '\r'),
            '0' => try buf.append(a, 0),
            'b' => try buf.append(a, 8),
            'f' => try buf.append(a, 12),
            '"' => try buf.append(a, '"'),
            '\\' => try buf.append(a, '\\'),
            '/' => try buf.append(a, '/'),
            'u' => {
                if (i + 4 < inner.len) {
                    const cp = std.fmt.parseInt(u21, inner[i + 1 .. i + 5], 16) catch 0;
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8) catch 0;
                    try buf.appendSlice(a, utf8[0..len]);
                    i += 4;
                }
            },
            else => try buf.append(a, esc),
        }
    }
    const out = try a.create(Node);
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = try buf.toOwnedSlice(a) };
    return out;
}

fn convertBlockScalar(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const raw = text[start(node)..end(node)];
    var nl: usize = 0;
    while (nl < raw.len and raw[nl] != '\n') : (nl += 1) {}
    const header = raw[0..nl];
    const body = if (nl < raw.len) raw[nl + 1 ..] else "";
    const folded = header.len > 0 and header[0] == '>';
    const strip = std.mem.indexOfScalar(u8, header, '-') != null;
    const keep = std.mem.indexOfScalar(u8, header, '+') != null;

    // Determine common indentation of non-empty lines.
    var min_indent: usize = std.math.maxInt(usize);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var ind: usize = 0;
        while (ind < line.len and line[ind] == ' ') : (ind += 1) {}
        if (ind < line.len) min_indent = @min(min_indent, ind);
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    var lines = std.ArrayList([]const u8).empty;
    var it2 = std.mem.splitScalar(u8, body, '\n');
    while (it2.next()) |line| {
        const stripped = if (line.len >= min_indent) line[min_indent..] else "";
        try lines.append(a, stripped);
    }
    // Drop trailing empty lines produced by the final newline.
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0)
        _ = lines.pop();

    var buf = std.ArrayList(u8).empty;
    for (lines.items, 0..) |line, idx| {
        if (idx > 0) try buf.append(a, if (folded) ' ' else '\n');
        try buf.appendSlice(a, line);
    }
    if (!strip) try buf.append(a, '\n');
    if (keep) try buf.append(a, '\n');

    const out = try a.create(Node);
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = try buf.toOwnedSlice(a) };
    return out;
}

fn convertAlias(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    var value: []const u8 = text[start(node)..end(node)];
    if (c.ts_node_named_child_count(node) > 0) {
        const ch = c.ts_node_named_child(node, 0);
        value = text[start(ch)..end(ch)];
    } else if (value.len > 0 and value[0] == '*') {
        value = value[1..];
    }
    const out = try a.create(Node);
    out.* = .{ .kind = .alias, .start = start(node), .end = end(node), .value = value };
    return out;
}

test "tree-sitter parses a playbook" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: ping
        \\      ansible.builtin.ping:
        \\        data: "hello"
        \\
    ;
    var forest = try parse(std.testing.allocator, src);
    defer forest.deinit();
    try std.testing.expectEqual(@as(usize, 1), forest.roots.len);
    const root = forest.roots[0];
    try std.testing.expect(root.isSeq());
    try std.testing.expectEqual(@as(usize, 1), root.items.len);
    const play = root.items[0];
    try std.testing.expect(play.isMap());
    try std.testing.expectEqualStrings("hosts", play.items[0].key.?.value.?);
    try std.testing.expectEqualStrings("all", play.items[0].val.?.value.?);
}

fn checkAcyclic(node: *const Node, depth: usize) !void {
    if (depth > 200) return error.Cycle;
    switch (node.kind) {
        .map, .seq => for (node.items) |it| try checkAcyclic(it, depth + 1),
        .pair => {
            if (node.key) |k| try checkAcyclic(k, depth + 1);
            if (node.val) |v| try checkAcyclic(v, depth + 1);
        },
        else => {},
    }
}

test "tree-sitter DOM is acyclic" {
    const src =
        \\---
        \\- hosts: all
        \\  become: true
        \\  tasks:
        \\    - name: ping
        \\      ansible.builtin.ping:
        \\    - name: install
        \\      ansible.builtin.package:
        \\        name: nginx
        \\        state: present
        \\
    ;
    var forest = try parse(std.testing.allocator, src);
    defer forest.deinit();
    for (forest.roots) |root| try checkAcyclic(root, 0);
}

fn expectSameNode(a: *const Node, b: *const Node) !void {
    try std.testing.expectEqual(a.kind, b.kind);
    if (a.value) |v| try std.testing.expectEqualStrings(v, b.value.?);
    if (a.key) |k| try expectSameNode(k, b.key.?);
    if (a.val) |v| try expectSameNode(v, b.val.?);
    try std.testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| try expectSameNode(x, y);
}

test "tree-sitter and subset backends agree on block YAML" {
    const corpus = [_][]const u8{
        "- hosts: all\n  tasks:\n    - name: ping\n      ansible.builtin.ping:\n",
        "key: value\nlist:\n  - a\n  - b\nnested:\n  x: 1\n  y: 2\n",
        "a: 'single'\nb: \"double\"\nc: 42\nd: true\n",
        "- name: multi\n  vars:\n    msg: |\n      line one\n      line two\n",
    };
    for (corpus) |src| {
        var ts = try parse(std.testing.allocator, src);
        defer ts.deinit();
        var sub = try @import("parser.zig").parse(std.testing.allocator, src);
        defer sub.deinit();
        try std.testing.expectEqual(ts.roots.len, sub.roots.len);
        for (ts.roots, sub.roots) |x, y| try expectSameNode(x, y);
    }
}
