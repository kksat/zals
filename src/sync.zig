const std = @import("std");
const fsio = @import("fsio.zig");

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(fsio.get());
    }

    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(fsio.get());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(c: *Condition, mutex: *Mutex) void {
        c.inner.waitUncancelable(fsio.get(), &mutex.inner);
    }

    pub fn timedWait(c: *Condition, mutex: *Mutex, ns: u64) error{Timeout}!void {
        return c.inner.waitTimeout(fsio.get(), &mutex.inner, .{ .duration = .fromNanoseconds(ns) });
    }

    pub fn signal(c: *Condition) void {
        c.inner.signal(fsio.get());
    }

    pub fn broadcast(c: *Condition) void {
        c.inner.broadcast(fsio.get());
    }
};

pub fn sleep(ns: u64) void {
    fsio.get().sleep(.fromNanoseconds(ns), .awake) catch {};
}
