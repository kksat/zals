const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const out = @import("../lsp/outgoing.zig");
const Server = @import("../lsp/server.zig").Server;
const validation = @import("../services/validation.zig");
const exec = @import("../exec/root.zig");
const concurrency = @import("../concurrency/root.zig");
const cel_rules = @import("../cel/root.zig");
const ast = @import("../ast/root.zig");
const paths = @import("../paths.zig");
const discover = @import("../workspace/discover.zig");
const doc_mod = @import("../workspace/document.zig");

const max_native_read_bytes: usize = 2 * 1024 * 1024;

const SharedRuleSet = struct {
    refs: std.atomic.Value(usize),
    ruleset: cel_rules.RuleSet,

    fn create(gpa: Allocator, ruleset: cel_rules.RuleSet) !*SharedRuleSet {
        const self = try gpa.create(SharedRuleSet);
        self.* = .{
            .refs = std.atomic.Value(usize).init(1),
            .ruleset = ruleset,
        };
        return self;
    }

    fn retain(self: *SharedRuleSet) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *SharedRuleSet, gpa: Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.ruleset.deinit();
            gpa.destroy(self);
        }
    }
};

const ProviderBuckets = struct {
    cel: []types.Diagnostic = &.{},
    schema: []types.Diagnostic = &.{},
    external: []types.Diagnostic = &.{},
    rule_file: []types.Diagnostic = &.{},

    fn deinit(self: *ProviderBuckets, gpa: Allocator) void {
        freeDiagSlice(gpa, self.cel);
        freeDiagSlice(gpa, self.schema);
        freeDiagSlice(gpa, self.external);
        freeDiagSlice(gpa, self.rule_file);
        self.* = .{};
    }

    fn isEmpty(self: ProviderBuckets) bool {
        return self.cel.len == 0 and self.schema.len == 0 and self.external.len == 0 and self.rule_file.len == 0;
    }
};

fn freeDiagSlice(gpa: Allocator, slice: []types.Diagnostic) void {
    for (slice) |d| {
        gpa.free(d.message);
        if (d.code) |c| gpa.free(c);
        if (d.source) |s| gpa.free(s);
    }
    if (slice.len > 0) gpa.free(slice);
}

fn cloneDiagSlice(gpa: Allocator, src: []const types.Diagnostic) ![]types.Diagnostic {
    if (src.len == 0) return &.{};
    const dst = try gpa.alloc(types.Diagnostic, src.len);
    var built: usize = 0;
    errdefer {
        for (dst[0..built]) |d| {
            gpa.free(d.message);
            if (d.code) |c| gpa.free(c);
            if (d.source) |s| gpa.free(s);
        }
        gpa.free(dst);
    }
    for (src, 0..) |d, i| {
        dst[i] = .{
            .range = d.range,
            .severity = d.severity,
            .code = if (d.code) |c| try gpa.dupe(u8, c) else null,
            .source = if (d.source) |s| try gpa.dupe(u8, s) else null,
            .message = try gpa.dupe(u8, d.message),
        };
        built += 1;
    }
    return dst;
}

