//! The variable index: the shared seam behind find-references and
//! go-to-definition (ADR-0024, ADR-0025).
//!
//! The index is stateless per request. It reads file text and directory
//! listings through a `FileSource` seam (so tests can inject an in-memory
//! filesystem), builds the file set for the cursor's role or playbook, and
//! scans each file for definitions and references.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const dom = @import("../yaml/dom.zig");
const Node = dom.Node;
const jinja = @import("jinja.zig");
const scalar_expression = @import("scalar_expression.zig");
const definitions_mod = @import("definitions.zig");
const scope = @import("scope.zig");
const bindings = @import("bindings.zig");
const fields_mod = @import("fields.zig");
const source_mod = @import("source.zig");
const roles = @import("../roles/resolve.zig");

pub const FileSource = source_mod.FileSource;
pub const DirEntry = source_mod.DirEntry;
pub const Definition = definitions_mod.Definition;
pub const Site = definitions_mod.Site;

pub const OccurrenceKind = enum { definition, reference };

pub const Occurrence = struct {
    uri: []const u8,
    start: usize,
    end: usize,
    kind: OccurrenceKind,
    site: ?Site = null,
    /// Root and mapping keys for a field definition; lists add no component.
    /// Root occurrences and field reads do not carry a structured binding path.
    field_path: []const []const u8 = &.{},
};

pub const Cursor = struct {
    name: []const u8,
    kind: OccurrenceKind,
    /// Byte range of this occurrence. `end` is exclusive. Zero when a caller
    /// only needed the name.
    start: usize = 0,
    end: usize = 0,
    /// A key that binds only if a vars load targets its file (ADR-0045). The
    /// caller decides, because loads live in other files.
    requires_load: bool = false,
};

