//! On-disk cache for module docs (ADR-0008).
//!
//! Serializes the catalog and fetched module docs to a JSON file keyed by an
//! Ansible-version fingerprint, so a warm start avoids `ansible-doc` entirely.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const docs = @import("docs.zig");
const DocsLibrary = docs.DocsLibrary;
const json_util = @import("../lsp/json_util.zig");

pub const format_version = 1;

pub fn cacheDir(allocator: Allocator) ![]u8 {
    if (std.posix.getenv("XDG_CACHE_HOME")) |x|
        return std.fs.path.join(allocator, &.{ x, "zals" });
    if (std.posix.getenv("HOME")) |h|
        return std.fs.path.join(allocator, &.{ h, ".cache", "zals" });
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
        try mo.put("filename", .{ .string = m.filename });
        var opts = std.json.ObjectMap.init(a);
        var oit = m.options.iterator();
        while (oit.next()) |oe| {
            const o = oe.value_ptr.*;
            var oo = std.json.ObjectMap.init(a);
            try oo.put("description", .{ .string = o.description });
            try oo.put("type", .{ .string = o.type });
            try oo.put("required", .{ .bool = o.required });
            try opts.put(oe.key_ptr.*, .{ .object = oo });
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
                    try options.put(opt_name, .{
                        .name = opt_name,
                        .description = try a.dupe(u8, json_util.string(oe.value_ptr.*, "description") orelse ""),
                        .type = try a.dupe(u8, json_util.string(oe.value_ptr.*, "type") orelse ""),
                        .required = json_util.boolean(oe.value_ptr.*, "required") orelse false,
                    });
                }
            }
            try lib.modules.put(name, .{
                .name = name,
                .description = try a.dupe(u8, json_util.string(e.value_ptr.*, "description") orelse ""),
                .filename = try a.dupe(u8, json_util.string(e.value_ptr.*, "filename") orelse ""),
                .options = options,
            });
        }
    }

    lib.ready = true;
    return true;
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