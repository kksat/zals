//! Discovers module FQCNs by scanning installed collections and redirect
//! routes, mirroring upstream's `docsFinder`.
//!
//! Upstream offers completions for every module it can find on disk, including
//! redirect routes declared in `meta/runtime.yml`. `ansible-doc -l` only lists
//! modules that resolve, so we scan the filesystem directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("../exec/root.zig");
const yaml = @import("../yaml/root.zig");

pub const Index = struct {
    allocator: Allocator,
    runner: exec.Runner,
    /// FQCN → void. Keys are owned by `arena`.
    fqcns: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, runner: exec.Runner) Index {
        return .{
            .allocator = allocator,
            .runner = runner,
            .fqcns = std.StringHashMap(void).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Index) void {
        self.fqcns.deinit();
        self.arena.deinit();
    }

    pub fn scan(self: *Index) void {
        const a = self.arena.allocator();

        const ver = self.runner.run(self.allocator, &.{ "ansible", "--version" }) catch return;
        defer ver.deinit(self.allocator);
        const module_search = versionField(ver.stdout, "configured module search path");
        const ansible_location = versionField(ver.stdout, "ansible python module location");

        const cfg = self.runner.run(self.allocator, &.{ "ansible-config", "dump" }) catch null;
        defer if (cfg) |c| c.deinit(self.allocator);
        const collections_paths = if (cfg) |c| configField(c.stdout, "COLLECTIONS_PATHS") else null;

        if (ansible_location) |loc| {
            const modules_dir = std.fs.path.join(a, &.{ loc, "modules" }) catch return;
            self.scanBuiltin(a, modules_dir);
            const runtime = std.fs.path.join(a, &.{ loc, "config", "ansible_builtin_runtime.yml" }) catch return;
            self.scanRuntime(a, runtime, "ansible.builtin");
        }
        if (module_search) |ms| {
            const paths = parsePythonArray(a, ms) catch &.{};
            for (paths) |p| self.scanBuiltin(a, p);
        }
        if (collections_paths) |cp| {
            const paths = parsePythonArray(a, cp) catch &.{};
            for (paths) |p| self.scanCollections(a, p);
        }
    }

    fn add(self: *Index, a: Allocator, fqcn: []const u8) void {
        const key = a.dupe(u8, fqcn) catch return;
        self.fqcns.put(key, {}) catch {};
    }

    fn scanBuiltin(self: *Index, a: Allocator, dir: []const u8) void {
        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
        defer d.close();
        var walker = d.walk(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".py")) continue;
            if (std.mem.startsWith(u8, entry.basename, "_")) continue;
            const name = entry.basename[0 .. entry.basename.len - 3];
            const fqcn = std.fmt.allocPrint(a, "ansible.builtin.{s}", .{name}) catch continue;
            self.add(a, fqcn);
        }
    }

    fn scanCollections(self: *Index, a: Allocator, base: []const u8) void {
        const root = std.fs.path.join(a, &.{ base, "ansible_collections" }) catch return;
        var d = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
        defer d.close();
        var ns_it = d.iterate();
        while (ns_it.next() catch null) |ns_entry| {
            if (ns_entry.kind != .directory) continue;
            var ns_dir = d.openDir(ns_entry.name, .{ .iterate = true }) catch continue;
            defer ns_dir.close();
            var coll_it = ns_dir.iterate();
            while (coll_it.next() catch null) |coll_entry| {
                if (coll_entry.kind != .directory) continue;
                const modules_dir = std.fs.path.join(a, &.{
                    base, "ansible_collections", ns_entry.name, coll_entry.name, "plugins", "modules",
                }) catch continue;
                self.scanCollectionModules(a, modules_dir, ns_entry.name, coll_entry.name);
                const runtime = std.fs.path.join(a, &.{
                    base, "ansible_collections", ns_entry.name, coll_entry.name, "meta", "runtime.yml",
                }) catch continue;
                const collection = std.fmt.allocPrint(a, "{s}.{s}", .{ ns_entry.name, coll_entry.name }) catch continue;
                self.scanRuntime(a, runtime, collection);
            }
        }
    }

    fn scanCollectionModules(self: *Index, a: Allocator, dir: []const u8, ns: []const u8, coll: []const u8) void {
        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
        defer d.close();
        var walker = d.walk(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".py")) continue;
            if (std.mem.startsWith(u8, entry.basename, "_")) continue;
            const name = entry.basename[0 .. entry.basename.len - 3];
            // Subdirectories extend the collection name, e.g. `foo.bar.sub`.
            var collection = coll;
            if (std.fs.path.dirname(entry.path)) |sub| {
                const joined = std.mem.replaceOwned(u8, a, sub, "/", ".") catch continue;
                collection = std.fmt.allocPrint(a, "{s}.{s}", .{ coll, joined }) catch continue;
            }
            const fqcn = std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ ns, collection, name }) catch continue;
            self.add(a, fqcn);
        }
    }

    fn scanRuntime(self: *Index, a: Allocator, path: []const u8, collection: []const u8) void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024) catch return;
        defer self.allocator.free(bytes);
        var forest = yaml.parse(self.allocator, bytes) catch return;
        defer forest.deinit();
        if (forest.roots.len == 0) return;
        const pr = mapGet(forest.roots[0], "plugin_routing") orelse return;
        const modules = mapGet(pr, "modules") orelse return;
        if (!modules.isMap()) return;
        for (modules.items) |pair| {
            const key = pair.key orelse continue;
            const name = key.stringValue() orelse continue;
            const route = pair.val orelse continue;
            if (mapGet(route, "redirect") == null) continue;
            if (mapGet(route, "tombstone") != null) continue;
            const fqcn = std.fmt.allocPrint(a, "{s}.{s}", .{ collection, name }) catch continue;
            self.add(a, fqcn);
        }
    }
};

fn mapGet(node: *yaml.Node, key: []const u8) ?*yaml.Node {
    if (!node.isMap()) return null;
    for (node.items) |pair| {
        const k = pair.key orelse continue;
        const s = k.stringValue() orelse continue;
        if (std.mem.eql(u8, s, key)) return pair.val;
    }
    return null;
}

/// Extract `key = value` from `ansible --version` output.
fn versionField(stdout: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = trimmed[key.len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        return std.mem.trim(u8, rest[eq + 1 ..], " \t");
    }
    return null;
}

/// Extract `KEY(source) = value` from `ansible-config dump` output.
fn configField(stdout: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    }
    return null;
}

/// Parse a Python list repr like `['a', 'b']` into strings.
fn parsePythonArray(a: Allocator, s: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\'' or s[i] == '"') {
            const quote = s[i];
            i += 1;
            const start = i;
            while (i < s.len and s[i] != quote) : (i += 1) {}
            try list.append(a, try a.dupe(u8, s[start..i]));
            if (i < s.len) i += 1;
        } else {
            i += 1;
        }
    }
    return try list.toOwnedSlice(a);
}

test "parse python array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try parsePythonArray(a, "['/a', '/b/c']");
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/a", paths[0]);
    try std.testing.expectEqualStrings("/b/c", paths[1]);
}

test "version field" {
    const out = "ansible [core 2.17.1]\n  configured module search path = ['/x']\n  ansible python module location = /y\n";
    try std.testing.expectEqualStrings("['/x']", versionField(out, "configured module search path").?);
    try std.testing.expectEqualStrings("/y", versionField(out, "ansible python module location").?);
}