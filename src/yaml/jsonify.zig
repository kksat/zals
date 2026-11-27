//! Lower the YAML DOM into `std.json.Value` for schema validation (ADR-0053).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Node = @import("dom.zig").Node;
const python_json = @import("python_json.zig");

pub fn toJson(arena: Allocator, node: *const Node) !Value {
    var ctx = Ctx{ .arena = arena, .anchors = std.StringHashMap(*const Node).init(arena) };
    try collectAnchors(&ctx, node);
    return lower(&ctx, node, 0);
}

const Ctx = struct {
    arena: Allocator,
    anchors: std.StringHashMap(*const Node),
};

fn collectAnchors(ctx: *Ctx, node: *const Node) error{OutOfMemory}!void {
    if (node.anchor) |name| try ctx.anchors.put(name, node);
    switch (node.kind) {
        .map, .seq => for (node.items) |it| try collectAnchors(ctx, it),
        .pair => {
            if (node.key) |k| try collectAnchors(ctx, k);
            if (node.val) |v| try collectAnchors(ctx, v);
        },
        else => {},
    }
}

fn lower(ctx: *Ctx, node: *const Node, depth: usize) error{OutOfMemory}!Value {
    if (depth > 64) return .null;
    return switch (node.kind) {
        .alias => {
            const name = node.value orelse "";
            if (ctx.anchors.get(name)) |target| return lower(ctx, target, depth + 1);
            return .{ .string = name };
        },
        .scalar => lowerScalar(ctx, node),
        .seq => lowerSeq(ctx, node, depth),
        .map => lowerMap(ctx, node, depth),
        .pair => if (node.val) |v| lower(ctx, v, depth + 1) else Value.null,
    };
}

fn lowerScalar(ctx: *Ctx, node: *const Node) error{OutOfMemory}!Value {
    const s = node.stringValue() orelse "";
    if (node.tag) |tag| {
        if (applyTag(ctx, tag, node, s)) |v| return v;
    }
    return switch (node.style) {
        .quoted, .block => .{ .string = s },
        .plain => resolvePlain(ctx, s),
    };
}

fn applyTag(ctx: *Ctx, tag: []const u8, node: *const Node, s: []const u8) ?Value {
    if (std.mem.eql(u8, tag, "!!str") or std.mem.eql(u8, tag, "!unsafe"))
        return .{ .string = s };
    if (std.mem.eql(u8, tag, "!!null")) return .null;
    if (std.mem.eql(u8, tag, "!!bool")) return boolTagged(s);
    if (std.mem.eql(u8, tag, "!!int")) return intOf(ctx.arena, s) catch null;
    if (std.mem.eql(u8, tag, "!!float")) return floatTagged(s);
    if (std.mem.eql(u8, tag, "!!timestamp")) return timestampOf(ctx.arena, s, true);
    if (std.mem.eql(u8, tag, "!!binary")) return binaryTagged(ctx.arena, s);
    if (std.mem.eql(u8, tag, "!vault")) return vaultTagged(ctx.arena, s);
    return switch (node.style) {
        .quoted, .block => .{ .string = s },
        .plain => resolvePlain(ctx, s) catch null,
    };
}

fn boolTagged(s: []const u8) ?Value {
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return null;
    const lower_s = std.ascii.lowerString(buf[0..s.len], s);
    const trues = [_][]const u8{ "true", "yes", "on" };
    const falses = [_][]const u8{ "false", "no", "off" };
    for (trues) |w| if (std.mem.eql(u8, lower_s, w)) return .{ .bool = true };
    for (falses) |w| if (std.mem.eql(u8, lower_s, w)) return .{ .bool = false };
    return null;
}

fn floatTagged(s: []const u8) ?Value {
    if (floatOf(s)) |f| return .{ .float = f };
    var buf: [128]u8 = undefined;
    if (s.len > buf.len) return null;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    const f = std.fmt.parseFloat(f64, buf[0..n]) catch return null;
    return .{ .float = f };
}

fn binaryTagged(a: Allocator, s: []const u8) ?Value {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(trimmed) catch return null;
    const buf = a.alloc(u8, len) catch return null;
    decoder.decode(buf, trimmed) catch return null;
    return .{ .string = buf };
}

