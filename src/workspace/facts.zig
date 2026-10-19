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
    /// Root and field bindings this file adds only when a vars load in the
    /// Workspace targets it (ADR-0045). Classification is per file, so the
    /// index records them here and query time decides; see `loaded`.
    load_var_defs: []const Definition = &.{},
    load_field_defs: []const variables.fields.Definition = &.{},
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

    /// These facts as a vars-load target: load-only bindings join the
    /// file's other bindings. Facts without them are returned unchanged.
    /// Only the two binding slices are allocated with `a`; strings stay
    /// shared with the original facts.
    pub fn loaded(self: Facts, a: Allocator) !Facts {
        if (self.load_var_defs.len == 0 and self.load_field_defs.len == 0) return self;
        var out = self;
        out.var_defs = try std.mem.concat(a, Definition, &.{ self.var_defs, self.load_var_defs });
        out.field_defs = try std.mem.concat(a, variables.fields.Definition, &.{ self.field_defs, self.load_field_defs });
        out.load_var_defs = &.{};
        out.load_field_defs = &.{};
        return out;
    }
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
/// unrelated JSON files still cannot introduce navigation facts. The result
/// is a load target, so it includes load-only bindings.
pub fn extractDependencyIn(a: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    return (try extractDependencyWithParser(a, a, root, path, text)).loaded(a);
}

const Interner = struct {
    arena: Allocator,
    scratch: Allocator,
    strings: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn get(self: *Interner, s: []const u8) ![]const u8 {
        if (s.len == 0) return "";
        if (self.strings.get(s)) |owned| return owned;
        const owned = try self.arena.dupe(u8, s);
        try self.strings.putNoClobber(self.scratch, owned, owned);
        return owned;
    }
};

fn extractDependencyWithParser(a: Allocator, parser_allocator: Allocator, root: ?[]const u8, path: []const u8, text: []const u8) !Facts {
    var forest = yaml.parse(parser_allocator, text) catch return .{};
    defer forest.deinit();
    const scratch = forest.allocator();
    var interner = Interner{ .arena = a, .scratch = scratch };

    const kind = variables.scope.fileKind(path, role_resolve.enclosingRole(path));
    const bound = variables.bindings.collect(scratch, &forest, kind) catch variables.bindings.Bindings{};
    const defs = try internDefinitions(a, &interner, bound.roots);
    const field_defs = try internFieldDefinitions(a, &interner, bound.fields);
    const load_defs = try internDefinitions(a, &interner, bound.loaded_roots);
    const load_field_defs = try internFieldDefinitions(a, &interner, bound.loaded_fields);

    var idents = std.array_list.Managed(variables.jinja.Ident).init(scratch);
    variables.index.collectReferences(scratch, &forest, &idents) catch {};
    const refs = try internIdents(a, &interner, idents.items);

    var field_idents = std.array_list.Managed(variables.jinja.Ident).init(scratch);
    variables.index.collectFieldReferences(scratch, &forest, &field_idents) catch {};
    const field_refs = try internIdents(a, &interner, field_idents.items);

    var raw_role_refs = std.array_list.Managed(RoleRef).init(scratch);
    var role_path = std.array_list.Managed(*Node).init(scratch);
    for (forest.roots) |r| try walkRoleRefs(a, &interner, &forest, path, r, &role_path, &raw_role_refs);
    const role_refs: []const RoleRef = if (raw_role_refs.items.len == 0) &.{} else try a.dupe(RoleRef, raw_role_refs.items);

    const sym = symbols.collect(scratch, &forest, path) catch symbols.Result{};
    const syms = try internSymbols(a, &interner, sym.symbols);

    const raw_loads = variables.scope.varFileLoads(scratch, &forest, path, root) catch &.{};
    const var_loads = try internVarLoads(a, &interner, raw_loads);

    const raw_file_refs = file_refs.collect(scratch, &forest, path, root) catch &.{};
    const f_refs = try internFileRefs(a, &interner, raw_file_refs);

    const raw_col_refs = collection_refs.collect(scratch, &forest, path) catch &.{};
    const col_refs = try internCollectionSpans(a, &interner, raw_col_refs);

    return .{
        .source_fingerprint = sourceFingerprint(text),
        .binding_lines = try bindingLines(a, text, &.{ defs, load_defs }, &.{ field_defs, load_field_defs }),
        .var_defs = defs,
        .var_refs = refs,
        .field_defs = field_defs,
        .load_var_defs = load_defs,
        .load_field_defs = load_field_defs,
        .field_refs = field_refs,
        .role_refs = role_refs,
        .var_loads = var_loads,
        .file_refs = f_refs,
        .collection_refs = col_refs,
        .shape = sym.shape,
        .symbols = syms,
    };
}

