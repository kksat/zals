//! Background docs loading: catalog bootstrap, prefetch, and cache writes
//! (ADR-0008, ADR-0011).
//!
//! Version probing, catalog bootstrap, and module discovery run on the pool,
//! independently of Workspace indexing. The main thread reports readiness once
//! bootstrap completes; full module docs are then prefetched in batches.

const std = @import("std");
const fsio = @import("../fsio.zig");
const Allocator = std.mem.Allocator;
const docs = @import("docs.zig");
const memory = @import("../memory.zig");
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
    /// Owned; freed after the pool has joined.
    cache_path: ?[]const u8 = null,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reported_ready: bool = false,
    bootstrap_task: Task = undefined,
    lib: *DocsLibrary = undefined,
    pool: *ThreadPool = undefined,
    cache_writing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cache_task: Task = undefined,
    started: bool = false,

    pub fn init(allocator: Allocator) DocsService {
        return .{ .allocator = allocator };
    }

    /// The pool must already be joined.
    pub fn deinit(self: *DocsService) void {
        if (self.cache_path) |p| self.allocator.free(p);
    }

    /// Keep polling until the main thread consumes readiness, not merely
    /// until the worker finishes. Otherwise completion between drain and
    /// the next blocking read could strand the readiness notification.
    pub fn hasPendingBootstrap(self: *const DocsService) bool {
        return self.started and !self.reported_ready;
    }

    /// Main-thread readiness handoff, once per service lifetime.
    pub fn takeReadyEvent(self: *DocsService) bool {
        if (!self.ready.load(.acquire) or self.reported_ready) return false;
        self.reported_ready = true;
        return true;
    }

    /// Schedule bootstrap without running subprocesses on the request thread.
    /// `lib` and `pool` must outlive the service.
    pub fn start(self: *DocsService, lib: *DocsLibrary, pool: *ThreadPool) void {
        if (self.started) return;
        self.started = true;
        self.lib = lib;
        self.pool = pool;
        // Bind before submitting: fingerprint, catalog, nested config/module
        // discovery, and prefetch all inherit one owner-lifetime token.
        self.lib.runner.cancel = &self.shutdown;
        self.bootstrap_task = .{ .func = bootstrapEntry, .ctx = self };
        self.pool.submit(&self.bootstrap_task) catch self.ready.store(true, .release);
    }

    fn bootstrapEntry(ctx: *anyopaque) void {
        const self: *DocsService = @ptrCast(@alignCast(ctx));
        self.bootstrap();
    }

    fn bootstrap(self: *DocsService) void {
        if (self.shutdown.load(.acquire)) return;
        if (computeFingerprint(self.allocator, self.lib.runner)) |fp| {
            defer self.allocator.free(fp.hash);
            defer self.allocator.free(fp.version);
            self.cache_path = docs_cache.cachePath(self.allocator, fp.hash) catch null;
            self.lib.recordAnsibleVersion(fp.version) catch {};
        }
        if (self.shutdown.load(.acquire)) return;
        var loaded = false;
        if (self.cache_path) |p| {
            loaded = docs_cache.load(self.allocator, self.lib, p) catch false;
            // A cache with an empty catalog is useless; fall back to ansible-doc.
            if (loaded and self.lib.catalogCount() == 0) loaded = false;
        }
        if (!loaded) {
            self.lib.loadCatalog() catch {};
        }
        // Discover module FQCNs on disk for completion (builtin + collections +
        // redirects). This is independent of the ansible-doc catalog.
        if (self.shutdown.load(.acquire)) return;
        // This worker owns its config snapshot; the server's lazy config is
        // main-thread-only and must not be shared with bootstrap.
        var config = AnsibleConfig.init(self.allocator, self.lib.runner);
        defer config.deinit();
        self.lib.scanModuleIndex(&config);
        memory.trimReleasedHeap();
        self.ready.store(true, .release);
        // One `--metadata-dump` call carries every installed module's full
        // docs, replacing the batched prefetch entirely; when it is not
        // usable (older ansible-core), prefetch in batches as before.
        const already_complete = loaded and self.lib.cacheComplete();
        var complete = already_complete;
        if (!already_complete) {
            if (self.lib.loadMetadataDump()) {
                complete = true;
            } else {
                complete = self.prefetch();
            }
        }
        if (!self.shutdown.load(.acquire)) {
            if (complete) self.lib.markBootstrapComplete();
            if (!already_complete) self.scheduleCacheWrite();
        }
        memory.trimReleasedHeap();
    }

    fn prefetch(self: *DocsService) bool {
        if (self.lib.catalogCount() == 0) return false;
        const names = self.lib.missingCatalogNames(self.allocator) catch return false;
        defer self.allocator.free(names);

        var ok = true;
        var i: usize = 0;
        while (i < names.len) : (i += batch_size) {
            if (self.shutdown.load(.acquire)) return false;
            const end = @min(i + batch_size, names.len);
            if (!self.lib.fetchBatch(names[i..end])) ok = false;
            if ((i / batch_size) % write_every == write_every - 1) self.scheduleCacheWrite();
        }
        if (self.shutdown.load(.acquire)) return false;
        return ok;
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
        memory.trimReleasedHeap();
    }
};

