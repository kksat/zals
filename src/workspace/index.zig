//! The Workspace index (ADR-0031).
//!
//! One entry per discovered Ansible file, keyed by absolute path and carrying
//! its mtime and navigation facts. Scans run on the worker pool and hand
//! finished entries to a mutex-guarded pending queue; the main thread drains
//! that queue before it handles a message, so it stays the sole writer of the
//! entry map (ADR-0011).

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");
const discover_mod = @import("discover.zig");
const concurrency = @import("../concurrency/root.zig");

pub const Facts = facts_mod.Facts;

pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    /// Workspace root the file belongs to.
    root: []const u8,
    mtime: i128,
    facts: Facts,

    /// Parse `path` (or `text` when given) into a new entry.
    pub fn build(gpa: Allocator, root: []const u8, path: []const u8, text: ?[]const u8, mtime: i128) !*Entry {
        const self = try gpa.create(Entry);
        errdefer gpa.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.path = try a.dupe(u8, path);
        self.root = try a.dupe(u8, root);
        self.mtime = mtime;
        const body = text orelse (readFile(a, path) orelse "");
        self.facts = try facts_mod.extract(a, path, body);
        return self;
    }

    pub fn destroy(self: *Entry, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Discovery results for one Workspace root.
pub const RootInfo = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    roles_dirs: []const []const u8,
    collection_paths: []const []const u8,
    file_count: usize,

    fn destroy(self: *RootInfo, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

const Pending = struct {
    generation: u64,
    root: []const u8,
    entry: ?*Entry = null,
    info: ?*RootInfo = null,
    done: bool = false,
};

pub const WorkspaceIndex = struct {
    gpa: Allocator,
    /// Main-thread state.
    entries: std.StringHashMap(*Entry),
    infos: std.StringHashMap(*RootInfo),
    /// Current scan generation per root; stale scan output is dropped.
    generations: std.StringHashMap(u64),
    next_generation: u64 = 1,
    active_scans: usize = 0,
    /// Set when the last active scan finished and not yet reported.
    ready_event: bool = false,
    /// Worker → main handoff.
    mutex: std.Thread.Mutex = .{},
    pending: std.ArrayList(Pending) = .empty,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn create(gpa: Allocator) !*WorkspaceIndex {
        const self = try gpa.create(WorkspaceIndex);
        self.* = .{
            .gpa = gpa,
            .entries = std.StringHashMap(*Entry).init(gpa),
            .infos = std.StringHashMap(*RootInfo).init(gpa),
            .generations = std.StringHashMap(u64).init(gpa),
        };
        return self;
    }

    /// Free everything. Background scans must already be stopped (the pool
    /// joined) before this runs.
    pub fn destroy(self: *WorkspaceIndex) void {
        for (self.pending.items) |p| self.freePending(p);
        self.pending.deinit(self.gpa);
        var it = self.entries.valueIterator();
        while (it.next()) |e| e.*.destroy(self.gpa);
        self.entries.deinit();
        var iit = self.infos.valueIterator();
        while (iit.next()) |i| i.*.destroy(self.gpa);
        self.infos.deinit();
        var git = self.generations.keyIterator();
        while (git.next()) |k| self.gpa.free(k.*);
        self.generations.deinit();
        self.gpa.destroy(self);
    }

    /// Keep exactly `roots` indexed: scan roots that are new (or all of them
    /// when `rescan`), and drop entries of roots no longer in the session.
    pub fn syncRoots(self: *WorkspaceIndex, pool: *concurrency.ThreadPool, roots: []const []const u8, marker: []const u8, rescan: bool) !void {
        // Drop removed roots.
        var removed = std.array_list.Managed([]const u8).init(self.gpa);
        defer removed.deinit();
        var git = self.generations.keyIterator();
        while (git.next()) |k| {
            if (!contains(roots, k.*)) try removed.append(k.*);
        }
        for (removed.items) |root| self.dropRoot(root);

        for (roots) |root| {
            if (!rescan and self.generations.contains(root)) continue;
            try self.startScan(pool, root, marker);
        }
    }

    fn dropRoot(self: *WorkspaceIndex, root: []const u8) void {
        var doomed = std.array_list.Managed([]const u8).init(self.gpa);
        defer doomed.deinit();
        var it = self.entries.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.*.root, root)) doomed.append(e.key_ptr.*) catch {};
        }
        for (doomed.items) |k| {
            if (self.entries.fetchRemove(k)) |kv| kv.value.destroy(self.gpa);
        }
        if (self.infos.fetchRemove(root)) |kv| kv.value.destroy(self.gpa);
        if (self.generations.fetchRemove(root)) |kv| self.gpa.free(kv.key);
    }

    fn startScan(self: *WorkspaceIndex, pool: *concurrency.ThreadPool, root: []const u8, marker: []const u8) !void {
        const generation = self.next_generation;
        self.next_generation += 1;
        if (self.generations.getPtr(root)) |g| {
            g.* = generation;
        } else {
            try self.generations.put(try self.gpa.dupe(u8, root), generation);
        }
        const job = try self.gpa.create(ScanJob);
        errdefer self.gpa.destroy(job);
        job.* = .{
            .index = self,
            .root = try self.gpa.dupe(u8, root),
            .marker = try self.gpa.dupe(u8, marker),
            .generation = generation,
            .task = .{ .func = ScanJob.run, .ctx = job },
        };
        self.active_scans += 1;
        pool.submit(&job.task) catch |err| {
            self.active_scans -= 1;
            job.free();
            return err;
        };
    }

    /// Scan `root` on the calling thread. Tests and callers without a pool use
    /// this; it still goes through the pending queue.
    pub fn scanNow(self: *WorkspaceIndex, root: []const u8, marker: []const u8) !void {
        const generation = self.next_generation;
        self.next_generation += 1;
        if (self.generations.getPtr(root)) |g| {
            g.* = generation;
        } else {
            try self.generations.put(try self.gpa.dupe(u8, root), generation);
        }
        self.active_scans += 1;
        scan(self, root, marker, generation);
        self.drain();
    }

    /// Move finished scan output into the entry map. Main thread only.
    pub fn drain(self: *WorkspaceIndex) void {
        self.mutex.lock();
        const items = self.pending.toOwnedSlice(self.gpa) catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        defer self.gpa.free(items);

        for (items) |p| {
            const current = self.generations.get(p.root);
            const fresh = current != null and current.? == p.generation;
            if (p.done) {
                if (self.active_scans > 0) self.active_scans -= 1;
                if (self.active_scans == 0) self.ready_event = true;
            }
            if (!fresh) {
                self.freePending(p);
                continue;
            }
            if (p.entry) |e| self.putEntry(e);
            if (p.info) |ri| {
                if (self.infos.fetchRemove(ri.root)) |kv| kv.value.destroy(self.gpa);
                self.infos.put(ri.root, ri) catch ri.destroy(self.gpa);
            }
            self.gpa.free(p.root);
        }
    }

    /// True once after every started scan has finished.
    pub fn takeReadyEvent(self: *WorkspaceIndex) bool {
        const e = self.ready_event;
        self.ready_event = false;
        return e;
    }

    pub fn isScanning(self: *const WorkspaceIndex) bool {
        return self.active_scans > 0;
    }

    /// Re-index one file on the main thread (save, watched-file change).
    /// `root` is the Workspace that owns it.
    pub fn reindex(self: *WorkspaceIndex, root: []const u8, path: []const u8) void {
        const st = std.fs.cwd().statFile(path) catch {
            self.remove(path);
            return;
        };
        const e = Entry.build(self.gpa, root, path, null, st.mtime) catch return;
        self.putEntry(e);
    }

    pub fn remove(self: *WorkspaceIndex, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |kv| kv.value.destroy(self.gpa);
    }

    /// Re-stat every entry and re-parse those whose mtime changed; drop the
    /// ones that disappeared. Used when the client cannot watch files.
    pub fn refreshStale(self: *WorkspaceIndex) void {
        var stale = std.array_list.Managed(*Entry).init(self.gpa);
        defer stale.deinit();
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            const st = std.fs.cwd().statFile(e.*.path) catch {
                stale.append(e.*) catch {};
                continue;
            };
            if (st.mtime != e.*.mtime) stale.append(e.*) catch {};
        }
        for (stale.items) |e| {
            const root = self.gpa.dupe(u8, e.root) catch continue;
            defer self.gpa.free(root);
            const path = self.gpa.dupe(u8, e.path) catch continue;
            defer self.gpa.free(path);
            self.reindex(root, path);
        }
    }

    pub fn get(self: *const WorkspaceIndex, path: []const u8) ?*Entry {
        return self.entries.get(path);
    }

    pub fn info(self: *const WorkspaceIndex, root: []const u8) ?*RootInfo {
        return self.infos.get(root);
    }

    /// Entries of the Workspace rooted at `root`, sorted by path.
    pub fn entriesOf(self: *const WorkspaceIndex, a: Allocator, root: []const u8) ![]const *Entry {
        var out = std.array_list.Managed(*Entry).init(a);
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.*.root, root)) try out.append(e.*);
        }
        std.mem.sort(*Entry, out.items, {}, lessEntry);
        return out.toOwnedSlice();
    }

    pub fn count(self: *const WorkspaceIndex) usize {
        return self.entries.count();
    }

    fn putEntry(self: *WorkspaceIndex, e: *Entry) void {
        if (self.entries.fetchRemove(e.path)) |kv| kv.value.destroy(self.gpa);
        self.entries.put(e.path, e) catch e.destroy(self.gpa);
    }

    fn push(self: *WorkspaceIndex, p: Pending) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending.append(self.gpa, p) catch self.freePending(p);
    }

    fn freePending(self: *WorkspaceIndex, p: Pending) void {
        if (p.entry) |e| e.destroy(self.gpa);
        if (p.info) |i| i.destroy(self.gpa);
        self.gpa.free(p.root);
    }
};

