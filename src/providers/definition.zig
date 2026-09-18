//! Go to definition: jump to the module source file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");

pub fn definition(self: *Server, a: Allocator, params: Value) !Value {
    var cur = util.parseAt(self, a, params) orelse return Value.null;
    defer cur.forest.deinit();
    const name = util.currentKey(cur.path) orelse return Value.null;
    const arena = cur.forest.allocator();
    const collections = yaml.collections.getDeclaredCollections(arena, cur.path) catch &.{};
    const mod = self.docs.findModuleInContext(arena, name, collections) orelse return Value.null;
    if (mod.filename.len == 0) return Value.null;

    const uri = try pathToUri(a, mod.filename);
    var range = json_util.obj(a);
    var zero = json_util.obj(a);
    try zero.put("line", json_util.num(0));
    try zero.put("character", json_util.num(0));
    try range.put("start", .{ .object = zero });
    try range.put("end", .{ .object = zero });
    var loc = json_util.obj(a);
    try loc.put("uri", json_util.str(uri));
    try loc.put("range", .{ .object = range });
    return .{ .object = loc };
}

fn pathToUri(a: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "file:")) return path;
    return std.fmt.allocPrint(a, "file://{s}", .{path});
}
