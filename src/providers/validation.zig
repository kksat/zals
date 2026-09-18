//! Publish diagnostics from ansible-lint / syntax-check.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const lint = @import("../services/lint.zig");
const schema = @import("../services/schema.zig");
const yaml = @import("../yaml/root.zig");

pub fn publish(self: *Server, a: Allocator, uri: []const u8) !void {
    if (!self.settings.validation_enabled) {
        try send(self, a, uri, &.{});
        return;
    }
    const doc = self.documents.get(uri) orelse return;
    const path = try lint.uriToPath(a, uri);
    const lint_path, const tmp = try existingOrTemp(a, path, doc.bytes());
    defer if (tmp) std.fs.deleteFileAbsolute(lint_path) catch {};

    var diags: []const types.Diagnostic = &.{};
    if (self.schemas.schemaForUri(uri)) |sch| {
        diags = schemaDiags(a, doc, sch) catch &.{};
    }
    if (self.settings.lint_enabled) {
        const lint_diags = lint.lintFile(a, self.runner, self.settings.lint_path, self.settings.lint_arguments, lint_path) catch &.{};
        diags = try concatDiags(a, diags, lint_diags);
    }
    if (diags.len == 0 and !self.settings.lint_enabled) {
        diags = lint.syntaxCheck(a, self.runner, "ansible-playbook", lint_path, doc) catch &.{};
    }

    try send(self, a, uri, diags);
}

fn concatDiags(a: Allocator, left: []const types.Diagnostic, right: []const types.Diagnostic) ![]const types.Diagnostic {
    if (left.len == 0) return right;
    if (right.len == 0) return left;
    const out = try a.alloc(types.Diagnostic, left.len + right.len);
    @memcpy(out[0..left.len], left);
    @memcpy(out[left.len..], right);
    return out;
}

fn schemaDiags(a: Allocator, doc: *const @import("../workspace/document.zig").Document, sch: Value) ![]types.Diagnostic {
    var forest = yaml.parse(a, doc.bytes()) catch return &.{};
    defer forest.deinit();
    if (forest.roots.len == 0) return &.{};
    const instance = yaml.jsonify.toJson(a, forest.roots[0]) catch return &.{};
    const found = try schema.validate(a, sch, instance);
    if (found.len == 0) return &.{};
    const root_range = doc.rangeFromOffsets(0, doc.bytes().len);
    var out = try a.alloc(types.Diagnostic, found.len);
    for (found, 0..) |d, i| {
        out[i] = .{
            .range = root_range,
            .severity = .err,
            .source = "ansible-schema",
            .message = d.message,
        };
    }
    return out;
}

fn existingOrTemp(a: Allocator, path: []const u8, bytes: []const u8) !struct { []const u8, bool } {
    if (std.fs.openFileAbsolute(path, .{})) |f| {
        f.close();
        return .{ path, false };
    } else |_| {}
    const tmp = try std.fmt.allocPrint(a, "/tmp/zals-{d}.yml", .{std.crypto.random.int(u32)});
    var file = try std.fs.createFileAbsolute(tmp, .{});
    defer file.close();
    try file.writeAll(bytes);
    return .{ tmp, true };
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
