//! Maps Ansible metadata URIs to bundled JSON schemas (ADR-0006).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const bundled = @import("schemas");

const Mapping = struct {
    suffix: []const u8,
    bytes: []const u8,
};

const mappings = [_]Mapping{
    .{ .suffix = "/meta/main.yml", .bytes = bundled.meta },
    .{ .suffix = "/meta/main.yaml", .bytes = bundled.meta },
    .{ .suffix = "/meta/runtime.yml", .bytes = bundled.meta_runtime },
    .{ .suffix = "/meta/runtime.yaml", .bytes = bundled.meta_runtime },
    .{ .suffix = "/galaxy.yml", .bytes = bundled.galaxy },
    .{ .suffix = "/galaxy.yaml", .bytes = bundled.galaxy },
    .{ .suffix = "/requirements.yml", .bytes = bundled.requirements },
    .{ .suffix = "/requirements.yaml", .bytes = bundled.requirements },
    .{ .suffix = "/execution-environment.yml", .bytes = bundled.execution_environment },
    .{ .suffix = "/execution-environment.yaml", .bytes = bundled.execution_environment },
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    parsed: [mappings.len]?Value = .{null} ** mappings.len,

    pub fn init(allocator: Allocator) Catalog {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn schemaForUri(self: *Catalog, uri: []const u8) ?Value {
        const path = stripFile(uri);
        for (mappings, 0..) |m, i| {
            if (endsWithIgnoreCase(path, m.suffix)) {
                if (self.parsed[i] == null) {
                    self.parsed[i] = std.json.parseFromSliceLeaky(Value, self.arena.allocator(), m.bytes, .{}) catch return null;
                }
                return self.parsed[i];
            }
        }
        return null;
    }
};

fn stripFile(uri: []const u8) []const u8 {
    if (std.mem.startsWith(u8, uri, "file://")) return uri["file://".len..];
    return uri;
}

fn endsWithIgnoreCase(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - suffix.len ..], suffix);
}

test "galaxy mapping" {
    var cat = Catalog.init(std.testing.allocator);
    defer cat.deinit();
    try std.testing.expect(cat.schemaForUri("file:///tmp/roles/foo/galaxy.yml") != null);
    try std.testing.expect(cat.schemaForUri("file:///tmp/playbook.yml") == null);
}