test "bootstrap remains pending until readiness is consumed" {
    var service = DocsService.init(std.testing.allocator);
    defer service.deinit();
    try std.testing.expect(!service.hasPendingBootstrap());
    service.started = true;
    try std.testing.expect(service.hasPendingBootstrap());
    try std.testing.expect(!service.takeReadyEvent());
    service.ready.store(true, .release);
    try std.testing.expect(service.hasPendingBootstrap());
    try std.testing.expect(service.takeReadyEvent());
    try std.testing.expect(!service.hasPendingBootstrap());
    try std.testing.expect(!service.takeReadyEvent());
}

/// Contextual module libraries. Each ordered collection-path list (shared by
/// every file with the same effective paths) owns an immutable subprocess
/// environment and its own in-memory docs. `ansible-doc` runs from `PATH` in
/// the server's working directory; collection selection reaches it only via
/// `ANSIBLE_COLLECTIONS_PATH`, so no per-file `ansible.cfg` or cwd is supplied.
/// Never load/save these libraries through the process-wide, version-only disk
/// cache: identical FQCNs may resolve to different files under different
/// paths. Created/read on the main thread; no background task borrows these
/// snapshots.
pub const ContextLibraries = struct {
    const ContextLibrary = struct {
        lib: DocsLibrary,
        env: std.process.Environ.Map,
    };

    allocator: Allocator,
    runner: exec.Runner,
    base: ?*DocsLibrary = null,
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
            self.allocator.destroy(context);
            self.allocator.free(e.key_ptr.*);
        }
        self.libraries.deinit();
    }

    pub fn forPaths(self: *ContextLibraries, paths: []const []const u8) !*DocsLibrary {
        const a = self.allocator;
        // JSON preserves ordering and component boundaries, unlike a bare hash
        // or delimiter-concatenated cache key.
        const key = try std.json.Stringify.valueAlloc(a, paths, .{});
        errdefer a.free(key);
        if (self.libraries.get(key)) |context| {
            a.free(key);
            if (self.base) |base| context.lib.copyBuiltinsFrom(base);
            return &context.lib;
        }
        const context = try a.create(ContextLibrary);
        errdefer a.destroy(context);
        context.* = .{
            .lib = DocsLibrary.init(a, self.runner, "ansible-doc"),
            .env = try fsio.getEnvMap(a),
        };
        errdefer context.lib.deinit();
        errdefer context.env.deinit();
        const joined = try std.mem.join(a, &.{std.fs.path.delimiter}, paths);
        defer a.free(joined);
        try context.env.put("ANSIBLE_COLLECTIONS_PATH", joined);
        _ = context.env.orderedRemove("ANSIBLE_COLLECTIONS_PATHS");
        // Do not let Python's unrelated sys.path reintroduce unselected venvs.
        try context.env.put("ANSIBLE_COLLECTIONS_SCAN_SYS_PATH", "false");
        context.lib.execution = .{ .env_map = &context.env };
        context.lib.loadCatalog() catch {};
        context.lib.scanModulePaths(paths);
        if (self.base) |base| context.lib.copyBuiltinsFrom(base);
        try self.libraries.put(key, context);
        return &context.lib;
    }
};

test "ContextLibraries keys by collection paths and runs ansible-doc without a cwd" {
    const Fake = struct {
        calls: usize = 0,
        cwd_supplied: bool = false,
        fn run(ptr: *anyopaque, a: Allocator, argv: []const []const u8) anyerror!exec.Result {
            return runWithOptions(ptr, a, argv, .{});
        }
        fn runWithOptions(ptr: *anyopaque, a: Allocator, _: []const []const u8, options: exec.Options) anyerror!exec.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (options.cwd != null) self.cwd_supplied = true;
            return .{
                .stdout = try a.dupe(u8, "{}"),
                .stderr = try a.dupe(u8, ""),
                .term = .{ .exited = 0 },
            };
        }
        const vtable = exec.Runner.VTable{ .run = run, .run_with_options = runWithOptions };
    };
    var fake = Fake{};
    const runner = exec.Runner{ .ptr = &fake, .vtable = &Fake.vtable };
    var libs = ContextLibraries.init(std.testing.allocator, runner);
    defer libs.deinit();

    const p1 = try libs.forPaths(&.{"/ws/.venv"});
    const p2 = try libs.forPaths(&.{"/ws/.venv"});
    try std.testing.expectEqual(p1, p2);
    try std.testing.expectEqual(@as(usize, 1), libs.libraries.count());

    const other = try libs.forPaths(&.{ "/ws/collections", "/ws/.venv" });
    try std.testing.expect(other != p1);
    try std.testing.expectEqual(@as(usize, 2), libs.libraries.count());

    try std.testing.expect(fake.calls > 0);
    try std.testing.expect(!fake.cwd_supplied);
}

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
    if (!result.success() or result.stdout.len == 0) return null;
    const line = std.mem.sliceTo(result.stdout, '\n');
    var hash = std.hash.Wyhash.init(0);
    hash.update(result.stdout);
    hashInstalledCollections(allocator, &hash, result.stdout);
    return .{
        .hash = std.fmt.allocPrint(allocator, "{x}", .{hash.final()}) catch return null,
        .version = allocator.dupe(u8, line) catch return null,
    };
}

