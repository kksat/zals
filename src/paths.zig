//! Shared filesystem-path helpers: `file://` URI conversion, path
//! predicates, and small whole-file reads.

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

/// True when `path` names an existing regular file. Relative paths open
/// against the process working directory.
pub fn isFile(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    const st = f.stat() catch return false;
    return st.kind == .file;
}

/// True when `path` names an existing directory.
pub fn isDir(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// Bytes of the file at `path`, or null when it is missing, larger than
/// `max_bytes`, or unreadable for any other reason. The caller owns the
/// result. `max_bytes` is the caller's memory invariant: each call site
/// passes the cap its own read budget allows, not a module-wide default.
pub fn readFile(a: Allocator, path: []const u8, max_bytes: usize) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, max_bytes) catch null;
}

/// `s` without trailing spaces, tabs, and newlines.
pub fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\r\n");
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

test "readFile honours the caller's size cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "f.yml", .data = "0123456789" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fs.path.join(a, &.{ root, "f.yml" });
    try testing.expectEqualStrings("0123456789", readFile(a, file_path, 256 * 1024).?);
    try testing.expect(readFile(a, file_path, 4) == null);
}

test "isFile, isDir, readFile, trimEnd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("d");
    try tmp.dir.writeFile(.{ .sub_path = "f.yml", .data = "x\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const file_path = try std.fs.path.join(a, &.{ root, "f.yml" });
    const dir_path = try std.fs.path.join(a, &.{ root, "d" });
    try testing.expect(isFile(file_path));
    try testing.expect(!isFile(dir_path));
    try testing.expect(!isFile("no such file"));
    try testing.expect(isDir(dir_path));
    try testing.expect(!isDir(file_path));
    try testing.expectEqualStrings("x\n", readFile(a, file_path, 16 * 1024 * 1024).?);
    try testing.expect(readFile(a, dir_path, 16 * 1024 * 1024) == null);
    try testing.expect(readFile(a, "no such file", 16 * 1024 * 1024) == null);
    try testing.expectEqualStrings("x", trimEnd("x \t\r\n"));
    try testing.expectEqualStrings(" x", trimEnd(" x"));
}
