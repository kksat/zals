const std = @import("std");
const cel = @import("cel");

pub const Value = cel.value.Value;
pub const Map = cel.value.Map;
pub const Entry = cel.value.Map.Entry;
pub const Binding = cel.stdlib.Binding;

pub const MapBuilder = struct {
    entries: std.ArrayList(Entry),

    pub fn init() MapBuilder {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *MapBuilder, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    pub fn put(self: *MapBuilder, alloc: std.mem.Allocator, key: []const u8, val: Value) !void {
        try self.entries.append(alloc, .{
            .key = .{ .string_t = key },
            .value = val,
        });
    }

    pub fn putString(self: *MapBuilder, alloc: std.mem.Allocator, key: []const u8, val: []const u8) !void {
        try self.put(alloc, key, .{ .string_t = val });
    }

    pub fn putBool(self: *MapBuilder, alloc: std.mem.Allocator, key: []const u8, val: bool) !void {
        try self.put(alloc, key, .{ .bool_t = val });
    }

    pub fn putInt(self: *MapBuilder, alloc: std.mem.Allocator, key: []const u8, val: i64) !void {
        try self.put(alloc, key, .{ .int_t = val });
    }

    pub fn putNull(self: *MapBuilder, alloc: std.mem.Allocator, key: []const u8) !void {
        try self.put(alloc, key, .{ .null_t = {} });
    }

    pub fn putStringList(self: *MapBuilder, alloc: std.mem.Allocator, key: []const u8, items: []const []const u8) !void {
        const vals = try alloc.alloc(Value, items.len);
        for (items, 0..) |s, i| {
            vals[i] = .{ .string_t = s };
        }
        try self.put(alloc, key, .{ .list_t = vals });
    }

    pub fn finish(self: *MapBuilder, alloc: std.mem.Allocator) !Value {
        const owned = try self.entries.toOwnedSlice(alloc);
        const m = Map.init(alloc, owned) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RepeatedKey => return error.RepeatedKey,
        };
        return .{ .map_t = m };
    }
};

pub const LocationValue = struct {
    path: []const u8,
    line: i64,
    column: i64,

    pub fn toCel(self: LocationValue, alloc: std.mem.Allocator) !Value {
        var b = MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "path", self.path);
        try b.putInt(alloc, "line", self.line);
        try b.putInt(alloc, "column", self.column);
        return b.finish(alloc);
    }
};

pub fn emptyMapValue() Value {
    return .{ .map_t = Map.emptyMap() };
}

pub fn makeBindings(
    node: Value,
    location: Value,
    document: Value,
    context: Value,
    metadata: Value,
    options: Value,
) [6]Binding {
    return .{
        .{ .name = "node", .value = node },
        .{ .name = "location", .value = location },
        .{ .name = "document", .value = document },
        .{ .name = "context", .value = context },
        .{ .name = "metadata", .value = metadata },
        .{ .name = "options", .value = options },
    };
}

test "map builder and location value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const loc = try (LocationValue{ .path = "site.yml", .line = 12, .column = 5 }).toCel(a);
    try std.testing.expectEqualStrings("site.yml", loc.map_t.get(.{ .string_t = "path" }).?.string_t);
    try std.testing.expectEqual(@as(i64, 12), loc.map_t.get(.{ .string_t = "line" }).?.int_t);
    try std.testing.expectEqual(@as(i64, 5), loc.map_t.get(.{ .string_t = "column" }).?.int_t);
}
