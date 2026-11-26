//! Small helpers for reading `std.json.Value` trees.

const std = @import("std");
const Value = std.json.Value;

pub fn field(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn string(v: Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

pub fn integer(v: Value, key: []const u8) ?i64 {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn boolean(v: Value, key: []const u8) ?bool {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .bool => |b| b,
        else => null,
    };
}

pub fn array(v: Value, key: []const u8) ?std.json.Array {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .array => |a| a,
        else => null,
    };
}

pub fn object(v: Value, key: []const u8) ?std.json.ObjectMap {
    const x = field(v, key) orelse return null;
    return switch (x) {
        .object => |o| o,
        else => null,
    };
}

pub fn position(v: Value) ?@import("types.zig").Position {
    const line = integer(v, "line") orelse return null;
    const character = integer(v, "character") orelse return null;
    return .{ .line = @intCast(line), .character = @intCast(character) };
}

pub fn range(v: Value) ?@import("types.zig").Range {
    const start = field(v, "start") orelse return null;
    const end = field(v, "end") orelse return null;
    return .{ .start = position(start) orelse return null, .end = position(end) orelse return null };
}

pub const Obj = struct {
    map: std.json.ObjectMap = .empty,
    allocator: std.mem.Allocator,

    pub fn put(self: *Obj, key: []const u8, v: Value) std.mem.Allocator.Error!void {
        return self.map.put(self.allocator, key, v);
    }

    pub fn getOrPut(self: *Obj, key: []const u8) std.mem.Allocator.Error!std.json.ObjectMap.GetOrPutResult {
        return self.map.getOrPut(self.allocator, key);
    }

    pub fn value(self: *const Obj) Value {
        return .{ .object = self.map };
    }
};

pub fn obj(allocator: std.mem.Allocator) Obj {
    return .{ .allocator = allocator };
}

pub fn str(s: []const u8) Value {
    return .{ .string = s };
}

pub fn num(n: anytype) Value {
    return .{ .integer = @intCast(n) };
}

pub fn booleanValue(b: bool) Value {
    return .{ .bool = b };
}

pub fn nullValue() Value {
    return .null;
}
