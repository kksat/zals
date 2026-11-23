const std = @import("std");
const cel_env = @import("../cel/env.zig");

pub const AvailabilityStatus = enum(u8) {
    ready,
    pending,
    unavailable,
    partial,
    stale,

    pub fn name(self: AvailabilityStatus) []const u8 {
        return switch (self) {
            .ready => "ready",
            .pending => "pending",
            .unavailable => "unavailable",
            .partial => "partial",
            .stale => "stale",
        };
    }
};

pub const ModuleFact = struct {
    fqcn: []const u8,
    deprecated: bool = false,
};

pub const MetadataSnapshot = struct {
    status: AvailabilityStatus = .unavailable,
    environment_id: []const u8 = "",
    generation: u64 = 0,
    reason: []const u8 = "",
    modules: []const ModuleFact = &.{},

    pub fn isAvailable(self: MetadataSnapshot) bool {
        return self.status == .ready or self.status == .partial;
    }

    pub fn matchesEnvironment(self: MetadataSnapshot, expected_env_id: []const u8) bool {
        return self.environment_id.len > 0 and std.mem.eql(u8, self.environment_id, expected_env_id);
    }

    pub fn toCel(self: MetadataSnapshot, alloc: std.mem.Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putBool(alloc, "available", self.isAvailable());
        try b.putString(alloc, "status", self.status.name());
        try b.putString(alloc, "environment_id", self.environment_id);
        try b.putString(alloc, "reason", self.reason);

        var mod_b = cel_env.MapBuilder.init();
        errdefer mod_b.deinit(alloc);
        for (self.modules) |m| {
            var entry_b = cel_env.MapBuilder.init();
            errdefer entry_b.deinit(alloc);
            try entry_b.putBool(alloc, "deprecated", m.deprecated);
            try mod_b.put(alloc, m.fqcn, try entry_b.finish(alloc));
        }
        try b.put(alloc, "modules", try mod_b.finish(alloc));
        return b.finish(alloc);
    }
};

pub fn computeEnvironmentId(
    alloc: std.mem.Allocator,
    ansible_path: []const u8,
    python_path: []const u8,
    venv_path: []const u8,
    collection_paths: []const []const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(ansible_path);
    hasher.update("\x00");
    hasher.update(python_path);
    hasher.update("\x00");
    hasher.update(venv_path);
    hasher.update("\x00");
    for (collection_paths) |p| {
        hasher.update(p);
        hasher.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

test "metadata environment isolation produces distinct identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env1 = try computeEnvironmentId(a, "ansible", "", ".venv", &.{"/ws/a/collections"});
    const env2 = try computeEnvironmentId(a, "ansible", "", ".venv", &.{"/ws/b/collections"});
    const env3 = try computeEnvironmentId(a, "ansible", "", ".venv-alt", &.{"/ws/a/collections"});
    try std.testing.expect(!std.mem.eql(u8, env1, env2));
    try std.testing.expect(!std.mem.eql(u8, env1, env3));

    const snap = MetadataSnapshot{
        .status = .ready,
        .environment_id = env1,
        .generation = 1,
    };
    try std.testing.expect(snap.matchesEnvironment(env1));
    try std.testing.expect(!snap.matchesEnvironment(env2));
    const v = try snap.toCel(a);
    try std.testing.expect(v.map_t.get(.{ .string_t = "available" }).?.bool_t);
}
