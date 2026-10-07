//! A small fixed-size thread pool (ADR-0011).
//!
//! Tasks are plain function-pointer + context pairs. The pool owns the worker
//! threads and a FIFO queue; callers own the task context and free it inside
//! the task function.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Task = struct {
    func: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const ThreadPool = struct {
    allocator: Allocator,
    threads: []std.Thread,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(*Task) = .empty,
    head: usize = 0,
    shutdown: bool = false,

    pub fn init(allocator: Allocator, n: usize) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .threads = &.{} };

        const threads = try allocator.alloc(std.Thread, n);
        var started: usize = 0;
        errdefer {
            self.mutex.lock();
            self.shutdown = true;
            self.cond.broadcast();
            self.mutex.unlock();
            for (threads[0..started]) |t| t.join();
            allocator.free(threads);
        }
        for (threads) |*t| {
            t.* = try std.Thread.spawn(.{}, worker, .{self});
            started += 1;
        }
        self.threads = threads;
        return self;
    }

    pub fn deinit(self: *ThreadPool) void {
        self.mutex.lock();
        self.shutdown = true;
        self.cond.broadcast();
        self.mutex.unlock();
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn submit(self: *ThreadPool, task: *Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutdown) return error.Shutdown;
        try self.queue.append(self.allocator, task);
        self.cond.signal();
    }

    fn worker(self: *ThreadPool) void {
        while (true) {
            self.mutex.lock();
            while (self.head >= self.queue.items.len and !self.shutdown)
                self.cond.wait(&self.mutex);
            if (self.head >= self.queue.items.len) {
                self.mutex.unlock();
                return;
            }
            const task = self.queue.items[self.head];
            self.head += 1;
            // Compact the queue once the consumed prefix dominates.
            if (self.head > 64 and self.head * 2 > self.queue.items.len) {
                const remaining = self.queue.items.len - self.head;
                std.mem.copyForwards(*Task, self.queue.items[0..remaining], self.queue.items[self.head..]);
                self.queue.shrinkRetainingCapacity(remaining);
                self.head = 0;
            }
            self.mutex.unlock();
            task.func(task.ctx);
        }
    }
};

test "pool runs tasks" {
    const Ctx = struct {
        counter: *std.atomic.Value(usize),
        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.counter.fetchAdd(1, .monotonic);
        }
    };
    var counter = std.atomic.Value(usize).init(0);
    var pool = try ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var tasks: [32]Task = undefined;
    var ctxs: [32]Ctx = undefined;
    for (&tasks, &ctxs) |*t, *c| {
        c.* = .{ .counter = &counter };
        t.* = .{ .func = Ctx.run, .ctx = c };
        try pool.submit(t);
    }
    while (counter.load(.monotonic) < 32) std.Thread.sleep(1 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 32), counter.load(.monotonic));
}
