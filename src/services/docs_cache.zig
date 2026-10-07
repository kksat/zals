//! On-disk cache for module docs (ADR-0008).
//!
//! Serializes the catalog and fetched module docs to a JSON file keyed by an
//! Ansible-version fingerprint, so a warm start avoids `ansible-doc` entirely.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const docs = @import("docs.zig");
const DocsLibrary = docs.DocsLibrary;
const json_util = @import("../lsp/json_util.zig");

pub const format_version = 3;

pub fn cacheDir(allocator: Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |base| {
            defer allocator.free(base);
            return std.fs.path.join(allocator, &.{ base, "zals", "cache" });
        } else |_| {}
    } else {
        if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |x| {
            defer allocator.free(x);
            return std.fs.path.join(allocator, &.{ x, "zals" });
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "HOME")) |h| {
            defer allocator.free(h);
            return std.fs.path.join(allocator, &.{ h, ".cache", "zals" });
        } else |_| {}
    }
    return error.NoCacheDir;
}

pub fn cachePath(allocator: Allocator, fingerprint: []const u8) ![]u8 {
    const dir = try cacheDir(allocator);
    defer allocator.free(dir);
    const name = try std.fmt.allocPrint(allocator, "docs-{s}.json", .{fingerprint});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

/// Persist the library's catalog and modules. Writes atomically via a temp file.
pub fn save(allocator: Allocator, lib: *DocsLibrary, path: []const u8) !void {
    // Build the JSON tree in a scratch arena so nested maps are freed at once.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.ObjectMap.init(a);
    try root.put("version", .{ .integer = format_version });
    try root.put("ansible_version", .{ .string = lib.ansible_version });

    lib.mutex.lock();
    defer lib.mutex.unlock();

    var cat = std.json.ObjectMap.init(a);
    var it = lib.catalog.iterator();
    while (it.next()) |e| try cat.put(e.key_ptr.*, .{ .string = e.value_ptr.description });
    try root.put("catalog", .{ .object = cat });

    var mods = std.json.ObjectMap.init(a);
    var mit = lib.modules.iterator();
    while (mit.next()) |e| {
        const m = e.value_ptr.*;
        var mo = std.json.ObjectMap.init(a);
        try mo.put("description", .{ .string = m.description });
        try mo.put("long_description", try stringArray(a, m.long_description));
        try mo.put("requirements", try stringArray(a, m.requirements));
        try mo.put("notes", try stringArray(a, m.notes));
        try mo.put("deprecated", .{ .bool = m.deprecated });
        try mo.put("filename", .{ .string = m.filename });
        var opts = std.json.ObjectMap.init(a);
        var oit = m.options.iterator();
        while (oit.next()) |oe| {
            try opts.put(oe.key_ptr.*, try optionToJson(a, oe.value_ptr.*));
        }
        try mo.put("options", .{ .object = opts });
        try mods.put(e.key_ptr.*, .{ .object = mo });
    }
    try root.put("modules", .{ .object = mods });

    const bytes = try std.json.Stringify.valueAlloc(allocator, Value{ .object = root }, .{});
    defer allocator.free(bytes);

    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(bytes);
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Load a cache file into the library. Returns false if absent or incompatible.
pub fn load(allocator: Allocator, lib: *DocsLibrary, path: []const u8) !bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    const bytes = f.readToEndAlloc(allocator, 128 * 1024 * 1024) catch return false;
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();

    const v = json_util.integer(parsed.value, "version") orelse return false;
    if (v != format_version) return false;

    const a = lib.arena.allocator();
    lib.mutex.lock();
    defer lib.mutex.unlock();

    if (json_util.string(parsed.value, "ansible_version")) |ver| {
        lib.ansible_version = try a.dupe(u8, ver);
    }

    if (json_util.object(parsed.value, "catalog")) |cat| {
        var it = cat.iterator();
        while (it.next()) |e| {
            const name = try a.dupe(u8, e.key_ptr.*);
            const desc = switch (e.value_ptr.*) {
                .string => |s| s,
                else => "",
            };
            try lib.catalog.put(name, .{ .name = name, .description = try a.dupe(u8, desc) });
        }
    }

    if (json_util.object(parsed.value, "modules")) |mods| {
        var it = mods.iterator();
        while (it.next()) |e| {
            const name = try a.dupe(u8, e.key_ptr.*);
            var options = std.StringHashMap(docs.Option).init(lib.allocator);
            if (json_util.object(e.value_ptr.*, "options")) |opts| {
                var oi = opts.iterator();
                while (oi.next()) |oe| {
                    const opt_name = try a.dupe(u8, oe.key_ptr.*);
                    var opt = try optionFromJson(a, oe.value_ptr.*);
                    opt.name = opt_name;
                    try options.put(opt_name, opt);
                }
            }
            try lib.modules.put(name, .{
                .name = name,
                .description = try a.dupe(u8, json_util.string(e.value_ptr.*, "description") orelse ""),
                .long_description = try stringList(a, json_util.field(e.value_ptr.*, "long_description") orelse Value.null),
                .requirements = try stringList(a, json_util.field(e.value_ptr.*, "requirements") orelse Value.null),
                .notes = try stringList(a, json_util.field(e.value_ptr.*, "notes") orelse Value.null),
                .deprecated = json_util.boolean(e.value_ptr.*, "deprecated") orelse false,
                .filename = try a.dupe(u8, json_util.string(e.value_ptr.*, "filename") orelse ""),
                .options = options,
            });
        }
    }

    lib.ready = true;
    return true;
}

fn optionToJson(a: Allocator, o: docs.Option) !Value {
    var oo = std.json.ObjectMap.init(a);
    try oo.put("description", .{ .string = o.description });
    try oo.put("type", .{ .string = o.type });
    try oo.put("required", .{ .bool = o.required });
    try oo.put("default", if (o.default) |d| .{ .string = d } else .null);
    try oo.put("elements", .{ .string = o.elements });
    if (o.suboptions.len > 0) {
        var subs = std.json.ObjectMap.init(a);
        for (o.suboptions) |s| try subs.put(s.name, try optionToJson(a, s));
        try oo.put("suboptions", .{ .object = subs });
    }
    return .{ .object = oo };
}

fn optionFromJson(a: Allocator, v: Value) !docs.Option {
    var sub: []const docs.Option = &.{};
    if (json_util.object(v, "suboptions")) |subs| {
        var list = std.ArrayList(docs.Option).empty;
        var it = subs.iterator();
        while (it.next()) |e| {
            var o = try optionFromJson(a, e.value_ptr.*);
            o.name = try a.dupe(u8, e.key_ptr.*);
            try list.append(a, o);
        }
        sub = try list.toOwnedSlice(a);
    }
    return .{
        .name = "",
        .description = try a.dupe(u8, json_util.string(v, "description") orelse ""),
        .type = try a.dupe(u8, json_util.string(v, "type") orelse ""),
        .required = json_util.boolean(v, "required") orelse false,
        .suboptions = sub,
        .default = if (json_util.string(v, "default")) |d| try a.dupe(u8, d) else null,
        .elements = try a.dupe(u8, json_util.string(v, "elements") orelse ""),
    };
}

fn stringArray(a: Allocator, items: []const []const u8) !Value {
    var arr = std.json.Array.init(a);
    for (items) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

fn stringList(a: Allocator, v: Value) ![]const []const u8 {
    switch (v) {
        .array => |arr| {
            var list = std.ArrayList([]const u8).empty;
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| try list.append(a, try a.dupe(u8, s)),
                    else => {},
                }
            }
            return try list.toOwnedSlice(a);
        },
        else => return &.{},
    }
}

