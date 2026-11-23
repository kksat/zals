const std = @import("std");
const Allocator = std.mem.Allocator;
const span_mod = @import("span.zig");
const noqa_mod = @import("noqa.zig");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_yaml() *const c.TSLanguage;

pub const max_yaml_bytes: usize = 2 * 1024 * 1024;
pub const max_recovery_attempts: usize = 16;
pub const max_recovery_region_bytes: usize = 64 * 1024;
pub const max_alias_depth: usize = 8;

pub const ScalarStyle = enum(u8) {
    empty,
    plain,
    single_quoted,
    double_quoted,
    literal_block,
    folded_block,

    pub fn isQuoted(self: ScalarStyle) bool {
        return self == .single_quoted or self == .double_quoted;
    }
};

pub const NodeKind = enum(u8) {
    scalar,
    map,
    seq,
    pair,
    alias,
};

pub const YamlNode = struct {
    kind: NodeKind,
    start: usize,
    end: usize,
    scalar_style: ScalarStyle = .plain,
    raw: []const u8 = "",
    value: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    items: []*YamlNode = &.{},
    key: ?*YamlNode = null,
    val: ?*YamlNode = null,
    has_error: bool = false,

    pub fn findPair(self: *const YamlNode, name: []const u8) ?*YamlNode {
        if (self.kind != .map) return null;
        for (self.items) |pair| {
            const k = pair.key orelse continue;
            if (k.kind == .scalar) {
                if (k.value) |v| {
                    if (std.mem.eql(u8, v, name)) return pair;
                }
            }
        }
        return null;
    }
};

pub const IssueKind = enum(u8) {
    yaml_syntax,
    ansible_structure,

    pub fn name(self: IssueKind) []const u8 {
        return switch (self) {
            .yaml_syntax => "yaml_syntax",
            .ansible_structure => "ansible_structure",
        };
    }
};

pub const RawIssue = struct {
    kind: IssueKind,
    start: usize,
    end: usize,
    message: []const u8,
};

pub const YamlDoc = struct {
    start: usize,
    end: usize,
    root: ?*YamlNode,
    recovered_items: []*YamlNode,
};

pub const RecoveredYaml = struct {
    documents: []const YamlDoc,
    issues: []const RawIssue,
    comments: []const noqa_mod.Comment,
};

const ParseCtx = struct {
    alloc: Allocator,
    text: []const u8,
    base_offset: usize,
    issues: *std.ArrayList(RawIssue),
    comments: *std.ArrayList(noqa_mod.Comment),
    recovery_attempts: *usize,
    record_meta: bool,

    fn addIssue(self: *ParseCtx, start_b: usize, end_b: usize, msg: []const u8) !void {
        if (!self.record_meta) return;
        const abs_s = self.base_offset + start_b;
        const abs_e = self.base_offset + end_b;
        for (self.issues.items) |existing| {
            if (existing.start == abs_s and existing.end == abs_e) return;
        }
        try self.issues.append(self.alloc, .{
            .kind = .yaml_syntax,
            .start = abs_s,
            .end = abs_e,
            .message = msg,
        });
    }
};

