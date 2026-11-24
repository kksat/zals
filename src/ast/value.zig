const std = @import("std");
const Allocator = std.mem.Allocator;
const cel_env = @import("../cel/env.zig");
const yaml_recover = @import("yaml_recover.zig");
const span_mod = @import("span.zig");

pub const ValueKind = enum(u8) {
    null_val,
    bool_val,
    int_val,
    float_val,
    string_val,
    template_val,
    list_val,
    map_val,

    pub fn name(self: ValueKind) []const u8 {
        return switch (self) {
            .null_val => "null",
            .bool_val => "bool",
            .int_val => "int",
            .float_val => "float",
            .string_val => "string",
            .template_val => "template",
            .list_val => "list",
            .map_val => "map",
        };
    }
};

pub const MapEntry = struct {
    key: []const u8,
    key_kind: ValueKind,
    key_quoted: bool,
    key_span: span_mod.Span,
    val: TypedValue,
};

pub const TypedValue = struct {
    kind: ValueKind,
    is_templated: bool = false,
    is_quoted: bool = false,
    raw: []const u8 = "",
    span: span_mod.Span = .{ .start = 0, .end = 0 },
    bool_v: bool = false,
    int_v: i64 = 0,
    float_v: f64 = 0,
    str_v: []const u8 = "",
    list_v: []const TypedValue = &.{},
    map_v: []const MapEntry = &.{},

    pub fn containsTemplate(self: TypedValue) bool {
        if (self.is_templated) return true;
        switch (self.kind) {
            .list_val => {
                for (self.list_v) |it| if (it.containsTemplate()) return true;
            },
            .map_val => {
                for (self.map_v) |e| {
                    if (hasJinjaDelimiters(e.key) or e.val.containsTemplate()) return true;
                }
            },
            else => {},
        }
        return false;
    }

    pub fn toCelPlain(self: TypedValue, alloc: Allocator) std.mem.Allocator.Error!cel_env.Value {
        return switch (self.kind) {
            .null_val => .{ .null_t = {} },
            .bool_val => .{ .bool_t = self.bool_v },
            .int_val => .{ .int_t = self.int_v },
            .float_val => .{ .double_t = self.float_v },
            .string_val, .template_val => .{ .string_t = self.str_v },
            .list_val => blk: {
                const items = try alloc.alloc(cel_env.Value, self.list_v.len);
                for (self.list_v, 0..) |it, i| {
                    items[i] = try it.toCelPlain(alloc);
                }
                break :blk .{ .list_t = items };
            },
            .map_val => blk: {
                var b = cel_env.MapBuilder.init();
                errdefer b.deinit(alloc);
                var seen = std.StringHashMapUnmanaged(void).empty;
                for (self.map_v) |e| {
                    if (seen.contains(e.key)) continue;
                    try seen.put(alloc, e.key, {});
                    try b.put(alloc, e.key, try e.val.toCelPlain(alloc));
                }
                break :blk b.finish(alloc) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.RepeatedKey => cel_env.emptyMapValue(),
                };
            },
        };
    }

    pub fn toCelTyped(self: TypedValue, alloc: Allocator) std.mem.Allocator.Error!cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "kind", self.kind.name());
        try b.putBool(alloc, "is_templated", self.is_templated);
        try b.putBool(alloc, "is_quoted", self.is_quoted);
        try b.putString(alloc, "raw", self.raw);
        try b.put(alloc, "value", try self.toCelPlain(alloc));
        return b.finish(alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RepeatedKey => cel_env.emptyMapValue(),
        };
    }
};

pub fn hasJinjaDelimiters(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "{{") != null or
        std.mem.indexOf(u8, s, "{%") != null or
        std.mem.indexOf(u8, s, "{#") != null;
}

pub fn fromYaml(alloc: Allocator, node: ?*const yaml_recover.YamlNode) std.mem.Allocator.Error!TypedValue {
    const n = node orelse return .{ .kind = .null_val };
    return fromYamlDepth(alloc, n, 0);
}

