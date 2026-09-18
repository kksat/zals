//! Lower the YAML DOM into `std.json.Value` for schema validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Node = @import("dom.zig").Node;

pub fn toJson(arena: Allocator, node: *const Node) !Value {
    return switch (node.kind) {
        .scalar, .alias => scalarValue(node.stringValue() orelse ""),
        .seq => blk: {
            var arr = std.json.Array.init(arena);
            for (node.items) |item| try arr.append(try toJson(arena, item));
            break :blk .{ .array = arr };
        },
        .map => blk: {
            var obj = std.json.ObjectMap.init(arena);
            for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
                const val = if (pair.val) |v| try toJson(arena, v) else Value.null;
                try obj.put(key, val);
            }
            break :blk .{ .object = obj };
        },
        .pair => if (node.val) |v| try toJson(arena, v) else Value.null,
    };
}

fn scalarValue(s: []const u8) Value {
    if (s.len == 0) return .null;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "Yes"))
        return .{ .bool = true };
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "False") or std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "No"))
        return .{ .bool = false };
    if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~")) return .null;
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return .{ .integer = n };
    } else |_| {}
    if (std.fmt.parseFloat(f64, s)) |n| {
        return .{ .float = n };
    } else |_| {}
    return .{ .string = s };
}

test "map to json" {
    const parser = @import("parser.zig");
    const src =
        \\name: foo
        \\count: 2
        \\
    ;
    var forest = try parser.parse(std.testing.allocator, src);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try toJson(arena.allocator(), forest.roots[0]);
    try std.testing.expect(v == .object);
    try std.testing.expectEqualStrings("foo", v.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), v.object.get("count").?.integer);
}
