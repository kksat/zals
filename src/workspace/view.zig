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
    /// Parsed root-and-key path, carried only by field definitions.
    field_path: []const []const u8 = &.{},
    /// Only set for definitions: whether it can apply at the query site.
    reachable: bool = false,
};

pub const Reachability = struct {
    paths: []const []const u8,
    /// Loads from base files only; targets are followed one level.
    loads: []const variables.scope.VarFileLoad,

    fn loadSite(self: Reachability, path: []const u8) ?Site {
        var best: ?Site = null;
        for (self.loads) |load| {
            if (!std.mem.eql(u8, load.path, path)) continue;
            if (best == null or load.site.rank() < best.?.rank()) best = load.site;
        }
        return best;
    }
};

/// The root variable occurrence at `offset` in one file's facts: a binding,
/// else a read, else a load-only binding the caller must admit (ADR-0045).
pub fn occurrenceAt(facts: Facts, offset: usize) ?variables.Cursor {
    for (facts.var_defs) |d| if (d.start <= offset and offset <= d.end) {
        return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end };
    };
    for (facts.var_refs) |r| if (r.start <= offset and offset <= r.end) {
        return .{ .name = r.name, .kind = .reference, .start = r.start, .end = r.end };
    };
    for (facts.load_var_defs) |d| if (d.start <= offset and offset <= d.end) {
        return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end, .requires_load = true };
    };
    return null;
}

/// The field occurrence at `offset`, in the separate leaf-name group.
pub fn fieldOccurrenceAt(facts: Facts, offset: usize) ?variables.Cursor {
    for (facts.field_defs) |d| if (d.start <= offset and offset <= d.end) {
        return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end };
    };
    for (facts.field_refs) |r| if (r.start <= offset and offset <= r.end) {
        return .{ .name = r.name, .kind = .reference, .start = r.start, .end = r.end };
    };
    for (facts.load_field_defs) |d| if (d.start <= offset and offset <= d.end) {
        return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end, .requires_load = true };
    };
    return null;
}

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

/// Field names are grouped independently of root variables and receivers.
pub fn fieldOccurrences(a: Allocator, files: []const File, name: []const u8) ![]Occurrence {
    var out = std.array_list.Managed(Occurrence).init(a);
    for (files) |f| {
        for (f.facts.field_defs) |def| {
            if (std.mem.eql(u8, def.name, name)) try out.append(.{
                .uri = f.uri,
                .path = f.path,
                .start = def.start,
                .end = def.end,
                .kind = .definition,
                .site = def.site,
                .field_path = def.path,
            });
        }
        for (f.facts.field_refs) |ref| {
            if (std.mem.eql(u8, ref.name, name)) try out.append(.{
                .uri = f.uri,
                .path = f.path,
                .start = ref.start,
                .end = ref.end,
                .kind = .reference,
            });
        }
    }
    std.mem.sort(Occurrence, out.items, {}, lessPosition);
    return out.toOwnedSlice();
}

pub fn fieldDefinitions(a: Allocator, files: []const File, name: []const u8, reachable: Reachability) ![]Occurrence {
    const all = try fieldOccurrences(a, files, name);
    var near = std.array_list.Managed(Occurrence).init(a);
    var far = std.array_list.Managed(Occurrence).init(a);
    for (all) |occurrence| {
        if (occurrence.kind != .definition) continue;
        var copy = occurrence;
        if (contains(reachable.paths, occurrence.path)) {
            copy.reachable = true;
            if (reachable.loadSite(occurrence.path)) |site| {
                if (copy.site == null or site.rank() < copy.site.?.rank()) copy.site = site;
            }
            try near.append(copy);
        } else {
            try far.append(copy);
        }
    }
    std.mem.sort(Occurrence, near.items, {}, lessRank);
    try near.appendSlice(far.items);
    return near.toOwnedSlice();
}

