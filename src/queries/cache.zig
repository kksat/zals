const std = @import("std");
const Allocator = std.mem.Allocator;
const discover = @import("../workspace/discover.zig");
const facts_mod = @import("../workspace/facts.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");
const workspace_session = @import("../workspace/session.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const FileSet = context_mod.FileSet;

pub const Probe = struct {
    path: []const u8,
    mtime: i128,
};

const SetEntry = struct {
    set: *FileSet,
    probes: []const Probe,
};

pub const DirPaths = struct {
    roles: []const []const u8,
    collections: []const []const u8,
};

const DocEntry = struct {
    arena: std.heap.ArenaAllocator,
    doc_address: usize = 0,
    version: i64 = -1,
    root: ?[]const u8 = null,
    facts: facts_mod.Facts = .{},
    dependency: ?facts_mod.Facts = null,
};

const Stamps = struct {
    entries: u64,
    documents: u64,
    session: u64,
};

const PathStamps = struct {
    entries: u64,
    session: u64,
};

pub const Cache = struct {
    gpa: Allocator,
    sets_arena: std.heap.ArenaAllocator,
    paths_arena: std.heap.ArenaAllocator,
    sets: std.StringHashMapUnmanaged(*SetEntry) = .empty,
    paths: std.StringHashMapUnmanaged([]const u8) = .empty,
    dirs: std.StringHashMapUnmanaged(*DirPaths) = .empty,
    docs: std.StringHashMapUnmanaged(*DocEntry) = .empty,
    set_stamps: Stamps = .{ .entries = 0, .documents = 0, .session = 0 },
    path_stamps: PathStamps = .{ .entries = 0, .session = 0 },
    probe_sink: ?std.array_list.Managed(Probe) = null,

    pub fn create(gpa: Allocator) !*Cache {
        const self = try gpa.create(Cache);
        self.* = .{
            .gpa = gpa,
            .sets_arena = std.heap.ArenaAllocator.init(gpa),
            .paths_arena = std.heap.ArenaAllocator.init(gpa),
        };
        return self;
    }

    pub fn destroy(self: *Cache) void {
        self.sets.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        self.dirs.deinit(self.gpa);
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.arena.deinit();
            self.gpa.destroy(entry.value_ptr.*);
            self.gpa.free(entry.key_ptr.*);
        }
        self.docs.deinit(self.gpa);
        self.sets_arena.deinit();
        self.paths_arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn beginRequest(self: *Cache, entries: u64, documents: u64, session: u64) void {
        if (entries != self.set_stamps.entries or documents != self.set_stamps.documents or session != self.set_stamps.session) {
            self.resetSets();
            self.set_stamps = .{ .entries = entries, .documents = documents, .session = session };
        }
        if (entries != self.path_stamps.entries or session != self.path_stamps.session) {
            _ = self.paths_arena.reset(.retain_capacity);
            self.paths.clearRetainingCapacity();
            self.dirs.clearRetainingCapacity();
            self.path_stamps = .{ .entries = entries, .session = session };
        }
    }

    fn resetSets(self: *Cache) void {
        _ = self.sets_arena.reset(.retain_capacity);
        self.sets.clearRetainingCapacity();
        self.probe_sink = null;
    }

    pub fn setAllocator(self: *Cache) Allocator {
        return self.sets_arena.allocator();
    }

    pub fn lookupSet(self: *Cache, key: []const u8) !?*FileSet {
        const entry = self.sets.get(key) orelse return null;
        for (entry.probes) |probe| {
            const st = std.fs.cwd().statFile(probe.path) catch {
                self.resetSets();
                return null;
            };
            if (st.mtime != probe.mtime) {
                self.resetSets();
                return null;
            }
        }
        return entry.set;
    }

    pub fn beginSetBuild(self: *Cache) !void {
        const sink = try std.array_list.Managed(Probe).initCapacity(self.gpa, 4);
        self.probe_sink = sink;
    }

    pub fn storeSet(self: *Cache, key: []const u8, set: *FileSet) !void {
        const sink = self.probe_sink orelse return;
        self.probe_sink = null;
        const a = self.sets_arena.allocator();
        const entry = try a.create(SetEntry);
        entry.* = .{
            .set = set,
            .probes = try a.dupe(Probe, sink.items),
        };
        sink.deinit();
        try self.sets.put(self.gpa, try a.dupe(u8, key), entry);
    }

    pub fn recordProbe(self: *Cache, path: []const u8) void {
        if (self.probe_sink == null) return;
        const sink = &self.probe_sink.?;
        const st = std.fs.cwd().statFile(path) catch return;
        const a = self.sets_arena.allocator();
        const owned = a.dupe(u8, path) catch return;
        sink.append(.{ .path = owned, .mtime = st.mtime }) catch {};
    }

    pub fn dropSetBuild(self: *Cache) void {
        if (self.probe_sink) |*sink| {
            sink.deinit();
            self.probe_sink = null;
        }
    }

    pub fn pathOf(self: *Cache, uri: []const u8) ![]const u8 {
        if (self.paths.get(uri)) |found| return found;
        const a = self.paths_arena.allocator();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const raw = try paths.uriToPath(scratch.allocator(), uri);
        const resolved = try workspace_session.resolvedPath(a, raw);
        try self.paths.put(self.gpa, try a.dupe(u8, uri), resolved);
        return resolved;
    }

    pub fn dirPaths(self: *Cache, context: *Context, file_path: []const u8) !*DirPaths {
        const dir = std.fs.path.dirname(file_path) orelse file_path;
        if (self.dirs.get(dir)) |found| return found;
        const a = self.paths_arena.allocator();
        const found = try a.create(DirPaths);
        found.* = .{
            .roles = try project_config.rolesPaths(a, context.projectContext(file_path), file_path),
            .collections = try project_config.collectionsPaths(a, context.projectContext(file_path), file_path),
        };
        try self.dirs.put(self.gpa, try a.dupe(u8, dir), found);
        return found;
    }

    pub fn forgetDocument(self: *Cache, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            kv.value.arena.deinit();
            self.gpa.destroy(kv.value);
            self.gpa.free(kv.key);
        }
    }

    fn docEntry(self: *Cache, uri: []const u8) !*DocEntry {
        if (self.docs.get(uri)) |found| return found;
        const key = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(key);
        const entry = try self.gpa.create(DocEntry);
        errdefer self.gpa.destroy(entry);
        entry.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
        try self.docs.put(self.gpa, key, entry);
        return entry;
    }

    fn refresh(entry: *DocEntry, context: *Context, root: ?[]const u8, path: []const u8, uri: []const u8) !void {
        const doc = context.session.documents.get(uri) orelse return;
        if (entry.doc_address == @intFromPtr(doc) and entry.version == doc.version and sameRoot(entry.root, root)) return;
        _ = entry.arena.reset(.{ .retain_with_limit = 128 * 1024 });
        const a = entry.arena.allocator();
        entry.doc_address = @intFromPtr(doc);
        entry.version = doc.version;
        entry.root = if (root) |r| try a.dupe(u8, r) else null;
        entry.dependency = null;
        entry.facts = try facts_mod.extractDocumentIn(a, root, path, doc.bytes());
    }

    pub fn overlayFacts(self: *Cache, context: *Context, root: ?[]const u8, path: []const u8, uri: []const u8) !facts_mod.Facts {
        if (!discover.isAnsibleFile(std.fs.path.basename(path))) return .{};
        const entry = try self.docEntry(uri);
        try refresh(entry, context, root, path, uri);
        return entry.facts;
    }

    pub fn documentFacts(self: *Cache, context: *Context, root: ?[]const u8, path: []const u8, uri: []const u8) !facts_mod.Facts {
        const entry = try self.docEntry(uri);
        try refresh(entry, context, root, path, uri);
        return entry.facts;
    }

    pub fn dependencyFacts(self: *Cache, context: *Context, root: ?[]const u8, path: []const u8, uri: []const u8) !facts_mod.Facts {
        const entry = try self.docEntry(uri);
        try refresh(entry, context, root, path, uri);
        if (entry.dependency) |found| return found;
        const merged = try entry.facts.loaded(entry.arena.allocator());
        entry.dependency = merged;
        return merged;
    }
};

