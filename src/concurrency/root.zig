//! Concurrency primitives (ADR-0011).

pub const pool = @import("pool.zig");
pub const ThreadPool = pool.ThreadPool;
pub const Task = pool.Task;

test {
    @import("std").testing.refAllDecls(@This());
}