pub const Index = struct {
    allocator: Allocator,
    source: FileSource,
    scans: std.StringHashMapUnmanaged(FileScan) = .empty,
    role_roots: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    file_sets: std.StringHashMapUnmanaged(FileSet) = .empty,

    pub fn init(allocator: Allocator, source: FileSource) Index {
        return .{ .allocator = allocator, .source = source };
    }

    /// A field read or key, in a separate name group from root variables.
    pub fn fieldOccurrenceAt(self: *Index, a: Allocator, uri: []const u8, offset: usize) !?Cursor {
        const scan = try self.scanFile(a, uri, try scope.uriToPath(a, uri));
        for (scan.field_defs) |d| {
            if (d.start <= offset and offset <= d.end) return .{
                .name = d.name,
                .kind = .definition,
                .start = d.start,
                .end = d.end,
            };
        }
        for (scan.field_refs) |r| {
            if (r.start <= offset and offset <= r.end) return .{
                .name = r.name,
                .kind = .reference,
                .start = r.start,
                .end = r.end,
            };
        }
        for (scan.loaded_field_defs) |d| {
            if (d.start <= offset and offset <= d.end) return .{
                .name = d.name,
                .kind = .definition,
                .start = d.start,
                .end = d.end,
                .requires_load = true,
            };
        }
        return null;
    }

    pub fn fieldOccurrences(self: *Index, a: Allocator, uri: []const u8, name: []const u8) ![]Occurrence {
        const files = try self.fileSet(a, uri);
        var out = std.array_list.Managed(Occurrence).init(a);
        for (files.uris) |file_uri| {
            const path = try scope.uriToPath(a, file_uri);
            const scan = try self.scanFile(a, file_uri, path);
            const field_defs = if (isLoaded(files.loads, path)) try std.mem.concat(a, fields_mod.Definition, &.{ scan.field_defs, scan.loaded_field_defs }) else scan.field_defs;
            for (field_defs) |d| {
                if (!std.mem.eql(u8, d.name, name)) continue;
                var site = d.site;
                for (files.loads) |load| {
                    if (std.mem.eql(u8, load.path, path) and load.site.rank() < site.rank()) site = load.site;
                }
                try out.append(.{ .uri = file_uri, .start = d.start, .end = d.end, .kind = .definition, .site = site, .field_path = d.path });
            }
            for (scan.field_refs) |r| {
                if (std.mem.eql(u8, r.name, name)) try out.append(.{
                    .uri = file_uri,
                    .start = r.start,
                    .end = r.end,
                    .kind = .reference,
                });
            }
        }
        return out.toOwnedSlice();
    }

    pub fn fieldDefinitions(self: *Index, a: Allocator, uri: []const u8, name: []const u8) ![]Occurrence {
        var out = std.array_list.Managed(Occurrence).init(a);
        for (try self.fieldOccurrences(a, uri, name)) |occurrence| {
            if (occurrence.kind == .definition) try out.append(occurrence);
        }
        std.mem.sort(Occurrence, out.items, {}, lessByRank);
        return out.toOwnedSlice();
    }

    /// The variable occurrence under `offset` in `uri`, or null.
    pub fn occurrenceAt(self: *Index, a: Allocator, uri: []const u8, offset: usize) !?Cursor {
        const path = try scope.uriToPath(a, uri);
        const scan = try self.scanFile(a, uri, path);
        for (scan.definitions) |d| {
            if (d.start <= offset and offset <= d.end) {
                return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end };
            }
        }
        for (scan.references) |r| {
            if (r.start <= offset and offset <= r.end) {
                return .{ .name = r.name, .kind = .reference, .start = r.start, .end = r.end };
            }
        }
        for (scan.loaded_definitions) |d| {
            if (d.start <= offset and offset <= d.end) {
                return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end, .requires_load = true };
            }
        }
        return null;
    }

    /// The variable occurrence under `offset` in an already-parsed `forest`.
    ///
    /// Names borrow `forest` or normalization storage owned by `a`; keep both
    /// alive while using the cursor. Used by providers that parse the document
    /// once and need both the variable and its YAML context.
    pub fn occurrenceInForest(
        a: Allocator,
        forest: *const dom.Forest,
        path: []const u8,
        offset: usize,
    ) !?Cursor {
        var defs = std.array_list.Managed(Definition).init(a);
        try definitions_mod.collect(a, forest, scope.fileKind(path, roles.enclosingRole(path)), &defs);
        for (defs.items) |d| {
            if (d.start <= offset and offset <= d.end) {
                return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end };
            }
        }
        var refs = std.array_list.Managed(jinja.Ident).init(a);
        for (forest.roots) |root| try collectRefs(a, root, forest.text, &refs);
        for (refs.items) |r| {
            if (r.start <= offset and offset <= r.end) {
                return .{ .name = r.name, .kind = .reference, .start = r.start, .end = r.end };
            }
        }
        return null;
    }

    /// Every occurrence of `name` in the file set that owns `uri`.
    pub fn occurrences(self: *Index, a: Allocator, uri: []const u8, name: []const u8) ![]Occurrence {
        const files = try self.fileSet(a, uri);
        var out = std.array_list.Managed(Occurrence).init(a);
        for (files.uris) |file_uri| {
            const path = try scope.uriToPath(a, file_uri);
            const scan = try self.scanFile(a, file_uri, path);
            const defs = if (isLoaded(files.loads, path)) try std.mem.concat(a, Definition, &.{ scan.definitions, scan.loaded_definitions }) else scan.definitions;
            for (defs) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    var site = d.site;
                    for (files.loads) |load| {
                        if (std.mem.eql(u8, load.path, path) and load.site.rank() < site.rank()) site = load.site;
                    }
                    try out.append(.{
                        .uri = file_uri,
                        .start = d.start,
                        .end = d.end,
                        .kind = .definition,
                        .site = site,
                    });
                }
            }
            for (scan.references) |r| {
                if (std.mem.eql(u8, r.name, name)) {
                    try out.append(.{ .uri = file_uri, .start = r.start, .end = r.end, .kind = .reference });
                }
            }
        }
        return out.toOwnedSlice();
    }

    /// Visible definitions of `name`, ranked by precedence (ADR-0024).
    ///
    /// Visibility is approximated by the file set: every definition in the
    /// enclosing role or playbook is a candidate. Per-site scoping (a
    /// `loop_control.loop_var` is only visible inside its loop body) is not yet
    /// modelled.
    pub fn definitions(self: *Index, a: Allocator, uri: []const u8, name: []const u8) ![]Occurrence {
        const all = try self.occurrences(a, uri, name);
        var defs = std.array_list.Managed(Occurrence).init(a);
        for (all) |o| {
            if (o.kind == .definition) try defs.append(o);
        }
        std.mem.sort(Occurrence, defs.items, {}, lessByRank);
        return defs.toOwnedSlice();
    }

    /// Text of `uri`, for mapping byte offsets to positions.
    pub fn fileText(self: *Index, a: Allocator, uri: []const u8) !?[]const u8 {
        return self.source.read(a, uri);
    }

    const FileScan = struct {
        definitions: []Definition = &.{},
        references: []jinja.Ident = &.{},
        field_refs: []jinja.Ident = &.{},
        field_defs: []fields_mod.Definition = &.{},
        loads: []const scope.VarFileLoad = &.{},
        /// Bindings that apply only when a vars load targets the file.
        loaded_definitions: []Definition = &.{},
        loaded_field_defs: []fields_mod.Definition = &.{},
    };

    fn cachedRoleRoot(self: *Index, a: Allocator, path: []const u8) !?[]const u8 {
        const dir = std.fs.path.dirname(path) orelse return null;
        if (self.role_roots.get(dir)) |root| return root;
        const root = scope.roleRoot(a, self.source, path);
        try self.role_roots.put(a, try a.dupe(u8, dir), root);
        return root;
    }

    fn scanFile(self: *Index, a: Allocator, uri: []const u8, path: []const u8) !FileScan {
        if (self.scans.get(uri)) |cached| return cached;

        const text = (try self.source.read(a, uri)) orelse {
            const empty = FileScan{};
            try self.scans.put(a, try a.dupe(u8, uri), empty);
            return empty;
        };
        defer a.free(text);
        var forest = yaml.parse(a, text) catch {
            const empty = FileScan{};
            try self.scans.put(a, try a.dupe(u8, uri), empty);
            return empty;
        };
        defer forest.deinit();
        const scratch = forest.allocator();

        const role_root = try self.cachedRoleRoot(a, path);
        const bound = try bindings.collect(scratch, &forest, scope.fileKind(path, role_root));

        var refs = std.array_list.Managed(jinja.Ident).init(scratch);
        for (forest.roots) |root| try collectRefs(scratch, root, forest.text, &refs);

        var field_refs = std.array_list.Managed(jinja.Ident).init(scratch);
        try collectFieldReferences(scratch, &forest, &field_refs);
        const loads = scope.varFileLoads(a, &forest, path, null) catch &.{};

        const scan = FileScan{
            .definitions = try dupeDefinitions(a, bound.roots),
            .references = try dupeIdents(a, refs.items),
            .field_refs = try dupeIdents(a, field_refs.items),
            .field_defs = try dupeFieldDefinitions(a, bound.fields),
            .loads = loads,
            .loaded_definitions = try dupeDefinitions(a, bound.loaded_roots),
            .loaded_field_defs = try dupeFieldDefinitions(a, bound.loaded_fields),
        };
        try self.scans.put(a, try a.dupe(u8, uri), scan);
        return scan;
    }

    /// The file set for `uri`: the role's conventional dirs, or the playbook
    /// file, plus one level of `vars_files`/`include_vars` targets.
    const FileSet = struct {
        uris: []const []const u8,
        loads: []const scope.VarFileLoad,
    };

    fn fileSet(self: *Index, a: Allocator, uri: []const u8) !FileSet {
        const path = try scope.uriToPath(a, uri);
        const role_root = try self.cachedRoleRoot(a, path);
        const cache_key = role_root orelse uri;
        if (self.file_sets.get(cache_key)) |cached| return cached;

        var base = std.array_list.Managed([]const u8).init(a);
        if (role_root) |root| {
            const role_files = try scope.enumerateFiles(a, self.source, root);
            for (role_files) |f| {
                if (std.fs.path.dirname(f)) |f_dir| {
                    if (!self.role_roots.contains(f_dir)) {
                        try self.role_roots.put(a, try a.dupe(u8, f_dir), root);
                    }
                }
                try base.append(try scope.pathToUri(a, f));
            }
        } else {
            try base.append(try a.dupe(u8, uri));
        }

        var all = std.array_list.Managed([]const u8).init(a);
        var loads = std.array_list.Managed(scope.VarFileLoad).init(a);
        for (base.items) |u| try appendUnique(a, &all, u);

        for (base.items) |u| {
            const p = try scope.uriToPath(a, u);
            const scan = try self.scanFile(a, u, p);
            for (scan.loads) |load| {
                try loads.append(load);
                const target_uri = try scope.pathToUri(a, load.path);
                try appendUnique(a, &all, target_uri);
            }
        }
        const set = FileSet{ .uris = try all.toOwnedSlice(), .loads = try loads.toOwnedSlice() };
        try self.file_sets.put(a, try a.dupe(u8, cache_key), set);
        return set;
    }
};

