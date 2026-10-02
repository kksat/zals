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

pub const Options = struct {
    env_map: ?*const std.process.EnvMap = null,
    cwd: ?[]const u8 = null,
};

/// Interface: a vtable so tests can inject fakes and a future pure-Zig backend
/// can replace process spawning without touching consumers.
pub const Runner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, allocator: Allocator, argv: []const []const u8) anyerror!Result,
        run_with_options: ?*const fn (ptr: *anyopaque, allocator: Allocator, argv: []const []const u8, options: Options) anyerror!Result = null,
    };

    pub fn run(self: Runner, allocator: Allocator, argv: []const []const u8) anyerror!Result {
        return self.vtable.run(self.ptr, allocator, argv);
    }

    pub fn runWithOptions(self: Runner, allocator: Allocator, argv: []const []const u8, options: Options) anyerror!Result {
        if (self.vtable.run_with_options) |run_options| return run_options(self.ptr, allocator, argv, options);
        if (options.env_map != null or options.cwd != null) return error.UnsupportedExecutionOptions;
        return self.run(allocator, argv);
    }
};

pub const Posix = struct {
    const vtable = Runner.VTable{ .run = run, .run_with_options = runWithOptions };

    pub fn posixRunner() Runner {
        return .{ .ptr = undefined, .vtable = &vtable };
    }

    fn run(ptr: *anyopaque, allocator: Allocator, argv: []const []const u8) anyerror!Result {
        return runWithOptions(ptr, allocator, argv, .{});
    }

    fn runWithOptions(_: *anyopaque, allocator: Allocator, argv: []const []const u8, options: Options) anyerror!Result {
        const spawned = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .env_map = options.env_map,
            .cwd = options.cwd,
            .max_output_bytes = 16 * 1024 * 1024,
        });
        return .{
            .stdout = spawned.stdout,
            .stderr = spawned.stderr,
            .term = spawned.term,
        };
    }
};
