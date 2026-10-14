//! Zig-native JSON Schema draft-07 subset validator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const regex = @import("regex.zig");

pub const Diagnostic = struct {
    message: []const u8,
};

pub fn validate(arena: Allocator, schema: Value, instance: Value) ![]const Diagnostic {
    var out = std.array_list.Managed(Diagnostic).init(arena);
    try walk(arena, &out, schema, instance, schema);
    return try out.toOwnedSlice();
}

fn walk(arena: Allocator, out: *std.array_list.Managed(Diagnostic), schema: Value, instance: Value, root: Value) !void {
    const sch = resolveRef(schema, root);

    if (json_util.string(sch, "type")) |ty| {
        if (!typeMatches(ty, instance)) {
            try out.append(.{ .message = try std.fmt.allocPrint(arena, "Incorrect type. Expected \"{s}\".", .{ty}) });
        }
    }

    if (json_util.array(sch, "enum")) |en| {
        var ok = false;
        for (en.items) |choice| {
            if (valuesEqual(choice, instance)) {
                ok = true;
                break;
            }
        }
        if (!ok) try out.append(.{ .message = "Value is not accepted. Valid values:" });
    }

    if (json_util.field(sch, "const")) |c| {
        if (!valuesEqual(c, instance)) {
            try out.append(.{ .message = "Value is not accepted. Valid values:" });
        }
    }

    if (json_util.array(sch, "allOf")) |all| {
        for (all.items) |sub| try walk(arena, out, sub, instance, root);
    }
    if (json_util.array(sch, "anyOf")) |any| {
        if (!matchesAny(arena, any.items, instance, root)) {
            try out.append(.{ .message = "Value is not accepted. Valid values:" });
        }
    }
    if (json_util.array(sch, "oneOf")) |one| {
        var hits: usize = 0;
        for (one.items) |sub| {
            if (matchesSchema(arena, sub, instance, root)) hits += 1;
        }
        if (hits != 1) try out.append(.{ .message = "Value is not accepted. Valid values:" });
    }
    if (json_util.field(sch, "not")) |n| {
        if (matchesSchema(arena, n, instance, root)) {
            try out.append(.{ .message = "Value is not accepted. Valid values:" });
        }
    }
    if (instance == .string) {
        if (json_util.integer(sch, "minLength")) |min| {
            if (instance.string.len < @as(usize, @intCast(min))) {
                try out.append(.{ .message = "Incorrect type. Expected \"string\"." });
            }
        }
        if (json_util.string(sch, "pattern")) |pat| {
            const ok = regex.matches(arena, pat, instance.string) catch |err| switch (err) {
                error.InvalidPattern => true,
                error.OutOfMemory => return err,
            };
            if (!ok) {
                try out.append(.{ .message = try std.fmt.allocPrint(arena, "String does not match pattern \"{s}\".", .{pat}) });
            }
        }
    }
    if (instance == .array) {
        if (json_util.field(sch, "items")) |items_schema| {
            for (instance.array.items) |item| try walk(arena, out, items_schema, item, root);
        }
    }

    if (instance != .object) return;
    const obj = instance.object;

    if (json_util.array(sch, "required")) |req| {
        for (req.items) |r| {
            const name = switch (r) {
                .string => |s| s,
                else => continue,
            };
            if (obj.get(name) == null) {
                try out.append(.{ .message = try std.fmt.allocPrint(arena, "Missing property \"{s}\".", .{name}) });
            }
        }
    }

    const props = json_util.object(sch, "properties");
    const additional = json_util.field(sch, "additionalProperties");
    var it = obj.iterator();
    while (it.next()) |e| {
        if (props) |p| {
            if (p.get(e.key_ptr.*)) |sub| {
                try walk(arena, out, sub, e.value_ptr.*, root);
                continue;
            }
        }
        if (additional) |add| {
            switch (add) {
                .bool => |b| if (!b) {
                    try out.append(.{ .message = try std.fmt.allocPrint(arena, "Unexpected property \"{s}\".", .{e.key_ptr.*}) });
                },
                .object => try walk(arena, out, add, e.value_ptr.*, root),
                else => {},
            }
        }
    }
}

fn matchesAny(arena: Allocator, options: []const Value, instance: Value, root: Value) bool {
    for (options) |sub| {
        if (matchesSchema(arena, sub, instance, root)) return true;
    }
    return false;
}

