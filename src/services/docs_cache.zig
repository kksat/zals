//! On-disk cache for module docs (ADR-0008).
//!
//! Reads/writes the library-owned JSON representation, keyed by an Ansible-
//! version fingerprint, so a warm start avoids `ansible-doc` entirely. The
//! library encodes a coherent snapshot before this adapter performs disk I/O.

const std = @import("std");
const fsio = @import("../fsio.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const docs = @import("docs.zig");
const DocsLibrary = docs.DocsLibrary;
pub const format_version = docs.cache_format_version;

pub fn cacheDir(allocator: Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (fsio.getEnvVarOwned(allocator, "LOCALAPPDATA")) |base| {
            defer allocator.free(base);
            return std.fs.path.join(allocator, &.{ base, "zals", "cache" });
        }
    } else {
        if (fsio.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |x| {
            defer allocator.free(x);
            return std.fs.path.join(allocator, &.{ x, "zals" });
        }
        if (fsio.getEnvVarOwned(allocator, "HOME")) |h| {
            defer allocator.free(h);
            return std.fs.path.join(allocator, &.{ h, ".cache", "zals" });
        }
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

/// Persist the library's catalog and modules. Writes atomically via a temp file,
/// using owned bytes so no filesystem operation holds the library lock.
pub fn save(allocator: Allocator, lib: *DocsLibrary, path: []const u8) !void {
    const bytes = try lib.encodeCache(allocator);
    defer allocator.free(bytes);

    if (std.fs.path.dirname(path)) |dir| fsio.makePath(dir) catch {};
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try fsio.createFile(tmp, .{ .truncate = true });
        defer f.close(fsio.get());
        try f.writeStreamingAll(fsio.get(), bytes);
    }
    try fsio.rename(tmp, path);
}

/// Load a cache file into the library. Returns false if absent or incompatible.
pub fn load(allocator: Allocator, lib: *DocsLibrary, path: []const u8) !bool {
    const bytes = fsio.readFileAlloc(allocator, path, 128 * 1024 * 1024) catch return false;
    defer allocator.free(bytes);
    return lib.restoreCache(allocator, bytes);
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
    const opts = try a.dupe(docs.Option, &.{.{
        .name = "data",
        .description = "data option",
        .type = "str",
        .required = true,
    }});
    try lib.modules.put(try a.dupe(u8, "ansible.builtin.ping"), .{
        .name = "ansible.builtin.ping",
        .description = "ping module",
        .filename = "/x/ping.py",
        .options = opts,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try std.testing.expectEqualStrings("str", m.getOption("data").?.type);
    try std.testing.expect(m.getOption("data").?.required);
}
