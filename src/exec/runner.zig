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
    /// Borrowed owner-lifetime token; cancellation terminates and reaps the child.
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// Interface: a vtable so tests can inject fakes and a future pure-Zig backend
/// can replace process spawning without touching consumers.
pub const Runner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Bind cancellation once so nested docs/config runners inherit it.
    cancel: ?*const std.atomic.Value(bool) = null,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, allocator: Allocator, argv: []const []const u8) anyerror!Result,
        run_with_options: ?*const fn (ptr: *anyopaque, allocator: Allocator, argv: []const []const u8, options: Options) anyerror!Result = null,
    };

    pub fn run(self: Runner, allocator: Allocator, argv: []const []const u8) anyerror!Result {
        return self.runWithOptions(allocator, argv, .{});
    }

    pub fn runWithOptions(self: Runner, allocator: Allocator, argv: []const []const u8, options: Options) anyerror!Result {
        var bound = options;
        bound.cancel = options.cancel orelse self.cancel;
        try checkCancelled(bound.cancel);
        if (self.vtable.run_with_options) |run_options| return run_options(self.ptr, allocator, argv, bound);
        if (bound.env_map != null or bound.cwd != null) return error.UnsupportedExecutionOptions;
        return self.vtable.run(self.ptr, allocator, argv);
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
        if (options.cancel == null) {
            const spawned = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = argv,
                .env_map = options.env_map,
                .cwd = options.cwd,
                .max_output_bytes = max_output_bytes,
            });
            return .{ .stdout = spawned.stdout, .stderr = spawned.stderr, .term = spawned.term };
        }

        try checkCancelled(options.cancel);
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.env_map = options.env_map;
        child.cwd = options.cwd;
        try child.spawn();
        errdefer terminateChild(&child);
        try child.waitForSpawn();

        var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
            .stdout = child.stdout.?,
            .stderr = child.stderr.?,
        });
        defer poller.deinit();
        while (true) {
            try checkCancelled(options.cancel);
            const active = try poller.pollTimeout(cancel_interval_ns);
            if (poller.reader(.stdout).bufferedLen() > max_output_bytes) return error.StdoutStreamTooLong;
            if (poller.reader(.stderr).bufferedLen() > max_output_bytes) return error.StderrStreamTooLong;
            if (!active) break;
        }
        // A child can close its output streams and remain alive. Do not turn
        // that case back into an uncancellable blocking wait.
        const term = try waitForTerm(&child, options.cancel);
        const stdout = try poller.toOwnedSlice(.stdout);
        errdefer allocator.free(stdout);
        const stderr = try poller.toOwnedSlice(.stderr);
        return .{ .stdout = stdout, .stderr = stderr, .term = term };
    }
};

const max_output_bytes = 16 * 1024 * 1024;
const cancel_interval_ns = 25 * std.time.ns_per_ms;

fn checkCancelled(token: ?*const std.atomic.Value(bool)) !void {
    if (token) |cancel| {
        if (cancel.load(.acquire)) return error.Cancelled;
    }
}

fn terminateChild(child: *std.process.Child) void {
    if (@import("builtin").os.tag == .windows or child.term != null) {
        _ = child.kill() catch {};
    } else {
        // SIGTERM handlers in an external plugin must not stall server teardown.
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    }
}

fn waitForTerm(child: *std.process.Child, token: ?*const std.atomic.Value(bool)) !std.process.Child.Term {
    while (true) {
        try checkCancelled(token);
        if (@import("builtin").os.tag == .windows) {
            std.os.windows.WaitForSingleObjectEx(child.id, 25, false) catch |err| switch (err) {
                error.WaitTimeOut => continue,
                else => return err,
            };
            return child.wait();
        } else {
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) {
                // waitpid reaped it. Cache the status so Child.wait only performs
                // its normal stream cleanup rather than waiting a second time.
                const status = result.status;
                child.term = if (std.posix.W.IFEXITED(status))
                    std.process.Child.Term{ .Exited = std.posix.W.EXITSTATUS(status) }
                else if (std.posix.W.IFSIGNALED(status))
                    std.process.Child.Term{ .Signal = std.posix.W.TERMSIG(status) }
                else if (std.posix.W.IFSTOPPED(status))
                    std.process.Child.Term{ .Stopped = std.posix.W.STOPSIG(status) }
                else
                    std.process.Child.Term{ .Unknown = status };
                return child.wait();
            }
            std.Thread.sleep(cancel_interval_ns);
        }
    }
}

test "bound cancellation prevents spawning an already cancelled command" {
    var cancelled = std.atomic.Value(bool).init(true);
    var runner = Posix.posixRunner();
    runner.cancel = &cancelled;
    try std.testing.expectError(error.Cancelled, runner.run(std.testing.allocator, &.{"does-not-exist"}));
}

test "cancellable command preserves output and exit status" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var cancelled = std.atomic.Value(bool).init(false);
    var runner = Posix.posixRunner();
    runner.cancel = &cancelled;
    const result = try runner.run(std.testing.allocator, &.{ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(@as(u8, 7), result.term.Exited);
}