fn fromYamlDepth(alloc: Allocator, n: *const yaml_recover.YamlNode, depth: usize) std.mem.Allocator.Error!TypedValue {
    const sp = span_mod.Span{ .start = n.start, .end = n.end };
    if (depth > 32) {
        return .{ .kind = .null_val, .raw = n.raw, .span = sp };
    }
    switch (n.kind) {
        .scalar => return fromScalar(n, sp),
        .alias => {
            const name = n.value orelse "";
            return .{ .kind = .string_val, .raw = n.raw, .span = sp, .str_v = name };
        },
        .seq => {
            const list = try alloc.alloc(TypedValue, n.items.len);
            var templated = false;
            for (n.items, 0..) |it, i| {
                list[i] = try fromYamlDepth(alloc, it, depth + 1);
                if (list[i].is_templated) templated = true;
            }
            return .{ .kind = .list_val, .is_templated = templated, .raw = n.raw, .span = sp, .list_v = list };
        },
        .map => {
            var entries = std.ArrayList(MapEntry).empty;
            var templated = false;
            for (n.items) |pair| {
                if (pair.kind != .pair) continue;
                const k = pair.key orelse continue;
                const kt = try fromYamlDepth(alloc, k, depth + 1);
                const key_str: []const u8 = switch (kt.kind) {
                    .string_val, .template_val => kt.str_v,
                    else => k.value orelse k.raw,
                };
                const vt = if (pair.val) |v| try fromYamlDepth(alloc, v, depth + 1) else TypedValue{
                    .kind = .null_val,
                    .span = .{ .start = pair.end, .end = pair.end },
                };
                if (kt.is_templated or vt.is_templated) templated = true;
                try entries.append(alloc, .{
                    .key = key_str,
                    .key_kind = kt.kind,
                    .key_quoted = kt.is_quoted,
                    .key_span = .{ .start = k.start, .end = k.end },
                    .val = vt,
                });
            }
            return .{
                .kind = .map_val,
                .is_templated = templated,
                .raw = n.raw,
                .span = sp,
                .map_v = try entries.toOwnedSlice(alloc),
            };
        },
        .pair => return .{ .kind = .null_val, .raw = n.raw, .span = sp },
    }
}

fn fromScalar(n: *const yaml_recover.YamlNode, sp: span_mod.Span) TypedValue {
    const val = n.value orelse "";
    const quoted = n.scalar_style.isQuoted();

    if (n.scalar_style == .empty) {
        return .{ .kind = .null_val, .raw = n.raw, .span = sp };
    }

    if (n.tag) |tag| {
        if (std.mem.eql(u8, tag, "!!str") or std.mem.eql(u8, tag, "tag:yaml.org,2002:str")) {
            const templated = hasJinjaDelimiters(val);
            return .{
                .kind = if (templated) .template_val else .string_val,
                .is_templated = templated,
                .is_quoted = quoted,
                .raw = n.raw,
                .span = sp,
                .str_v = val,
            };
        }
    }

    if (quoted or n.scalar_style == .literal_block or n.scalar_style == .folded_block) {
        const templated = hasJinjaDelimiters(val);
        return .{
            .kind = if (templated) .template_val else .string_val,
            .is_templated = templated,
            .is_quoted = quoted,
            .raw = n.raw,
            .span = sp,
            .str_v = val,
        };
    }

    if (val.len == 0 or
        std.mem.eql(u8, val, "~") or
        std.mem.eql(u8, val, "null") or
        std.mem.eql(u8, val, "Null") or
        std.mem.eql(u8, val, "NULL"))
    {
        return .{ .kind = .null_val, .raw = n.raw, .span = sp, .str_v = val };
    }

    if (parseYamlBool(val)) |b| {
        return .{ .kind = .bool_val, .raw = n.raw, .span = sp, .bool_v = b, .str_v = val };
    }

    if (parseYamlInt(val)) |iv| {
        return .{ .kind = .int_val, .raw = n.raw, .span = sp, .int_v = iv, .str_v = val };
    }

    if (parseYamlFloat(val)) |fv| {
        return .{ .kind = .float_val, .raw = n.raw, .span = sp, .float_v = fv, .str_v = val };
    }

    const templated = hasJinjaDelimiters(val);
    return .{
        .kind = if (templated) .template_val else .string_val,
        .is_templated = templated,
        .is_quoted = false,
        .raw = n.raw,
        .span = sp,
        .str_v = val,
    };
}

pub fn parseYamlBool(s: []const u8) ?bool {
    const trues = [_][]const u8{ "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON" };
    for (trues) |t| if (std.mem.eql(u8, s, t)) return true;
    const falses = [_][]const u8{ "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF" };
    for (falses) |f| if (std.mem.eql(u8, s, f)) return false;
    return null;
}