fn isLoaded(loads: []const scope.VarFileLoad, path: []const u8) bool {
    for (loads) |load| if (std.mem.eql(u8, load.path, path)) return true;
    return false;
}

fn appendUnique(a: Allocator, list: *std.array_list.Managed([]const u8), uri: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, uri)) return;
    }
    try list.append(try a.dupe(u8, uri));
}

fn lessByRank(_: void, x: Occurrence, y: Occurrence) bool {
    const rx = if (x.site) |s| s.rank() else 99;
    const ry = if (y.site) |s| s.rank() else 99;
    return rx < ry;
}

fn dupeDefinitions(a: Allocator, defs: []const Definition) ![]Definition {
    const out = try a.alloc(Definition, defs.len);
    for (defs, 0..) |d, i| {
        out[i] = .{
            .name = try a.dupe(u8, d.name),
            .start = d.start,
            .end = d.end,
            .site = d.site,
        };
    }
    return out;
}

/// Field names and paths come from parse-lifetime scratch storage.
fn dupeFieldDefinitions(a: Allocator, defs: []const fields_mod.Definition) ![]fields_mod.Definition {
    const out = try a.alloc(fields_mod.Definition, defs.len);
    for (defs, 0..) |d, i| {
        const path = try a.alloc([]const u8, d.path.len);
        for (d.path, 0..) |segment, j| path[j] = try a.dupe(u8, segment);
        out[i] = .{
            .name = if (path.len > 0) path[path.len - 1] else try a.dupe(u8, d.name),
            .start = d.start,
            .end = d.end,
            .site = d.site,
            .path = path,
        };
    }
    return out;
}

