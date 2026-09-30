//! Per-file navigation facts stored in the Workspace index (ADR-0031).
//!
//! `extract` parses one file and records names and byte ranges only, so an
//! entry never keeps a parse tree. Every string is allocated with the caller's
//! allocator (an entry arena).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");
const role_reference = @import("../roles/reference.zig");
const file_refs = @import("file_refs.zig");
pub const FileRef = file_refs.FileRef;
const Node = yaml.Node;

pub const Definition = variables.definitions.Definition;

/// A named occurrence and its byte range.
pub const Span = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

pub const Facts = struct {
    var_defs: []const Definition = &.{},
    var_refs: []const Span = &.{},
    /// Role references (role invocations, `include_role`/`import_role`
    /// names, role dependencies).
    role_refs: []const Span = &.{},
    /// Absolute paths loaded by `vars_files` and `include_vars`.
    vars_targets: []const []const u8 = &.{},
    /// Task-file and vars-file references with their resolved targets.
    file_refs: []const FileRef = &.{},
};

/// Facts for the file at `path` with contents `text`.
pub fn extract(a: Allocator, path: []const u8, text: []const u8) !Facts {
    return extractIn(a, null, path, text);
}

/// Facts for the file at `path` in the Workspace rooted at `root` (used to
/// resolve file references).
pub fn extractIn(a: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    var forest = yaml.parse(a, text) catch return .{};
    defer forest.deinit();

    var defs = std.array_list.Managed(Definition).init(a);
    variables.definitions.collect(a, &forest, variables.scope.fileKind(path), &defs) catch {};
    for (defs.items) |*d| d.name = try a.dupe(u8, d.name);

    var idents = std.array_list.Managed(variables.jinja.Ident).init(a);
    variables.index.collectReferences(a, &forest, &idents) catch {};
    const refs = try a.alloc(Span, idents.items.len);
    for (idents.items, 0..) |r, i| refs[i] = .{ .name = try a.dupe(u8, r.name), .start = r.start, .end = r.end };

    var role_refs = std.array_list.Managed(Span).init(a);
    for (forest.roots) |r| try walkRoleRefs(a, r, forest.text, &role_refs);

    const base_dir = std.fs.path.dirname(path) orelse ".";
    const targets = variables.scope.varFileTargets(a, &forest, base_dir) catch &.{};
    const vars_targets = try a.alloc([]const u8, targets.len);
    for (targets, 0..) |t, i| vars_targets[i] = try a.dupe(u8, t);

    return .{
        .var_defs = try defs.toOwnedSlice(),
        .var_refs = refs,
        .role_refs = try role_refs.toOwnedSlice(),
        .vars_targets = vars_targets,
        .file_refs = file_refs.collect(a, &forest, path, root) catch &.{},
    };
}

/// Visit every scalar and keep those `roles.reference.detect` recognises, so
/// the index and the cursor agree on what a role reference is.
fn walkRoleRefs(a: Allocator, node: *Node, text: []const u8, out: *std.array_list.Managed(Span)) !void {
    switch (node.kind) {
        .scalar => {
            const path = try ancestors(a, node);
            if (role_reference.detect(path, text)) |ref| {
                try out.append(.{ .name = try a.dupe(u8, ref.name), .start = ref.start, .end = ref.end });
            }
        },
        .map, .seq => for (node.items) |item| try walkRoleRefs(a, item, text, out),
        .pair => if (node.val) |v| try walkRoleRefs(a, v, text, out),
        else => {},
    }
}

/// `node` and its parents, root first.
pub fn ancestors(a: Allocator, node: *Node) ![]*Node {
    var buf = std.array_list.Managed(*Node).init(a);
    var n: ?*Node = node;
    while (n) |cur| {
        try buf.append(cur);
        n = cur.parent;
    }
    std.mem.reverse(*Node, buf.items);
    return buf.toOwnedSlice();
}

const testing = std.testing;

test "extract records variable definitions and references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\- hosts: all
        \\  vars:
        \\    app_port: 8080
        \\  tasks:
        \\    - debug: msg="{{ app_port }}"
        \\
    ;
    const f = try extract(a, "/w/site.yml", text);
    try testing.expectEqual(@as(usize, 1), f.var_defs.len);
    try testing.expectEqualStrings("app_port", f.var_defs[0].name);
    try testing.expectEqual(@as(usize, 1), f.var_refs.len);
    try testing.expectEqualStrings("app_port", f.var_refs[0].name);
}

test "extract records role references and vars targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\- hosts: all
        \\  vars_files:
        \\    - vars/prod.yml
        \\  roles:
        \\    - web
        \\    - role: db
        \\  tasks:
        \\    - include_role:
        \\        name: cache
        \\
    ;
    const f = try extract(a, "/w/site.yml", text);
    try testing.expectEqual(@as(usize, 3), f.role_refs.len);
    try testing.expectEqualStrings("web", f.role_refs[0].name);
    try testing.expectEqualStrings("db", f.role_refs[1].name);
    try testing.expectEqualStrings("cache", f.role_refs[2].name);
    try testing.expectEqualStrings("web", text[f.role_refs[0].start..f.role_refs[0].end]);
    try testing.expectEqualStrings("/w/vars/prod.yml", f.vars_targets[0]);
}