fn sameRoot(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

const testing = std.testing;
const Fixture = @import("testing.zig").Fixture;

const Definition = @import("../variables/definitions.zig").Definition;

fn countNamed(defs: []const Definition, name: []const u8) usize {
    var n: usize = 0;
    for (defs) |def| {
        if (std.mem.eql(u8, def.name, name)) n += 1;
    }
    return n;
}

test "open-document facts follow edits and close forgets" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try fixture.write("site.yml", "- hosts: all\n  vars:\n    port: 1\n");
    const uri = try fixture.open("site.yml", "- hosts: all\n  vars:\n    port: 2\n");
    try fixture.scan();
    var cache = try Cache.create(testing.allocator);
    defer cache.destroy();

    {
        var context = try fixture.contextWithCache(cache);
        const facts = (try context.documentFacts(uri)).?;
        try testing.expectEqual(@as(usize, 1), countNamed(facts.var_defs, "port"));
    }
    fixture.release();
    try fixture.documents.applyChanges(uri, 2, &.{.{ .text = "- hosts: all\n  vars:\n    other: 1\n" }});
    {
        var context = try fixture.contextWithCache(cache);
        const facts = (try context.documentFacts(uri)).?;
        try testing.expectEqual(@as(usize, 0), countNamed(facts.var_defs, "port"));
        try testing.expectEqual(@as(usize, 1), countNamed(facts.var_defs, "other"));
    }
    fixture.release();

    cache.forgetDocument(uri);
    try testing.expectEqual(@as(usize, 0), cache.docs.count());
}