fn dupeIdents(a: Allocator, idents: []const jinja.Ident) ![]jinja.Ident {
    const out = try a.alloc(jinja.Ident, idents.len);
    for (idents, 0..) |r, i| {
        out[i] = .{ .name = try a.dupe(u8, r.name), .start = r.start, .end = r.end };
    }
    return out;
}

fn isBareExprKey(key: []const u8) bool {
    const set = [_][]const u8{ "when", "changed_when", "failed_when", "until", "loop", "that" };
    for (set) |s| if (std.mem.eql(u8, key, s)) return true;
    return std.mem.startsWith(u8, key, "with_");
}

fn collectRefs(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
) !void {
    try walkRefs(a, node, text, out, false, .roots);
}

/// Every variable reference in `forest`: Jinja root identifiers and names in
/// bare-expression keys.
pub fn collectReferences(a: Allocator, forest: *const dom.Forest, out: *std.array_list.Managed(jinja.Ident)) !void {
    for (forest.roots) |root| try collectRefs(a, root, forest.text, out);
}

pub fn collectFieldReferences(a: Allocator, forest: *const dom.Forest, out: *std.array_list.Managed(jinja.Ident)) !void {
    for (forest.roots) |root| try walkRefs(a, root, forest.text, out, false, .fields);
}

const RefNames = scalar_expression.Names;

