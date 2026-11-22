const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");

const max_remembered = 1024;

pub const Cancellation = struct {
    allocator: Allocator,
    ids: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator) Cancellation {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cancellation) void {
        self.clear();
        self.ids.deinit(self.allocator);
    }

    pub fn record(self: *Cancellation, params: Value) void {
        const id = json_util.field(params, "id") orelse return;
        var buf: [128]u8 = undefined;
        const key = canonicalId(&buf, id) orelse return;
        if (self.ids.count() >= max_remembered) self.clear();
        if (self.ids.contains(key)) return;
        const owned = self.allocator.dupe(u8, key) catch return;
        self.ids.put(self.allocator, owned, {}) catch self.allocator.free(owned);
    }

    pub fn take(self: *Cancellation, id: Value) bool {
        var buf: [128]u8 = undefined;
        const key = canonicalId(&buf, id) orelse return false;
        if (self.ids.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            return true;
        }
        return false;
    }

    fn clear(self: *Cancellation) void {
        var it = self.ids.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.ids.clearRetainingCapacity();
    }
};

fn canonicalId(buf: []u8, id: Value) ?[]const u8 {
    return switch (id) {
        .integer => |i| std.fmt.bufPrint(buf, "n{d}", .{i}) catch null,
        .float => |f| std.fmt.bufPrint(buf, "n{d}", .{f}) catch null,
        .number_string => |s| std.fmt.bufPrint(buf, "n{s}", .{s}) catch null,
        .string => |s| std.fmt.bufPrint(buf, "s{s}", .{s}) catch null,
        else => null,
    };
}

const testing = std.testing;

fn paramsOf(a: Allocator, json: []const u8) Value {
    return std.json.parseFromSliceLeaky(Value, a, json, .{}) catch unreachable;
}

test "record and take number and string ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancellation = Cancellation.init(testing.allocator);
    defer cancellation.deinit();

    cancellation.record(paramsOf(a, "{\"id\": 7}"));
    try testing.expect(cancellation.take(.{ .integer = 7 }));
    try testing.expect(!cancellation.take(.{ .integer = 7 }));

    cancellation.record(paramsOf(a, "{\"id\": \"abc\"}"));
    try testing.expect(cancellation.take(.{ .string = "abc" }));
    try testing.expect(!cancellation.take(.{ .integer = 8 }));
}

test "recording the same id twice remembers one entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancellation = Cancellation.init(testing.allocator);
    defer cancellation.deinit();

    cancellation.record(paramsOf(a, "{\"id\": 3}"));
    cancellation.record(paramsOf(a, "{\"id\": 3}"));
    try testing.expect(cancellation.take(.{ .integer = 3 }));
    try testing.expectEqual(@as(usize, 0), cancellation.ids.count());
}

test "a cancel without an id is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancellation = Cancellation.init(testing.allocator);
    defer cancellation.deinit();

    cancellation.record(paramsOf(a, "{\"other\": 1}"));
    cancellation.record(.null);
    try testing.expectEqual(@as(usize, 0), cancellation.ids.count());
    try testing.expect(!cancellation.take(.{ .integer = 1 }));
}

test "the remembered set is bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancellation = Cancellation.init(testing.allocator);
    defer cancellation.deinit();

    var i: usize = 0;
    while (i < max_remembered + 10) : (i += 1) {
        const json = try std.fmt.allocPrint(a, "{{\"id\": {d}}}", .{i});
        cancellation.record(paramsOf(a, json));
    }
    try testing.expect(cancellation.ids.count() <= max_remembered);
}