test "a cached workspace set survives unchanged requests and rebuilds on edit" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    const task = "- debug: msg=\"{{ port }}\"\n";
    try fixture.write("roles/db/defaults/main.yml", "port: 5432\n");
    try fixture.write("roles/db/tasks/main.yml", task);
    const uri = try fixture.open("roles/db/tasks/main.yml", task);
    try fixture.scan();
    var cache = try Cache.create(testing.allocator);
    defer cache.destroy();

    const filesOf = struct {
        fn run(f: *Fixture, c: *Cache, u: []const u8) !usize {
            var context = try f.contextWithCache(c);
            const ws = (try context.workspaceOf(u)).?;
            return ws.files.len;
        }
    }.run;

    const first = try filesOf(&fixture, cache, uri);
    fixture.release();
    try testing.expect(first > 0);
    const second = try filesOf(&fixture, cache, uri);
    fixture.release();
    try testing.expectEqual(first, second);

    _ = try fixture.documents.applyChanges(uri, 2, &.{.{ .text = "- debug: msg=hi\n" }});
    const third = try filesOf(&fixture, cache, uri);
    fixture.release();
    try testing.expectEqual(first, third);
}

test "mtime probes rebuild a cached set whose load target changed on disk" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    const play = "- hosts: all\n  vars_files: [data.json]\n  tasks:\n    - debug: msg=\"{{ port }}\"\n";
    try fixture.write("site.yml", play);
    try fixture.write("data.json", "{\"port\": 1}\n");
    const uri = try fixture.open("site.yml", play);
    var cache = try Cache.create(testing.allocator);
    defer cache.destroy();

    const defsOf = struct {
        fn run(f: *Fixture, c: *Cache, u: []const u8) !usize {
            var context = try f.contextWithCache(c);
            const ws = try context.searchFiles(u);
            var n: usize = 0;
            for (ws.files) |file| {
                n += file.facts.var_defs.len;
            }
            return n;
        }
    }.run;

    try testing.expectEqual(@as(usize, 1), try defsOf(&fixture, cache, uri));
    fixture.release();
    try fixture.write("data.json", "{\"port\": 1, \"extra\": 2}\n");
    try testing.expectEqual(@as(usize, 2), try defsOf(&fixture, cache, uri));
    fixture.release();
}