const ScanJob = struct {
    index: *WorkspaceIndex,
    root: []u8,
    marker: []u8,
    generation: u64,
    task: concurrency.Task,

    fn run(ctx: *anyopaque) void {
        const self: *ScanJob = @ptrCast(@alignCast(ctx));
        defer self.free();
        scan(self.index, self.root, self.marker, self.generation);
    }

    fn free(self: *ScanJob) void {
        const gpa = self.index.gpa;
        gpa.free(self.root);
        gpa.free(self.marker);
        gpa.destroy(self);
    }
};

/// Walk and parse one Workspace, pushing entries, the root info, and a done
/// marker onto the pending queue. Safe on a worker thread: it touches only
/// the queue.
fn scan(index: *WorkspaceIndex, root: []const u8, marker: []const u8, generation: u64) void {
    const gpa = index.gpa;
    defer index.push(.{ .generation = generation, .root = gpa.dupe(u8, root) catch "", .done = true });

    const ri = gpa.create(RootInfo) catch return;
    ri.arena = std.heap.ArenaAllocator.init(gpa);
    const a = ri.arena.allocator();
    var walk_arena = std.heap.ArenaAllocator.init(gpa);
    defer walk_arena.deinit();
    const found = discover_mod.discover(walk_arena.allocator(), root, marker) catch {
        ri.destroy(gpa);
        return;
    };
    ri.root = a.dupe(u8, root) catch root;
    ri.roles_dirs = dupeAll(a, found.roles_dirs) catch &.{};
    ri.collection_paths = dupeAll(a, found.collection_paths) catch &.{};
    ri.file_count = found.files.len;
    index.push(.{ .generation = generation, .root = gpa.dupe(u8, root) catch "", .info = ri });

    for (found.files) |path| {
        if (index.shutdown.load(.acquire)) return;
        const st = std.fs.cwd().statFile(path) catch continue;
        const e = Entry.build(gpa, root, path, null, st.mtime) catch continue;
        index.push(.{ .generation = generation, .root = gpa.dupe(u8, root) catch "", .entry = e });
    }
}