fn vaultTagged(a: Allocator, s: []const u8) ?Value {
    var obj: std.json.ObjectMap = .empty;
    obj.put(a, "__ansible_vault", .{ .string = s }) catch return null;
    return .{ .object = obj };
}
fn lowerSeq(ctx: *Ctx, node: *const Node, depth: usize) error{OutOfMemory}!Value {
    if (node.tag) |tag| {
        if (std.mem.eql(u8, tag, "!!omap")) {
            if (omapOf(ctx, node, depth)) |v| return v;
        }
    }
    var arr = std.json.Array.init(ctx.arena);
    for (node.items) |item| try arr.append(try lower(ctx, item, depth + 1));
    return .{ .array = arr };
}

fn omapOf(ctx: *Ctx, node: *const Node, depth: usize) ?Value {
    var arr = std.json.Array.init(ctx.arena);
    for (node.items) |item| {
        if (item.kind != .map or item.items.len != 1) return null;
        const pair = item.items[0];
        const key = keyText(ctx, keyResolvedValue(ctx, pair.key) orelse return null) orelse return null;
        const val = lower(ctx, pair.val orelse return null, depth + 1) catch return null;
        var entry = std.json.Array.init(ctx.arena);
        entry.append(.{ .string = key }) catch return null;
        entry.append(val) catch return null;
        arr.append(.{ .array = entry }) catch return null;
    }
    return .{ .array = arr };
}

fn lowerMap(ctx: *Ctx, node: *const Node, depth: usize) error{OutOfMemory}!Value {
    var obj: std.json.ObjectMap = .empty;
    var keys = std.ArrayList(KeyEntry).empty;
    var merged = std.ArrayList(MergedEntry).empty;
    for (node.items) |pair| {
        if (isMergeKey(pair.key)) {
            collectMerge(ctx, pair.val, &merged, depth + 1) catch {};
            continue;
        }
        const key_value = keyResolvedValue(ctx, pair.key) orelse continue;
        const key = keyText(ctx, key_value) orelse continue;
        const val = if (pair.val) |v| try lower(ctx, v, depth + 1) else Value.null;
        var hit: ?[]const u8 = null;
        for (keys.items) |entry| {
            if (pythonKeyEqual(entry.value, key_value)) {
                hit = entry.text;
                break;
            }
        }
        if (hit) |text| {
            try obj.put(ctx.arena, text, val);
        } else {
            try keys.append(ctx.arena, .{ .text = key, .value = key_value });
            try obj.put(ctx.arena, key, val);
        }
    }
    for (merged.items) |entry| {
        if (!obj.contains(entry.key)) try obj.put(ctx.arena, entry.key, entry.val);
    }
    return .{ .object = obj };
}

const KeyEntry = struct { text: []const u8, value: Value };

fn pythonKeyEqual(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        .bool, .integer, .float, .number_string => switch (b) {
            .bool, .integer, .float, .number_string => numericKeyOf(a) == numericKeyOf(b),
            else => false,
        },
        else => false,
    };
}

