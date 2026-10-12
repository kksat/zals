//! Per-file navigation facts stored in the Workspace index (ADR-0031).
//!
//! `extract` parses one file and records names, byte ranges and compact source
//! revision/line metadata, never source text or a parse tree. Every string is
//! allocated with the caller's allocator (an entry arena).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");
const role_reference = @import("../roles/reference.zig");
const role_resolve = @import("../roles/resolve.zig");
const file_refs = @import("file_refs.zig");
const collection_refs = @import("collection_refs.zig");
pub const symbols = @import("symbols.zig");
pub const FileRef = file_refs.FileRef;
const Node = yaml.Node;

pub const Definition = variables.definitions.Definition;

/// Exact source revision proof for on-demand descriptions. No source text or
/// parse tree is retained in the index.
pub const SourceFingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub fn sourceFingerprint(text: []const u8) SourceFingerprint {
    var fingerprint: SourceFingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &fingerprint, .{});
    return fingerprint;
}

pub const BindingLine = struct {
    start: usize,
    line: usize,
};

/// A named occurrence and its byte range.
pub const Span = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

/// A role invocation with the collections visible at this specific site.
pub const RoleRef = struct {
    name: []const u8,
    start: usize,
    end: usize,
    declared_collections: []const []const u8 = &.{},
};

pub const Facts = struct {
    /// Null for manually assembled facts without source-revision evidence.
    source_fingerprint: ?SourceFingerprint = null,
    /// Sorted binding offsets and their source-revision lines, including
    /// fields. Stale descriptions can retain locations without reading newer
    /// bytes at old offsets. These do not change binding/reference identities.
    binding_lines: []const BindingLine = &.{},
    var_defs: []const Definition = &.{},
    var_refs: []const Span = &.{},
    /// Nested mapping keys in recognized variable values.
    field_defs: []const variables.fields.Definition = &.{},
    /// Member reads, name-matched independently of their receiver.
    field_refs: []const Span = &.{},
    /// Role references (role invocations, `include_role`/`import_role`
    /// names, role dependencies).
    role_refs: []const RoleRef = &.{},
    /// Absolute targets and source kinds of `vars_files`/`include_vars` loads.
    var_loads: []const variables.scope.VarFileLoad = &.{},
    /// Task-file and vars-file references with their resolved targets.
    file_refs: []const FileRef = &.{},
    /// Collection references; `name` is `namespace.collection`.
    collection_refs: []const Span = &.{},
    /// Playbook, task file, or neither.
    shape: symbols.Shape = .other,
    /// Named plays, tasks, and handlers.
    symbols: []const symbols.Symbol = &.{},
};

/// Facts for the file at `path` with contents `text`.
pub fn extract(a: Allocator, path: []const u8, text: []const u8) !Facts {
    return extractIn(a, null, path, text);
}

/// Facts for the file at `path` in the Workspace rooted at `root` (used to
/// resolve file references).
pub fn extractIn(a: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    return extractInWithParser(a, a, root, path, text);
}

/// Keep parser storage separate from the facts' long-lived entry arena.
/// A nested arena backed by an entry arena cannot release its parse tree.
/// Returned facts own all their strings in `a`; no parse storage is borrowed.
pub fn extractInWithParser(a: Allocator, parser_allocator: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    // Collection source files contribute path-based symbols only. Python
    // DOCUMENTATION strings are not Ansible plays or variable definitions.
    if (!@import("discover.zig").isAnsibleFile(std.fs.path.basename(path))) return .{};
    return extractDependencyWithParser(a, parser_allocator, root, path, text);
}

/// Explicit vars-file loads are Ansible data regardless of their extension.
/// Keep this separate from Workspace discovery so Python DOCUMENTATION and
/// unrelated JSON files still cannot introduce navigation facts.
pub fn extractDependencyIn(a: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    return extractDependencyWithParser(a, a, root, path, text);
}

fn extractDependencyWithParser(a: Allocator, parser_allocator: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    var forest = yaml.parse(parser_allocator, text) catch return .{};
    defer forest.deinit();

    const kind = variables.scope.fileKind(path, role_resolve.enclosingRole(path));
    var defs = std.array_list.Managed(Definition).init(a);
    variables.definitions.collect(a, &forest, kind, &defs) catch {};
    for (defs.items) |*d| d.name = try a.dupe(u8, d.name);

    var idents = std.array_list.Managed(variables.jinja.Ident).init(a);
    variables.index.collectReferences(a, &forest, &idents) catch {};
    const refs = try a.alloc(Span, idents.items.len);
    for (idents.items, 0..) |r, i| refs[i] = .{ .name = try a.dupe(u8, r.name), .start = r.start, .end = r.end };

    var field_defs = std.array_list.Managed(variables.fields.Definition).init(a);
    variables.fields.collect(a, &forest, path, kind, &field_defs) catch {};

    var field_idents = std.array_list.Managed(variables.jinja.Ident).init(a);
    variables.index.collectFieldReferences(a, &forest, &field_idents) catch {};
    const field_refs = try a.alloc(Span, field_idents.items.len);
    for (field_idents.items, 0..) |r, i| field_refs[i] = .{ .name = try a.dupe(u8, r.name), .start = r.start, .end = r.end };

    var role_refs = std.array_list.Managed(RoleRef).init(a);
    for (forest.roots) |r| try walkRoleRefs(a, &forest, path, r, &role_refs);

    const sym = symbols.collect(a, &forest, path) catch symbols.Result{};

    const var_loads = variables.scope.varFileLoads(a, &forest, path, root) catch &.{};

    return .{
        .source_fingerprint = sourceFingerprint(text),
        .binding_lines = try bindingLines(a, text, defs.items, field_defs.items),
        .var_defs = try defs.toOwnedSlice(),
        .var_refs = refs,
        .field_defs = try field_defs.toOwnedSlice(),
        .field_refs = field_refs,
        .role_refs = try role_refs.toOwnedSlice(),
        .var_loads = var_loads,
        .file_refs = file_refs.collect(a, &forest, path, root) catch &.{},
        .collection_refs = collectionSpans(a, &forest, path) catch &.{},
        .shape = sym.shape,
        .symbols = sym.symbols,
    };
}