/// Load-only bindings are included, so a description stays revision-safe
/// whether or not the file is loaded at query time.
fn bindingLines(a: Allocator, text: []const u8, defs: []const []const Definition, fields: []const []const variables.fields.Definition) ![]const BindingLine {
    var total: usize = 0;
    for (defs) |group| total += group.len;
    for (fields) |group| total += group.len;
    if (total == 0) return &.{};
    const lines = try a.alloc(BindingLine, total);
    var i: usize = 0;
    for (defs) |group| for (group) |def| {
        lines[i] = .{ .start = def.start, .line = 1 };
        i += 1;
    };
    for (fields) |group| for (group) |def| {
        lines[i] = .{ .start = def.start, .line = 1 };
        i += 1;
    };
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

fn internDefinitions(a: Allocator, interner: *Interner, defs: []const Definition) ![]const Definition {
    if (defs.len == 0) return &.{};
    const out = try a.alloc(Definition, defs.len);
    for (defs, 0..) |d, i| {
        out[i] = .{
            .name = try interner.get(d.name),
            .start = d.start,
            .end = d.end,
            .site = d.site,
        };
    }
    return out;
}

fn internIdents(a: Allocator, interner: *Interner, idents: []const variables.jinja.Ident) ![]const Span {
    if (idents.len == 0) return &.{};
    const out = try a.alloc(Span, idents.len);
    for (idents, 0..) |r, i| {
        out[i] = .{ .name = try interner.get(r.name), .start = r.start, .end = r.end };
    }
    return out;
}

fn internFieldDefinitions(a: Allocator, interner: *Interner, defs: []const variables.fields.Definition) ![]const variables.fields.Definition {
    if (defs.len == 0) return &.{};
    const out = try a.alloc(variables.fields.Definition, defs.len);
    for (defs, 0..) |d, i| {
        const path_out: []const []const u8 = if (d.path.len == 0) &.{} else blk: {
            const segs = try a.alloc([]const u8, d.path.len);
            for (d.path, 0..) |seg, j| segs[j] = try interner.get(seg);
            break :blk segs;
        };
        out[i] = .{
            .name = try interner.get(d.name),
            .start = d.start,
            .end = d.end,
            .site = d.site,
            .path = path_out,
        };
    }
    return out;
}

fn internSymbols(a: Allocator, interner: *Interner, syms: []const symbols.Symbol) ![]const symbols.Symbol {
    if (syms.len == 0) return &.{};
    const out = try a.alloc(symbols.Symbol, syms.len);
    for (syms, 0..) |s, i| {
        out[i] = .{
            .name = try interner.get(s.name),
            .kind = s.kind,
            .play = try interner.get(s.play),
            .start = s.start,
            .end = s.end,
        };
    }
    return out;
}

fn internVarLoads(a: Allocator, interner: *Interner, loads: []const variables.scope.VarFileLoad) ![]const variables.scope.VarFileLoad {
    if (loads.len == 0) return &.{};
    const out = try a.alloc(variables.scope.VarFileLoad, loads.len);
    for (loads, 0..) |load, i| {
        out[i] = .{
            .path = try interner.get(load.path),
            .site = load.site,
        };
    }
    return out;
}

fn internFileRefs(a: Allocator, interner: *Interner, refs: []const FileRef) ![]const FileRef {
    if (refs.len == 0) return &.{};
    const out = try a.alloc(FileRef, refs.len);
    for (refs, 0..) |r, i| {
        out[i] = .{
            .kind = r.kind,
            .raw = try interner.get(r.raw),
            .target = try interner.get(r.target),
            .start = r.start,
            .end = r.end,
        };
    }
    return out;
}

fn internCollectionSpans(a: Allocator, interner: *Interner, spans: []const collection_refs.Span) ![]const Span {
    if (spans.len == 0) return &.{};
    const out = try a.alloc(Span, spans.len);
    for (spans, 0..) |c, i| {
        out[i] = .{ .name = try interner.get(c.name), .start = c.start, .end = c.end };
    }
    return out;
}

/// Visit every scalar and keep those `roles.reference.detect` recognises, so
/// the index and the cursor agree on what a role reference is.
fn walkRoleRefs(
    a: Allocator,
    interner: *Interner,
    forest: *yaml.Forest,
    file_path: []const u8,
    node: *Node,
    path: *std.array_list.Managed(*Node),
    out: *std.array_list.Managed(RoleRef),
) !void {
    try path.append(node);
    defer _ = path.pop();
    switch (node.kind) {
        .scalar => {
            if (role_reference.detect(path.items, forest.text)) |ref| {
                const declared = try yaml.collections.getRoleDeclaredCollections(forest.allocator(), file_path, path.items);
                const collections: []const []const u8 = if (declared.len == 0) &.{} else blk: {
                    const cols = try a.alloc([]const u8, declared.len);
                    for (declared, 0..) |name, i| cols[i] = try interner.get(name);
                    break :blk cols;
                };
                try out.append(.{
                    .name = try interner.get(ref.name),
                    .start = ref.start,
                    .end = ref.end,
                    .declared_collections = collections,
                });
            }
        },
        .map, .seq => for (node.items) |item| try walkRoleRefs(a, interner, forest, file_path, item, path, out),
        .pair => if (node.val) |v| try walkRoleRefs(a, interner, forest, file_path, v, path, out),
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

test "extract interns repeated names and play labels within an entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const f = try extractInWithParser(arena.allocator(), scratch.allocator(), null, "/w/site.yml",
        \\- name: Configure web
        \\  hosts: all
        \\  collections: [ns.col]
        \\  vars:
        \\    settings:
        \\      port: 8080
        \\  roles: [web]
        \\  tasks:
        \\    - name: First task
        \\      ns.col.mod:
        \\        msg: "{{ settings.port }} {{ settings.port }}"
        \\    - name: Second task
        \\      debug:
        \\        msg: "{{ settings.port }}"
        \\
    );
    try testing.expectEqual(f.var_defs[0].name.ptr, f.var_refs[0].name.ptr);
    try testing.expectEqual(f.var_refs[0].name.ptr, f.var_refs[1].name.ptr);
    try testing.expectEqual(f.var_defs[0].name.ptr, f.field_defs[0].path[0].ptr);
    try testing.expectEqual(f.field_defs[0].name.ptr, f.field_defs[0].path[1].ptr);
    try testing.expectEqual(f.field_defs[0].name.ptr, f.field_refs[0].name.ptr);
    try testing.expectEqual(f.field_refs[0].name.ptr, f.field_refs[1].name.ptr);
    try testing.expectEqual(f.role_refs[0].declared_collections[0].ptr, f.collection_refs[0].name.ptr);
    try testing.expectEqual(f.collection_refs[0].name.ptr, f.collection_refs[1].name.ptr);
    try testing.expectEqual(f.symbols[0].name.ptr, f.symbols[1].play.ptr);
    try testing.expectEqual(f.symbols[1].play.ptr, f.symbols[2].play.ptr);
}

test "map-rooted metadata binds only as a vars-load target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const galaxy = try extract(a, "/w/galaxy.yml", "namespace: acme\nversion: 1.0.0\ndependencies:\n  acme.base: '*'\n");
    try testing.expectEqual(@as(usize, 0), galaxy.var_defs.len);
    try testing.expectEqual(@as(usize, 0), galaxy.field_defs.len);
    const loaded = try galaxy.loaded(a);
    try testing.expectEqual(@as(usize, 3), loaded.var_defs.len);
    try testing.expectEqualStrings("version", loaded.var_defs[1].name);
    try testing.expectEqualStrings("acme.base", loaded.field_defs[0].name);
    try testing.expectEqual(@as(usize, 0), loaded.load_var_defs.len);

    // Load-only names share the entry's interned strings.
    const settings = try extract(a, "/w/settings.yml", "version: 2\nlabel: \"{{ version }}\"\n");
    try testing.expectEqual(settings.var_refs[0].name.ptr, settings.load_var_defs[0].name.ptr);

    const group_vars = try extract(a, "/w/inventory/group_vars/all.yml", "version: 2\n");
    try testing.expectEqualStrings("version", group_vars.var_defs[0].name);
    try testing.expectEqual(variables.Site.vars_files, group_vars.var_defs[0].site);
}
