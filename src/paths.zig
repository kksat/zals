//! Shared filesystem-path helpers: `file://` URI conversion.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Strip a `file://` URI to a filesystem path and percent-decode once.
/// A literal `%20` filename is represented as `%2520`, not a space.
pub fn uriToPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    var path = uri;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') {
        path = path[1..];
    }
    const component: std.Uri.Component = .{ .percent_encoded = path };
    return std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatRaw)});
}

/// LSP file URIs must be absolute. Anchor relative filesystem paths to the
/// same process directory used for their lookup; do not require the file to
/// exist (code actions also use this helper for new files).
pub fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "file:")) return path;
    if (std.fs.path.isAbsolute(path)) return absolutePathToUri(allocator, path);
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const absolute = try std.fs.path.join(allocator, &.{ cwd, path });
    defer allocator.free(absolute);
    return absolutePathToUri(allocator, absolute);
}

fn absolutePathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    const uri: std.Uri = .{ .scheme = "file", .host = .{ .raw = "" }, .path = .{ .raw = path } };
    return std.fmt.allocPrint(allocator, "{f}", .{uri});
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