fn walkRefs(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
    bare: bool,
    names: RefNames,
) !void {
    switch (node.kind) {
        .map => {
            for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
                const val = pair.val orelse continue;
                const is_bare = isBareExprKey(key);
                if (is_bare) try scanBare(a, val, text, out, names);
                try walkRefs(a, val, text, out, is_bare, names);
            }
        },
        .seq => for (node.items) |item| try walkRefs(a, item, text, out, bare, names),
        .scalar => if (!bare) try scalar_expression.scan(a, node, text, names, false, out),
        else => {},
    }
}

fn scanBare(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
    names: RefNames,
) !void {
    if (node.isScalar()) {
        try scalar_expression.scan(a, node, text, names, true, out);
    } else if (node.isSeq()) {
        for (node.items) |item| {
            if (!item.isScalar()) continue;
            try scalar_expression.scan(a, item, text, names, true, out);
        }
    }
}

const testing = std.testing;

/// In-memory filesystem for tests. Files are keyed by URI; directories are
/// derived from the file paths.
const MapSource = struct {
    files: std.StringHashMap([]const u8),
    reads: usize = 0,

    fn read(ptr: *anyopaque, allocator: Allocator, uri: []const u8) anyerror!?[]const u8 {
        const self: *MapSource = @ptrCast(@alignCast(ptr));
        self.reads += 1;
        const text = self.files.get(uri) orelse return null;
        return try allocator.dupe(u8, text);
    }

    fn listDir(ptr: *anyopaque, allocator: Allocator, path: []const u8) anyerror![]const DirEntry {
        const self: *MapSource = @ptrCast(@alignCast(ptr));
        var out = std.array_list.Managed(DirEntry).init(allocator);
        var seen = std.StringHashMap(void).init(allocator);
        var it = self.files.iterator();
        while (it.next()) |e| {
            const p = try scope.uriToPath(allocator, e.key_ptr.*);
            var dir = std.fs.path.dirname(p);
            while (dir) |d| {
                const parent = std.fs.path.dirname(d);
                if (parent) |par| {
                    if (std.mem.eql(u8, par, path)) {
                        const base = std.fs.path.basename(d);
                        if (!seen.contains(base)) {
                            try seen.put(base, {});
                            try out.append(.{ .name = base, .is_dir = true });
                        }
                    }
                }
                dir = parent;
            }
            if (std.fs.path.dirname(p)) |d| {
                if (std.mem.eql(u8, d, path)) {
                    const base = std.fs.path.basename(p);
                    if (!seen.contains(base)) {
                        try seen.put(base, {});
                        try out.append(.{ .name = base, .is_dir = false });
                    }
                }
            }
        }
        return out.toOwnedSlice();
    }

    fn source(self: *MapSource) FileSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = FileSource.VTable{ .read = read, .listDir = listDir };
};

test "references across a role" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///r/meta/main.yml", "---\n");
    try files.put("file:///r/defaults/main.yml", "app_name: demo\napp_port: 8080\n");
    try files.put("file:///r/tasks/main.yml",
        \\- name: show
        \\  debug:
        \\    msg: "{{ app_name }}:{{ app_port }}"
        \\  when: app_name == 'demo'
        \\
    );
    var src = MapSource{ .files = files };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, src.source());
    const occ = try index.occurrences(a, "file:///r/tasks/main.yml", "app_name");
    // definition in defaults + two references in tasks (msg and when)
    try testing.expectEqual(@as(usize, 3), occ.len);
    var defs: usize = 0;
    var refs: usize = 0;
    for (occ) |o| {
        if (o.kind == .definition) defs += 1 else refs += 1;
    }
    try testing.expectEqual(@as(usize, 1), defs);
    try testing.expectEqual(@as(usize, 2), refs);
}

test "occurrenceAt finds a reference" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///r/tasks/main.yml", "- debug: msg=\"{{ app_name }}\"\n");
    var src = MapSource{ .files = files };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, src.source());
    const text = (try index.fileText(a, "file:///r/tasks/main.yml")).?;
    const off = std.mem.indexOf(u8, text, "app_name").?;
    const cur = (try index.occurrenceAt(a, "file:///r/tasks/main.yml", off)).?;
    try testing.expectEqualStrings("app_name", cur.name);
    try testing.expectEqual(OccurrenceKind.reference, cur.kind);
}

