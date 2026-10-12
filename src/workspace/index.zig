//! The Workspace index (ADR-0031).
//!
//! One entry per discovered Ansible file, keyed by absolute path and carrying
//! its mtime and navigation facts. Scans run on the worker pool and hand
//! finished entries to a mutex-guarded pending queue; the main thread drains
//! that queue between messages, so it stays the sole writer of the entry map
//! (ADR-0011). A query lease keeps entry and root-info arenas alive throughout
//! a request; worker results remain pending until the lease is released.

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
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        return buildWithScratch(gpa, scratch.allocator(), root, path, text, mtime);
    }

    fn buildWithScratch(gpa: Allocator, temporary: Allocator, root: []const u8, path: []const u8, text: ?[]const u8, mtime: i128) !*Entry {
        const self = try gpa.create(Entry);
        errdefer gpa.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.path = try a.dupe(u8, path);
        self.root = try a.dupe(u8, root);
        self.mtime = mtime;
        // Source candidates contribute path-only symbols, so never read their
        // Python/PowerShell bodies. YAML text and parser storage are temporary,
        // not backed by the entry arena which survives for the whole session.
        const body = if (text == null and discover_mod.isAnsibleFile(std.fs.path.basename(path))) readFile(temporary, path) else null;
        self.facts = try facts_mod.extractInWithParser(a, temporary, self.root, path, text orelse body orelse "");
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
    /// A request's refresh policy, or null outside a request. Preparation is
    /// lazy so discovery-only requests do not re-stat the whole Workspace.
    query_refresh_stale: ?bool = null,
    /// Discovery preparation freezes pending drains and root-info storage.
    query_discovery_prepared: bool = false,
    /// Entry preparation refreshes disk facts once, then freezes entry storage.
    query_entries_borrowed: bool = false,
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

    /// A main-thread request lease, not an independently owned snapshot. Each
    /// storage class is prepared before its first borrow and remains alive until
    /// release. Workers may keep queuing results, but cannot replace borrowed
    /// storage; disk facts are refreshed only when entries are first needed.
    pub const QueryLease = struct {
        index: ?*WorkspaceIndex,

        pub fn release(self: *QueryLease) void {
            const index = self.index orelse unreachable;
            std.debug.assert(index.query_refresh_stale != null);
            index.query_entries_borrowed = false;
            index.query_discovery_prepared = false;
            index.query_refresh_stale = null;
            self.index = null;
        }
    };

    /// Start a request. Its first entry or discovery read applies available
    /// scan results without waiting for startup. Without watching, the first
    /// entry read also refreshes known disk files. Nested reads share preparation;
    /// discovery-only requests never refresh entries.
    pub fn acquireQuery(self: *WorkspaceIndex, refresh_stale: bool) QueryLease {
        std.debug.assert(self.query_refresh_stale == null);
        self.query_refresh_stale = refresh_stale;
        return .{ .index = self };
    }

    /// Drain once before any borrow. Further drains could replace both entry
    /// and root-info arenas, so even discovery-only reads freeze the queue.
    fn prepareDiscovery(self: *WorkspaceIndex) void {
        if (self.query_refresh_stale == null or self.query_discovery_prepared) return;
        self.drain();
        self.query_discovery_prepared = true;
    }

    /// Disk refresh changes only entry storage, never RootInfo. It may therefore
    /// follow a discovery borrow, but must precede the first entry borrow. Do not
    /// drain again here: pending root-info replacements must stay queued.
    fn prepareEntries(self: *WorkspaceIndex) void {
        const refresh = self.query_refresh_stale orelse return;
        if (self.query_entries_borrowed) return;
        self.prepareDiscovery();
        if (refresh) self.refreshStale();
        self.query_entries_borrowed = true;
    }

    /// Free everything. Background scans must already be stopped (the pool
    /// joined) and all query borrows released before this runs.
    pub fn destroy(self: *WorkspaceIndex) void {
        std.debug.assert(self.query_refresh_stale == null);
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
        std.debug.assert(self.query_refresh_stale == null);
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
            .pool = pool,
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
        std.debug.assert(self.query_refresh_stale == null);
        const generation = self.next_generation;
        self.next_generation += 1;
        if (self.generations.getPtr(root)) |g| {
            g.* = generation;
        } else {
            try self.generations.put(try self.gpa.dupe(u8, root), generation);
        }
        self.active_scans += 1;
        scan(self, root, marker, generation, null);
        self.drain();
    }

    /// Move finished scan output into the entry map. Main thread only.
    /// After the first query borrow, leave output queued for the next message
    /// or idle drain. Before that borrow, preparation may still apply it.
    pub fn drain(self: *WorkspaceIndex) void {
        if (self.query_discovery_prepared) return;
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
    /// `root` is the Workspace that owns it. Also used by lazy preparation,
    /// before any entry arena is borrowed; root-info storage is unaffected.
    /// Explicit save/watch notifications run outside the request lease.
    pub fn reindex(self: *WorkspaceIndex, root: []const u8, path: []const u8) void {
        std.debug.assert(!self.query_entries_borrowed);
        const st = std.fs.cwd().statFile(path) catch {
            self.remove(path);
            return;
        };
        const e = Entry.build(self.gpa, root, path, null, st.mtime) catch return;
        self.putEntry(e);
    }

    pub fn remove(self: *WorkspaceIndex, path: []const u8) void {
        std.debug.assert(!self.query_entries_borrowed);
        if (self.entries.fetchRemove(path)) |kv| kv.value.destroy(self.gpa);
    }

    /// Re-stat every entry and re-parse those whose mtime changed; drop the
    /// ones that disappeared. Used when the client cannot watch files.
    pub fn refreshStale(self: *WorkspaceIndex) void {
        if (self.query_entries_borrowed) return;
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

    /// Borrowed until the next mutation, or through release of an active lease.
    pub fn get(self: *WorkspaceIndex, path: []const u8) ?*const Entry {
        self.prepareEntries();
        return self.entries.get(path);
    }

    /// Discovery storage has the same borrowing lifetime as entries.
    pub fn info(self: *WorkspaceIndex, root: []const u8) ?*const RootInfo {
        self.prepareDiscovery();
        return self.infos.get(root);
    }

    /// Entries of the Workspace rooted at `root`, sorted by path. The pointer
    /// list belongs to `a`; entries are borrowed with the lifetime of `get`.
    pub fn entriesOf(self: *WorkspaceIndex, a: Allocator, root: []const u8) ![]const *const Entry {
        return self.collectEntries(a, root, null);
    }

    /// Entries below `directory` in this Workspace, with entriesOf's ordering
    /// and borrowing lifetime. Filter before allocating/sorting the pointer
    /// list so a directory-local query need not sort the whole Workspace.
    pub fn entriesWithin(self: *WorkspaceIndex, a: Allocator, root: []const u8, directory: []const u8) ![]const *const Entry {
        return self.collectEntries(a, root, directory);
    }

    fn collectEntries(self: *WorkspaceIndex, a: Allocator, root: []const u8, directory: ?[]const u8) ![]const *const Entry {
        self.prepareEntries();
        var out = std.array_list.Managed(*const Entry).init(a);
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.*.root, root)) continue;
            if (directory) |dir| {
                const path = e.*.path;
                if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) continue;
                // A trailing separator already delimits the directory; without
                // one, reject sibling names sharing its textual prefix.
                if (dir.len > 0 and dir[dir.len - 1] != '/' and dir[dir.len - 1] != '\\' and path[dir.len] != '/' and path[dir.len] != '\\') continue;
            }
            try out.append(e.*);
        }
        std.mem.sort(*const Entry, out.items, {}, lessEntry);
        return out.toOwnedSlice();
    }

    pub fn count(self: *const WorkspaceIndex) usize {
        return self.entries.count();
    }

    fn putEntry(self: *WorkspaceIndex, e: *Entry) void {
        std.debug.assert(!self.query_entries_borrowed);
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
    pool: *concurrency.ThreadPool,
    task: concurrency.Task,

    fn run(ctx: *anyopaque) void {
        const self: *ScanJob = @ptrCast(@alignCast(ctx));
        defer self.free();
        scan(self.index, self.root, self.marker, self.generation, self.pool);
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
fn scan(index: *WorkspaceIndex, root: []const u8, marker: []const u8, generation: u64, pool: ?*concurrency.ThreadPool) void {
    const gpa = index.gpa;
    // Transfer completion and discovery storage to ScanWork only after setup
    // succeeds. Until then, even a failed discovery completes this generation.
    var handed_off = false;
    defer if (!handed_off) index.push(.{ .generation = generation, .root = gpa.dupe(u8, root) catch "", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer if (!handed_off) arena.deinit();
    const a = arena.allocator();
    const owned_root = a.dupe(u8, root) catch return;
    const found = discover_mod.discover(a, owned_root, marker) catch return;
    const work = gpa.create(ScanWork) catch return;
    work.* = .{ .index = index, .arena = arena, .root = owned_root, .generation = generation, .files = found.files };
    handed_off = true;

    info: {
        const ri = gpa.create(RootInfo) catch break :info;
        ri.arena = std.heap.ArenaAllocator.init(gpa);
        const info_a = ri.arena.allocator();
        ri.root = info_a.dupe(u8, root) catch {
            ri.destroy(gpa);
            break :info;
        };
        ri.roles_dirs = dupeAll(info_a, found.roles_dirs) catch &.{};
        ri.collection_paths = dupeAll(info_a, found.collection_paths) catch &.{};
        ri.file_count = found.files.len;
        index.push(.{ .generation = generation, .root = gpa.dupe(u8, root) catch "", .info = ri });
    }

    // The discovery worker also parses files; it never waits on tasks queued
    // to its own pool. Small scans avoid scheduling overhead. Additional tasks
    // share a cursor, balancing uneven file sizes with at most four lanes.
    if (pool) |p| {
        const lanes = @max(1, @min(p.threads.len, @min(4, 1 + found.files.len / 64)));
        for (work.tasks[0 .. lanes - 1]) |*task| {
            task.* = .{ .func = ScanWork.run, .ctx = work };
            _ = work.remaining.fetchAdd(1, .monotonic);
            p.submit(task) catch {
                _ = work.remaining.fetchSub(1, .monotonic);
            };
        }
    }
    ScanWork.run(work);
}

/// Immutable discovery snapshot plus a shared file cursor. The last lane
/// publishes completion and frees the snapshot; no lane blocks waiting for
/// another, so rescans and shutdown also work with a one-thread pool.
const ScanWork = struct {
    index: *WorkspaceIndex,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    generation: u64,
    files: []const []const u8,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    tasks: [3]concurrency.Task = undefined,

    fn run(ctx: *anyopaque) void {
        const self: *ScanWork = @ptrCast(@alignCast(ctx));
        defer self.finish();
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        while (!self.index.shutdown.load(.acquire)) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.files.len) return;
            _ = scratch.reset(.{ .retain_with_limit = 1024 * 1024 });
            const path = self.files[i];
            const st = std.fs.cwd().statFile(path) catch continue;
            const e = Entry.buildWithScratch(self.index.gpa, scratch.allocator(), self.root, path, null, st.mtime) catch continue;
            self.index.push(.{ .generation = self.generation, .root = self.index.gpa.dupe(u8, self.root) catch "", .entry = e });
        }
    }

    fn finish(self: *ScanWork) void {
        if (self.remaining.fetchSub(1, .acq_rel) != 1) return;
        const index = self.index;
        index.push(.{ .generation = self.generation, .root = index.gpa.dupe(u8, self.root) catch "", .done = true });
        self.arena.deinit();
        index.gpa.destroy(self);
    }
};

fn dupeAll(a: Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |x, i| out[i] = try a.dupe(u8, x);
    return out;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn lessEntry(_: void, x: *const Entry, y: *const Entry) bool {
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

test "entries retain facts without retaining file text or parse storage" {
    var tree = try Tree.init();
    defer tree.deinit();
    var body = std.array_list.Managed(u8).init(testing.allocator);
    defer body.deinit();
    try body.appendSlice("value: '{{ live_value }}'\n");
    for (0..10_000) |_| try body.appendSlice("# ignored padding\n");
    try tree.write("data.yml", body.items);
    const path = try tree.path("data.yml");
    defer testing.allocator.free(path);
    const entry = try Entry.build(testing.allocator, tree.root, path, null, 0);
    defer entry.destroy(testing.allocator);
    try testing.expectEqualStrings("live_value", entry.facts.var_refs[0].name);
    try testing.expect(entry.arena.queryCapacity() < 32 * 1024);
}

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

fn waitForScans(index: *WorkspaceIndex) !void {
    var timer = try std.time.Timer.start();
    while (index.isScanning() and timer.read() < 10 * std.time.ns_per_s) {
        index.drain();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try testing.expect(!index.isScanning());
}

test "shared file scans retain every fact with one or several pool workers" {
    var tree = try Tree.init();
    defer tree.deinit();
    var other = try Tree.init();
    defer other.deinit();
    const body =
        \\- hosts: all
        \\  vars:
        \\    settings: {port: 80}
        \\  tasks:
        \\    - debug:
        \\        msg: "{{ settings.port }}"
        \\
    ;
    for (0..129) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "playbooks/{d}.yml", .{i});
        defer testing.allocator.free(name);
        try tree.write(name, body);
        try other.write(name, body);
    }
    for ([_]usize{ 1, 2, 4 }) |workers| {
        const index = try WorkspaceIndex.create(testing.allocator);
        defer index.destroy();
        const pool = try concurrency.ThreadPool.init(testing.allocator, workers);
        defer pool.deinit();
        try index.syncRoots(pool, &.{ tree.root, other.root }, ".git", false);
        try testing.expect(!index.takeReadyEvent());
        try waitForScans(index);
        try testing.expect(index.takeReadyEvent());
        try testing.expect(!index.takeReadyEvent());
        try testing.expectEqual(@as(usize, 258), index.count());
        try testing.expectEqual(@as(usize, 129), index.info(tree.root).?.file_count);
        try testing.expectEqual(@as(usize, 129), index.info(other.root).?.file_count);
        var it = index.entries.valueIterator();
        while (it.next()) |entry| {
            const facts = entry.*.facts;
            try testing.expectEqual(@as(usize, 1), facts.var_refs.len);
            try testing.expectEqualStrings("settings", facts.var_refs[0].name);
            try testing.expectEqual(@as(usize, 1), facts.field_refs.len);
            try testing.expectEqualStrings("port", facts.field_refs[0].name);
            try testing.expectEqualStrings("settings", facts.var_defs[0].name);
            try testing.expectEqualStrings("port", facts.field_defs[0].name);
        }
    }
}

test "shared scans drop removed roots and stale generations, including on shutdown" {
    var tree = try Tree.init();
    defer tree.deinit();
    for (0..129) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "{d}.yml", .{i});
        defer testing.allocator.free(name);
        try tree.write(name, "- debug: msg=\"{{ value }}\"\n");
    }
    const index = try WorkspaceIndex.create(testing.allocator);
    defer index.destroy();
    const pool = try concurrency.ThreadPool.init(testing.allocator, 4);
    var joined = false;
    defer if (!joined) pool.deinit();
    try index.syncRoots(pool, &.{tree.root}, ".git", false);
    // Rescan while the first generation may still be discovering/parsing.
    try index.syncRoots(pool, &.{tree.root}, ".git", true);
    try index.syncRoots(pool, &.{}, ".git", false);
    try waitForScans(index);
    try testing.expectEqual(@as(usize, 0), index.count());
    try testing.expect(index.info(tree.root) == null);
    try testing.expect(index.takeReadyEvent());

    try index.syncRoots(pool, &.{tree.root}, ".git", false);
    try waitForScans(index);
    try testing.expectEqual(@as(usize, 129), index.count());
    try testing.expect(index.takeReadyEvent());
    // Stop an active rescan with queued parse lanes. Joining the pool must
    // release every snapshot and entry, even without another main-thread drain.
    try index.syncRoots(pool, &.{tree.root}, ".git", true);
    index.shutdown.store(true, .release);
    pool.deinit();
    joined = true;
    index.drain();
    try testing.expect(!index.isScanning());
    try testing.expect(index.takeReadyEvent());
}