/// Whether a path is a conventional source of this callee, without admitting
/// callers or other roles whose directory merely shares the same prefix.
pub fn isCalleeSource(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir) or path.len <= dir.len + 1) return false;
    if (path[dir.len] != '/' and path[dir.len] != '\\') return false;
    var components = std.mem.tokenizeAny(u8, path[dir.len + 1 ..], "/\\");
    const first = components.next() orelse return false;
    for ([_][]const u8{ "defaults", "vars", "tasks", "handlers", "templates", "meta" }) |name| {
        if (std.mem.eql(u8, first, name)) return true;
    }
    return false;
}

/// An indexed callee's conventional sources and one level of their vars loads.
/// No invokers join this file set. Null means this callee is not indexed here.
pub fn calleeFiles(a: Allocator, files: []const File, dir: []const u8) !?Reachability {
    var base = std.array_list.Managed([]const u8).init(a);
    for (files) |f| {
        if (isCalleeSource(f.path, dir)) try appendUnique(&base, f.path);
    }
    if (base.items.len == 0) return null;
    const conventional = try a.dupe([]const u8, base.items);
    var loads = std.array_list.Managed(variables.scope.VarFileLoad).init(a);
    for (conventional) |path| {
        const f = find(files, path) orelse continue;
        for (f.facts.var_loads) |load| {
            try loads.append(load);
            try appendUnique(&base, load.path);
        }
    }
    return .{ .paths = try base.toOwnedSlice(), .loads = try loads.toOwnedSlice() };
}

/// Concrete root bindings from the same callee file set used for fields.
/// Explicit loads can outrank the file's intrinsic definition site.
pub fn calleeRootDefinitions(a: Allocator, files: []const File, set: Reachability, name: []const u8) ![]Occurrence {
    var out = std.array_list.Managed(Occurrence).init(a);
    for (files) |f| {
        if (!contains(set.paths, f.path)) continue;
        for (f.facts.var_defs) |def| {
            if (def.site == .argument_specs or !std.mem.eql(u8, def.name, name)) continue;
            var site = def.site;
            if (set.loadSite(f.path)) |load| if (load.rank() < site.rank()) {
                site = load;
            };
            try out.append(.{ .uri = f.uri, .path = f.path, .start = def.start, .end = def.end, .kind = .definition, .site = site, .reachable = true });
        }
    }
    std.mem.sort(Occurrence, out.items, {}, lessRank);
    return try out.toOwnedSlice();
}

/// Concrete full-path field bindings from the selected callee file set.
/// Read stored facts instead of reparsing every role file per request.
pub fn calleeFieldDefinitions(a: Allocator, files: []const File, set: Reachability, names: []const []const u8) ![]Occurrence {
    var out = std.array_list.Managed(Occurrence).init(a);
    for (files) |f| {
        if (!contains(set.paths, f.path)) continue;
        for (f.facts.field_defs) |def| {
            if (def.site == .argument_specs or def.path.len != names.len) continue;
            var equal = true;
            for (def.path, names) |x, y| if (!std.mem.eql(u8, x, y)) {
                equal = false;
                break;
            };
            if (!equal) continue;
            var site = def.site;
            if (set.loadSite(f.path)) |load| if (load.rank() < site.rank()) {
                site = load;
            };
            try out.append(.{ .uri = f.uri, .path = f.path, .start = def.start, .end = def.end, .kind = .definition, .site = site, .field_path = def.path, .reachable = true });
        }
    }
    std.mem.sort(Occurrence, out.items, {}, lessRank);
    return try out.toOwnedSlice();
}

