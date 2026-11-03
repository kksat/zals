//! Adapt open documents/settings to background validation on the worker pool
//! and publish diagnostics on the main thread (ADR-0011, ADR-0015).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const validation = @import("../services/validation.zig");
const exec = @import("../exec/root.zig");
const concurrency = @import("../concurrency/root.zig");

pub const Queue = struct {
    gpa: Allocator,
    mutex: std.Thread.Mutex = .{},
    latest_seq: std.StringHashMapUnmanaged(u64) = .empty,
    next_seq: u64 = 1,
    pending: std.ArrayListUnmanaged(*Job) = .empty,
    completed: std.ArrayListUnmanaged(*Job) = .empty,
    worker_running: bool = false,
    worker_task: concurrency.Task = undefined,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(gpa: Allocator) Queue {
        return .{ .gpa = gpa };
    }

    /// The worker pool must already be joined before deinit.
    pub fn deinit(self: *Queue) void {
        for (self.pending.items) |job| job.destroy(self.gpa);
        self.pending.deinit(self.gpa);
        for (self.completed.items) |job| job.destroy(self.gpa);
        self.completed.deinit(self.gpa);
        var it = self.latest_seq.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.latest_seq.deinit(self.gpa);
    }

    pub fn hasPending(self: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.worker_running or self.pending.items.len > 0 or self.completed.items.len > 0;
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

        // Drop any queued-but-unstarted job for the same URI so a burst of
        // opens/saves never runs superseded lint passes.
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

    fn isLatest(self: *Queue, uri: []const u8, seq: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return (self.latest_seq.get(uri) orelse 0) == seq;
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
                job.diagnostics = res.diagnostics;
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
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    seq: u64 = 0,
    snapshot: validation.Snapshot,
    options: validation.Options,
    runner: exec.Runner,
    schema: ?Value,
    diagnostics: []const types.Diagnostic = &.{},
    failed: bool = false,

    fn destroy(self: *Job, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub fn publish(self: *Server, a: Allocator, uri: []const u8) !void {
    if (!self.settings.validation_enabled) {
        try send(self, a, uri, &.{});
        return;
    }
    const doc = self.documents.get(uri) orelse return;

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
        .lint_enabled = self.settings.lint_enabled,
        .lint_path = try ja.dupe(u8, self.settings.lint_path),
        .lint_arguments = try ja.dupe(u8, self.settings.lint_arguments),
    };
    job.runner.cancel = &self.validation.shutdown;

    try self.validation.enqueue(self.pool, job);
}

pub fn drain(self: *Server, a: Allocator) !void {
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
        if (self.documents.get(job.snapshot.uri) == null) continue;
        try send(self, a, job.snapshot.uri, job.diagnostics);
    }
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
