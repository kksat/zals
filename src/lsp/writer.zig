//! Outgoing message writer thread (ADR-0011).
//!
//! All LSP messages are framed and enqueued here; a dedicated thread drains the
//! queue and writes to the output fd. This keeps the main loop from blocking on
//! a slow client. Ordering is FIFO, so responses stay in request order.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    allocator: Allocator,
    out_file: std.fs.File,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList([]u8) = .empty,
    head: usize = 0,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    pub fn init(allocator: Allocator, out_file: std.fs.File) !*Writer {
        const self = try allocator.create(Writer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .out_file = out_file };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *Writer) void {
        self.mutex.lock();
        self.shutdown = true;
        self.cond.signal();
        self.mutex.unlock();
        if (self.thread) |t| t.join();
        for (self.queue.items[self.head..]) |b| self.allocator.free(b);
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Enqueue one message body. The writer thread frames and writes it.
    pub fn writeMessage(self: *Writer, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutdown) {
            self.allocator.free(copy);
            return error.Shutdown;
        }
        try self.queue.append(self.allocator, copy);
        self.cond.signal();
    }

    fn run(self: *Writer) void {
        while (true) {
            self.mutex.lock();
            while (self.head >= self.queue.items.len and !self.shutdown)
                self.cond.wait(&self.mutex);
            if (self.head >= self.queue.items.len) {
                self.mutex.unlock();
                return;
            }
            const body = self.queue.items[self.head];
            self.head += 1;
            if (self.head > 64 and self.head * 2 > self.queue.items.len) {
                const remaining = self.queue.items.len - self.head;
                std.mem.copyForwards([]u8, self.queue.items[0..remaining], self.queue.items[self.head..]);
                self.queue.shrinkRetainingCapacity(remaining);
                self.head = 0;
            }
            self.mutex.unlock();

            writeFramed(self.out_file, body) catch {};
            self.allocator.free(body);
        }
    }
};

fn writeFramed(file: std.fs.File, body: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
    try writeAll(file, header);
    try writeAll(file, body);
}

fn writeAll(file: std.fs.File, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += file.write(bytes[written..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}

test "writer frames and writes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("out", .{ .read = true });
    defer file.close();

    var writer = try Writer.init(allocator, file);
    try writer.writeMessage("{\"jsonrpc\":\"2.0\"}");
    writer.deinit();

    try file.seekTo(0);
    var buf: [128]u8 = undefined;
    const n = try file.read(&buf);
    try std.testing.expectEqualStrings("Content-Length: 17\r\n\r\n{\"jsonrpc\":\"2.0\"}", buf[0..n]);
}