/// Paths whose definitions can apply in the file at `path` (the Reachable
/// definitions of `GLOSSARY.md`): the file's role scope (every file under
/// `role_dir`) or the file itself, the files whose references resolve to
/// that Role (or, for a task file outside a role, the files that include it),
/// and one level of the vars files those load. Role invokers are resolved by
/// the provider, which has the per-file project configuration.
pub fn reachableFiles(a: Allocator, files: []const File, path: []const u8, role_dir: ?[]const u8, role_invokers: []const []const u8) !Reachability {
    var set = std.array_list.Managed([]const u8).init(a);
    var loads = std.array_list.Managed(variables.scope.VarFileLoad).init(a);
    if (role_dir) |rd| {
        const prefix = try std.fmt.allocPrint(a, "{s}/", .{rd});
        for (files) |f| {
            if (std.mem.startsWith(u8, f.path, prefix)) try appendUnique(&set, f.path);
        }
        for (role_invokers) |invoker| try appendUnique(&set, invoker);
    } else {
        for (files) |f| {
            for (f.facts.file_refs) |r| {
                if (r.kind == .task_file and std.mem.eql(u8, r.target, path)) {
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
        for (f.facts.var_loads) |load| {
            try loads.append(load);
            try appendUnique(&set, load.path);
        }
    }
    return .{ .paths = try set.toOwnedSlice(), .loads = try loads.toOwnedSlice() };
}

/// Definitions of `name`: the reachable ones ranked by precedence (ADR-0024),
/// then every other definition in `files` by position.
pub fn definitions(a: Allocator, files: []const File, name: []const u8, reachable: Reachability) ![]Occurrence {
    const all = try occurrences(a, files, name);
    var near = std.array_list.Managed(Occurrence).init(a);
    var far = std.array_list.Managed(Occurrence).init(a);
    for (all) |o| {
        if (o.kind != .definition) continue;
        var copy = o;
        if (contains(reachable.paths, o.path)) {
            copy.reachable = true;
            // Files are indexed independently of their invokers. An explicit
            // load may outrank the file's intrinsic definition site.
            if (reachable.loadSite(o.path)) |site| {
                if (copy.site == null or site.rank() < copy.site.?.rank()) copy.site = site;
            }
            try near.append(copy);
        } else {
            try far.append(copy);
        }
    }
    std.mem.sort(Occurrence, near.items, {}, lessRank);
    try near.appendSlice(far.items);
    return near.toOwnedSlice();
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
    const reach = try reachableFiles(a, &files, "/w/roles/db/tasks/main.yml", "/w/roles/db", &.{"/w/playbooks/site.yml"});
    const defs = try definitions(a, &files, "port", reach);
    try testing.expectEqual(@as(usize, 4), defs.len);
    // play vars_files (rank below role defaults) comes first among reachable.
    try testing.expect(defs[0].reachable and defs[1].reachable);
    try testing.expectEqualStrings("/w/playbooks/vars/prod.yml", defs[0].path);
    try testing.expectEqualStrings("/w/roles/db/defaults/main.yml", defs[1].path);
    try testing.expect(!defs[2].reachable and !defs[3].reachable);
}

test "standalone Role directory-style defaults and vars retain precedence" {
    for ([_][]const u8{ "yml", "yaml" }) |ext| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try tmp.dir.makePath("meta");
        try tmp.dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "meta/main.{s}", .{ext}), .data = "galaxy_info: {}\n" });
        const root = try tmp.dir.realpathAlloc(a, ".");
        const default_path = try std.fmt.allocPrint(a, "{s}/defaults/main/settings.{s}", .{ root, ext });
        const vars_path = try std.fmt.allocPrint(a, "{s}/vars/main/nested/settings.{s}", .{ root, ext });
        const task_path = try std.fmt.allocPrint(a, "{s}/tasks/main.{s}", .{ root, ext });
        const play_path = try std.fmt.allocPrint(a, "{s}/site.{s}", .{ root, ext });
        const files = [_]File{
            try file(a, default_path, "config:\n  port: 80\n"),
            try file(a, vars_path, "config:\n  port: 8080\n"),
            try file(a, task_path, "- debug:\n    msg: '{{ config.port }}'\n"),
            try file(a, play_path, "- hosts: all\n  vars:\n    config:\n      port: 8000\n"),
        };
        const role_dir = @import("../roles/resolve.zig").enclosingRole(task_path);
        try testing.expect(role_dir != null);
        try testing.expectEqualStrings(root, role_dir.?);
        const reach = try reachableFiles(a, &files, task_path, role_dir, &.{play_path});
        const defs = try definitions(a, &files, "config", reach);
        try testing.expectEqual(@as(usize, 3), defs.len);
        try testing.expectEqualStrings(vars_path, defs[0].path);
        try testing.expectEqual(Site.role_vars, defs[0].site.?);
        try testing.expectEqualStrings(play_path, defs[1].path);
        try testing.expectEqual(Site.play_vars, defs[1].site.?);
        try testing.expectEqualStrings(default_path, defs[2].path);
        try testing.expectEqual(Site.role_defaults, defs[2].site.?);
        // Structured fields use the same intrinsic sites as their bindings.
        try testing.expectEqual(Site.role_defaults, files[0].facts.field_defs[0].site);
        try testing.expectEqual(Site.role_vars, files[1].facts.field_defs[0].site);
    }
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
    const reach = try reachableFiles(a, &files, "/w/site.yml", null, &.{});
    try testing.expectEqual(@as(usize, 2), reach.paths.len);
    try testing.expectEqualStrings("/w/extra.yml", reach.paths[1]);
}

