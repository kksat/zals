//! Workspace-wide queries over indexed facts (ADR-0032).
//!
//! Pure functions over a list of files and their facts, so they can be tested
//! without a server. The provider layer builds the list from the Workspace
//! index and the open documents.

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");
const variables = @import("../variables/root.zig");

pub const Facts = facts_mod.Facts;
pub const Site = variables.Site;

pub const File = struct {
    path: []const u8,
    uri: []const u8,
    facts: Facts,
};

pub const Occurrence = struct {
    uri: []const u8,
    path: []const u8,
    start: usize,
    end: usize,
    kind: variables.OccurrenceKind,
    site: ?Site = null,
    /// Only set for definitions: whether it can apply at the query site.
    reachable: bool = false,
};

pub fn find(files: []const File, path: []const u8) ?*const File {
    for (files) |*f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

/// Every definition and reference of `name` in `files`, ordered by URI then
/// offset.
pub fn occurrences(a: Allocator, files: []const File, name: []const u8) ![]Occurrence {
    var out = std.array_list.Managed(Occurrence).init(a);
    for (files) |f| {
        for (f.facts.var_defs) |d| {
            if (std.mem.eql(u8, d.name, name)) try out.append(.{
                .uri = f.uri,
                .path = f.path,
                .start = d.start,
                .end = d.end,
                .kind = .definition,
                .site = d.site,
            });
        }
        for (f.facts.var_refs) |r| {
            if (std.mem.eql(u8, r.name, name)) try out.append(.{
                .uri = f.uri,
                .path = f.path,
                .start = r.start,
                .end = r.end,
                .kind = .reference,
            });
        }
    }
    std.mem.sort(Occurrence, out.items, {}, lessPosition);
    return out.toOwnedSlice();
}

/// Paths whose definitions can apply in the file at `path` (the Reachable
/// definitions of `CONTEXT.md`): the file's role scope (every file under
/// `role_dir`) or the file itself, the playbooks that invoke that role, and
/// one level of the vars files those load.
pub fn reachableFiles(a: Allocator, files: []const File, path: []const u8, role_dir: ?[]const u8) ![]const []const u8 {
    var set = std.array_list.Managed([]const u8).init(a);
    if (role_dir) |rd| {
        const prefix = try std.fmt.allocPrint(a, "{s}/", .{rd});
        for (files) |f| {
            if (std.mem.startsWith(u8, f.path, prefix)) try appendUnique(&set, f.path);
        }
        const name = std.fs.path.basename(rd);
        for (files) |f| {
            for (f.facts.role_refs) |r| {
                if (namesRole(r.name, name)) {
                    try appendUnique(&set, f.path);
                    break;
                }
            }
        }
    }
    try appendUnique(&set, path);

    const base_len = set.items.len;
    for (set.items[0..base_len]) |p| {
        const f = find(files, p) orelse continue;
        for (f.facts.vars_targets) |t| try appendUnique(&set, t);
    }
    return set.toOwnedSlice();
}

/// Definitions of `name`: the reachable ones ranked by precedence (ADR-0024),
/// then every other definition in `files` by position.
pub fn definitions(a: Allocator, files: []const File, name: []const u8, reachable: []const []const u8) ![]Occurrence {
    const all = try occurrences(a, files, name);
    var near = std.array_list.Managed(Occurrence).init(a);
    var far = std.array_list.Managed(Occurrence).init(a);
    for (all) |o| {
        if (o.kind != .definition) continue;
        var copy = o;
        if (contains(reachable, o.path)) {
            copy.reachable = true;
            try near.append(copy);
        } else {
            try far.append(copy);
        }
    }
    std.mem.sort(Occurrence, near.items, {}, lessRank);
    try near.appendSlice(far.items);
    return near.toOwnedSlice();
}

/// A role reference `ref` names the role directory basename `role`: exactly,
/// or as the last segment of an FQCN.
pub fn namesRole(ref: []const u8, role: []const u8) bool {
    if (std.mem.eql(u8, ref, role)) return true;
    if (std.mem.count(u8, ref, ".") < 2) return false;
    const last = ref[std.mem.lastIndexOfScalar(u8, ref, '.').? + 1 ..];
    return std.mem.eql(u8, last, role);
}

fn lessPosition(_: void, x: Occurrence, y: Occurrence) bool {
    const order = std.mem.order(u8, x.uri, y.uri);
    if (order != .eq) return order == .lt;
    return x.start < y.start;
}

fn lessRank(_: void, x: Occurrence, y: Occurrence) bool {
    const rx = if (x.site) |s| s.rank() else 99;
    const ry = if (y.site) |s| s.rank() else 99;
    if (rx != ry) return rx < ry;
    return lessPosition({}, x, y);
}

fn appendUnique(list: *std.array_list.Managed([]const u8), item: []const u8) !void {
    if (contains(list.items, item)) return;
    try list.append(item);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

const testing = std.testing;

fn file(a: Allocator, path: []const u8, text: []const u8) !File {
    return .{ .path = path, .uri = try std.fmt.allocPrint(a, "file://{s}", .{path}), .facts = try facts_mod.extract(a, path, text) };
}

test "occurrences span the Workspace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{
        try file(a, "/w/roles/web/defaults/main.yml", "app_port: 80\n"),
        try file(a, "/w/playbooks/site.yml", "- hosts: all\n  tasks:\n    - debug: msg=\"{{ app_port }}\"\n"),
    };
    const occ = try occurrences(a, &files, "app_port");
    try testing.expectEqual(@as(usize, 2), occ.len);
    try testing.expectEqual(variables.OccurrenceKind.reference, occ[0].kind);
    try testing.expectEqual(variables.OccurrenceKind.definition, occ[1].kind);
}

