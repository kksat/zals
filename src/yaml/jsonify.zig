//! Lower the YAML DOM into `std.json.Value` for schema validation (ADR-0053).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Node = @import("dom.zig").Node;

pub fn toJson(arena: Allocator, node: *const Node) !Value {
    return switch (node.kind) {
        .scalar, .alias => scalarValue(node),
        .seq => blk: {
            var arr = std.json.Array.init(arena);
            for (node.items) |item| try arr.append(try toJson(arena, item));
            break :blk .{ .array = arr };
        },
        .map => blk: {
            var obj: std.json.ObjectMap = .empty;
            for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
                const val = if (pair.val) |v| try toJson(arena, v) else Value.null;
                try obj.put(arena, key, val);
            }
            break :blk .{ .object = obj };
        },
        .pair => if (node.val) |v| try toJson(arena, v) else Value.null,
    };
}

fn scalarValue(node: *const Node) Value {
    const s = node.stringValue() orelse "";
    return switch (node.style) {
        .quoted, .block => .{ .string = s },
        .plain => resolvePlain(s),
    };
}

fn resolvePlain(s: []const u8) Value {
    if (s.len == 0) return .null;
    if (boolOf(s)) |b| return .{ .bool = b };
    if (isNullLiteral(s)) return .null;
    if (intOf(s)) |n| return .{ .integer = n };
    if (floatOf(s)) |f| return .{ .float = f };
    return .{ .string = s };
}

fn boolOf(s: []const u8) ?bool {
    const trues = [_][]const u8{ "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON" };
    const falses = [_][]const u8{ "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF" };
    for (trues) |w| if (std.mem.eql(u8, s, w)) return true;
    for (falses) |w| if (std.mem.eql(u8, s, w)) return false;
    return null;
}

fn isNullLiteral(s: []const u8) bool {
    return std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "null") or
        std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL");
}

fn intOf(s: []const u8) ?i64 {
    var sign: i64 = 1;
    var body = s;
    if (body.len > 1 and (body[0] == '-' or body[0] == '+')) {
        if (body[0] == '-') sign = -1;
        body = body[1..];
    }
    if (std.mem.eql(u8, body, "0")) return 0;
    if (body.len > 2 and body[0] == '0' and body[1] == 'b')
        return sign * (digitsOf(body[2..], 2, .any) orelse return null);
    if (body.len > 2 and body[0] == '0' and body[1] == 'x')
        return sign * (digitsOf(body[2..], 16, .any) orelse return null);
    if (body.len > 1 and body[0] == '0')
        return sign * (digitsOf(body[1..], 8, .any) orelse return null);
    if (std.mem.indexOfScalar(u8, body, ':') != null) return sexagesimalInt(body, sign);
    return sign * (digitsOf(body, 10, .nonzero) orelse return null);
}

const Start = enum { any, nonzero };

fn digitsOf(s: []const u8, base: u8, start: Start) ?i64 {
    var n: i64 = 0;
    var saw_digit = false;
    var first_char = true;
    for (s) |c| {
        if (c == '_') {
            first_char = false;
            continue;
        }
        const d = std.fmt.charToDigit(c, base) catch return null;
        if (first_char and start == .nonzero and d == 0) return null;
        first_char = false;
        saw_digit = true;
        n = std.math.mul(i64, n, base) catch return null;
        n = std.math.add(i64, n, d) catch return null;
    }
    if (!saw_digit) return null;
    return n;
}

fn sexagesimalInt(body: []const u8, sign: i64) ?i64 {
    var n: i64 = 0;
    var first = true;
    var it = std.mem.splitScalar(u8, body, ':');
    while (it.next()) |part| {
        const d = if (first) digitsOf(part, 10, .nonzero) else minuteOf(part);
        if (d == null) return null;
        first = false;
        n = std.math.mul(i64, n, 60) catch return null;
        n = std.math.add(i64, n, d.?) catch return null;
    }
    return sign * n;
}

fn minuteOf(part: []const u8) ?i64 {
    if (part.len == 0 or part.len > 2) return null;
    const d = digitsOf(part, 10, .any) orelse return null;
    return if (d <= 59) d else null;
}

fn floatOf(s: []const u8) ?f64 {
    if (isNanWord(s)) return std.math.nan(f64);
    var sign: f64 = 1.0;
    var body = s;
    if (body.len > 1 and (body[0] == '-' or body[0] == '+')) {
        if (body[0] == '-') sign = -1.0;
        body = body[1..];
    }
    if (isInfWord(body)) return sign * std.math.inf(f64);
    if (std.mem.indexOfScalar(u8, body, ':') != null) return sexagesimalFloat(body, sign);
    return decimalFloat(body, sign, s.len != body.len);
}

fn isNanWord(s: []const u8) bool {
    return std.mem.eql(u8, s, ".nan") or std.mem.eql(u8, s, ".NaN") or std.mem.eql(u8, s, ".NAN");
}

fn isInfWord(s: []const u8) bool {
    return std.mem.eql(u8, s, ".inf") or std.mem.eql(u8, s, ".Inf") or std.mem.eql(u8, s, ".INF");
}