pub fn parse(alloc: Allocator, text: []const u8) !RecoveredYaml {
    var issues = std.ArrayList(RawIssue).empty;
    var comments = std.ArrayList(noqa_mod.Comment).empty;
    var docs = std.ArrayList(YamlDoc).empty;
    var recovery_attempts: usize = 0;

    if (text.len > max_yaml_bytes) {
        try issues.append(alloc, .{
            .kind = .yaml_syntax,
            .start = 0,
            .end = 0,
            .message = "YAML document exceeds maximum allowed size",
        });
        return .{
            .documents = &.{},
            .issues = try issues.toOwnedSlice(alloc),
            .comments = &.{},
        };
    }

    const parser = c.ts_parser_new() orelse return error.ParserInit;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, tree_sitter_yaml())) return error.LanguageMismatch;

    const tree = c.ts_parser_parse_string(parser, null, text.ptr, @intCast(text.len)) orelse
        return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    var ctx = ParseCtx{
        .alloc = alloc,
        .text = text,
        .base_offset = 0,
        .issues = &issues,
        .comments = &comments,
        .recovery_attempts = &recovery_attempts,
        .record_meta = true,
    };

    const root = c.ts_tree_root_node(tree);
    try collectCommentsAndErrors(&ctx, root);

    const n = c.ts_node_named_child_count(root);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(root, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "document")) {
            var recovered_items = std.ArrayList(*YamlNode).empty;
            const doc_root = try convertDocument(&ctx, ch, &recovered_items);
            var anchors = std.StringHashMapUnmanaged(*YamlNode).empty;
            if (doc_root) |dr| {
                try collectAnchors(alloc, dr, &anchors);
                _ = try resolveAliases(alloc, dr, &anchors, 0);
            }
            for (recovered_items.items) |item| {
                try collectAnchors(alloc, item, &anchors);
                _ = try resolveAliases(alloc, item, &anchors, 0);
            }
            try docs.append(alloc, .{
                .start = startByte(ch),
                .end = endByte(ch),
                .root = doc_root,
                .recovered_items = try recovered_items.toOwnedSlice(alloc),
            });
        } else if (c.ts_node_is_error(ch)) {
            var recovered_items = std.ArrayList(*YamlNode).empty;
            try recoverFromErrorNode(&ctx, ch, &recovered_items);
            if (recovered_items.items.len > 0) {
                try docs.append(alloc, .{
                    .start = startByte(ch),
                    .end = endByte(ch),
                    .root = null,
                    .recovered_items = try recovered_items.toOwnedSlice(alloc),
                });
            }
        }
    }

    return .{
        .documents = try docs.toOwnedSlice(alloc),
        .issues = try issues.toOwnedSlice(alloc),
        .comments = try comments.toOwnedSlice(alloc),
    };
}

fn typeName(node: c.TSNode) []const u8 {
    return std.mem.span(c.ts_node_type(node));
}

fn startByte(node: c.TSNode) usize {
    return c.ts_node_start_byte(node);
}

fn endByte(node: c.TSNode) usize {
    return c.ts_node_end_byte(node);
}

fn collectCommentsAndErrors(ctx: *ParseCtx, node: c.TSNode) anyerror!void {
    const ty = typeName(node);
    if (std.mem.eql(u8, ty, "comment")) {
        const s = startByte(node);
        const e = endByte(node);
        if (e <= ctx.text.len and s <= e) {
            const lc = span_mod.lineColAt(ctx.text, s);
            try ctx.comments.append(ctx.alloc, .{
                .start = ctx.base_offset + s,
                .end = ctx.base_offset + e,
                .line = lc.line,
                .text = ctx.text[s..e],
            });
        }
        return;
    }

    if (c.ts_node_is_missing(node)) {
        const msg = try std.fmt.allocPrint(ctx.alloc, "missing expected YAML syntax ({s})", .{ty});
        try ctx.addIssue(startByte(node), endByte(node), msg);
        return;
    }

    if (c.ts_node_is_error(node)) {
        try ctx.addIssue(startByte(node), endByte(node), "YAML syntax error");
    }

    const total = c.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        try collectCommentsAndErrors(ctx, c.ts_node_child(node, i));
    }
}

fn convertDocument(ctx: *ParseCtx, doc_node: c.TSNode, recovered_items: *std.ArrayList(*YamlNode)) !?*YamlNode {
    var root: ?*YamlNode = null;
    const n = c.ts_node_named_child_count(doc_node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(doc_node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "comment") or std.mem.eql(u8, ty, "tag_directive") or std.mem.eql(u8, ty, "yaml_directive")) continue;
        if (c.ts_node_is_error(ch)) {
            try recoverFromErrorNode(ctx, ch, recovered_items);
            continue;
        }
        if (root == null) {
            root = try convertNode(ctx, ch, recovered_items);
        } else {
            if (try convertNode(ctx, ch, recovered_items)) |extra| {
                try recovered_items.append(ctx.alloc, extra);
            }
        }
    }
    return root;
}