test "include_vars outranks vars_files for a reachable variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{
        try file(a, "/w/play.yml",
            \\- hosts: all
            \\  vars_files: [vars/release.yml]
            \\  tasks:
            \\    - include_vars: vars/runtime.yml
            \\
        ),
        try file(a, "/w/vars/release.yml", "channel: planned\n"),
        try file(a, "/w/vars/runtime.yml", "channel: active\n"),
    };
    const reach = try reachableFiles(a, &files, "/w/play.yml", null, &.{});
    const defs = try definitions(a, &files, "channel", reach);
    try testing.expectEqual(@as(usize, 2), defs.len);
    try testing.expectEqualStrings("/w/vars/runtime.yml", defs[0].path);
    try testing.expectEqual(Site.include_vars, defs[0].site.?);
    try testing.expectEqualStrings("/w/vars/release.yml", defs[1].path);
    try testing.expectEqual(Site.vars_files, defs[1].site.?);
}

test "a task file outside a role reaches the playbooks that include it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{
        try file(a, "/nowhere-zals/site.yml", "- hosts: all\n  vars:\n    user: bob\n  tasks:\n    - include_tasks: tasks/common.yml\n"),
        try file(a, "/nowhere-zals/tasks/common.yml", "- debug: msg=\"{{ user }}\"\n"),
    };
    const reach = try reachableFiles(a, &files, "/nowhere-zals/tasks/common.yml", null, &.{});
    const defs = try definitions(a, &files, "user", reach);
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expect(defs[0].reachable);
}

test "occurrence at an offset: bindings, reads, then load-only bindings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const play = "- hosts: all\n  vars:\n    app: {port: 1}\n  tasks:\n    - debug: msg=\"{{ app.port }}\"\n";
    const facts = try facts_mod.extract(a, "/w/site.yml", play);
    const read = occurrenceAt(facts, std.mem.indexOf(u8, play, "{{ app").? + 3).?;
    try testing.expectEqualStrings("app", read.name);
    try testing.expectEqual(variables.OccurrenceKind.reference, read.kind);
    const binding = occurrenceAt(facts, std.mem.indexOf(u8, play, "app:").?).?;
    try testing.expectEqual(variables.OccurrenceKind.definition, binding.kind);
    const field = fieldOccurrenceAt(facts, std.mem.indexOf(u8, play, "port }}").?).?;
    try testing.expectEqualStrings("port", field.name);
    try testing.expectEqual(variables.OccurrenceKind.reference, field.kind);
    try testing.expect(occurrenceAt(facts, std.mem.indexOf(u8, play, "hosts").?) == null);

    // A map-rooted file outside Variable-file locations binds only when loaded.
    const general = try facts_mod.extract(a, "/w/settings.yml", "channel: stable\n");
    const loaded = occurrenceAt(general, 0).?;
    try testing.expectEqualStrings("channel", loaded.name);
    try testing.expect(loaded.requires_load);
}
