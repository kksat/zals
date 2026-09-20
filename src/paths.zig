//! Shared filesystem-path helpers: `file://` URI conversion.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Strip a `file://` URI to a filesystem path. Percent-decodes `%20` only,
/// matching the rest of the server.
pub fn uriToPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    var path = uri;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') {
        path = path[1..];
    }
    if (std.mem.indexOf(u8, path, "%20") == null) return allocator.dupe(u8, path);
    var buf = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < path.len) {
        if (i + 2 < path.len and path[i] == '%' and path[i + 1] == '2' and path[i + 2] == '0') {
            try buf.append(' ');
            i += 3;
        } else {
            try buf.append(path[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice();
}

pub fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "file:")) return path;
    return std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

const testing = std.testing;

test "uri round trip" {
    const a = testing.allocator;
    const path = try uriToPath(a, "file:///tmp/x.yml");
    defer a.free(path);
    try testing.expectEqualStrings("/tmp/x.yml", path);
    const uri = try pathToUri(a, "/tmp/x.yml");
    defer a.free(uri);
    try testing.expectEqualStrings("file:///tmp/x.yml", uri);
}

test "uri decodes spaces" {
    const a = testing.allocator;
    const path = try uriToPath(a, "file:///tmp/a%20b.yml");
    defer a.free(path);
    try testing.expectEqualStrings("/tmp/a b.yml", path);
}