fn convertNode(ctx: *ParseCtx, node: c.TSNode, recovered_items: *std.ArrayList(*YamlNode)) anyerror!?*YamlNode {
    if (c.ts_node_is_missing(node)) return null;
    if (c.ts_node_is_error(node)) {
        try recoverFromErrorNode(ctx, node, recovered_items);
        return null;
    }

    const ty = typeName(node);
    if (std.mem.eql(u8, ty, "block_node") or std.mem.eql(u8, ty, "flow_node")) {
        return convertWrapper(ctx, node, recovered_items);
    }
    if (std.mem.eql(u8, ty, "block_sequence_item")) {
        return convertWrapper(ctx, node, recovered_items);
    }
    if (std.mem.eql(u8, ty, "block_mapping") or std.mem.eql(u8, ty, "flow_mapping")) {
        return convertMap(ctx, node, recovered_items);
    }
    if (std.mem.eql(u8, ty, "block_sequence") or std.mem.eql(u8, ty, "flow_sequence")) {
        return convertSeq(ctx, node, recovered_items);
    }
    if (std.mem.eql(u8, ty, "block_mapping_pair") or std.mem.eql(u8, ty, "flow_pair")) {
        return convertPair(ctx, node, recovered_items);
    }
    if (std.mem.eql(u8, ty, "plain_scalar")) return convertPlain(ctx, node);
    if (std.mem.eql(u8, ty, "single_quote_scalar")) return convertSingle(ctx, node);
    if (std.mem.eql(u8, ty, "double_quote_scalar")) return convertDouble(ctx, node);
    if (std.mem.eql(u8, ty, "block_scalar")) return convertBlockScalar(ctx, node);
    if (std.mem.eql(u8, ty, "alias")) return convertAlias(ctx, node);
    return null;
}

fn convertWrapper(ctx: *ParseCtx, node: c.TSNode, recovered_items: *std.ArrayList(*YamlNode)) anyerror!?*YamlNode {
    var tag: ?[]const u8 = null;
    var anchor: ?[]const u8 = null;
    var content: ?*YamlNode = null;

    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "comment")) continue;
        if (std.mem.eql(u8, ty, "tag")) {
            tag = sliceOf(ctx.text, ch);
            continue;
        }
        if (std.mem.eql(u8, ty, "anchor")) {
            var raw = sliceOf(ctx.text, ch);
            if (raw.len > 0 and raw[0] == '&') raw = raw[1..];
            anchor = raw;
            continue;
        }
        if (c.ts_node_is_error(ch)) {
            try recoverFromErrorNode(ctx, ch, recovered_items);
            continue;
        }
        if (content == null) {
            content = try convertNode(ctx, ch, recovered_items);
        } else {
            if (try convertNode(ctx, ch, recovered_items)) |extra| {
                try recovered_items.append(ctx.alloc, extra);
            }
        }
    }

    if (content) |out| {
        if (tag != null) out.tag = tag;
        if (anchor != null) out.anchor = anchor;
        if (c.ts_node_has_error(node)) out.has_error = true;
        return out;
    }

    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .scalar,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .scalar_style = .empty,
        .raw = sliceOf(ctx.text, node),
        .value = "",
        .tag = tag,
        .anchor = anchor,
        .has_error = c.ts_node_has_error(node),
    };
    return out;
}

fn convertMap(ctx: *ParseCtx, node: c.TSNode, recovered_items: *std.ArrayList(*YamlNode)) anyerror!*YamlNode {
    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .map,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .has_error = c.ts_node_has_error(node),
    };
    var items = std.ArrayList(*YamlNode).empty;
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "comment")) continue;
        if (std.mem.eql(u8, ty, "block_mapping_pair") or std.mem.eql(u8, ty, "flow_pair")) {
            try items.append(ctx.alloc, try convertPair(ctx, ch, recovered_items));
        } else if (std.mem.eql(u8, ty, "flow_node") or std.mem.eql(u8, ty, "block_node")) {
            if (try convertNode(ctx, ch, recovered_items)) |k| {
                const p = try ctx.alloc.create(YamlNode);
                p.* = .{
                    .kind = .pair,
                    .start = k.start,
                    .end = k.end,
                    .key = k,
                    .has_error = k.has_error,
                };
                try items.append(ctx.alloc, p);
            }
        } else if (c.ts_node_is_error(ch)) {
            try recoverFromErrorNode(ctx, ch, recovered_items);
        }
    }
    out.items = try items.toOwnedSlice(ctx.alloc);
    return out;
}

