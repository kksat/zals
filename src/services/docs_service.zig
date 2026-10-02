//! Background docs loading: catalog bootstrap, prefetch, and cache writes
//! (ADR-0008, ADR-0011).
//!
//! The catalog is loaded eagerly (from the on-disk cache when possible) so
//! `ansible/docsLibraryReady` can fire immediately. Full module docs are then
//! prefetched on the thread pool in batches, with periodic cache writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const docs = @import("docs.zig");
const DocsLibrary = docs.DocsLibrary;
const docs_cache = @import("docs_cache.zig");
const exec = @import("../exec/root.zig");
const AnsibleConfig = @import("ansible_config.zig").AnsibleConfig;
const concurrency = @import("../concurrency/root.zig");
const ThreadPool = concurrency.ThreadPool;
const Task = concurrency.Task;

const batch_size = 25;
/// Write the cache every N batches during prefetch.
const write_every = 4;

pub const DocsService = struct {
    allocator: Allocator,
    cache_path: ?[]const u8 = null,
    lib: *DocsLibrary = undefined,
    pool: *ThreadPool = undefined,
    cache_writing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    prefetch_task: Task = undefined,
    cache_task: Task = undefined,
    started: bool = false,

    pub fn init(allocator: Allocator, cache_path: ?[]const u8) DocsService {
        return .{ .allocator = allocator, .cache_path = cache_path };
    }

    /// Load the catalog (cache first, then `ansible-doc`) and kick off prefetch.
    /// `lib`, `pool`, and `config` must outlive the service.
    pub fn start(self: *DocsService, lib: *DocsLibrary, pool: *ThreadPool, config: *AnsibleConfig) void {
        if (self.started) return;
        self.started = true;
        self.lib = lib;
        self.pool = pool;

        var loaded = false;
        if (self.cache_path) |p| {
            loaded = docs_cache.load(self.allocator, self.lib, p) catch false;
            // A cache with an empty catalog is useless; fall back to ansible-doc.
            if (loaded and self.lib.catalog.count() == 0) loaded = false;
        }
        if (!loaded) {
            self.lib.loadCatalog() catch {};
        }
        // Discover module FQCNs on disk for completion (builtin + collections +
        // redirects). This is independent of the ansible-doc catalog.
        self.lib.scanModuleIndex(config);

        self.prefetch_task = .{ .func = prefetchEntry, .ctx = self };
        self.pool.submit(&self.prefetch_task) catch {};
    }

    fn prefetchEntry(ctx: *anyopaque) void {
        const self: *DocsService = @ptrCast(@alignCast(ctx));
        self.prefetch();
    }

    fn prefetch(self: *DocsService) void {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.allocator);
        {
            self.lib.mutex.lock();
            defer self.lib.mutex.unlock();
            var it = self.lib.catalog.iterator();
            while (it.next()) |e| {
                if (!self.lib.modules.contains(e.key_ptr.*))
                    names.append(self.allocator, e.key_ptr.*) catch {};
            }
        }

        var i: usize = 0;
        while (i < names.items.len) : (i += batch_size) {
            if (self.shutdown.load(.acquire)) return;
            const end = @min(i + batch_size, names.items.len);
            self.lib.fetchMany(names.items[i..end]) catch {};
            if ((i / batch_size) % write_every == write_every - 1) self.scheduleCacheWrite();
        }
        self.scheduleCacheWrite();
    }

    /// Submit a cache write to the pool, coalescing concurrent requests.
    pub fn scheduleCacheWrite(self: *DocsService) void {
        if (self.cache_path == null) return;
        if (self.cache_writing.swap(true, .acq_rel)) return;
        self.cache_task = .{ .func = cacheWriteEntry, .ctx = self };
        self.pool.submit(&self.cache_task) catch {
            self.cache_writing.store(false, .release);
        };
    }

    fn cacheWriteEntry(ctx: *anyopaque) void {
        const self: *DocsService = @ptrCast(@alignCast(ctx));
        defer self.cache_writing.store(false, .release);
        const p = self.cache_path orelse return;
        docs_cache.save(self.allocator, self.lib, p) catch {};
    }
};