fn numericKeyOf(v: Value) f64 {
    return switch (v) {
        .bool => |b| if (b) 1 else 0,
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

const MergedEntry = struct { key: []const u8, val: Value };

fn isMergeKey(key: ?*const Node) bool {
    const k = key orelse return false;
    if (k.kind != .scalar or k.tag != null or k.style != .plain) return false;
    return std.mem.eql(u8, k.stringValue() orelse "", "<<");
}

fn collectMerge(ctx: *Ctx, node: ?*const Node, merged: *std.ArrayList(MergedEntry), depth: usize) !void {
    const target = node orelse return;
    if (depth > 64) return;
    const v = try lower(ctx, target, depth);
    switch (v) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |kv| {
                var seen = false;
                for (merged.items) |entry| {
                    if (std.mem.eql(u8, entry.key, kv.key_ptr.*)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try merged.append(ctx.arena, .{ .key = kv.key_ptr.*, .val = kv.value_ptr.* });
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                var it = item.object.iterator();
                while (it.next()) |kv| {
                    var seen = false;
                    for (merged.items) |entry| {
                        if (std.mem.eql(u8, entry.key, kv.key_ptr.*)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try merged.append(ctx.arena, .{ .key = kv.key_ptr.*, .val = kv.value_ptr.* });
                }
            }
        },
        else => {},
    }
}

fn keyResolvedValue(ctx: *Ctx, key: ?*const Node) ?Value {
    const k = key orelse return null;
    if (k.kind != .scalar) return null;
    return lowerScalar(ctx, k) catch null;
}

fn keyText(ctx: *Ctx, v: Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .integer => |n| std.fmt.allocPrint(ctx.arena, "{d}", .{n}) catch null,
        .number_string => |s| s,
        .float => |f| python_json.floatText(ctx.arena, f) catch null,
        else => null,
    };
}

fn resolvePlain(ctx: *Ctx, s: []const u8) error{OutOfMemory}!Value {
    if (s.len == 0) return .null;
    if (boolOf(s)) |b| return .{ .bool = b };
    if (isNullLiteral(s)) return .null;
    if (try intOf(ctx.arena, s)) |v| return v;
    if (floatOf(s)) |f| return .{ .float = f };
    if (timestampOf(ctx.arena, s, false)) |v| return v;
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

fn intOf(a: Allocator, s: []const u8) error{OutOfMemory}!?Value {
    var sign: i64 = 1;
    var negative = false;
    var body = s;
    if (body.len > 1 and (body[0] == '-' or body[0] == '+')) {
        if (body[0] == '-') {
            sign = -1;
            negative = true;
        }
        body = body[1..];
    }
    if (std.mem.eql(u8, body, "0")) return .{ .integer = 0 };
    if (body.len > 2 and body[0] == '0' and body[1] == 'b')
        return intRun(a, body[2..], 2, sign, negative, .any);
    if (body.len > 2 and body[0] == '0' and body[1] == 'x')
        return intRun(a, body[2..], 16, sign, negative, .any);
    if (body.len > 1 and body[0] == '0')
        return intRun(a, body[1..], 8, sign, negative, .any);
    if (std.mem.indexOfScalar(u8, body, ':') != null) {
        if (sexagesimalInt(body, sign)) |n| return .{ .integer = n };
        return null;
    }
    return intRun(a, body, 10, sign, negative, .nonzero);
}

fn intRun(a: Allocator, s: []const u8, base: u8, sign: i64, negative: bool, start: Start) error{OutOfMemory}!?Value {
    if (!digitsValid(s, base, start)) return null;
    if (digitsOf(s, base, start)) |n| return .{ .integer = sign * n };
    return .{ .number_string = try bigNumberText(a, s, base, negative) };
}

const Start = enum { any, nonzero };

fn digitsValid(s: []const u8, base: u8, start: Start) bool {
    var saw_digit = false;
    var first_char = true;
    for (s) |c| {
        if (c == '_') {
            first_char = false;
            continue;
        }
        const d = std.fmt.charToDigit(c, base) catch return false;
        if (first_char and start == .nonzero and d == 0) return false;
        first_char = false;
        saw_digit = true;
    }
    return saw_digit;
}

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

fn bigNumberText(a: Allocator, s: []const u8, base: u8, negative: bool) ![]const u8 {
    var digits = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '_') continue;
        const d = std.fmt.charToDigit(c, base) catch continue;
        var carry: u32 = d;
        for (digits.items) |*p| {
            const v = @as(u32, p.*) * @as(u32, base) + carry;
            p.* = @intCast(v % 10);
            carry = v / 10;
        }
        while (carry > 0) {
            try digits.append(a, @intCast(carry % 10));
            carry /= 10;
        }
    }
    if (digits.items.len == 0) try digits.append(a, 0);
    while (digits.items.len > 1 and digits.items[digits.items.len - 1] == 0)
        _ = digits.pop();
    var buf = std.ArrayList(u8).empty;
    if (negative) try buf.append(a, '-');
    var i = digits.items.len;
    while (i > 0) {
        i -= 1;
        try buf.append(a, '0' + digits.items[i]);
    }
    return buf.toOwnedSlice(a);
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

fn timestampOf(a: Allocator, s: []const u8, short_date: bool) ?Value {
    var i: usize = 0;
    if (s.len < 8) return null;
    const year = fourDigits(s[0..4]) orelse return null;
    if (year == 0 or s[4] != '-') return null;
    i = 5;
    const month_at = i;
    const month = readNum(s, &i, 1, 2) orelse return null;
    if (i >= s.len or s[i] != '-') return null;
    i += 1;
    const day_at = i;
    const day = readNum(s, &i, 1, 2) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var buf: [40]u8 = undefined;
    if (i == s.len) {
        if (!short_date and (i - month_at != 2 or i - day_at != 2)) return null;
        const text = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return null;
        return .{ .string = a.dupe(u8, text) catch return null };
    }
    if (s[i] == 'T' or s[i] == 't') {
        i += 1;
    } else {
        const before = i;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i == before) return null;
    }
    const hour = readNum(s, &i, 1, 2) orelse return null;
    if (i >= s.len or s[i] != ':') return null;
    i += 1;
    const minute = twoDigits(s, &i) orelse return null;
    if (i >= s.len or s[i] != ':') return null;
    i += 1;
    const second = twoDigits(s, &i) orelse return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var fraction: []const u8 = "";
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        fraction = s[start..i];
    }
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var tz_buf: [8]u8 = undefined;
    var tz: []const u8 = "";
    if (i < s.len and s[i] == 'Z') {
        i += 1;
        tz = "+00:00";
    } else if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        const sign = s[i];
        i += 1;
        const tzh = readNum(s, &i, 1, 2) orelse return null;
        var tzm: u32 = 0;
        if (i < s.len and s[i] == ':') {
            i += 1;
            tzm = twoDigits(s, &i) orelse return null;
        }
        if (tzh > 23 or tzm > 59) return null;
        tz = std.fmt.bufPrint(&tz_buf, "{c}{d:0>2}:{d:0>2}", .{ sign, tzh, tzm }) catch return null;
    }
    if (i != s.len) return null;

    var frac_buf: [8]u8 = undefined;
    var frac_text: []const u8 = "";
    if (fraction.len > 0) {
        var six: [6]u8 = .{ '0', '0', '0', '0', '0', '0' };
        var nonzero = false;
        for (fraction, 0..) |c, j| {
            if (j >= 6) break;
            six[j] = c;
            if (c != '0') nonzero = true;
        }
        if (nonzero) {
            frac_text = std.fmt.bufPrint(&frac_buf, ".{s}", .{six}) catch return null;
        }
    }
    const text = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}{s}", .{
        year, month, day, hour, minute, second, frac_text, tz,
    }) catch return null;
    return .{ .string = a.dupe(u8, text) catch return null };
}