fn convertSeq(ctx: *ParseCtx, node: c.TSNode, recovered_items: *std.ArrayList(*YamlNode)) anyerror!*YamlNode {
    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .seq,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .has_error = c.ts_node_has_error(node),
    };
    var items = std.ArrayList(*YamlNode).empty;
    const n = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "comment")) continue;
        if (std.mem.eql(u8, ty, "block_sequence_item")) {
            if (try convertWrapper(ctx, ch, recovered_items)) |it| {
                try items.append(ctx.alloc, it);
            }
        } else if (std.mem.eql(u8, ty, "flow_node") or std.mem.eql(u8, ty, "block_node")) {
            if (try convertNode(ctx, ch, recovered_items)) |it| {
                try items.append(ctx.alloc, it);
            }
        } else if (c.ts_node_is_error(ch)) {
            try recoverFromErrorNode(ctx, ch, recovered_items);
        }
    }
    out.items = try items.toOwnedSlice(ctx.alloc);
    return out;
}

fn convertPair(ctx: *ParseCtx, node: c.TSNode, recovered_items: *std.ArrayList(*YamlNode)) anyerror!*YamlNode {
    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .pair,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .has_error = c.ts_node_has_error(node),
    };
    const key_ts = c.ts_node_child_by_field_name(node, "key", 3);
    const val_ts = c.ts_node_child_by_field_name(node, "value", 5);
    if (!c.ts_node_is_null(key_ts)) {
        out.key = try convertNode(ctx, key_ts, recovered_items);
    }
    if (!c.ts_node_is_null(val_ts)) {
        out.val = try convertNode(ctx, val_ts, recovered_items);
    }
    return out;
}

fn sliceOf(text: []const u8, node: c.TSNode) []const u8 {
    const s = @min(startByte(node), text.len);
    const e = @min(@max(endByte(node), s), text.len);
    return text[s..e];
}

fn convertPlain(ctx: *ParseCtx, node: c.TSNode) !*YamlNode {
    const out = try ctx.alloc.create(YamlNode);
    const full_raw = sliceOf(ctx.text, node);
    var raw = full_raw;
    if (c.ts_node_named_child_count(node) > 0) {
        const ch = c.ts_node_named_child(node, 0);
        raw = sliceOf(ctx.text, ch);
    }
    out.* = .{
        .kind = .scalar,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .scalar_style = .plain,
        .raw = full_raw,
        .value = std.mem.trim(u8, raw, " \t\r\n"),
        .has_error = c.ts_node_has_error(node),
    };
    return out;
}

fn convertSingle(ctx: *ParseCtx, node: c.TSNode) !*YamlNode {
    const raw = sliceOf(ctx.text, node);
    var inner = raw;
    if (inner.len >= 2 and inner[0] == '\'' and inner[inner.len - 1] == '\'')
        inner = inner[1 .. inner.len - 1];
    const value: []const u8 = if (std.mem.indexOf(u8, inner, "''") == null) inner else blk: {
        const buf = try ctx.alloc.alloc(u8, inner.len);
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
        break :blk buf[0..j];
    };
    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .scalar,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .scalar_style = .single_quoted,
        .raw = raw,
        .value = value,
        .has_error = c.ts_node_has_error(node),
    };
    return out;
}

fn convertDouble(ctx: *ParseCtx, node: c.TSNode) !*YamlNode {
    const raw = sliceOf(ctx.text, node);
    var inner = raw;
    if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"')
        inner = inner[1 .. inner.len - 1];
    const value: []const u8 = if (std.mem.indexOfScalar(u8, inner, '\\') == null) inner else blk: {
        var buf = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] != '\\' or i + 1 >= inner.len) {
                try buf.append(ctx.alloc, inner[i]);
                continue;
            }
            i += 1;
            const esc = inner[i];
            switch (esc) {
                'n' => try buf.append(ctx.alloc, '\n'),
                't' => try buf.append(ctx.alloc, '\t'),
                'r' => try buf.append(ctx.alloc, '\r'),
                '0' => try buf.append(ctx.alloc, 0),
                'b' => try buf.append(ctx.alloc, 8),
                'f' => try buf.append(ctx.alloc, 12),
                '"' => try buf.append(ctx.alloc, '"'),
                '\\' => try buf.append(ctx.alloc, '\\'),
                '/' => try buf.append(ctx.alloc, '/'),
                'u' => {
                    if (i + 4 < inner.len) {
                        const cp = std.fmt.parseInt(u21, inner[i + 1 .. i + 5], 16) catch 0;
                        var utf8: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8) catch 0;
                        try buf.appendSlice(ctx.alloc, utf8[0..len]);
                        i += 4;
                    }
                },
                else => try buf.append(ctx.alloc, esc),
            }
        }
        break :blk try buf.toOwnedSlice(ctx.alloc);
    };
    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .scalar,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .scalar_style = .double_quoted,
        .raw = raw,
        .value = value,
        .has_error = c.ts_node_has_error(node),
    };
    return out;
}

