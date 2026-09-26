//! Encode LSP result types into JSON-RPC values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const types = @import("types.zig");

pub fn hover(a: Allocator, item: ?types.Hover) !Value {
    const h = item orelse return Value.null;
    var contents = json_util.obj(a);
    try contents.put("kind", json_util.str(markupKind(h.contents.kind)));
    try contents.put("value", json_util.str(h.contents.value));
    var result = json_util.obj(a);
    try result.put("contents", .{ .object = contents });
    if (h.range) |r| try result.put("range", .{ .object = try rangeObject(a, r) });
    return .{ .object = result };
}

pub fn completionList(a: Allocator, list: types.CompletionList) !Value {
    var items = std.json.Array.init(a);
    for (list.items) |item| try items.append(try completionItem(a, item));
    var obj = json_util.obj(a);
    try obj.put("isIncomplete", json_util.booleanValue(list.isIncomplete));
    try obj.put("items", .{ .array = items });
    return .{ .object = obj };
}

pub fn completionItem(a: Allocator, item: types.CompletionItem) !Value {
    var obj = json_util.obj(a);
    try obj.put("label", json_util.str(item.label));
    if (item.kind) |k| try obj.put("kind", json_util.num(@intFromEnum(k)));
    if (item.detail) |d| try obj.put("detail", json_util.str(d));
    if (item.documentation) |doc| try obj.put("documentation", try markup(a, doc));
    if (item.insertText) |t| try obj.put("insertText", json_util.str(t));
    if (item.insertTextFormat) |f| try obj.put("insertTextFormat", json_util.num(@intFromEnum(f)));
    if (item.sortText) |t| try obj.put("sortText", json_util.str(t));
    if (item.filterText) |t| try obj.put("filterText", json_util.str(t));
    if (item.data) |d| try obj.put("data", d);
    return .{ .object = obj };
}

pub fn markup(a: Allocator, doc: types.MarkupContent) !Value {
    var obj = json_util.obj(a);
    try obj.put("kind", json_util.str(markupKind(doc.kind)));
    try obj.put("value", json_util.str(doc.value));
    return .{ .object = obj };
}

pub fn semanticTokens(a: Allocator, tokens: []const types.AbsoluteToken) !Value {
    var data = std.json.Array.init(a);
    var prev_line: u32 = 0;
    var prev_start: u32 = 0;
    for (tokens) |t| {
        const dline = t.line - prev_line;
        const dstart: u32 = if (t.line == prev_line) t.start - prev_start else t.start;
        try data.append(json_util.num(dline));
        try data.append(json_util.num(dstart));
        try data.append(json_util.num(t.length));
        try data.append(json_util.num(t.kind));
        try data.append(json_util.num(t.mods));
        prev_line = t.line;
        prev_start = t.start;
    }
    var obj = json_util.obj(a);
    try obj.put("data", .{ .array = data });
    return .{ .object = obj };
}

pub fn location(a: Allocator, loc: types.Location) !Value {
    var obj = json_util.obj(a);
    try obj.put("uri", json_util.str(loc.uri));
    try obj.put("range", .{ .object = try rangeObject(a, loc.range) });
    return .{ .object = obj };
}

pub fn optionalLocation(a: Allocator, loc: ?types.Location) !Value {
    const l = loc orelse return Value.null;
    return location(a, l);
}

pub fn locations(a: Allocator, locs: []const types.Location) !Value {
    var arr = std.json.Array.init(a);
    for (locs) |loc| try arr.append(try location(a, loc));
    return .{ .array = arr };
}

fn markupKind(kind: types.MarkupKind) []const u8 {
    return switch (kind) {
        .markdown => "markdown",
        .plaintext => "plaintext",
    };
}

fn rangeObject(a: Allocator, r: types.Range) !std.json.ObjectMap {
    var obj = json_util.obj(a);
    try obj.put("start", try positionValue(a, r.start));
    try obj.put("end", try positionValue(a, r.end));
    return obj;
}

fn positionValue(a: Allocator, p: types.Position) !Value {
    var obj = json_util.obj(a);
    try obj.put("line", json_util.num(p.line));
    try obj.put("character", json_util.num(p.character));
    return .{ .object = obj };
}
