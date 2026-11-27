const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub fn render(allocator: Allocator, v: Value) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try renderValue(allocator, &buf, v);
    return buf.toOwnedSlice(allocator);
}

fn renderValue(a: Allocator, buf: *std.ArrayList(u8), v: Value) error{OutOfMemory}!void {
    switch (v) {
        .null => try buf.appendSlice(a, "null"),
        .bool => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .integer => |n| {
            const s = std.fmt.allocPrint(a, "{d}", .{n}) catch return error.OutOfMemory;
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .number_string => |s| try buf.appendSlice(a, s),
        .float => |f| {
            var fbuf: [420]u8 = undefined;
            try buf.appendSlice(a, floatTextInto(&fbuf, f));
        },
        .string => |s| try renderString(a, buf, s),
        .array => |arr| {
            try buf.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(a, ',');
                try renderValue(a, buf, item);
            }
            try buf.append(a, ']');
        },
        .object => |obj| {
            try buf.append(a, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try buf.append(a, ',');
                first = false;
                try renderString(a, buf, kv.key_ptr.*);
                try buf.append(a, ':');
                try renderValue(a, buf, kv.value_ptr.*);
            }
            try buf.append(a, '}');
        },
    }
}

fn renderString(a: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            8 => try buf.appendSlice(a, "\\b"),
            12 => try buf.appendSlice(a, "\\f"),
            else => {
                if (c < 0x20) {
                    const hex = std.fmt.allocPrint(a, "\\u{x:0>4}", .{c}) catch return error.OutOfMemory;
                    defer a.free(hex);
                    try buf.appendSlice(a, hex);
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

pub fn floatText(a: Allocator, f: f64) ![]const u8 {
    var buf: [420]u8 = undefined;
    return a.dupe(u8, floatTextInto(&buf, f));
}

pub fn floatTextInto(out: []u8, f: f64) []const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isPositiveInf(f)) return "Infinity";
    if (std.math.isNegativeInf(f)) return "-Infinity";
    const s = std.fmt.bufPrint(out, "{}", .{f}) catch return "0.0";
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
        out[s.len] = '.';
        out[s.len + 1] = '0';
        return out[0 .. s.len + 2];
    }
    return s;
}

test "python json text" {
    const a = std.testing.allocator;
    const cases = [_]struct { v: Value, want: []const u8 }{
        .{ .v = .null, .want = "null" },
        .{ .v = .{ .bool = true }, .want = "true" },
        .{ .v = .{ .integer = 42 }, .want = "42" },
        .{ .v = .{ .integer = -7 }, .want = "-7" },
        .{ .v = .{ .number_string = "12345678901234567890" }, .want = "12345678901234567890" },
        .{ .v = .{ .float = 2.5 }, .want = "2.5" },
        .{ .v = .{ .float = 2500.0 }, .want = "2500.0" },
        .{ .v = .{ .float = std.math.inf(f64) }, .want = "Infinity" },
        .{ .v = .{ .float = -std.math.inf(f64) }, .want = "-Infinity" },
        .{ .v = .{ .float = std.math.nan(f64) }, .want = "NaN" },
        .{ .v = .{ .string = "a\"b\nc" }, .want = "\"a\\\"b\\nc\"" },
        .{ .v = .{ .string = "café" }, .want = "\"café\"" },
    };
    for (cases) |case| {
        const text = try render(a, case.v);
        defer a.free(text);
        try std.testing.expectEqualStrings(case.want, text);
    }
}