fn convertBlockScalar(ctx: *ParseCtx, node: c.TSNode) !*YamlNode {
    const raw = sliceOf(ctx.text, node);
    var nl: usize = 0;
    while (nl < raw.len and raw[nl] != '\n') : (nl += 1) {}
    const header = raw[0..nl];
    const body = if (nl < raw.len) raw[nl + 1 ..] else "";
    const folded = header.len > 0 and header[0] == '>';
    const strip = std.mem.indexOfScalar(u8, header, '-') != null;
    const keep = std.mem.indexOfScalar(u8, header, '+') != null;

    var min_indent: usize = std.math.maxInt(usize);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const trimmed_cr = std.mem.trimRight(u8, line, "\r");
        if (trimmed_cr.len == 0) continue;
        var ind: usize = 0;
        while (ind < trimmed_cr.len and trimmed_cr[ind] == ' ') : (ind += 1) {}
        if (ind < trimmed_cr.len) min_indent = @min(min_indent, ind);
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    var lines = std.ArrayList([]const u8).empty;
    var it2 = std.mem.splitScalar(u8, body, '\n');
    while (it2.next()) |line| {
        const trimmed_cr = std.mem.trimRight(u8, line, "\r");
        const stripped = if (trimmed_cr.len >= min_indent) trimmed_cr[min_indent..] else "";
        try lines.append(ctx.alloc, stripped);
    }
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0)
        _ = lines.pop();

    var buf = std.ArrayList(u8).empty;
    for (lines.items, 0..) |line, idx| {
        if (idx > 0) try buf.append(ctx.alloc, if (folded) ' ' else '\n');
        try buf.appendSlice(ctx.alloc, line);
    }
    if (!strip) try buf.append(ctx.alloc, '\n');
    if (keep) try buf.append(ctx.alloc, '\n');

    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .scalar,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .scalar_style = if (folded) .folded_block else .literal_block,
        .raw = raw,
        .value = try buf.toOwnedSlice(ctx.alloc),
        .has_error = c.ts_node_has_error(node),
    };
    return out;
}

fn convertAlias(ctx: *ParseCtx, node: c.TSNode) !*YamlNode {
    const raw = sliceOf(ctx.text, node);
    var value: []const u8 = raw;
    if (c.ts_node_named_child_count(node) > 0) {
        const ch = c.ts_node_named_child(node, 0);
        value = sliceOf(ctx.text, ch);
    } else if (value.len > 0 and value[0] == '*') {
        value = value[1..];
    }
    const out = try ctx.alloc.create(YamlNode);
    out.* = .{
        .kind = .alias,
        .start = ctx.base_offset + startByte(node),
        .end = ctx.base_offset + endByte(node),
        .raw = raw,
        .value = value,
        .has_error = c.ts_node_has_error(node),
    };
    return out;
}

fn recoverFromErrorNode(
    ctx: *ParseCtx,
    err_node: c.TSNode,
    recovered_items: *std.ArrayList(*YamlNode),
) anyerror!void {
    const before_len = recovered_items.items.len;
    const n = c.ts_node_named_child_count(err_node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ch = c.ts_node_named_child(err_node, i);
        const ty = typeName(ch);
        if (std.mem.eql(u8, ty, "comment")) continue;
        if (std.mem.eql(u8, ty, "block_sequence_item") or
            std.mem.eql(u8, ty, "block_mapping") or
            std.mem.eql(u8, ty, "block_sequence"))
        {
            if (try convertNode(ctx, ch, recovered_items)) |item| {
                try recovered_items.append(ctx.alloc, item);
            }
        }
    }

    if (recovered_items.items.len > before_len) return;
    if (!ctx.record_meta) return;
    if (ctx.recovery_attempts.* >= max_recovery_attempts) return;

    const s = startByte(err_node);
    const e = endByte(err_node);
    if (e <= s or e > ctx.text.len or (e - s) > max_recovery_region_bytes) return;
    const region = ctx.text[s..e];
    if (std.mem.indexOfScalar(u8, region, '\n') == null) return;

    try recoverRegionLines(ctx, s, e, recovered_items);
}