test "definitions are ranked" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///r/meta/main.yml", "---\n");
    try files.put("file:///r/defaults/main.yml", "foo: 1\n");
    try files.put("file:///r/vars/main.yml", "foo: 2\n");
    var src = MapSource{ .files = files };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, src.source());
    const defs = try index.definitions(a, "file:///r/vars/main.yml", "foo");
    try testing.expectEqual(@as(usize, 2), defs.len);
    // role vars (rank 7) before role defaults (rank 11)
    try testing.expectEqual(Site.role_vars, defs[0].site.?);
    try testing.expectEqual(Site.role_defaults, defs[1].site.?);
}

test "without a Workspace, a map-rooted file binds only through a load in the file set" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///p/site.yml",
        \\- hosts: all
        \\  vars_files: [settings.yml]
        \\  tasks:
        \\    - debug: msg="{{ version }} {{ channel }}"
        \\
    );
    try files.put("file:///p/settings.yml", "channel: stable\nconfig:\n  version: 3\n");
    try files.put("file:///p/galaxy.yml", "version: 1.0.0\n");
    var src = MapSource{ .files = files };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var index = Index.init(a, src.source());

    const channel = try index.definitions(a, "file:///p/site.yml", "channel");
    try testing.expectEqual(@as(usize, 1), channel.len);
    try testing.expectEqualStrings("file:///p/settings.yml", channel[0].uri);
    try testing.expectEqual(Site.vars_files, channel[0].site.?);
    const field = try index.fieldDefinitions(a, "file:///p/site.yml", "version");
    try testing.expectEqual(@as(usize, 1), field.len);
    try testing.expectEqualStrings("file:///p/settings.yml", field[0].uri);
    try testing.expectEqual(@as(usize, 0), (try index.definitions(a, "file:///p/site.yml", "version")).len);

    // The caller decides whether a load-only key binds; nothing here loads galaxy.yml.
    const cur = (try index.occurrenceAt(a, "file:///p/galaxy.yml", 0)).?;
    try testing.expectEqualStrings("version", cur.name);
    try testing.expect(cur.requires_load);
    try testing.expectEqual(@as(usize, 0), (try index.definitions(a, "file:///p/galaxy.yml", "version")).len);
}

/// Disk-backed source for fixture tests. Paths are relative to the repo root,
/// which is the working directory under `zig build test`.
const DiskSource = struct {
    fn read(_: *anyopaque, allocator: Allocator, uri: []const u8) anyerror!?[]const u8 {
        const path = try scope.uriToPath(allocator, uri);
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        return file.readToEndAlloc(allocator, 1 << 20) catch null;
    }

    fn listDir(_: *anyopaque, allocator: Allocator, path: []const u8) anyerror![]const DirEntry {
        var out = std.array_list.Managed(DirEntry).init(allocator);
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return out.toOwnedSlice();
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            try out.append(.{
                .name = try allocator.dupe(u8, entry.name),
                .is_dir = entry.kind == .directory,
            });
        }
        return out.toOwnedSlice();
    }

    const vtable = FileSource.VTable{ .read = read, .listDir = listDir };

    fn source() FileSource {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

test "fixture role references span defaults, meta, tasks, and templates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, DiskSource.source());
    const uri = "file://test/fixtures/roles/demo/tasks/main.yml";
    const occ = try index.occurrences(a, uri, "app_name");
    // defaults key + argument_specs option in meta/main.yml + argument_specs
    // option in meta/argument_specs.yml + task usage + template usage
    try testing.expectEqual(@as(usize, 5), occ.len);

    var defs: usize = 0;
    var refs: usize = 0;
    for (occ) |o| {
        if (o.kind == .definition) defs += 1 else refs += 1;
    }
    try testing.expectEqual(@as(usize, 3), defs);
    try testing.expectEqual(@as(usize, 2), refs);

    // register: definition + usage
    const app_result = try index.occurrences(a, uri, "app_result");
    try testing.expectEqual(@as(usize, 2), app_result.len);

    // loop_control.loop_var: definition + usage
    const entry = try index.occurrences(a, uri, "entry");
    try testing.expectEqual(@as(usize, 2), entry.len);
}