fn dupeAll(a: Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |x, i| out[i] = try a.dupe(u8, x);
    return out;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn lessEntry(_: void, x: *Entry, y: *Entry) bool {
    return std.mem.order(u8, x.path, y.path) == .lt;
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 16 * 1024 * 1024) catch null;
}

const testing = std.testing;

const Tree = struct {
    root: []u8,

    fn init() !Tree {
        var n: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&n));
        const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zals-index-{x}", .{n});
        try std.fs.cwd().makePath(root);
        return .{ .root = root };
    }

    fn deinit(self: *Tree) void {
        std.fs.cwd().deleteTree(self.root) catch {};
        testing.allocator.free(self.root);
    }

    fn write(self: Tree, rel: []const u8, data: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.root, .{});
        defer dir.close();
        if (std.fs.path.dirname(rel)) |parent| try dir.makePath(parent);
        try dir.writeFile(.{ .sub_path = rel, .data = data });
    }

    fn path(self: Tree, rel: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.root, rel });
    }
};

test "scan indexes files and root info" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("site.yml", "- hosts: all\n  vars:\n    port: 1\n");
    try tree.write("roles/web/tasks/main.yml", "- debug: msg=\"{{ port }}\"\n");

    var index = try WorkspaceIndex.create(testing.allocator);
    defer index.destroy();
    try index.scanNow(tree.root, ".git");

    try testing.expectEqual(@as(usize, 2), index.count());
    try testing.expect(index.takeReadyEvent());
    try testing.expect(!index.isScanning());
    const info = index.info(tree.root).?;
    try testing.expectEqual(@as(usize, 1), info.roles_dirs.len);

    const site = try tree.path("site.yml");
    defer testing.allocator.free(site);
    try testing.expectEqualStrings("port", index.get(site).?.facts.var_defs[0].name);
}

test "reindex and refreshStale pick up changes" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("site.yml", "- hosts: all\n  vars:\n    port: 1\n");

    var index = try WorkspaceIndex.create(testing.allocator);
    defer index.destroy();
    try index.scanNow(tree.root, ".git");

    const site = try tree.path("site.yml");
    defer testing.allocator.free(site);
    try tree.write("site.yml", "- hosts: all\n  vars:\n    other: 1\n");
    index.reindex(tree.root, site);
    try testing.expectEqualStrings("other", index.get(site).?.facts.var_defs[0].name);

    try std.fs.cwd().deleteFile(site);
    index.refreshStale();
    try testing.expect(index.get(site) == null);
}

test "pool scan delivers through drain" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("a.yml", "x: 1\n");
    try tree.write("b.yml", "y: 1\n");

    var pool = try concurrency.ThreadPool.init(testing.allocator, 2);
    var index = try WorkspaceIndex.create(testing.allocator);
    try index.syncRoots(pool, &.{tree.root}, ".git", false);
    var tries: usize = 0;
    while (index.isScanning() and tries < 2000) : (tries += 1) {
        index.drain();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 2), index.count());
    // Removing the root drops its entries.
    try index.syncRoots(pool, &.{}, ".git", false);
    try testing.expectEqual(@as(usize, 0), index.count());
    pool.deinit();
    index.destroy();
}