fn fourDigits(s: []const u8) ?u32 {
    if (s.len < 4) return null;
    var v: u32 = 0;
    for (s[0..4]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn twoDigits(s: []const u8, i: *usize) ?u32 {
    if (i.* + 2 > s.len) return null;
    if (s[i.*] < '0' or s[i.*] > '9' or s[i.* + 1] < '0' or s[i.* + 1] > '9') return null;
    const v = @as(u32, s[i.*] - '0') * 10 + (s[i.* + 1] - '0');
    i.* += 2;
    return v;
}

fn readNum(s: []const u8, i: *usize, min: usize, max: usize) ?u32 {
    var v: u32 = 0;
    var count: usize = 0;
    while (i.* < s.len and count < max and s[i.*] >= '0' and s[i.*] <= '9') {
        v = v * 10 + (s[i.*] - '0');
        i.* += 1;
        count += 1;
    }
    if (count < min) return null;
    return v;
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = Ctx{ .arena = arena.allocator(), .anchors = undefined };
    ctx.anchors = std.StringHashMap(*const Node).init(arena.allocator());
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
        .{ .in = "2024-1-1", .out = .{ .string = "2024-1-1" } },
        .{ .in = "2024-01-01", .out = .{ .string = "2024-01-01" } },
        .{ .in = "2024-01-01T10:20:30Z", .out = .{ .string = "2024-01-01T10:20:30+00:00" } },
        .{ .in = "2024-01-01 10:20:30", .out = .{ .string = "2024-01-01T10:20:30" } },
        .{ .in = "2024-01-01T10:20:30.5", .out = .{ .string = "2024-01-01T10:20:30.500000" } },
        .{ .in = "2024-01-01T10:20:30.000", .out = .{ .string = "2024-01-01T10:20:30" } },
        .{ .in = "2024-01-01T10:20:30+5", .out = .{ .string = "2024-01-01T10:20:30+05:00" } },
        .{ .in = "2024-01-01T10:20:30.1234567", .out = .{ .string = "2024-01-01T10:20:30.123456" } },
        .{ .in = "2024-13-01", .out = .{ .string = "2024-13-01" } },
    };
    for (cases) |case| {
        const got = try resolvePlain(&ctx, case.in);
        if (case.out == .string and got == .string) {
            try std.testing.expectEqualStrings(case.out.string, got.string);
        } else {
            try std.testing.expectEqual(case.out, got);
        }
    }
}

test "anchors, aliases, and merge keys" {
    const yaml = @import("root.zig");
    const src =
        \\base: &b
        \\  a: 1
        \\  b: 2
        \\other: &o
        \\  c: 3
        \\merged:
        \\  <<: *b
        \\  b: 3
        \\list_merge:
        \\  <<: [*b, *o]
        \\alias: *b
        \\
    ;
    var forest = try yaml.parse(std.testing.allocator, src);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try toJson(arena.allocator(), forest.roots[0]);
    const merged = v.object.get("merged").?;
    try std.testing.expectEqual(@as(i64, 1), merged.object.get("a").?.integer);
    try std.testing.expectEqual(@as(i64, 3), merged.object.get("b").?.integer);
    const list_merge = v.object.get("list_merge").?;
    try std.testing.expectEqual(@as(i64, 3), list_merge.object.get("c").?.integer);
    const alias = v.object.get("alias").?;
    try std.testing.expectEqual(@as(usize, 2), alias.object.count());
}

test "tags lower like ansible constructors" {
    const yaml = @import("root.zig");
    const src =
        \\str_tag: !!str 5
        \\int_tag: !!int "7"
        \\float_tag: !!float 1
        \\bool_tag: !!bool YES
        \\null_tag: !!null ''
        \\ts_tag: !!timestamp 2024-1-1
        \\unsafe_tag: !unsafe foo
        \\binary_tag: !!binary aGVsbG8=
        \\vault_tag: !vault |
        \\  $ANSIBLE_VAULT;1.1;AES
        \\omap_tag: !!omap
        \\  - a: 1
        \\  - b: 2
        \\
    ;
    var forest = try yaml.parse(std.testing.allocator, src);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try toJson(arena.allocator(), forest.roots[0]);
    try std.testing.expectEqualStrings("5", v.object.get("str_tag").?.string);
    try std.testing.expectEqual(@as(i64, 7), v.object.get("int_tag").?.integer);
    try std.testing.expectEqual(@as(f64, 1.0), v.object.get("float_tag").?.float);
    try std.testing.expect(v.object.get("bool_tag").? == .bool);
    try std.testing.expect(v.object.get("null_tag").? == .null);
    try std.testing.expectEqualStrings("2024-01-01", v.object.get("ts_tag").?.string);
    try std.testing.expectEqualStrings("foo", v.object.get("unsafe_tag").?.string);
    try std.testing.expectEqualStrings("hello", v.object.get("binary_tag").?.string);
    try std.testing.expectEqualStrings("$ANSIBLE_VAULT;1.1;AES\n", v.object.get("vault_tag").?.object.get("__ansible_vault").?.string);
    const omap = v.object.get("omap_tag").?.array;
    try std.testing.expectEqual(@as(usize, 2), omap.items.len);
    try std.testing.expectEqualStrings("a", omap.items[0].array.items[0].string);
    try std.testing.expectEqual(@as(i64, 2), omap.items[1].array.items[1].integer);
}

test "non-string keys coerce like json.dumps" {
    const yaml = @import("root.zig");
    const src =
        \\on: yes
        \\1: one
        \\~: none
        \\2.5: two and a half
        \\12345678901234567890: big
        \\"quoted": kept
        \\
    ;
    var forest = try yaml.parse(std.testing.allocator, src);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try toJson(arena.allocator(), forest.roots[0]);
    try std.testing.expectEqualStrings("one", v.object.get("true").?.string);
    try std.testing.expect(v.object.get("1") == null);
    try std.testing.expect(v.object.get("null") != null);
    try std.testing.expect(v.object.get("2.5") != null);
    try std.testing.expect(v.object.get("12345678901234567890") != null);
    try std.testing.expect(v.object.get("quoted") != null);
}

test "big integers keep exact digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = (try intOf(a, "12345678901234567890")).?;
    try std.testing.expectEqualStrings("12345678901234567890", big.number_string);
    const neg = (try intOf(a, "-12345678901234567890")).?;
    try std.testing.expectEqualStrings("-12345678901234567890", neg.number_string);
    const hex = (try intOf(a, "0xfffffffffffffffff")).?;
    try std.testing.expectEqualStrings("295147905179352825855", hex.number_string);
}