fn hashInstalledCollections(allocator: Allocator, hash: *std.hash.Wyhash, version_stdout: []const u8) void {
    const locations = versionOutputField(version_stdout, "ansible collection location") orelse return;
    const project_config = @import("project_config.zig");
    var path_it = std.mem.splitScalar(u8, locations, std.fs.path.delimiter);
    while (path_it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        hash.update("\x00root:");
        hash.update(trimmed);
        const base = project_config.collectionPathRoot(trimmed);
        const root = std.fs.path.join(allocator, &.{ base, "ansible_collections" }) catch continue;
        defer allocator.free(root);
        hashCollectionsDir(allocator, hash, root);
    }
}

fn versionOutputField(stdout: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = trimmed[key.len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        return std.mem.trim(u8, rest[eq + 1 ..], " \t");
    }
    return null;
}

fn hashCollectionsDir(allocator: Allocator, hash: *std.hash.Wyhash, root: []const u8) void {
    const io = fsio.get();
    var d = fsio.openDir(root, .{ .iterate = true }) catch return;
    defer d.close(io);

    var entries = std.ArrayList([]u8).empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    var ns_it = d.iterate();
    while (ns_it.next(io) catch null) |ns_entry| {
        if (ns_entry.kind != .directory) continue;
        var ns_dir = d.openDir(io, ns_entry.name, .{ .iterate = true }) catch continue;
        defer ns_dir.close(io);
        var coll_it = ns_dir.iterate();
        while (coll_it.next(io) catch null) |coll_entry| {
            if (coll_entry.kind != .directory) continue;
            const rel = std.fs.path.join(allocator, &.{ ns_entry.name, coll_entry.name }) catch continue;
            entries.append(allocator, rel) catch {
                allocator.free(rel);
                continue;
            };
        }
    }

    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const probes = [_][]const u8{ "MANIFEST.json", "galaxy.yml", "meta/runtime.yml", "plugins/modules" };
    for (entries.items) |rel| {
        hash.update("\x00coll:");
        hash.update(rel);
        var coll_dir = d.openDir(io, rel, .{}) catch continue;
        defer coll_dir.close(io);
        for (probes) |probe| {
            const st = coll_dir.statFile(io, probe, .{}) catch continue;
            hash.update("\x00stat:");
            hash.update(probe);
            const meta = [2]i128{ @as(i128, st.size), st.mtime.nanoseconds };
            hash.update(std.mem.asBytes(&meta));
        }
    }
}

