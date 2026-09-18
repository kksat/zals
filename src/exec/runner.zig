//! Pluggable command execution.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn success(self: Result) bool {
        return switch (self.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }
};

/// Interface: a vtable so tests can inject fakes and a future pure-Zig backend
/// can replace process spawning without touching consumers.
pub const Runner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, allocator: Allocator, argv: []const []const u8) anyerror!Result,
    };

    pub fn run(self: Runner, allocator: Allocator, argv: []const []const u8) anyerror!Result {
        return self.vtable.run(self.ptr, allocator, argv);
    }
};

pub const Posix = struct {
    const vtable = Runner.VTable{ .run = run };

    pub fn posixRunner() Runner {
        return .{ .ptr = undefined, .vtable = &vtable };
    }

    fn run(_: *anyopaque, allocator: Allocator, argv: []const []const u8) anyerror!Result {
        const spawned = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .max_output_bytes = 16 * 1024 * 1024,
        });
        return .{
            .stdout = spawned.stdout,
            .stderr = spawned.stderr,
            .term = spawned.term,
        };
    }
};
