//! tree-sitter-yaml backend for the `YamlParser` seam (ADR-0004).
//!
//! Parses with the vendored tree-sitter runtime + tree-sitter-yaml grammar and
//! lowers the concrete syntax tree into the same `dom.Node` shape produced by
//! the indent-based subset parser, so every consumer is backend-agnostic.

const std = @import("std");
const fsio = @import("../fsio.zig");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Node = dom.Node;

const c = @import("../tree_sitter.zig");

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
            if (try convert(a, text, child, 0)) |node| {
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

/// Convert the first content child of a wrapper node (`document`, `block_node`,
/// `flow_node`, `block_sequence_item`), capturing any anchor or tag.
fn convertChild(a: Allocator, text: []const u8, node: c.TSNode, parent_col: usize) anyerror!?*Node {
    const n = c.ts_node_named_child_count(node);
    var out: ?*Node = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (isMeta(ty)) continue;
        if (out == null) out = try convert(a, text, ch, parent_col);
    }
    if (out == null) {
        const empty = try a.create(Node);
        empty.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = "" };
        out = empty;
    }
    return out;
}

fn isMeta(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "comment") or
        std.mem.eql(u8, ty, "anchor") or
        std.mem.eql(u8, ty, "tag");
}

fn columnOf(text: []const u8, byte: usize) usize {
    var i = byte;
    while (i > 0 and text[i - 1] != '\n') i -= 1;
    return byte - i;
}

fn convert(a: Allocator, text: []const u8, node: c.TSNode, parent_col: usize) anyerror!?*Node {
    const ty = typeName(node);
    if (std.mem.eql(u8, ty, "document") or
        std.mem.eql(u8, ty, "block_node") or
        std.mem.eql(u8, ty, "flow_node") or
        std.mem.eql(u8, ty, "block_sequence_item"))
        return convertChild(a, text, node, parent_col);
    if (std.mem.eql(u8, ty, "block_mapping") or std.mem.eql(u8, ty, "flow_mapping"))
        return convertMap(a, text, node);
    if (std.mem.eql(u8, ty, "block_sequence") or std.mem.eql(u8, ty, "flow_sequence"))
        return convertSeq(a, text, node);
    if (std.mem.eql(u8, ty, "block_mapping_pair") or std.mem.eql(u8, ty, "flow_pair"))
        return convertPair(a, text, node, parent_col);
    if (std.mem.eql(u8, ty, "plain_scalar")) return convertPlain(a, text, node);
    if (std.mem.eql(u8, ty, "single_quote_scalar")) return convertSingle(a, text, node);
    if (std.mem.eql(u8, ty, "double_quote_scalar")) return convertDouble(a, text, node);
    if (std.mem.eql(u8, ty, "block_scalar")) return convertBlockScalar(a, text, node, parent_col);
    if (std.mem.eql(u8, ty, "alias")) return convertAlias(a, text, node);
    return null;
}

fn convertMap(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const out = try a.create(Node);
    out.* = .{ .kind = .map, .start = start(node), .end = end(node) };
    const col = columnOf(text, start(node));
    var items = std.ArrayList(*Node).empty;
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "block_mapping_pair") or std.mem.eql(u8, ty, "flow_pair")) {
            try items.append(a, try convertPair(a, text, ch, col));
        } else if (std.mem.eql(u8, ty, "flow_node") or std.mem.eql(u8, ty, "block_node")) {
            // Flow mapping bare key with no value.
            if (try convert(a, text, ch, col)) |k| {
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
    const col = columnOf(text, start(node));
    var items = std.ArrayList(*Node).empty;
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "block_sequence_item")) {
            if (try convertChild(a, text, ch, col)) |it| try items.append(a, it);
        } else if (std.mem.eql(u8, ty, "flow_node") or std.mem.eql(u8, ty, "block_node")) {
            if (try convert(a, text, ch, col)) |it| try items.append(a, it);
        }
    }
    out.items = try items.toOwnedSlice(a);
    for (out.items) |it| it.parent = out;
    return out;
}