test "vars_files targets are in scope" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///p/play.yml",
        \\- hosts: all
        \\  vars_files:
        \\    - extra.yml
        \\  tasks:
        \\    - debug: msg="{{ extra_var }}"
        \\
    );
    try files.put("file:///p/extra.yml", "extra_var: hello\n");
    var src = MapSource{ .files = files };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, src.source());
    const occ = try index.occurrences(a, "file:///p/play.yml", "extra_var");
    try testing.expectEqual(@as(usize, 2), occ.len);
    var defs: usize = 0;
    for (occ) |o| {
        if (o.kind == .definition) defs += 1;
    }
    try testing.expectEqual(@as(usize, 1), defs);
}

test "include_vars definitions outrank vars_files from the same playbook" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///p/play.yml",
        \\- hosts: all
        \\  vars_files: [release.yml]
        \\  tasks:
        \\    - include_vars: runtime.yml
        \\    - debug: msg="{{ rollout_channel }}"
        \\
    );
    try files.put("file:///p/release.yml", "rollout_channel: planned\n");
    try files.put("file:///p/runtime.yml", "rollout_channel: active\n");
    var src = MapSource{ .files = files };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var index = Index.init(a, src.source());

    const defs = try index.definitions(a, "file:///p/play.yml", "rollout_channel");
    try testing.expectEqual(@as(usize, 2), defs.len);
    try testing.expectEqualStrings("file:///p/runtime.yml", defs[0].uri);
    try testing.expectEqual(Site.include_vars, defs[0].site.?);
    try testing.expectEqualStrings("file:///p/release.yml", defs[1].uri);
    try testing.expectEqual(Site.vars_files, defs[1].site.?);
}

test "fixture playbook scope is the file alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, DiskSource.source());
    const uri = "file://test/fixtures/playbook.yml";

    // play_var: definition + usage
    const play_var = try index.occurrences(a, uri, "play_var");
    try testing.expectEqual(@as(usize, 2), play_var.len);

    // prompted_var: vars_prompt name + usage
    const prompted = try index.occurrences(a, uri, "prompted_var");
    try testing.expectEqual(@as(usize, 2), prompted.len);

    // app_name is only used in the playbook; its definitions live in the role.
    const app_name = try index.occurrences(a, uri, "app_name");
    try testing.expectEqual(@as(usize, 1), app_name.len);
    try testing.expectEqual(OccurrenceKind.reference, app_name[0].kind);

    // app_port is a role invocation param in the playbook.
    const app_port = try index.occurrences(a, uri, "app_port");
    try testing.expectEqual(@as(usize, 1), app_port.len);
    try testing.expectEqual(Site.role_param, app_port[0].site.?);
}

test "Index memoizes file scans and role roots across queries" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("file:///r/meta/main.yml", "---\n");
    try files.put("file:///r/defaults/main.yml", "app: { port: 8080 }\n");
    try files.put("file:///r/tasks/main.yml", "- debug: msg=\"{{ app.port }}\"\n");
    var src = MapSource{ .files = files };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = Index.init(a, src.source());
    const occ = try index.occurrences(a, "file:///r/tasks/main.yml", "app");
    try testing.expectEqual(@as(usize, 2), occ.len);
    const reads_after_first = src.reads;
    // 1 read for isRoleRoot(meta/main.yml) + 3 reads for the 3 role files (not re-read in occurrences after fileSet)
    try testing.expectEqual(@as(usize, 4), reads_after_first);

    const field_occ = try index.fieldOccurrences(a, "file:///r/tasks/main.yml", "port");
    try testing.expectEqual(@as(usize, 2), field_occ.len);
    try testing.expectEqual(reads_after_first, src.reads);
}