fn decimalFloat(body: []const u8, sign: f64, signed: bool) ?f64 {
    if (body.len == 0 or body.len > 127) return null;
    if (body[0] == '.' and signed) return null;
    var buf: [130]u8 = undefined;
    var n: usize = 0;
    if (body[0] == '.') {
        buf[n] = '0';
        n += 1;
    }
    var i: usize = 0;
    var dot = false;
    var digits: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '_') continue;
        if (c == '.') {
            if (dot) return null;
            dot = true;
            buf[n] = '.';
            n += 1;
            continue;
        }
        if (c < '0' or c > '9') break;
        digits += 1;
        buf[n] = c;
        n += 1;
    }
    if (!dot or digits == 0) return null;
    if (buf[n - 1] == '.') {
        buf[n] = '0';
        n += 1;
    }
    if (i < body.len) {
        if (body[i] != 'e' and body[i] != 'E') return null;
        i += 1;
        if (i >= body.len or (body[i] != '+' and body[i] != '-')) return null;
        buf[n] = 'e';
        buf[n + 1] = body[i];
        n += 2;
        i += 1;
        var exp_digits: usize = 0;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            if (c < '0' or c > '9') return null;
            buf[n] = c;
            n += 1;
            exp_digits += 1;
        }
        if (exp_digits == 0) return null;
    }
    if (i != body.len) return null;
    const f = std.fmt.parseFloat(f64, buf[0..n]) catch return null;
    return sign * f;
}

fn sexagesimalFloat(body: []const u8, sign: f64) ?f64 {
    var value: f64 = 0;
    var rest = body;
    var first = true;
    while (rest.len > 0) {
        const colon = std.mem.indexOfScalar(u8, rest, ':');
        const part = if (colon) |c| rest[0..c] else rest;
        rest = if (colon) |c| rest[c + 1 ..] else &.{};
        var d: f64 = 0;
        if (first) {
            d = @floatFromInt(digitsOf(part, 10, .any) orelse return null);
        } else if (std.mem.indexOfScalar(u8, part, '.') != null) {
            if (colon != null) return null;
            const dot = std.mem.indexOfScalar(u8, part, '.').?;
            const mins: f64 = @floatFromInt(minuteOf(part[0..dot]) orelse return null);
            const frac = fractionOf(part[dot + 1 ..]) orelse return null;
            d = mins + frac;
        } else {
            d = @floatFromInt(minuteOf(part) orelse return null);
        }
        first = false;
        value = value * 60 + d;
    }
    return sign * value;
}

fn fractionOf(frac: []const u8) ?f64 {
    if (frac.len == 0) return 0;
    var buf: [66]u8 = undefined;
    buf[0] = '0';
    buf[1] = '.';
    var n: usize = 2;
    for (frac) |c| {
        if (c == '_') continue;
        if (c < '0' or c > '9') return null;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    if (n == 2) return 0;
    return std.fmt.parseFloat(f64, buf[0..n]) catch null;
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

test "quoted and block scalars are strings" {
    const parser = @import("parser.zig");
    const src =
        \\empty_double: ""
        \\empty_single: ''
        \\mode: "0644"
        \\bool_word: "true"
        \\null_word: "null"
        \\literal: |
        \\  text
        \\
    ;
    var forest = try parser.parse(std.testing.allocator, src);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try toJson(arena.allocator(), forest.roots[0]);
    try std.testing.expectEqualStrings("", v.object.get("empty_double").?.string);
    try std.testing.expectEqualStrings("", v.object.get("empty_single").?.string);
    try std.testing.expectEqualStrings("0644", v.object.get("mode").?.string);
    try std.testing.expectEqualStrings("true", v.object.get("bool_word").?.string);
    try std.testing.expectEqualStrings("null", v.object.get("null_word").?.string);
    try std.testing.expectEqualStrings("text\n", v.object.get("literal").?.string);
}

test "plain scalars resolve per YAML 1.1" {
    const Case = struct { in: []const u8, out: Value };
    const cases = [_]Case{
        .{ .in = "", .out = .null },
        .{ .in = "~", .out = .null },
        .{ .in = "null", .out = .null },
        .{ .in = "NULL", .out = .null },
        .{ .in = "yes", .out = .{ .bool = true } },
        .{ .in = "ON", .out = .{ .bool = true } },
        .{ .in = "off", .out = .{ .bool = false } },
        .{ .in = "No", .out = .{ .bool = false } },
        .{ .in = "y", .out = .{ .string = "y" } },
        .{ .in = "42", .out = .{ .integer = 42 } },
        .{ .in = "-42", .out = .{ .integer = -42 } },
        .{ .in = "+5", .out = .{ .integer = 5 } },
        .{ .in = "1_000", .out = .{ .integer = 1000 } },
        .{ .in = "0x1f", .out = .{ .integer = 31 } },
        .{ .in = "0b1010", .out = .{ .integer = 10 } },
        .{ .in = "0644", .out = .{ .integer = 420 } },
        .{ .in = "08", .out = .{ .string = "08" } },
        .{ .in = "0o17", .out = .{ .string = "0o17" } },
        .{ .in = "12:30", .out = .{ .integer = 750 } },
        .{ .in = "2.5", .out = .{ .float = 2.5 } },
        .{ .in = "2.", .out = .{ .float = 2.0 } },
        .{ .in = ".5", .out = .{ .float = 0.5 } },
        .{ .in = "2.5e+3", .out = .{ .float = 2500.0 } },
        .{ .in = "1e3", .out = .{ .string = "1e3" } },
        .{ .in = "-.5", .out = .{ .string = "-.5" } },
        .{ .in = "190:20:30.15", .out = .{ .float = 685230.15 } },
        .{ .in = "1.0.0", .out = .{ .string = "1.0.0" } },
    };
    for (cases) |case| try std.testing.expectEqual(case.out, resolvePlain(case.in));
}