test "prefetch reports incomplete on failed or cancelled batch" {
    const Fake = struct {
        fail_batch: bool = false,
        cancel_on_batch: ?*std.atomic.Value(bool) = null,

        fn run(ptr: *anyopaque, a: Allocator, argv: []const []const u8) anyerror!exec.Result {
            return runWithOptions(ptr, a, argv, .{});
        }
        fn runWithOptions(ptr: *anyopaque, a: Allocator, argv: []const []const u8, _: exec.Options) anyerror!exec.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.cancel_on_batch) |flag| {
                flag.store(true, .release);
                return error.Cancelled;
            }
            if (self.fail_batch) {
                return .{
                    .stdout = try a.dupe(u8, ""),
                    .stderr = try a.dupe(u8, "boom"),
                    .term = .{ .exited = 1 },
                };
            }
            _ = argv;
            return .{
                .stdout = try a.dupe(u8, "{\"ns.one\": {\"doc\": {\"short_description\": \"ok\"}}}"),
                .stderr = try a.dupe(u8, ""),
                .term = .{ .exited = 0 },
            };
        }
        const vtable = exec.Runner.VTable{ .run = run, .run_with_options = runWithOptions };
    };

    var fake_fail = Fake{ .fail_batch = true };
    var lib_fail = DocsLibrary.init(std.testing.allocator, .{ .ptr = &fake_fail, .vtable = &Fake.vtable }, "ansible-doc");
    defer lib_fail.deinit();
    try lib_fail.catalog.put(try lib_fail.arena.allocator().dupe(u8, "ns.one"), .{ .name = "ns.one", .description = "" });
    var svc_fail = DocsService.init(std.testing.allocator);
    defer svc_fail.deinit();
    svc_fail.lib = &lib_fail;
    try std.testing.expect(!svc_fail.prefetch());

    var svc_cancel = DocsService.init(std.testing.allocator);
    defer svc_cancel.deinit();
    var fake_cancel = Fake{ .cancel_on_batch = &svc_cancel.shutdown };
    var lib_cancel = DocsLibrary.init(std.testing.allocator, .{ .ptr = &fake_cancel, .vtable = &Fake.vtable }, "ansible-doc");
    defer lib_cancel.deinit();
    try lib_cancel.catalog.put(try lib_cancel.arena.allocator().dupe(u8, "ns.one"), .{ .name = "ns.one", .description = "" });
    svc_cancel.lib = &lib_cancel;
    try std.testing.expect(!svc_cancel.prefetch());

    var fake_ok = Fake{};
    var lib_ok = DocsLibrary.init(std.testing.allocator, .{ .ptr = &fake_ok, .vtable = &Fake.vtable }, "ansible-doc");
    defer lib_ok.deinit();
    try lib_ok.catalog.put(try lib_ok.arena.allocator().dupe(u8, "ns.one"), .{ .name = "ns.one", .description = "" });
    var svc_ok = DocsService.init(std.testing.allocator);
    defer svc_ok.deinit();
    svc_ok.lib = &lib_ok;
    try std.testing.expect(svc_ok.prefetch());
    try std.testing.expect(lib_ok.modules.get("ns.one") != null);
}

test "computeFingerprint changes with install location and collection updates" {
    const Fake = struct {
        stdout: []const u8,
        fn run(ptr: *anyopaque, a: Allocator, argv: []const []const u8) anyerror!exec.Result {
            return runWithOptions(ptr, a, argv, .{});
        }
        fn runWithOptions(ptr: *anyopaque, a: Allocator, _: []const []const u8, _: exec.Options) anyerror!exec.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return .{
                .stdout = try a.dupe(u8, self.stdout),
                .stderr = try a.dupe(u8, ""),
                .term = .{ .exited = 0 },
            };
        }
        const vtable = exec.Runner.VTable{ .run = run, .run_with_options = runWithOptions };
    };

    var a1 = Fake{ .stdout = "ansible-doc [core 2.18.1]\n  ansible python module location = /venv1/ansible\n" };
    var a2 = Fake{ .stdout = "ansible-doc [core 2.18.1]\n  ansible python module location = /venv2/ansible\n" };
    const fp1 = computeFingerprint(std.testing.allocator, .{ .ptr = &a1, .vtable = &Fake.vtable }).?;
    defer std.testing.allocator.free(fp1.hash);
    defer std.testing.allocator.free(fp1.version);
    const fp2 = computeFingerprint(std.testing.allocator, .{ .ptr = &a2, .vtable = &Fake.vtable }).?;
    defer std.testing.allocator.free(fp2.hash);
    defer std.testing.allocator.free(fp2.version);
    try std.testing.expect(!std.mem.eql(u8, fp1.hash, fp2.hash));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const stdout = try std.fmt.allocPrint(
        std.testing.allocator,
        "ansible-doc [core 2.18.1]\n  ansible collection location = {s}\n",
        .{dir},
    );
    defer std.testing.allocator.free(stdout);
    var fake_coll = Fake{ .stdout = stdout };
    const runner = exec.Runner{ .ptr = &fake_coll, .vtable = &Fake.vtable };

    const before = computeFingerprint(std.testing.allocator, runner).?;
    defer std.testing.allocator.free(before.hash);
    defer std.testing.allocator.free(before.version);

    try tmp.dir.createDirPath(std.testing.io, "ansible_collections/ns/coll");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ansible_collections/ns/coll/MANIFEST.json", .data = "{\"version\":\"1.0.0\"}" });

    const after_install = computeFingerprint(std.testing.allocator, runner).?;
    defer std.testing.allocator.free(after_install.hash);
    defer std.testing.allocator.free(after_install.version);
    try std.testing.expect(!std.mem.eql(u8, before.hash, after_install.hash));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ansible_collections/ns/coll/MANIFEST.json", .data = "{\"version\":\"1.1.0\",\"extra\":true}" });
    const after_upgrade = computeFingerprint(std.testing.allocator, runner).?;
    defer std.testing.allocator.free(after_upgrade.hash);
    defer std.testing.allocator.free(after_upgrade.version);
    try std.testing.expect(!std.mem.eql(u8, after_install.hash, after_upgrade.hash));
}