test "ansible-core YAML parity" {
    const fsio = @import("../fsio.zig");
    const yaml = @import("root.zig");
    const a = std.testing.allocator;

    var dir = fsio.openDir("test/fixtures/yaml-parity", .{ .iterate = true }) catch |err| {
        std.debug.print("could not open parity corpus: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer dir.close(fsio.get());
    var walker = try dir.walk(a);
    defer walker.deinit();

    var checked: usize = 0;
    while (try walker.next(fsio.get())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".yaml")) continue;
        const text = try entry.dir.readFileAlloc(fsio.get(), entry.basename, a, .limited(1 << 20));
        defer a.free(text);

        const stem = entry.path[0 .. entry.path.len - ".yaml".len];
        const expected_path = try std.fmt.allocPrint(a, "{s}.json", .{stem});
        defer a.free(expected_path);
        const expected_text = dir.readFileAlloc(fsio.get(), expected_path, a, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer a.free(expected_text);

        var parsed = try std.json.parseFromSlice(Value, a, expected_text, .{});
        defer parsed.deinit();

        var forest = try yaml.parse(a, text);
        defer forest.deinit();
        try std.testing.expect(forest.roots.len > 0);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const actual = try toJson(arena.allocator(), forest.roots[0]);
        try expectJsonEqual(parsed.value, actual);
        checked += 1;
    }
    try std.testing.expect(checked > 5);
}

fn expectJsonEqual(expected: Value, actual: Value) !void {
    switch (expected) {
        .null => try std.testing.expect(actual == .null),
        .bool => |b| {
            try std.testing.expect(actual == .bool);
            try std.testing.expectEqual(b, actual.bool);
        },
        .integer => |n| {
            if (actual == .number_string) {
                const parsed = std.fmt.parseInt(i64, actual.number_string, 10) catch return error.TestUnexpectedResult;
                try std.testing.expectEqual(n, parsed);
                return;
            }
            try std.testing.expect(actual == .integer);
            try std.testing.expectEqual(n, actual.integer);
        },
        .float => |f| {
            if (actual == .number_string) {
                const parsed = std.fmt.parseFloat(f64, actual.number_string) catch return error.TestUnexpectedResult;
                try std.testing.expectEqual(f, parsed);
                return;
            }
            try std.testing.expect(actual == .float);
            try std.testing.expectEqual(f, actual.float);
        },
        .number_string => try std.testing.expect(actual == .number_string),
        .string => |s| {
            try std.testing.expect(actual == .string);
            try std.testing.expectEqualStrings(s, actual.string);
        },
        .array => |arr| {
            try std.testing.expect(actual == .array);
            try std.testing.expectEqual(arr.items.len, actual.array.items.len);
            for (arr.items, actual.array.items) |e, x| try expectJsonEqual(e, x);
        },
        .object => |obj| {
            try std.testing.expect(actual == .object);
            try std.testing.expectEqual(obj.count(), actual.object.count());
            var it = obj.iterator();
            while (it.next()) |kv| {
                const x = actual.object.get(kv.key_ptr.*) orelse {
                    std.debug.print("missing key: {s}\n", .{kv.key_ptr.*});
                    return error.TestUnexpectedResult;
                };
                try expectJsonEqual(kv.value_ptr.*, x);
            }
        },
    }
}