pub fn parseYamlInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        return std.fmt.parseInt(i64, s[2..], 16) catch null;
    }
    if (std.mem.startsWith(u8, s, "0o") or std.mem.startsWith(u8, s, "0O")) {
        return std.fmt.parseInt(i64, s[2..], 8) catch null;
    }
    if (s.len > 1 and s[0] == '0' and isAllOctal(s[1..])) {
        return std.fmt.parseInt(i64, s[1..], 8) catch null;
    }
    if (s[0] == '+' or s[0] == '-' or std.ascii.isDigit(s[0])) {
        return std.fmt.parseInt(i64, s, 10) catch null;
    }
    return null;
}

fn isAllOctal(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '7') return false;
    }
    return true;
}

fn parseYamlFloat(s: []const u8) ?f64 {
    if (std.mem.indexOfScalar(u8, s, '.') == null and
        std.mem.indexOfScalar(u8, s, 'e') == null and
        std.mem.indexOfScalar(u8, s, 'E') == null) return null;
    if (s.len == 0) return null;
    if (!(s[0] == '+' or s[0] == '-' or s[0] == '.' or std.ascii.isDigit(s[0]))) return null;
    const v = std.fmt.parseFloat(f64, s) catch return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return v;
}

test "quoted booleans remain strings while unquoted booleans and templates are typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\a: true
        \\b: "true"
        \\c: "{{ my_var }}"
        \\d: null
        \\e: 0644
        \\f: "0644"
        \\
    ;
    const rec = try yaml_recover.parse(a, src);
    const root = rec.documents[0].root.?;

    const va = try fromYaml(a, root.findPair("a").?.val);
    try std.testing.expectEqual(ValueKind.bool_val, va.kind);
    try std.testing.expect(va.bool_v);

    const vb = try fromYaml(a, root.findPair("b").?.val);
    try std.testing.expectEqual(ValueKind.string_val, vb.kind);
    try std.testing.expect(vb.is_quoted);
    try std.testing.expectEqualStrings("true", vb.str_v);

    const vc = try fromYaml(a, root.findPair("c").?.val);
    try std.testing.expectEqual(ValueKind.template_val, vc.kind);
    try std.testing.expect(vc.is_templated);

    const vd = try fromYaml(a, root.findPair("d").?.val);
    try std.testing.expectEqual(ValueKind.null_val, vd.kind);

    const ve = try fromYaml(a, root.findPair("e").?.val);
    try std.testing.expectEqual(ValueKind.int_val, ve.kind);
    try std.testing.expectEqual(@as(i64, 0o644), ve.int_v);
    try std.testing.expectEqualStrings("0644", ve.raw);

    const vf = try fromYaml(a, root.findPair("f").?.val);
    try std.testing.expectEqual(ValueKind.string_val, vf.kind);
    try std.testing.expectEqualStrings("0644", vf.str_v);
}

test "nested list and map values propagate is_templated to the enclosing value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\plain_list:
        \\  - a
        \\  - 1
        \\tpl_list:
        \\  - a
        \\  - "{{ dynamic }}"
        \\plain_map:
        \\  host: localhost
        \\  port: 8080
        \\tpl_map_val:
        \\  nested:
        \\    host: "{{ ansible_host }}"
        \\tpl_map_key:
        \\  "{{ dyn_key }}": ok
        \\
    ;
    const rec = try yaml_recover.parse(a, src);
    const root = rec.documents[0].root.?;

    const plain_list = try fromYaml(a, root.findPair("plain_list").?.val);
    try std.testing.expect(!plain_list.is_templated);

    const tpl_list = try fromYaml(a, root.findPair("tpl_list").?.val);
    try std.testing.expect(tpl_list.is_templated);

    const plain_map = try fromYaml(a, root.findPair("plain_map").?.val);
    try std.testing.expect(!plain_map.is_templated);

    const tpl_map_val = try fromYaml(a, root.findPair("tpl_map_val").?.val);
    try std.testing.expect(tpl_map_val.is_templated);

    const tpl_map_key = try fromYaml(a, root.findPair("tpl_map_key").?.val);
    try std.testing.expect(tpl_map_key.is_templated);
}
