//! Cached `ansible-config dump` values used for path resolution.
//!
//! `ansible-config dump` is shelled out at most once per server lifetime. The
//! parsed values live in an arena owned by this struct. Consumers are the
//! module index (collections paths) and role resolution (collections paths and
//! `DEFAULT_ROLES_PATH`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("../exec/root.zig");

pub const AnsibleConfig = struct {
    allocator: Allocator,
    runner: exec.Runner,
    arena: std.heap.ArenaAllocator,
    loaded: bool = false,
    collections_paths: []const []const u8 = &.{},
    roles_path: []const []const u8 = &.{},

    pub fn init(allocator: Allocator, runner: exec.Runner) AnsibleConfig {
        return .{
            .allocator = allocator,
            .runner = runner,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AnsibleConfig) void {
        self.arena.deinit();
    }

    /// Run `ansible-config dump` once and cache the values we care about.
    /// Failures leave the lists empty; resolution then falls back to
    /// playbook-adjacent and workspace-relative paths.
    pub fn ensureLoaded(self: *AnsibleConfig) void {
        if (self.loaded) return;
        self.loaded = true;

        const result = self.runner.run(self.allocator, &.{ "ansible-config", "dump" }) catch return;
        defer result.deinit(self.allocator);

        const a = self.arena.allocator();
        if (configField(result.stdout, "COLLECTIONS_PATHS")) |v| {
            self.collections_paths = parsePythonArray(a, v) catch &.{};
        }
        if (configField(result.stdout, "DEFAULT_ROLES_PATH")) |v| {
            self.roles_path = parsePythonArray(a, v) catch &.{};
        }
    }

    pub fn collectionsPaths(self: *AnsibleConfig) []const []const u8 {
        self.ensureLoaded();
        return self.collections_paths;
    }

    pub fn rolesPath(self: *AnsibleConfig) []const []const u8 {
        self.ensureLoaded();
        return self.roles_path;
    }
};

/// Extract `KEY(source) = value` from `ansible-config dump` output.
pub fn configField(stdout: []const u8, key: []const u8) ?[]const u8 {
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
pub fn parsePythonArray(a: Allocator, s: []const u8) ![]const []const u8 {
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

const testing = std.testing;

test "config field" {
    const out = "COLLECTIONS_PATHS(default) = ['/a', '/b']\nDEFAULT_ROLES_PATH(default) = ['/r']\n";
    try testing.expectEqualStrings("['/a', '/b']", configField(out, "COLLECTIONS_PATHS").?);
    try testing.expectEqualStrings("['/r']", configField(out, "DEFAULT_ROLES_PATH").?);
    try testing.expect(configField(out, "MISSING") == null);
}

test "parse python array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try parsePythonArray(a, "['/a', '/b/c']");
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("/a", paths[0]);
    try testing.expectEqualStrings("/b/c", paths[1]);
}