fn convertPair(a: Allocator, text: []const u8, node: c.TSNode, _: usize) !*Node {
    const out = try a.create(Node);
    out.* = .{ .kind = .pair, .start = start(node), .end = end(node) };
    const col = columnOf(text, start(node));
    const key_ts = c.ts_node_child_by_field_name(node, "key", 3);
    const val_ts = c.ts_node_child_by_field_name(node, "value", 5);
    if (!c.ts_node_is_null(key_ts)) {
        out.key = try convert(a, text, key_ts, col);
        if (out.key) |k| k.parent = out;
    }
    if (!c.ts_node_is_null(val_ts)) {
        out.val = try convert(a, text, val_ts, col);
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
    out.value = try foldPlain(a, raw);
    return out;
}

fn convertSingle(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const raw = text[start(node)..end(node)];
    var inner = raw;
    if (inner.len >= 2 and inner[0] == '\'' and inner[inner.len - 1] == '\'')
        inner = inner[1 .. inner.len - 1];
    inner = try foldQuoted(a, inner);
    if (std.mem.indexOf(u8, inner, "''") == null) {
        const out = try a.create(Node);
        out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = inner, .style = .quoted };
        return out;
    }
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
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = buf[0..j], .style = .quoted };
    return out;
}

fn convertDouble(a: Allocator, text: []const u8, node: c.TSNode) !*Node {
    const raw = text[start(node)..end(node)];
    var inner = raw;
    if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"')
        inner = inner[1 .. inner.len - 1];
    inner = try joinEscapedBreaks(a, inner);
    inner = try foldQuoted(a, inner);
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
        const out = try a.create(Node);
        out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = inner, .style = .quoted };
        return out;
    }
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
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = try buf.toOwnedSlice(a), .style = .quoted };
    return out;
}

fn convertBlockScalar(a: Allocator, text: []const u8, node: c.TSNode, parent_col: usize) !*Node {
    const rendered = try @import("block_scalar.zig").render(a, text, start(node), parent_col);
    const out = try a.create(Node);
    out.* = .{ .kind = .scalar, .start = start(node), .end = end(node), .value = rendered.value, .style = .block };
    return out;
}

fn foldPlain(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\n') == null) return std.mem.trim(u8, raw, " \t\r");
    var buf = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    var pending: usize = 0;
    while (it.next()) |line| {
        const stripped = std.mem.trim(u8, line, " \t\r");
        if (stripped.len == 0) {
            if (!first) pending += 1;
            continue;
        }
        if (first) {
            try buf.appendSlice(a, stripped);
            first = false;
        } else {
            if (pending > 0) {
                while (pending > 0) : (pending -= 1) try buf.append(a, '\n');
            } else {
                try buf.append(a, ' ');
            }
            try buf.appendSlice(a, stripped);
        }
    }
    return buf.toOwnedSlice(a);
}

fn foldQuoted(a: Allocator, inner: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, inner, '\n') == null) return inner;
    var buf = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, inner, '\n');
    var first = true;
    var pending: usize = 0;
    while (it.next()) |line| {
        if (first) {
            try buf.appendSlice(a, std.mem.trimEnd(u8, line, " \t\r"));
            first = false;
            continue;
        }
        const stripped = std.mem.trim(u8, line, " \t\r");
        if (stripped.len == 0) {
            pending += 1;
            continue;
        }
        if (pending > 0) {
            while (pending > 0) : (pending -= 1) try buf.append(a, '\n');
        } else {
            try buf.append(a, ' ');
        }
        try buf.appendSlice(a, stripped);
    }
    return buf.toOwnedSlice(a);
}

fn joinEscapedBreaks(a: Allocator, inner: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i + 1 < inner.len) : (i += 1) {
        if (inner[i] == '\\' and inner[i + 1] == '\n') break;
    }
    if (i + 1 >= inner.len) return inner;
    var buf = std.ArrayList(u8).empty;
    i = 0;
    while (i < inner.len) {
        if (inner[i] == '\\' and i + 1 < inner.len and inner[i + 1] == '\n') {
            i += 2;
            while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) i += 1;
            continue;
        }
        if (inner[i] == '\\' and i + 1 < inner.len) {
            try buf.append(a, inner[i]);
            try buf.append(a, inner[i + 1]);
            i += 2;
            continue;
        }
        try buf.append(a, inner[i]);
        i += 1;
    }
    return buf.toOwnedSlice(a);
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
    const tasks = dom.findPair(play, "tasks").?.val.?;
    const ping = dom.findPair(tasks.items[0], "ansible.builtin.ping").?.val.?;
    const data_val = dom.findPair(ping, "data").?.val.?.stringValue().?;
    try std.testing.expectEqualStrings("hello", data_val);
    try std.testing.expect(@intFromPtr(data_val.ptr) >= @intFromPtr(src.ptr) and
        @intFromPtr(data_val.ptr) + data_val.len <= @intFromPtr(src.ptr) + src.len);
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
    if (a.kind == .scalar) try std.testing.expectEqual(a.style, b.style);
    if (a.key) |k| try expectSameNode(k, b.key.?);
    if (a.val) |v| try expectSameNode(v, b.val.?);
    try std.testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| try expectSameNode(x, y);
}

