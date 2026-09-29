//! Role references across the Workspace and role hover (ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const wv = @import("workspace_view.zig");

/// Every Role reference in the Workspace that names the role under the
/// cursor. Null when the cursor is not on a role reference.
pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const name = try a.dupe(u8, ref.name);

    var v = (try wv.View.forUri(self, a, cur.doc.uri)) orelse {
        // No session Workspace: only this document.
        const one = try a.alloc(types.Location, 1);
        one[0] = .{ .uri = cur.doc.uri, .range = cur.doc.rangeFromOffsets(ref.start, ref.end) };
        return one;
    };
    var locs = std.array_list.Managed(types.Location).init(a);
    for (v.files) |f| {
        for (f.facts.role_refs) |r| {
            if (!std.mem.eql(u8, r.name, name)) continue;
            try locs.append(try v.location(f.uri, r.start, r.end));
        }
    }
    std.mem.sort(types.Location, locs.items, {}, lessLocation);
    return try locs.toOwnedSlice();
}

/// Hover on a role reference: the role's `README.md`, else its unrendered
/// argument specs, else its unrendered `meta/main.yml`, else its name and
/// resolved path. Null when the cursor is not on a role reference.
pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const name = try a.dupe(u8, ref.name);
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getDeclaredCollections(cur.forest.allocator(), cur.path) catch &.{};
    const range = cur.doc.rangeFromOffsets(ref.start, ref.end);

    const dir = util.resolveRole(self, a, name, path, collections) orelse {
        return markdown(range, try std.fmt.allocPrint(a, "**Role** `{s}`\n\nNot found on the role search path.", .{name}));
    };
    return markdown(range, try roleCard(a, name, dir));
}

/// Markdown for a resolved role directory.
pub fn roleCard(a: Allocator, name: []const u8, dir: []const u8) ![]const u8 {
    for ([_][]const u8{ "README.md", "readme.md", "Readme.md" }) |readme| {
        if (readFile(a, &.{ dir, readme })) |text| return text;
    }
    for ([_][]const u8{ "argument_specs.yml", "argument_specs.yaml", "main.yml", "main.yaml" }) |meta| {
        if (readFile(a, &.{ dir, "meta", meta })) |text| {
            return std.fmt.allocPrint(a, "**Role** `{s}` — `meta/{s}`\n\n```yaml\n{s}\n```", .{ name, meta, trimEnd(text) });
        }
    }
    return std.fmt.allocPrint(a, "**Role** `{s}`\n\n`{s}`", .{ name, dir });
}

fn markdown(range: types.Range, text: []const u8) types.Hover {
    return .{ .contents = .{ .kind = .markdown, .value = text }, .range = range };
}

fn readFile(a: Allocator, parts: []const []const u8) ?[]const u8 {
    const p = std.fs.path.join(a, parts) catch return null;
    const f = std.fs.cwd().openFile(p, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 256 * 1024) catch null;
}

fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\r\n");
}

fn lessLocation(_: void, x: types.Location, y: types.Location) bool {
    const order = std.mem.order(u8, x.uri, y.uri);
    if (order != .eq) return order == .lt;
    if (x.range.start.line != y.range.start.line) return x.range.start.line < y.range.start.line;
    return x.range.start.character < y.range.start.character;
}

const testing = std.testing;

test "role card prefers README, then argument specs, then metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("web/meta");
    try tmp.dir.writeFile(.{ .sub_path = "web/meta/main.yml", .data = "galaxy_info:\n  author: me\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realpathAlloc(a, "web");

    var card = try roleCard(a, "web", dir);
    try testing.expect(std.mem.indexOf(u8, card, "meta/main.yml") != null);
    try testing.expect(std.mem.indexOf(u8, card, "author: me") != null);

    try tmp.dir.writeFile(.{ .sub_path = "web/meta/argument_specs.yml", .data = "argument_specs: {}\n" });
    card = try roleCard(a, "web", dir);
    try testing.expect(std.mem.indexOf(u8, card, "argument_specs: {}") != null);

    try tmp.dir.writeFile(.{ .sub_path = "web/README.md", .data = "# Web role\n" });
    card = try roleCard(a, "web", dir);
    try testing.expectEqualStrings("# Web role\n", card);
}

test "role card falls back to the path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bare/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realpathAlloc(a, "bare");
    const card = try roleCard(a, "bare", dir);
    try testing.expect(std.mem.indexOf(u8, card, dir) != null);
}