fn bindingLines(a: Allocator, text: []const u8, defs: []const Definition, fields: []const variables.fields.Definition) ![]const BindingLine {
    const lines = try a.alloc(BindingLine, defs.len + fields.len);
    for (defs, 0..) |def, i| lines[i] = .{ .start = def.start, .line = 1 };
    for (fields, defs.len..) |def, i| lines[i] = .{ .start = def.start, .line = 1 };
    std.mem.sort(BindingLine, lines, {}, struct {
        fn less(_: void, left: BindingLine, right: BindingLine) bool {
            return left.start < right.start;
        }
    }.less);
    var offset: usize = 0;
    var line: usize = 1;
    for (lines) |*binding| {
        const end = @min(binding.start, text.len);
        line += std.mem.count(u8, text[offset..end], "\n");
        binding.line = line;
        offset = end;
    }
    return lines;
}

fn collectionSpans(a: Allocator, forest: *const yaml.Forest, path: []const u8) ![]const Span {
    const spans = try collection_refs.collect(a, forest, path);
    const out = try a.alloc(Span, spans.len);
    for (spans, 0..) |c, i| out[i] = .{ .name = c.name, .start = c.start, .end = c.end };
    return out;
}

/// Visit every scalar and keep those `roles.reference.detect` recognises, so
/// the index and the cursor agree on what a role reference is.
fn walkRoleRefs(a: Allocator, forest: *yaml.Forest, file_path: []const u8, node: *Node, out: *std.array_list.Managed(RoleRef)) !void {
    switch (node.kind) {
        .scalar => {
            const path = try ancestors(forest.allocator(), node);
            if (role_reference.detect(path, forest.text)) |ref| {
                const declared = try yaml.collections.getRoleDeclaredCollections(forest.allocator(), file_path, path);
                const collections = try a.alloc([]const u8, declared.len);
                for (declared, 0..) |name, i| collections[i] = try a.dupe(u8, name);
                try out.append(.{
                    .name = try a.dupe(u8, ref.name),
                    .start = ref.start,
                    .end = ref.end,
                    .declared_collections = collections,
                });
            }
        },
        .map, .seq => for (node.items) |item| try walkRoleRefs(a, forest, file_path, item, out),
        .pair => if (node.val) |v| try walkRoleRefs(a, forest, file_path, v, out),
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
    try testing.expectEqual(@as(usize, 0), f.role_refs[0].declared_collections.len);
    try testing.expectEqualStrings("/w/vars/prod.yml", f.var_loads[0].path);
    try testing.expectEqual(variables.Site.vars_files, f.var_loads[0].site);
}

test "role facts retain per-site declared collections after parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try extract(a, "/w/site.yml",
        \\- hosts: all
        \\  collections: [ns.first]
        \\  roles: [web]
        \\- hosts: all
        \\  collections: [ns.second]
        \\  roles: [web]
        \\
    );
    try testing.expectEqual(@as(usize, 2), f.role_refs.len);
    try testing.expectEqualStrings("ns.first", f.role_refs[0].declared_collections[0]);
    try testing.expectEqualStrings("ns.second", f.role_refs[1].declared_collections[0]);

    const task = try extract(a, "/w/tasks.yml",
        \\- hosts: all
        \\  collections: [ns.play]
        \\  tasks:
        \\    - name: Invoke a role
        \\      collections: [ns.task]
        \\      include_role:
        \\        name: web
        \\
    );
    try testing.expectEqual(@as(usize, 1), task.role_refs.len);
    try testing.expectEqualStrings("ns.task", task.role_refs[0].declared_collections[0]);
    try testing.expectEqualStrings("ns.play", task.role_refs[0].declared_collections[1]);

    const metadata = try extract(a, "/w/roles/web/meta/main.yml",
        \\collections: [ns.meta]
        \\dependencies: [web]
        \\
    );
    try testing.expectEqualStrings("ns.meta", metadata.role_refs[0].declared_collections[0]);

    const non_play = try extract(a, "/w/config.yml",
        \\collections: [ns.install]
        \\roles: [web]
        \\
    );
    try testing.expectEqual(@as(usize, 1), non_play.role_refs.len);
    try testing.expectEqual(@as(usize, 0), non_play.role_refs[0].declared_collections.len);
}