/// Per-file module libraries. Each ordered path/cwd identity owns an immutable
/// subprocess environment and its own in-memory docs. Never load/save these
/// libraries through the process-wide, version-only disk cache: identical FQCNs
/// may resolve to different files in different Workspaces or configurations.
/// Created/read on the main thread; no background task borrows these snapshots.
pub const ContextLibraries = struct {
    const ContextLibrary = struct {
        lib: DocsLibrary,
        env: std.process.EnvMap,
        cwd: []const u8,
    };

    allocator: Allocator,
    runner: exec.Runner,
    libraries: std.StringHashMap(*ContextLibrary),

    pub fn init(a: Allocator, runner: exec.Runner) ContextLibraries {
        return .{ .allocator = a, .runner = runner, .libraries = std.StringHashMap(*ContextLibrary).init(a) };
    }

    pub fn deinit(self: *ContextLibraries) void {
        var it = self.libraries.iterator();
        while (it.next()) |e| {
            const context = e.value_ptr.*;
            context.lib.deinit();
            context.env.deinit();
            self.allocator.free(context.cwd);
            self.allocator.destroy(context);
            self.allocator.free(e.key_ptr.*);
        }
        self.libraries.deinit();
    }

    pub fn forPaths(self: *ContextLibraries, paths: []const []const u8, cwd: []const u8) !*DocsLibrary {
        const a = self.allocator;
        // JSON preserves ordering and component boundaries, unlike a bare hash
        // or delimiter-concatenated cache key.
        const key = try std.json.Stringify.valueAlloc(a, .{ .cwd = cwd, .collections_paths = paths }, .{});
        errdefer a.free(key);
        if (self.libraries.get(key)) |context| {
            a.free(key);
            return &context.lib;
        }
        const context = try a.create(ContextLibrary);
        errdefer a.destroy(context);
        const owned_cwd = try a.dupe(u8, cwd);
        errdefer a.free(owned_cwd);
        context.* = .{
            .lib = DocsLibrary.init(a, self.runner, "ansible-doc"),
            .env = try std.process.getEnvMap(a),
            .cwd = owned_cwd,
        };
        errdefer context.lib.deinit();
        errdefer context.env.deinit();
        const joined = try std.mem.join(a, &.{std.fs.path.delimiter}, paths);
        defer a.free(joined);
        try context.env.put("ANSIBLE_COLLECTIONS_PATH", joined);
        context.env.remove("ANSIBLE_COLLECTIONS_PATHS");
        // Do not let Python's unrelated sys.path reintroduce unselected venvs.
        try context.env.put("ANSIBLE_COLLECTIONS_SCAN_SYS_PATH", "false");
        context.lib.execution = .{ .env_map = &context.env, .cwd = context.cwd };
        context.lib.loadCatalog() catch {};
        context.lib.scanModulePaths(paths);
        try self.libraries.put(key, context);
        return &context.lib;
    }
};

/// Derive a cache fingerprint from the installed Ansible version. Returns null
/// when the version cannot be determined (caching is then disabled).
pub const Fingerprint = struct {
    /// Hex hash used in the cache file name.
    hash: []u8,
    /// Human-readable version line, stored in the cache for diagnostics.
    version: []u8,
};

pub fn computeFingerprint(allocator: Allocator, runner: exec.Runner) ?Fingerprint {
    const argv = [_][]const u8{ "ansible-doc", "--version" };
    const result = runner.run(allocator, &argv) catch return null;
    defer result.deinit(allocator);
    if (result.stdout.len == 0) return null;
    const line = std.mem.sliceTo(result.stdout, '\n');
    var hash = std.hash.Wyhash.init(0);
    hash.update(line);
    return .{
        .hash = std.fmt.allocPrint(allocator, "{x}", .{hash.final()}) catch return null,
        .version = allocator.dupe(u8, line) catch return null,
    };
}