pub const Queue = struct {
    gpa: Allocator,
    mutex: std.Thread.Mutex = .{},
    latest_seq: std.StringHashMapUnmanaged(u64) = .empty,
    next_seq: u64 = 1,
    pending: std.ArrayListUnmanaged(*Job) = .empty,
    completed: std.ArrayListUnmanaged(*Job) = .empty,
    worker_running: bool = false,
    worker_task: concurrency.Task = undefined,

    native_mutex: std.Thread.Mutex = .{},
    latest_native_seq: std.StringHashMapUnmanaged(u64) = .empty,
    next_native_seq: u64 = 1,
    native_pending: std.ArrayListUnmanaged(*NativeJob) = .empty,
    native_completed: std.ArrayListUnmanaged(*NativeJob) = .empty,
    native_worker_running: bool = false,
    native_worker_task: concurrency.Task = undefined,
    worker_cached_ruleset: ?cel_rules.WorkerRuleSet = null,

    active_ruleset: ?*SharedRuleSet = null,
    ruleset_generation: u64 = 0,
    last_reported_error_gen: u64 = 0,
    buckets: std.StringHashMapUnmanaged(ProviderBuckets) = .empty,
    rule_error_uris: std.ArrayListUnmanaged([]const u8) = .empty,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(gpa: Allocator) Queue {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Queue) void {
        for (self.pending.items) |job| job.destroy(self.gpa);
        self.pending.deinit(self.gpa);
        for (self.completed.items) |job| job.destroy(self.gpa);
        self.completed.deinit(self.gpa);
        var it = self.latest_seq.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.latest_seq.deinit(self.gpa);

        for (self.native_pending.items) |job| job.destroy(self.gpa);
        self.native_pending.deinit(self.gpa);
        for (self.native_completed.items) |job| job.destroy(self.gpa);
        self.native_completed.deinit(self.gpa);
        var nit = self.latest_native_seq.keyIterator();
        while (nit.next()) |key| self.gpa.free(key.*);
        self.latest_native_seq.deinit(self.gpa);

        if (self.worker_cached_ruleset) |*wrs| wrs.deinit();
        if (self.active_ruleset) |srs| srs.release(self.gpa);

        var bit = self.buckets.iterator();
        while (bit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.gpa);
        }
        self.buckets.deinit(self.gpa);

        for (self.rule_error_uris.items) |u| self.gpa.free(u);
        self.rule_error_uris.deinit(self.gpa);
    }

    pub fn hasPending(self: *Queue) bool {
        self.mutex.lock();
        const ext_pending = self.worker_running or self.pending.items.len > 0 or self.completed.items.len > 0;
        self.mutex.unlock();
        if (ext_pending) return true;

        self.native_mutex.lock();
        defer self.native_mutex.unlock();
        return self.native_worker_running or self.native_pending.items.len > 0 or self.native_completed.items.len > 0;
    }

    fn enqueue(self: *Queue, pool: *concurrency.ThreadPool, job: *Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const seq = self.next_seq;
        self.next_seq += 1;
        const gop = try self.latest_seq.getOrPut(self.gpa, job.snapshot.uri);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, job.snapshot.uri);
        }
        gop.value_ptr.* = seq;
        job.seq = seq;

        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (std.mem.eql(u8, self.pending.items[i].snapshot.uri, job.snapshot.uri)) {
                const stale = self.pending.orderedRemove(i);
                stale.destroy(self.gpa);
            } else {
                i += 1;
            }
        }

        try self.pending.append(self.gpa, job);
        if (!self.worker_running) {
            self.worker_task = .{ .func = workerEntry, .ctx = self };
            pool.submit(&self.worker_task) catch |err| {
                _ = self.pending.pop();
                return err;
            };
            self.worker_running = true;
        }
    }

    fn enqueueNative(self: *Queue, pool: *concurrency.ThreadPool, job: *NativeJob) !void {
        self.native_mutex.lock();
        defer self.native_mutex.unlock();

        const seq = self.next_native_seq;
        self.next_native_seq += 1;
        const gop = try self.latest_native_seq.getOrPut(self.gpa, job.uri);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, job.uri);
        }
        gop.value_ptr.* = seq;
        job.seq = seq;

        var i: usize = 0;
        while (i < self.native_pending.items.len) {
            if (std.mem.eql(u8, self.native_pending.items[i].uri, job.uri)) {
                const stale = self.native_pending.orderedRemove(i);
                stale.destroy(self.gpa);
            } else {
                i += 1;
            }
        }

        try self.native_pending.append(self.gpa, job);
        if (!self.native_worker_running) {
            self.native_worker_task = .{ .func = nativeWorkerEntry, .ctx = self };
            pool.submit(&self.native_worker_task) catch |err| {
                _ = self.native_pending.pop();
                return err;
            };
            self.native_worker_running = true;
        }
    }

    fn isLatest(self: *Queue, uri: []const u8, seq: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return (self.latest_seq.get(uri) orelse 0) == seq;
    }

    fn isLatestNative(self: *Queue, uri: []const u8, seq: u64) bool {
        self.native_mutex.lock();
        defer self.native_mutex.unlock();
        return (self.latest_native_seq.get(uri) orelse 0) == seq;
    }

    fn invalidateUri(self: *Queue, uri: []const u8) void {
        self.mutex.lock();
        const ext_seq = self.next_seq;
        self.next_seq += 1;
        if (self.latest_seq.getPtr(uri)) |ptr| ptr.* = ext_seq;
        self.mutex.unlock();

        self.native_mutex.lock();
        const nat_seq = self.next_native_seq;
        self.next_native_seq += 1;
        if (self.latest_native_seq.getPtr(uri)) |ptr| ptr.* = nat_seq;
        self.native_mutex.unlock();
    }

    fn workerEntry(ctx: *anyopaque) void {
        const self: *Queue = @ptrCast(@alignCast(ctx));
        self.workerLoop();
    }

    fn workerLoop(self: *Queue) void {
        while (true) {
            self.mutex.lock();
            if (self.shutdown.load(.acquire) or self.pending.items.len == 0) {
                self.worker_running = false;
                self.mutex.unlock();
                return;
            }
            const job = self.pending.orderedRemove(0);
            const latest = (self.latest_seq.get(job.snapshot.uri) orelse 0) == job.seq;
            self.mutex.unlock();

            if (!latest or self.shutdown.load(.acquire)) {
                job.destroy(self.gpa);
                continue;
            }

            if (validation.validate(
                job.arena.allocator(),
                job.snapshot,
                job.options,
                job.runner,
                job.schema,
            )) |res| {
                job.schema_diagnostics = res.schema_diagnostics;
                job.external_diagnostics = res.external_diagnostics;
            } else |_| {
                job.failed = true;
            }

            self.mutex.lock();
            if (self.shutdown.load(.acquire) or job.failed) {
                self.mutex.unlock();
                job.destroy(self.gpa);
                continue;
            }
            self.completed.append(self.gpa, job) catch job.destroy(self.gpa);
            self.mutex.unlock();
        }
    }

    fn nativeWorkerEntry(ctx: *anyopaque) void {
        const self: *Queue = @ptrCast(@alignCast(ctx));
        self.nativeWorkerLoop();
    }

    fn nativeWorkerLoop(self: *Queue) void {
        while (true) {
            self.native_mutex.lock();
            if (self.shutdown.load(.acquire) or self.native_pending.items.len == 0) {
                self.native_worker_running = false;
                self.native_mutex.unlock();
                return;
            }
            const job = self.native_pending.orderedRemove(0);
            const latest = (self.latest_native_seq.get(job.uri) orelse 0) == job.seq;
            self.native_mutex.unlock();

            if (!latest or self.shutdown.load(.acquire)) {
                job.destroy(self.gpa);
                continue;
            }

            self.runNativeJob(job);

            self.native_mutex.lock();
            if (self.shutdown.load(.acquire) or job.failed or job.cancelled) {
                self.native_mutex.unlock();
                job.destroy(self.gpa);
                continue;
            }
            self.native_completed.append(self.gpa, job) catch job.destroy(self.gpa);
            self.native_mutex.unlock();
        }
    }

    fn runNativeJob(self: *Queue, job: *NativeJob) void {
        const need_compile = if (self.worker_cached_ruleset) |wrs|
            wrs.generation != job.ruleset_generation
        else
            true;
        if (need_compile) {
            if (self.worker_cached_ruleset) |*old| {
                old.deinit();
                self.worker_cached_ruleset = null;
            }
            self.worker_cached_ruleset = job.shared_ruleset.ruleset.cloneForWorker(self.gpa) catch {
                job.failed = true;
                return;
            };
        }
        const wrs = &(self.worker_cached_ruleset orelse {
            job.failed = true;
            return;
        });

        const ja = job.arena.allocator();
        const bytes: []const u8 = if (job.bytes_override) |b| b else blk: {
            break :blk paths.readFile(ja, job.path, max_native_read_bytes) orelse {
                job.file_missing = true;
                return;
            };
        };

        var doc_ast = ast.build(self.gpa, job.path, job.display_path, bytes) catch {
            job.failed = true;
            return;
        };
        defer doc_ast.deinit();

        const res = cel_rules.evaluator.evaluateDocument(
            ja,
            &doc_ast,
            wrs,
            job.metadata,
            job.encoding,
            &self.shutdown,
        ) catch {
            job.failed = true;
            return;
        };
        job.cancelled = res.cancelled;
        job.diagnostics = res.diagnostics;
        job.runtime_errors = res.runtime_errors;
    }
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    seq: u64 = 0,
    snapshot: validation.Snapshot,
    options: validation.Options,
    runner: exec.Runner,
    schema: ?Value,
    schema_diagnostics: []const types.Diagnostic = &.{},
    external_diagnostics: []const types.Diagnostic = &.{},
    failed: bool = false,

    fn destroy(self: *Job, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

const NativeJob = struct {
    arena: std.heap.ArenaAllocator,
    seq: u64 = 0,
    ruleset_generation: u64,
    shared_ruleset: *SharedRuleSet,
    uri: []const u8,
    path: []const u8,
    display_path: []const u8,
    bytes_override: ?[]const u8,
    encoding: doc_mod.PositionEncoding,
    metadata: ast.MetadataSnapshot,
    diagnostics: []const types.Diagnostic = &.{},
    runtime_errors: []const cel_rules.evaluator.RuntimeError = &.{},
    file_missing: bool = false,
    cancelled: bool = false,
    failed: bool = false,

    fn destroy(self: *NativeJob, gpa: Allocator) void {
        self.shared_ruleset.release(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub fn isEligibleNativeYaml(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const is_yaml = std.mem.endsWith(u8, base, ".yml") or std.mem.endsWith(u8, base, ".yaml");
    if (!is_yaml) return false;
    if (discover.isInstalledCollectionFile(path)) return false;
    return true;
}

pub fn ensureRuleset(self: *Server, a: Allocator) !void {
    if (self.validation.active_ruleset != null) return;
    try reloadRuleset(self, a);
}

pub fn reloadRuleset(self: *Server, a: Allocator) !void {
    const next_gen = self.validation.ruleset_generation + 1;
    const snap = self.session.snapshot();

    const rs = try cel_rules.registry.buildRuleSet(self.validation.gpa, next_gen, .{
        .include_builtins = true,
        .global_rule_files = self.settings.cel_global_rule_files,
        .workspace_rule_files = self.settings.cel_workspace_rule_files,
        .allow_workspace_rules = self.settings.cel_allow_workspace_rules,
        .workspace_roots = snap.roots,
        .disabled_rules = self.settings.cel_disabled_rules,
        .severity_overrides = self.settings.cel_severity_overrides,
        .rule_options = self.settings.cel_rule_options,
    });
    const shared = try SharedRuleSet.create(self.validation.gpa, rs);

    if (self.validation.active_ruleset) |old| old.release(self.validation.gpa);
    self.validation.active_ruleset = shared;
    self.validation.ruleset_generation = next_gen;

    try publishRuleFileErrors(self, a, &shared.ruleset);
}

fn publishRuleFileErrors(self: *Server, a: Allocator, rs: *const cel_rules.RuleSet) !void {
    for (self.validation.rule_error_uris.items) |old_uri| {
        if (self.validation.buckets.getPtr(old_uri)) |b| {
            freeDiagSlice(self.validation.gpa, b.rule_file);
            b.rule_file = &.{};
            try publishCombined(self, a, old_uri);
        }
        self.validation.gpa.free(old_uri);
    }
    self.validation.rule_error_uris.clearRetainingCapacity();

    if (rs.errors.len == 0) return;

    var grouped = std.StringHashMapUnmanaged(std.ArrayList(types.Diagnostic)).empty;
    defer {
        var it = grouped.valueIterator();
        while (it.next()) |list| list.deinit(a);
        grouped.deinit(a);
    }

    for (rs.errors) |err_info| {
        const uri = if (std.fs.path.isAbsolute(err_info.file_path))
            paths.pathToUri(a, err_info.file_path) catch continue
        else
            continue;
        const gop = try grouped.getOrPut(a, uri);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const line_zero: u32 = if (err_info.line > 0) err_info.line - 1 else 0;
        const col_zero: u32 = if (err_info.column > 0) err_info.column - 1 else 0;
        try gop.value_ptr.append(a, .{
            .range = .{
                .start = .{ .line = line_zero, .character = col_zero },
                .end = .{ .line = line_zero, .character = col_zero + 1 },
            },
            .severity = .err,
            .source = "zals-cel-rule",
            .message = err_info.message,
        });
    }

    var it = grouped.iterator();
    while (it.next()) |entry| {
        const uri = entry.key_ptr.*;
        try self.validation.rule_error_uris.append(self.validation.gpa, try self.validation.gpa.dupe(u8, uri));
        const b = try getOrCreateBucket(&self.validation, uri);
        freeDiagSlice(self.validation.gpa, b.rule_file);
        b.rule_file = try cloneDiagSlice(self.validation.gpa, entry.value_ptr.items);
        try publishCombined(self, a, uri);
    }

    if (self.validation.last_reported_error_gen != rs.generation) {
        self.validation.last_reported_error_gen = rs.generation;
        const msg = try std.fmt.allocPrint(
            a,
            "zals-cel: {d} custom rule file error(s); invalid rules were deactivated",
            .{rs.errors.len},
        );
        out.logMessage(self.writer, a, 2, msg) catch {};
    }
}

pub fn publish(self: *Server, a: Allocator, uri: []const u8) !void {
    if (!self.settings.validation_enabled) {
        try clearUri(self, a, uri);
        return;
    }
    const doc = self.documents.get(uri) orelse return;
    if (self.settings.cel_enabled) {
        try scheduleNativeForOpenDoc(self, a, doc);
    } else {
        try clearProviderBucket(self, a, uri, .cel);
    }
    if (self.settings.schema_enabled or self.settings.lint_enabled) {
        try scheduleSchemaAndExternal(self, uri, doc);
    } else {
        try clearProviderBucket(self, a, uri, .schema);
        try clearProviderBucket(self, a, uri, .external);
    }
}

pub fn onChange(self: *Server, a: Allocator, uri: []const u8) !void {
    if (!self.settings.validation_enabled or !self.settings.cel_enabled) return;
    const doc = self.documents.get(uri) orelse return;
    try scheduleNativeForOpenDoc(self, a, doc);
}

pub fn onSave(self: *Server, a: Allocator, uri: []const u8) !void {
    const path = paths.uriToPath(a, uri) catch "";
    if (path.len > 0) {
        if (self.validation.active_ruleset) |srs| {
            if (srs.ruleset.isWatchedRuleFile(path)) {
                try reloadAndRevalidateAll(self, a);
                return;
            }
        }
    }
    try publish(self, a, uri);
}

pub fn onClose(self: *Server, a: Allocator, uri: []const u8) !void {
    const path = paths.uriToPath(a, uri) catch "";
    const in_workspace = path.len > 0 and self.session.snapshot().member(path) != null;

    if (self.settings.validation_enabled and self.settings.cel_enabled and in_workspace and isEligibleNativeYaml(path)) {
        try clearProviderBucket(self, a, uri, .schema);
        try clearProviderBucket(self, a, uri, .external);
        try scheduleNativeFromDisk(self, a, uri, path);
        return;
    }
    try clearUri(self, a, uri);
}

pub fn onWatchedFile(self: *Server, a: Allocator, path: []const u8, deleted: bool) !void {
    if (self.validation.active_ruleset) |srs| {
        if (srs.ruleset.isWatchedRuleFile(path)) {
            try reloadAndRevalidateAll(self, a);
            return;
        }
    }
    const uri = paths.pathToUri(a, path) catch return;
    if (deleted) {
        try clearUri(self, a, uri);
        return;
    }
    if (!self.settings.validation_enabled or !self.settings.cel_enabled) return;
    if (self.documents.get(uri) != null) return;
    if (self.session.snapshot().member(path) == null) return;
    if (!isEligibleNativeYaml(path)) return;
    try scheduleNativeFromDisk(self, a, uri, path);
}

pub fn onWorkspaceIndexReady(self: *Server, a: Allocator) !void {
    if (!self.settings.validation_enabled or !self.settings.cel_enabled) return;
    try scheduleWorkspaceNative(self, a);
}

pub fn reloadAndRevalidateAll(self: *Server, a: Allocator) !void {
    try reloadRuleset(self, a);

    var tracked = std.ArrayList([]const u8).empty;
    defer tracked.deinit(a);
    var bit = self.validation.buckets.keyIterator();
    while (bit.next()) |k| {
        try tracked.append(a, try a.dupe(u8, k.*));
    }

    for (tracked.items) |uri| {
        if (!self.settings.validation_enabled) {
            try clearUri(self, a, uri);
            continue;
        }
        if (!self.settings.cel_enabled) try clearProviderBucket(self, a, uri, .cel);
        if (!self.settings.schema_enabled) try clearProviderBucket(self, a, uri, .schema);
        if (!self.settings.lint_enabled) try clearProviderBucket(self, a, uri, .external);

        if (self.documents.get(uri) == null) {
            const path = paths.uriToPath(a, uri) catch "";
            const is_rule_err = blk: {
                for (self.validation.rule_error_uris.items) |ru| {
                    if (std.mem.eql(u8, ru, uri)) break :blk true;
                }
                break :blk false;
            };
            if (!is_rule_err and (path.len == 0 or self.session.snapshot().member(path) == null)) {
                try clearUri(self, a, uri);
            }
        }
    }

    if (!self.settings.validation_enabled) return;

    var open_uris = std.ArrayList([]const u8).empty;
    defer open_uris.deinit(a);
    var dit = self.documents.docs.keyIterator();
    while (dit.next()) |k| {
        try open_uris.append(a, try a.dupe(u8, k.*));
    }
    for (open_uris.items) |uri| {
        try publish(self, a, uri);
    }
    if (self.settings.cel_enabled) {
        try scheduleWorkspaceNative(self, a);
    }
}

fn scheduleWorkspaceNative(self: *Server, a: Allocator) !void {
    try ensureRuleset(self, a);
    var lease = self.index.acquireQuery(false);
    defer lease.release();

    var paths_list = std.ArrayList([]const u8).empty;
    defer paths_list.deinit(a);

    var it = self.index.entries.keyIterator();
    while (it.next()) |k| {
        const p = k.*;
        if (!isEligibleNativeYaml(p)) continue;
        try paths_list.append(a, try a.dupe(u8, p));
    }

    for (paths_list.items) |p| {
        const uri = paths.pathToUri(a, p) catch continue;
        if (self.documents.get(uri)) |doc| {
            try scheduleNativeForOpenDoc(self, a, doc);
        } else {
            try scheduleNativeFromDisk(self, a, uri, p);
        }
    }
}

fn scheduleNativeForOpenDoc(self: *Server, a: Allocator, doc: *const doc_mod.Document) !void {
    const path = paths.uriToPath(a, doc.uri) catch return;
    if (!isEligibleNativeYaml(path)) return;
    try ensureRuleset(self, a);
    const shared = self.validation.active_ruleset orelse return;
    const display = displayPathFor(self, path);

    shared.retain();
    errdefer shared.release(self.validation.gpa);

    const job = try self.validation.gpa.create(NativeJob);
    errdefer self.validation.gpa.destroy(job);
    job.* = .{
        .arena = std.heap.ArenaAllocator.init(self.validation.gpa),
        .ruleset_generation = shared.ruleset.generation,
        .shared_ruleset = shared,
        .uri = undefined,
        .path = undefined,
        .display_path = undefined,
        .bytes_override = undefined,
        .encoding = self.encoding,
        .metadata = currentMetadataSnapshot(self),
    };
    errdefer job.arena.deinit();

    const ja = job.arena.allocator();
    job.uri = try ja.dupe(u8, doc.uri);
    job.path = try ja.dupe(u8, path);
    job.display_path = try ja.dupe(u8, display);
    job.bytes_override = try ja.dupe(u8, doc.bytes());

    try self.validation.enqueueNative(self.pool, job);
}

fn scheduleNativeFromDisk(self: *Server, a: Allocator, uri: []const u8, path: []const u8) !void {
    try ensureRuleset(self, a);
    const shared = self.validation.active_ruleset orelse return;
    const display = displayPathFor(self, path);

    shared.retain();
    errdefer shared.release(self.validation.gpa);

    const job = try self.validation.gpa.create(NativeJob);
    errdefer self.validation.gpa.destroy(job);
    job.* = .{
        .arena = std.heap.ArenaAllocator.init(self.validation.gpa),
        .ruleset_generation = shared.ruleset.generation,
        .shared_ruleset = shared,
        .uri = undefined,
        .path = undefined,
        .display_path = undefined,
        .bytes_override = null,
        .encoding = self.encoding,
        .metadata = currentMetadataSnapshot(self),
    };
    errdefer job.arena.deinit();

    const ja = job.arena.allocator();
    job.uri = try ja.dupe(u8, uri);
    job.path = try ja.dupe(u8, path);
    job.display_path = try ja.dupe(u8, display);

    try self.validation.enqueueNative(self.pool, job);
}

fn scheduleSchemaAndExternal(self: *Server, uri: []const u8, doc: *const doc_mod.Document) !void {
    const job = try self.validation.gpa.create(Job);
    errdefer self.validation.gpa.destroy(job);
    job.* = .{
        .arena = std.heap.ArenaAllocator.init(self.validation.gpa),
        .snapshot = undefined,
        .options = undefined,
        .runner = self.runner,
        .schema = self.schemas.schemaForUri(uri),
    };
    errdefer job.arena.deinit();

    const ja = job.arena.allocator();
    job.snapshot = .{
        .uri = try ja.dupe(u8, uri),
        .bytes = try ja.dupe(u8, doc.bytes()),
        .document_range = doc.rangeFromOffsets(0, doc.bytes().len),
    };
    job.options = .{
        .schema_enabled = self.settings.schema_enabled,
        .lint_enabled = self.settings.lint_enabled,
        .lint_path = try ja.dupe(u8, self.settings.lint_path),
        .lint_arguments = try ja.dupe(u8, self.settings.lint_arguments),
    };
    job.runner.cancel = &self.validation.shutdown;

    try self.validation.enqueue(self.pool, job);
}

fn currentMetadataSnapshot(self: *Server) ast.MetadataSnapshot {
    const count = self.docs.catalogCount();
    if (count > 0) {
        return .{ .status = .ready, .generation = 1 };
    }
    if (self.docs_service.hasPendingBootstrap()) {
        return .{ .status = .pending, .reason = "module metadata catalog is loading" };
    }
    return .{ .status = .unavailable, .reason = "module metadata unavailable" };
}

fn displayPathFor(self: *Server, path: []const u8) []const u8 {
    if (self.session.snapshot().member(path)) |root| {
        if (path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and std.fs.path.isSep(path[root.len])) {
            return path[root.len + 1 ..];
        }
    }
    return path;
}

pub fn drain(self: *Server, a: Allocator) !void {
    try drainSchemaAndExternal(self, a);
    try drainNative(self, a);
}

fn drainSchemaAndExternal(self: *Server, a: Allocator) !void {
    self.validation.mutex.lock();
    if (self.validation.completed.items.len == 0) {
        self.validation.mutex.unlock();
        return;
    }
    const items = self.validation.completed.toOwnedSlice(self.validation.gpa) catch {
        self.validation.mutex.unlock();
        return;
    };
    self.validation.mutex.unlock();
    defer self.validation.gpa.free(items);

    for (items) |job| {
        defer job.destroy(self.validation.gpa);
        if (job.failed) continue;
        if (!self.validation.isLatest(job.snapshot.uri, job.seq)) continue;
        if (!self.settings.validation_enabled) continue;
        if (self.documents.get(job.snapshot.uri) == null) continue;

        const b = try getOrCreateBucket(&self.validation, job.snapshot.uri);
        if (self.settings.schema_enabled) {
            freeDiagSlice(self.validation.gpa, b.schema);
            b.schema = try cloneDiagSlice(self.validation.gpa, job.schema_diagnostics);
        }
        if (self.settings.lint_enabled) {
            freeDiagSlice(self.validation.gpa, b.external);
            b.external = try cloneDiagSlice(self.validation.gpa, job.external_diagnostics);
        }
        try publishCombined(self, a, job.snapshot.uri);
    }
}

fn drainNative(self: *Server, a: Allocator) !void {
    self.validation.native_mutex.lock();
    if (self.validation.native_completed.items.len == 0) {
        self.validation.native_mutex.unlock();
        return;
    }
    const items = self.validation.native_completed.toOwnedSlice(self.validation.gpa) catch {
        self.validation.native_mutex.unlock();
        return;
    };
    self.validation.native_mutex.unlock();
    defer self.validation.gpa.free(items);

    for (items) |job| {
        defer job.destroy(self.validation.gpa);
        if (job.failed or job.cancelled) continue;
        if (!self.validation.isLatestNative(job.uri, job.seq)) continue;
        if (job.ruleset_generation != self.validation.ruleset_generation) continue;
        if (!self.settings.validation_enabled or !self.settings.cel_enabled) continue;

        if (job.file_missing) {
            try clearProviderBucket(self, a, job.uri, .cel);
            continue;
        }

        const b = try getOrCreateBucket(&self.validation, job.uri);
        freeDiagSlice(self.validation.gpa, b.cel);
        b.cel = try cloneDiagSlice(self.validation.gpa, job.diagnostics);
        try publishCombined(self, a, job.uri);

        if (job.runtime_errors.len > 0) {
            const first = job.runtime_errors[0];
            const msg = try std.fmt.allocPrint(
                a,
                "zals-cel runtime error in rule '{s}': {s}",
                .{ first.rule_id, first.message },
            );
            out.logMessage(self.writer, a, 2, msg) catch {};
        }
    }
}

const BucketKind = enum { cel, schema, external, rule_file };

fn getOrCreateBucket(q: *Queue, uri: []const u8) !*ProviderBuckets {
    const gop = try q.buckets.getOrPut(q.gpa, uri);
    if (!gop.found_existing) {
        gop.key_ptr.* = try q.gpa.dupe(u8, uri);
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

fn clearProviderBucket(self: *Server, a: Allocator, uri: []const u8, kind: BucketKind) !void {
    const b = self.validation.buckets.getPtr(uri) orelse return;
    switch (kind) {
        .cel => {
            if (b.cel.len == 0) return;
            freeDiagSlice(self.validation.gpa, b.cel);
            b.cel = &.{};
        },
        .schema => {
            if (b.schema.len == 0) return;
            freeDiagSlice(self.validation.gpa, b.schema);
            b.schema = &.{};
        },
        .external => {
            if (b.external.len == 0) return;
            freeDiagSlice(self.validation.gpa, b.external);
            b.external = &.{};
        },
        .rule_file => {
            if (b.rule_file.len == 0) return;
            freeDiagSlice(self.validation.gpa, b.rule_file);
            b.rule_file = &.{};
        },
    }
    try publishCombined(self, a, uri);
}

fn clearUri(self: *Server, a: Allocator, uri: []const u8) !void {
    self.validation.invalidateUri(uri);
    if (self.validation.buckets.fetchRemove(uri)) |removed| {
        var b = removed.value;
        b.deinit(self.validation.gpa);
        self.validation.gpa.free(removed.key);
    }
    try send(self, a, uri, &.{});
}

fn publishCombined(self: *Server, a: Allocator, uri: []const u8) !void {
    const b = self.validation.buckets.get(uri) orelse {
        try send(self, a, uri, &.{});
        return;
    };
    const total = b.cel.len + b.schema.len + b.external.len + b.rule_file.len;
    if (total == 0) {
        try send(self, a, uri, &.{});
        return;
    }
    var combined = try a.alloc(types.Diagnostic, total);
    var offset: usize = 0;
    @memcpy(combined[offset..][0..b.cel.len], b.cel);
    offset += b.cel.len;
    @memcpy(combined[offset..][0..b.schema.len], b.schema);
    offset += b.schema.len;
    @memcpy(combined[offset..][0..b.external.len], b.external);
    offset += b.external.len;
    @memcpy(combined[offset..][0..b.rule_file.len], b.rule_file);
    try send(self, a, uri, combined);
}

fn send(self: *Server, a: Allocator, uri: []const u8, diags: []const types.Diagnostic) !void {
    var arr = std.json.Array.init(a);
    for (diags) |d| {
        var obj = json_util.obj(a);
        var range = json_util.obj(a);
        try putPos(&range, a, "start", d.range.start);
        try putPos(&range, a, "end", d.range.end);
        try obj.put("range", .{ .object = range });
        if (d.severity) |s| try obj.put("severity", json_util.num(@intFromEnum(s)));
        try obj.put("message", json_util.str(d.message));
        if (d.source) |src| try obj.put("source", json_util.str(src));
        if (d.code) |c| try obj.put("code", json_util.str(c));
        try arr.append(.{ .object = obj });
    }
    var params = json_util.obj(a);
    try params.put("uri", json_util.str(uri));
    try params.put("diagnostics", .{ .array = arr });
    try self.notify(a, "textDocument/publishDiagnostics", .{ .object = params });
}

fn putPos(obj: *std.json.ObjectMap, a: Allocator, key: []const u8, pos: types.Position) !void {
    var p = json_util.obj(a);
    try p.put("line", json_util.num(pos.line));
    try p.put("character", json_util.num(pos.character));
    try obj.put(key, .{ .object = p });
}

test "validation runs on the worker pool without blocking the main thread" {
    const testing = std.testing;
    const Transport = @import("../lsp/transport.zig").Transport;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try tmp.dir.createFile("messages", .{ .read = true });
    defer output.close();

    var server = try Server.init(testing.allocator, Transport.init(output, output), null);
    defer server.deinit();
    server.settings.lint_enabled = false;

    const uri = "file:///tmp/galaxy.yml";
    _ = try server.documents.open(uri, "yaml", 1, "namespace: acme\nname: web\nversion: 1.0.0\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try publish(&server, arena.allocator(), uri);

    var deadline: usize = 0;
    while (server.validation.hasPending() and deadline < 500) : (deadline += 1) {
        std.Thread.sleep(2 * std.time.ns_per_ms);
        try drain(&server, arena.allocator());
    }
    try testing.expect(!server.validation.hasPending());
}