fn recoverRegionLines(
    ctx: *ParseCtx,
    region_start: usize,
    region_end: usize,
    recovered_items: *std.ArrayList(*YamlNode),
) !void {
    const parser = c.ts_parser_new() orelse return;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, tree_sitter_yaml())) return;

    var pos = region_start;
    var candidate_starts = std.ArrayList(usize).empty;
    var candidate_indents = std.ArrayList(usize).empty;
    var in_block_scalar_indent: ?usize = null;

    while (pos < region_end) {
        const line_start = pos;
        const nl_rel = std.mem.indexOfScalar(u8, ctx.text[pos..region_end], '\n');
        const line_end = if (nl_rel) |r| pos + r else region_end;
        const line = std.mem.trimRight(u8, ctx.text[line_start..line_end], "\r");
        pos = if (nl_rel != null) line_end + 1 else region_end;

        var ind: usize = 0;
        while (ind < line.len and line[ind] == ' ') : (ind += 1) {}
        const trimmed = line[ind..];

        if (in_block_scalar_indent) |blk_ind| {
            if (trimmed.len == 0 or ind > blk_ind) continue;
            in_block_scalar_indent = null;
        }
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (isBlockScalarHeader(trimmed)) {
            in_block_scalar_indent = ind;
        }

        if (trimmed.len >= 2 and trimmed[0] == '-' and (trimmed[1] == ' ' or trimmed[1] == '\t')) {
            try candidate_starts.append(ctx.alloc, line_start);
            try candidate_indents.append(ctx.alloc, ind);
        }
    }

    for (candidate_starts.items, 0..) |c_start, idx| {
        if (ctx.recovery_attempts.* >= max_recovery_attempts) break;
        const c_indent = candidate_indents.items[idx];
        var c_end = region_end;
        var next_idx = idx + 1;
        while (next_idx < candidate_starts.items.len) : (next_idx += 1) {
            if (candidate_indents.items[next_idx] <= c_indent) {
                c_end = candidate_starts.items[next_idx];
                break;
            }
        }
        if (c_end <= c_start) continue;
        ctx.recovery_attempts.* += 1;

        const slice = ctx.text[c_start..c_end];
        const sub_tree = c.ts_parser_parse_string(parser, null, slice.ptr, @intCast(slice.len)) orelse continue;
        defer c.ts_tree_delete(sub_tree);
        const sub_root = c.ts_tree_root_node(sub_tree);
        if (c.ts_node_has_error(sub_root)) continue;

        var sub_ctx = ParseCtx{
            .alloc = ctx.alloc,
            .text = slice,
            .base_offset = ctx.base_offset + c_start,
            .issues = ctx.issues,
            .comments = ctx.comments,
            .recovery_attempts = ctx.recovery_attempts,
            .record_meta = false,
        };
        var dummy = std.ArrayList(*YamlNode).empty;
        const sub_n = c.ts_node_named_child_count(sub_root);
        var j: u32 = 0;
        while (j < sub_n) : (j += 1) {
            const doc = c.ts_node_named_child(sub_root, j);
            if (!std.mem.eql(u8, typeName(doc), "document")) continue;
            if (try convertDocument(&sub_ctx, doc, &dummy)) |parsed_node| {
                if (parsed_node.kind == .seq) {
                    for (parsed_node.items) |it| try recovered_items.append(ctx.alloc, it);
                } else {
                    try recovered_items.append(ctx.alloc, parsed_node);
                }
            }
        }
    }
}

fn isBlockScalarHeader(trimmed: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return false;
    const after = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    if (after.len == 0) return false;
    return after[0] == '|' or after[0] == '>';
}

fn collectAnchors(
    alloc: Allocator,
    node: *YamlNode,
    anchors: *std.StringHashMapUnmanaged(*YamlNode),
) anyerror!void {
    if (node.anchor) |name| {
        try anchors.put(alloc, name, node);
    }
    switch (node.kind) {
        .map, .seq => {
            for (node.items) |it| try collectAnchors(alloc, it, anchors);
        },
        .pair => {
            if (node.key) |k| try collectAnchors(alloc, k, anchors);
            if (node.val) |v| try collectAnchors(alloc, v, anchors);
        },
        else => {},
    }
}

