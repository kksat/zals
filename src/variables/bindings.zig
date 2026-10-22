//! What one file binds (ADR-0045). The Workspace index and the per-request
//! index both use this, so root variables and their fields follow one rule.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const definitions = @import("definitions.zig");
const fields = @import("fields.zig");

/// Valid while the forest and the allocator passed to `collect` live: root
/// names borrow the forest. Callers copy what they keep (the Workspace index
/// interns it into the entry arena).
pub const Bindings = struct {
    roots: []const definitions.Definition = &.{},
    fields: []const fields.Definition = &.{},
    /// Added only when a `vars_files`/`include_vars` load targets the file:
    /// the top-level keys of a `.general` file's map-rooted documents.
    loaded_roots: []const definitions.Definition = &.{},
    loaded_fields: []const fields.Definition = &.{},
};

/// `scratch` should be parse-lifetime storage, such as `forest.allocator()`.
pub fn collect(scratch: Allocator, forest: *const yaml.Forest, kind: definitions.FileKind) !Bindings {
    var roots = std.array_list.Managed(definitions.Definition).init(scratch);
    try definitions.collect(scratch, forest, kind, &roots);
    var loaded_roots = std.array_list.Managed(definitions.Definition).init(scratch);
    // Task/Handler locations refine general files without changing whether
    // a static vars load can admit a map-rooted document there (ADR-0045).
    if (kind == .general or kind == .role_tasks or kind == .role_handlers) try definitions.collectLoaded(forest, &loaded_roots);
    return .{
        .roots = roots.items,
        .fields = try fieldsBelow(scratch, forest, roots.items),
        .loaded_roots = loaded_roots.items,
        .loaded_fields = try fieldsBelow(scratch, forest, loaded_roots.items),
    };
}

fn fieldsBelow(scratch: Allocator, forest: *const yaml.Forest, roots: []const definitions.Definition) ![]const fields.Definition {
    var out = std.array_list.Managed(fields.Definition).init(scratch);
    try fields.below(scratch, forest, roots, &out);
    return out.items;
}

const testing = std.testing;

test "a map-rooted general file binds only when loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var forest = try yaml.parse(a, "namespace: acme\nversion: 1.0.0\ndependencies:\n  community.general: '*'\n");
    const general = try collect(a, &forest, .general);
    try testing.expectEqual(@as(usize, 0), general.roots.len);
    try testing.expectEqual(@as(usize, 0), general.fields.len);
    try testing.expectEqual(@as(usize, 3), general.loaded_roots.len);
    try testing.expectEqualStrings("version", general.loaded_roots[1].name);
    try testing.expectEqual(definitions.Site.vars_files, general.loaded_roots[1].site);
    try testing.expectEqualStrings("community.general", general.loaded_fields[0].name);

    const vars_file = try collect(a, &forest, .vars_file);
    try testing.expectEqual(@as(usize, 3), vars_file.roots.len);
    try testing.expectEqual(@as(usize, 1), vars_file.fields.len);
    try testing.expectEqual(@as(usize, 0), vars_file.loaded_roots.len);
}

test "Role task and Handler paths retain general-file load-only bindings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var forest = try yaml.parse(a, "settings: {port: 80}\n");
    defer forest.deinit();
    for ([_]definitions.FileKind{ .role_tasks, .role_handlers }) |kind| {
        const bound = try collect(a, &forest, kind);
        try testing.expectEqual(@as(usize, 0), bound.roots.len);
        try testing.expectEqual(@as(usize, 1), bound.loaded_roots.len);
        try testing.expectEqual(@as(usize, 1), bound.loaded_fields.len);
    }
}

test "a playbook's bindings do not depend on loads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var forest = try yaml.parse(a, "- hosts: all\n  vars:\n    config:\n      port: 80\n");
    const b = try collect(a, &forest, .general);
    try testing.expectEqual(@as(usize, 1), b.roots.len);
    try testing.expectEqualStrings("config", b.roots[0].name);
    try testing.expectEqualStrings("port", b.fields[0].name);
    try testing.expectEqual(@as(usize, 0), b.loaded_roots.len);
    try testing.expectEqual(@as(usize, 0), b.loaded_fields.len);
}
