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
const definitions_mod = @import("definitions.zig");
const scope = @import("scope.zig");
const source_mod = @import("source.zig");

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
};

pub const Cursor = struct {
    name: []const u8,
    kind: OccurrenceKind,
};

pub const Index = struct {
    allocator: Allocator,
    source: FileSource,

    pub fn init(allocator: Allocator, source: FileSource) Index {
        return .{ .allocator = allocator, .source = source };
    }

    /// The variable occurrence under `offset` in `uri`, or null.
    pub fn occurrenceAt(self: *Index, a: Allocator, uri: []const u8, offset: usize) !?Cursor {
        const path = try scope.uriToPath(a, uri);
        const scan = try self.scanFile(a, uri, path);
        for (scan.definitions) |d| {
            if (d.start <= offset and offset <= d.end) {
                return .{ .name = d.name, .kind = .definition };
            }
        }
        for (scan.references) |r| {
            if (r.start <= offset and offset <= r.end) {
                return .{ .name = r.name, .kind = .reference };
            }
        }
        return null;
    }

    /// The variable occurrence under `offset` in an already-parsed `forest`.
    ///
    /// The returned name points into `forest`'s arena, so it is valid only
    /// while the forest is alive. Used by providers that parse the document
    /// once and need both the variable and its YAML context.
    pub fn occurrenceInForest(
        a: Allocator,
        forest: *const dom.Forest,
        path: []const u8,
        offset: usize,
    ) !?Cursor {
        var defs = std.array_list.Managed(Definition).init(a);
        try definitions_mod.collect(a, forest, scope.fileKind(path), &defs);
        for (defs.items) |d| {
            if (d.start <= offset and offset <= d.end) {
                return .{ .name = d.name, .kind = .definition };
            }
        }
        var refs = std.array_list.Managed(jinja.Ident).init(a);
        for (forest.roots) |root| try collectRefs(a, root, forest.text, &refs);
        for (refs.items) |r| {
            if (r.start <= offset and offset <= r.end) {
                return .{ .name = r.name, .kind = .reference };
            }
        }
        return null;
    }

    /// Every occurrence of `name` in the file set that owns `uri`.
    pub fn occurrences(self: *Index, a: Allocator, uri: []const u8, name: []const u8) ![]Occurrence {
        const files = try self.fileSet(a, uri);
        var out = std.array_list.Managed(Occurrence).init(a);
        for (files) |file_uri| {
            const path = try scope.uriToPath(a, file_uri);
            const scan = try self.scanFile(a, file_uri, path);
            for (scan.definitions) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    try out.append(.{
                        .uri = file_uri,
                        .start = d.start,
                        .end = d.end,
                        .kind = .definition,
                        .site = d.site,
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
        definitions: []Definition,
        references: []jinja.Ident,
    };

    fn scanFile(self: *Index, a: Allocator, uri: []const u8, path: []const u8) !FileScan {
        const text = (try self.source.read(a, uri)) orelse return .{ .definitions = &.{}, .references = &.{} };
        var forest = yaml.parse(a, text) catch return .{ .definitions = &.{}, .references = &.{} };
        defer forest.deinit();

        var defs = std.array_list.Managed(Definition).init(a);
        try definitions_mod.collect(a, &forest, scope.fileKind(path), &defs);

        var refs = std.array_list.Managed(jinja.Ident).init(a);
        for (forest.roots) |root| try collectRefs(a, root, forest.text, &refs);

        return .{
            .definitions = try dupeDefinitions(a, defs.items),
            .references = try dupeIdents(a, refs.items),
        };
    }

    /// The file set for `uri`: the role's conventional dirs, or the playbook
    /// file, plus one level of `vars_files`/`include_vars` targets.
    fn fileSet(self: *Index, a: Allocator, uri: []const u8) ![]const []const u8 {
        const path = try scope.uriToPath(a, uri);
        var base = std.array_list.Managed([]const u8).init(a);
        if (scope.roleRoot(a, self.source, path)) |root| {
            const role_files = try scope.enumerateFiles(a, self.source, root);
            for (role_files) |f| try base.append(try scope.pathToUri(a, f));
        } else {
            try base.append(try a.dupe(u8, uri));
        }

        var all = std.array_list.Managed([]const u8).init(a);
        for (base.items) |u| try appendUnique(a, &all, u);

        for (base.items) |u| {
            const p = try scope.uriToPath(a, u);
            const text = (try self.source.read(a, u)) orelse continue;
            var forest = yaml.parse(a, text) catch continue;
            defer forest.deinit();
            const base_dir = std.fs.path.dirname(p) orelse ".";
            const targets = try scope.varFileTargets(a, &forest, base_dir);
            for (targets) |t| {
                const target_uri = try scope.pathToUri(a, t);
                try appendUnique(a, &all, target_uri);
            }
        }
        return all.toOwnedSlice();
    }
};

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
    try walkRefs(a, node, text, out, false);
}

fn walkRefs(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
    bare: bool,
) !void {
    switch (node.kind) {
        .map => {
            for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
                const val = pair.val orelse continue;
                const is_bare = isBareExprKey(key);
                if (is_bare) try scanBare(a, val, text, out);
                try walkRefs(a, val, text, out, is_bare);
            }
        },
        .seq => for (node.items) |item| try walkRefs(a, item, text, out, bare),
        .scalar => if (!bare) {
            const st = scalarText(node, text);
            try jinja.scanScalar(a, st.s, st.base, out);
        },
        else => {},
    }
}

fn scanBare(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
) !void {
    if (node.isScalar()) {
        const st = scalarText(node, text);
        try jinja.scanExpression(a, st.s, st.base, out);
    } else if (node.isSeq()) {
        for (node.items) |item| {
            if (!item.isScalar()) continue;
            const st = scalarText(item, text);
            try jinja.scanExpression(a, st.s, st.base, out);
        }
    }
}

/// The unquoted text of a scalar and its absolute base offset.
fn scalarText(node: *const Node, text: []const u8) struct { s: []const u8, base: usize } {
    if (node.end > text.len or node.start > node.end) return .{ .s = "", .base = node.start };
    const raw = text[node.start..node.end];
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) {
        return .{ .s = raw[1 .. raw.len - 1], .base = node.start + 1 };
    }
    return .{ .s = raw, .base = node.start };
}

const testing = std.testing;

/// In-memory filesystem for tests. Files are keyed by URI; directories are
/// derived from the file paths.
const MapSource = struct {
    files: std.StringHashMap([]const u8),

    fn read(ptr: *anyopaque, allocator: Allocator, uri: []const u8) anyerror!?[]const u8 {
        const self: *MapSource = @ptrCast(@alignCast(ptr));
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
    // defaults key + argument_specs option + task usage + template usage
    try testing.expectEqual(@as(usize, 4), occ.len);

    var defs: usize = 0;
    var refs: usize = 0;
    for (occ) |o| {
        if (o.kind == .definition) defs += 1 else refs += 1;
    }
    try testing.expectEqual(@as(usize, 2), defs);
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