fn expectSameNodeWithRanges(a: *const Node, b: *const Node) !void {
    try expectSameNode(a, b);
    try std.testing.expectEqual(a.start, b.start);
    try std.testing.expectEqual(a.end, b.end);
    if (a.key) |k| try expectSameNodeWithRanges(k, b.key.?);
    if (a.val) |v| try expectSameNodeWithRanges(v, b.val.?);
    for (a.items, b.items) |x, y| try expectSameNodeWithRanges(x, y);
}

test "tree-sitter and subset backends agree on block YAML" {
    const corpus = [_][]const u8{
        "- hosts: all\n  tasks:\n    - name: ping\n      ansible.builtin.ping:\n",
        "key: value\nlist:\n  - a\n  - b\nnested:\n  x: 1\n  y: 2\n",
        "a: 'single'\nb: \"double\"\nc: 42\nd: true\n",
        "- name: multi\n  vars:\n    msg: |\n      line one\n      line two\n",
        "---\n- hosts: all\n...\n---\nkey: 1\n",
        "- name: quoted jinja\n  ansible.builtin.debug:\n    msg: \"{{ a.b | default('x') }}\"\n",
        "# leading comment\n- name: c # trailing\n  when: a and not b\n",
        "\"quoted key\": v\n'sq': w\n",
        "key: # comment\n",
    };
    for (corpus) |src| {
        var ts = try parse(std.testing.allocator, src);
        defer ts.deinit();
        var sub = try @import("parser.zig").parseChecked(std.testing.allocator, src);
        defer sub.deinit();
        try std.testing.expectEqual(ts.roots.len, sub.roots.len);
        for (ts.roots, sub.roots) |x, y| try expectSameNodeWithRanges(x, y);
    }
}

test "the audit defers constructs the subset parser does not model" {
    const corpus = [_][]const u8{
        "when: {{ x }}\n",
        "vars: {port: 80}\n",
        "when: [a, b]\n",
        "x: &anchor\n  y: 1\n",
        "a: *b\n",
        "key: \"esc\\nap\"\n",
        "key: v\n  cont\n",
        "%YAML 1.1\n---\nx: 1\n",
        "- - a\n",
        "--- inline\n",
        "msg: 'it''s'\n",
        "msg: |2\n    indented\n",
        "? complex\n: value\n",
    };
    for (corpus) |src| {
        const result = @import("parser.zig").parseChecked(std.testing.allocator, src);
        try std.testing.expectError(error.UnsupportedYaml, result);
    }
}

test "audit-passing documents parse identically on every checked-in fixture" {
    const a = std.testing.allocator;
    var checked: usize = 0;
    var deferred_to_tree_sitter: usize = 0;
    try diffWalk(a, "test/fixtures", &checked, &deferred_to_tree_sitter);
    try std.testing.expect(checked > 20);
    try std.testing.expect(checked + deferred_to_tree_sitter > 40);
}

fn diffWalk(a: std.mem.Allocator, dir_path: []const u8, checked: *usize, deferred: *usize) !void {
    var dir = fsio.openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(fsio.get());
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(fsio.get())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".yml") and
            !std.mem.endsWith(u8, entry.path, ".yaml") and
            !std.mem.endsWith(u8, entry.path, ".j2")) continue;
        const text = try entry.dir.readFileAlloc(fsio.get(), entry.basename, a, .limited(1 << 20));
        defer a.free(text);

        var sub = @import("parser.zig").parseChecked(a, text) catch |err| switch (err) {
            error.UnsupportedYaml => {
                deferred.* += 1;
                continue;
            },
            else => continue,
        };
        defer sub.deinit();
        var ts = try parse(a, text);
        defer ts.deinit();
        try std.testing.expectEqual(ts.roots.len, sub.roots.len);
        try std.testing.expectEqualSlices(usize, ts.document_starts, sub.document_starts);
        for (ts.roots, sub.roots) |x, y| try expectSameNodeWithRanges(x, y);
        checked.* += 1;
    }
}
