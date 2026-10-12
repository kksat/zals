//! Adapt open documents/settings to validation and publish diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const validation = @import("../services/validation.zig");

pub fn publish(self: *Server, a: Allocator, uri: []const u8) !void {
    if (!self.settings.validation_enabled) {
        try send(self, a, uri, &.{});
        return;
    }
    const doc = self.documents.get(uri) orelse return;
    const result = try validation.validate(a, .{
        .uri = uri,
        .bytes = doc.bytes(),
        .document_range = doc.rangeFromOffsets(0, doc.bytes().len),
    }, .{
        .lint_enabled = self.settings.lint_enabled,
        .lint_path = self.settings.lint_path,
        .lint_arguments = self.settings.lint_arguments,
    }, self.runner, self.schemas.schemaForUri(uri));
    try send(self, a, uri, result.diagnostics);
}

fn send(self: *Server, a: Allocator, uri: []const u8, diags: []const types.Diagnostic) !void {
    var arr = std.json.Array.init(a);
    for (diags) |d| {
        var obj = json_util.obj(a);
        var range = json_util.obj(a);
        try putPos(&range, a, "start", d.range.start);
        try putPos(&range, a, "end", d.range.end);
        try obj.put("range", .{ .object = range });
        if (d.severity) |s| try obj.put("severity", json_util.num(@intFromEnum(s)));
        try obj.put("message", json_util.str(d.message));
        if (d.source) |src| try obj.put("source", json_util.str(src));
        if (d.code) |c| try obj.put("code", json_util.str(c));
        try arr.append(.{ .object = obj });
    }
    var params = json_util.obj(a);
    try params.put("uri", json_util.str(uri));
    try params.put("diagnostics", .{ .array = arr });
    try self.notify(a, "textDocument/publishDiagnostics", .{ .object = params });
}

fn putPos(obj: *std.json.ObjectMap, a: Allocator, key: []const u8, pos: types.Position) !void {
    var p = json_util.obj(a);
    try p.put("line", json_util.num(pos.line));
    try p.put("character", json_util.num(pos.character));
    try obj.put(key, .{ .object = p });
}