test "reachable definitions exclude unrelated roles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{
        try file(a, "/w/roles/web/defaults/main.yml", "port: 80\n"),
        try file(a, "/w/roles/db/defaults/main.yml", "port: 5432\n"),
        try file(a, "/w/roles/db/tasks/main.yml", "- debug: msg=\"{{ port }}\"\n"),
        try file(a, "/w/playbooks/site.yml",
            \\- hosts: db
            \\  vars_files:
            \\    - vars/prod.yml
            \\  roles:
            \\    - db
            \\
        ),
        try file(a, "/w/playbooks/vars/prod.yml", "port: 8080\n"),
        try file(a, "/w/playbooks/other.yml", "- hosts: all\n  vars:\n    port: 1\n"),
    };
    const reach = try reachableFiles(a, &files, "/w/roles/db/tasks/main.yml", "/w/roles/db");
    const defs = try definitions(a, &files, "port", reach);
    try testing.expectEqual(@as(usize, 4), defs.len);
    // play vars_files (rank below role defaults) comes first among reachable.
    try testing.expect(defs[0].reachable and defs[1].reachable);
    try testing.expectEqualStrings("/w/playbooks/vars/prod.yml", defs[0].path);
    try testing.expectEqualStrings("/w/roles/db/defaults/main.yml", defs[1].path);
    try testing.expect(!defs[2].reachable and !defs[3].reachable);
}

test "a playbook reaches itself and its vars files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{
        try file(a, "/w/site.yml", "- hosts: all\n  vars_files: [extra.yml]\n"),
        try file(a, "/w/extra.yml", "x: 1\n"),
        try file(a, "/w/unrelated.yml", "x: 2\n"),
    };
    const reach = try reachableFiles(a, &files, "/w/site.yml", null);
    try testing.expectEqual(@as(usize, 2), reach.len);
    try testing.expectEqualStrings("/w/extra.yml", reach[1]);
}

test "FQCN reference names a collection role" {
    try testing.expect(namesRole("acme.web.nginx", "nginx"));
    try testing.expect(namesRole("nginx", "nginx"));
    try testing.expect(!namesRole("geerlingguy.nginx", "nginx"));
    try testing.expect(namesRole("geerlingguy.nginx", "geerlingguy.nginx"));
}