fn resolveAliases(
    alloc: Allocator,
    node: *YamlNode,
    anchors: *const std.StringHashMapUnmanaged(*YamlNode),
    depth: usize,
) anyerror!*YamlNode {
    if (depth >= max_alias_depth) return node;
    switch (node.kind) {
        .alias => {
            if (node.value) |name| {
                if (anchors.get(name)) |target| {
                    return target;
                }
            }
            return node;
        },
        .seq => {
            for (node.items, 0..) |it, idx| {
                node.items[idx] = try resolveAliases(alloc, it, anchors, depth + 1);
            }
            return node;
        },
        .pair => {
            if (node.val) |v| {
                node.val = try resolveAliases(alloc, v, anchors, depth + 1);
            }
            return node;
        },
        .map => {
            var has_merge = false;
            for (node.items) |p| {
                if (p.key) |k| {
                    if (k.kind == .scalar and k.scalar_style == .plain) {
                        if (k.value) |kv| {
                            if (std.mem.eql(u8, kv, "<<")) has_merge = true;
                        }
                    }
                }
                _ = try resolveAliases(alloc, p, anchors, depth + 1);
            }
            if (!has_merge) return node;

            var merged = std.ArrayList(*YamlNode).empty;
            var explicit_keys = std.StringHashMapUnmanaged(void).empty;
            for (node.items) |p| {
                if (isMergePair(p)) continue;
                if (p.key) |k| {
                    if (k.kind == .scalar) {
                        if (k.value) |kv| try explicit_keys.put(alloc, kv, {});
                    }
                }
            }
            for (node.items) |p| {
                if (!isMergePair(p)) {
                    try merged.append(alloc, p);
                    continue;
                }
                const val = p.val orelse continue;
                if (val.kind == .map) {
                    try appendMergedMap(alloc, val, &explicit_keys, &merged);
                } else if (val.kind == .seq) {
                    for (val.items) |entry| {
                        if (entry.kind == .map) {
                            try appendMergedMap(alloc, entry, &explicit_keys, &merged);
                        }
                    }
                }
            }
            node.items = try merged.toOwnedSlice(alloc);
            return node;
        },
        else => return node,
    }
}

fn isMergePair(pair: *const YamlNode) bool {
    const k = pair.key orelse return false;
    if (k.kind != .scalar or k.scalar_style != .plain) return false;
    const kv = k.value orelse return false;
    return std.mem.eql(u8, kv, "<<");
}

fn appendMergedMap(
    alloc: Allocator,
    src_map: *const YamlNode,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(*YamlNode),
) !void {
    for (src_map.items) |pair| {
        const k = pair.key orelse continue;
        if (k.kind == .scalar) {
            if (k.value) |kv| {
                if (seen.contains(kv)) continue;
                try seen.put(alloc, kv, {});
            }
        }
        try out.append(alloc, pair);
    }
}

test "recover preserves valid siblings and collects real comments only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: first # noqa: name[missing]
        \\      ansible.builtin.debug:
        \\        msg: "not a # noqa comment"
        \\    - name: [broken
        \\    - name: second
        \\      ansible.builtin.ping:
        \\
    ;
    const rec = try parse(a, src);
    try std.testing.expect(rec.issues.len >= 1);
    try std.testing.expectEqual(@as(usize, 1), rec.comments.len);
    try std.testing.expectEqualStrings("# noqa: name[missing]", rec.comments[0].text);
    try std.testing.expectEqual(@as(u32, 3), rec.comments[0].line);
}

test "alias and merge keys resolve cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\defaults: &def
        \\  mode: "0644"
        \\task:
        \\  <<: *def
        \\  dest: /tmp/a
        \\
    ;
    const rec = try parse(a, src);
    try std.testing.expectEqual(@as(usize, 0), rec.issues.len);
    const root = rec.documents[0].root.?;
    const task = root.findPair("task").?.val.?;
    try std.testing.expectEqualStrings("0644", task.findPair("mode").?.val.?.value.?);
    try std.testing.expectEqualStrings("/tmp/a", task.findPair("dest").?.val.?.value.?);
}