fn matchesSchema(arena: Allocator, schema: Value, instance: Value, root: Value) bool {
    const sch = resolveRef(schema, root);

    if (json_util.string(sch, "type")) |ty| {
        if (!typeMatches(ty, instance)) return false;
    }

    if (json_util.array(sch, "enum")) |en| {
        var ok = false;
        for (en.items) |choice| {
            if (valuesEqual(choice, instance)) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }

    if (json_util.field(sch, "const")) |c| {
        if (!valuesEqual(c, instance)) return false;
    }

    if (json_util.array(sch, "allOf")) |all| {
        for (all.items) |sub| {
            if (!matchesSchema(arena, sub, instance, root)) return false;
        }
    }
    if (json_util.array(sch, "anyOf")) |any| {
        if (!matchesAny(arena, any.items, instance, root)) return false;
    }
    if (json_util.array(sch, "oneOf")) |one| {
        var hits: usize = 0;
        for (one.items) |sub| {
            if (matchesSchema(arena, sub, instance, root)) hits += 1;
        }
        if (hits != 1) return false;
    }
    if (json_util.field(sch, "not")) |n| {
        if (matchesSchema(arena, n, instance, root)) return false;
    }
    if (instance == .string) {
        if (json_util.integer(sch, "minLength")) |min| {
            if (instance.string.len < @as(usize, @intCast(min))) return false;
        }
        if (json_util.string(sch, "pattern")) |pat| {
            var scratch = std.heap.ArenaAllocator.init(arena);
            defer scratch.deinit();
            const ok = regex.matches(scratch.allocator(), pat, instance.string) catch |err| switch (err) {
                error.InvalidPattern => true,
                error.OutOfMemory => return false,
            };
            if (!ok) return false;
        }
    }
    if (instance == .array) {
        if (json_util.field(sch, "items")) |items_schema| {
            for (instance.array.items) |item| {
                if (!matchesSchema(arena, items_schema, item, root)) return false;
            }
        }
    }

    if (instance != .object) return true;
    const obj = instance.object;

    if (json_util.array(sch, "required")) |req| {
        for (req.items) |r| {
            const name = switch (r) {
                .string => |s| s,
                else => continue,
            };
            if (obj.get(name) == null) return false;
        }
    }

    const props = json_util.object(sch, "properties");
    const additional = json_util.field(sch, "additionalProperties");
    var it = obj.iterator();
    while (it.next()) |e| {
        if (props) |p| {
            if (p.get(e.key_ptr.*)) |sub| {
                if (!matchesSchema(arena, sub, e.value_ptr.*, root)) return false;
                continue;
            }
        }
        if (additional) |add| {
            switch (add) {
                .bool => |b| if (!b) return false,
                .object => if (!matchesSchema(arena, add, e.value_ptr.*, root)) return false,
                else => {},
            }
        }
    }
    return true;
}

fn resolveRef(schema: Value, root: Value) Value {
    const ref = json_util.string(schema, "$ref") orelse return schema;
    if (std.mem.startsWith(u8, ref, "#/$defs/")) {
        if (json_util.object(root, "$defs")) |defs| {
            if (defs.get(ref["#/$defs/".len..])) |d| return d;
        }
    }
    return schema;
}

fn typeMatches(ty: []const u8, v: Value) bool {
    return switch (v) {
        .object => std.mem.eql(u8, ty, "object"),
        .array => std.mem.eql(u8, ty, "array"),
        .string => std.mem.eql(u8, ty, "string"),
        .integer, .number_string => std.mem.eql(u8, ty, "integer") or std.mem.eql(u8, ty, "number"),
        .float => std.mem.eql(u8, ty, "number"),
        .bool => std.mem.eql(u8, ty, "boolean"),
        .null => std.mem.eql(u8, ty, "null"),
    };
}

fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            else => false,
        },
        .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        else => false,
    };
}

test "required and type" {
    const allocator = std.testing.allocator;
    const schema_json =
        \\{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}
    ;
    const parsed_schema = try std.json.parseFromSlice(Value, allocator, schema_json, .{});
    defer parsed_schema.deinit();
    const inst_json = "{\"name\":1}";
    const parsed_inst = try std.json.parseFromSlice(Value, allocator, inst_json, .{});
    defer parsed_inst.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const diags = try validate(arena.allocator(), parsed_schema.value, parsed_inst.value);
    try std.testing.expect(diags.len >= 1);
}

test "pattern keyword" {
    const allocator = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","pattern":"^[a-z][a-z0-9_]*$"}}}
    ;
    const parsed_schema = try std.json.parseFromSlice(Value, allocator, schema_json, .{});
    defer parsed_schema.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const good = try std.json.parseFromSlice(Value, allocator, "{\"name\":\"my_var1\"}", .{});
    defer good.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try validate(arena.allocator(), parsed_schema.value, good.value)).len);

    const bad = try std.json.parseFromSlice(Value, allocator, "{\"name\":\"Bad-Name\"}", .{});
    defer bad.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try validate(arena.allocator(), parsed_schema.value, bad.value)).len);
}

test "anyOf oneOf not combinators without diagnostic allocation churn" {
    const allocator = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"val":{"anyOf":[{"type":"string","pattern":"^[a-z]+$"},{"type":"integer"}],"oneOf":[{"type":"string"},{"type":"integer"}],"not":{"const":"forbidden"}}}}
    ;
    const parsed_schema = try std.json.parseFromSlice(Value, allocator, schema_json, .{});
    defer parsed_schema.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const good_str = try std.json.parseFromSlice(Value, allocator, "{\"val\":\"allowed\"}", .{});
    defer good_str.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try validate(arena.allocator(), parsed_schema.value, good_str.value)).len);

    const good_int = try std.json.parseFromSlice(Value, allocator, "{\"val\":42}", .{});
    defer good_int.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try validate(arena.allocator(), parsed_schema.value, good_int.value)).len);

    const bad_not = try std.json.parseFromSlice(Value, allocator, "{\"val\":\"forbidden\"}", .{});
    defer bad_not.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try validate(arena.allocator(), parsed_schema.value, bad_not.value)).len);

    const bad_any = try std.json.parseFromSlice(Value, allocator, "{\"val\":\"UPPER\"}", .{});
    defer bad_any.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try validate(arena.allocator(), parsed_schema.value, bad_any.value)).len);
}
