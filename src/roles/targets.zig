//! Choose the file a role navigation request opens.
//!
//! Definition prefers the role's argument specs, then its metadata, then its
//! main task file. Implementation always opens the main task file.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Definition target: `meta/argument_specs.*`, then `meta/main.*`, then
/// `tasks/main.*`. Null when none exists.
pub fn definitionTarget(a: Allocator, role_dir: []const u8) ?[]const u8 {
    if (joinFile(a, role_dir, "meta", "argument_specs.yml")) |p| return p;
    if (joinFile(a, role_dir, "meta", "argument_specs.yaml")) |p| return p;
    if (joinFile(a, role_dir, "meta", "main.yml")) |p| return p;
    if (joinFile(a, role_dir, "meta", "main.yaml")) |p| return p;
    if (joinFile(a, role_dir, "tasks", "main.yml")) |p| return p;
    if (joinFile(a, role_dir, "tasks", "main.yaml")) |p| return p;
    return null;
}

/// Implementation target: `tasks/main.*`. Null when it does not exist.
pub fn implementationTarget(a: Allocator, role_dir: []const u8) ?[]const u8 {
    if (joinFile(a, role_dir, "tasks", "main.yml")) |p| return p;
    if (joinFile(a, role_dir, "tasks", "main.yaml")) |p| return p;
    return null;
}

fn joinFile(a: Allocator, role_dir: []const u8, sub: []const u8, name: []const u8) ?[]const u8 {
    const path = std.fs.path.join(a, &.{ role_dir, sub, name }) catch return null;
    if (!isFile(path)) {
        a.free(path);
        return null;
    }
    return path;
}

fn isFile(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

const testing = std.testing;

test "definition prefers argument specs" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("role/meta");
    try tmp.dir.makePath("role/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "role/meta/argument_specs.yml", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "role/meta/main.yml", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "role/tasks/main.yml", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const role = try std.fs.path.join(a, &.{ root, "role" });
    defer a.free(role);
    const target = definitionTarget(a, role).?;
    defer a.free(target);
    const expected = try std.fs.path.join(a, &.{ role, "meta", "argument_specs.yml" });
    defer a.free(expected);
    try testing.expectEqualStrings(expected, target);
}

test "definition falls back to meta then tasks" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("role/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "role/tasks/main.yml", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const role = try std.fs.path.join(a, &.{ root, "role" });
    defer a.free(role);
    const target = definitionTarget(a, role).?;
    defer a.free(target);
    const expected = try std.fs.path.join(a, &.{ role, "tasks", "main.yml" });
    defer a.free(expected);
    try testing.expectEqualStrings(expected, target);
}

test "implementation opens tasks main" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("role/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "role/tasks/main.yml", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const role = try std.fs.path.join(a, &.{ root, "role" });
    defer a.free(role);
    const target = implementationTarget(a, role).?;
    defer a.free(target);
    const expected = try std.fs.path.join(a, &.{ role, "tasks", "main.yml" });
    defer a.free(expected);
    try testing.expectEqualStrings(expected, target);
}

test "missing targets return null" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("role");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const role = try std.fs.path.join(a, &.{ root, "role" });
    defer a.free(role);
    try testing.expect(definitionTarget(a, role) == null);
    try testing.expect(implementationTarget(a, role) == null);
}