test "cache round trip" {
    const allocator = std.testing.allocator;
    const runner = @import("../exec/root.zig").Posix.posixRunner();

    var lib = DocsLibrary.init(allocator, runner, "ansible-doc");
    defer lib.deinit();
    const a = lib.arena.allocator();
    try lib.catalog.put(try a.dupe(u8, "ansible.builtin.ping"), .{
        .name = "ansible.builtin.ping",
        .description = "ping module",
    });
    var opts = std.StringHashMap(docs.Option).init(allocator);
    try opts.put(try a.dupe(u8, "data"), .{
        .name = "data",
        .description = "data option",
        .type = "str",
        .required = true,
    });
    try lib.modules.put(try a.dupe(u8, "ansible.builtin.ping"), .{
        .name = "ansible.builtin.ping",
        .description = "ping module",
        .filename = "/x/ping.py",
        .options = opts,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const cache_file = try std.fs.path.join(allocator, &.{ dir, "docs.json" });
    defer allocator.free(cache_file);

    try save(allocator, &lib, cache_file);

    var lib2 = DocsLibrary.init(allocator, runner, "ansible-doc");
    defer lib2.deinit();
    try std.testing.expect(try load(allocator, &lib2, cache_file));
    try std.testing.expectEqual(@as(usize, 1), lib2.catalog.count());
    const m = lib2.modules.get("ansible.builtin.ping").?;
    try std.testing.expectEqualStrings("ping module", m.description);
    try std.testing.expectEqualStrings("/x/ping.py", m.filename);
    try std.testing.expectEqualStrings("str", m.options.get("data").?.type);
    try std.testing.expect(m.options.get("data").?.required);
}
