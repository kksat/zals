//! Pluggable command execution.

const std = @import("std");
const fsio = @import("../fsio.zig");
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
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub const Options = struct {
    env_map: ?*const std.process.Environ.Map = null,
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
        const io = fsio.get();
        const cwd: std.process.Child.Cwd = if (options.cwd) |c| .{ .path = c } else .inherit;
        if (options.cancel == null) {
            const spawned = try std.process.run(allocator, io, .{
                .argv = argv,
                .cwd = cwd,
                .environ_map = options.env_map,
                .stdout_limit = .limited(max_output_bytes),
                .stderr_limit = .limited(max_output_bytes),
            });
            return .{ .stdout = spawned.stdout, .stderr = spawned.stderr, .term = spawned.term };
        }

        try checkCancelled(options.cancel);
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = cwd,
            .environ_map = options.env_map,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer killChild(io, &child);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        while (true) {
            try checkCancelled(options.cancel);
            multi_reader.fill(1, .{ .duration = .{ .raw = .{ .nanoseconds = cancel_interval_ns }, .clock = .awake } }) catch |err| switch (err) {
                error.EndOfStream => {},
                error.Timeout => {},
                else => return err,
            };
            if (multi_reader.reader(0).buffered().len > max_output_bytes) return error.StdoutStreamTooLong;
            if (multi_reader.reader(1).buffered().len > max_output_bytes) return error.StderrStreamTooLong;
            var all_done = true;
            for (multi_reader.streams.contexts()) |*context| {
                if (context.err == null) {
                    all_done = false;
                    break;
                }
            }
            if (all_done) break;
        }
        try multi_reader.checkAnyError();
        const term = try waitForTerm(&child, options.cancel);
        const stdout = try multi_reader.toOwnedSlice(0);
        errdefer allocator.free(stdout);
        const stderr = try multi_reader.toOwnedSlice(1);
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

fn killChild(io: std.Io, child: *std.process.Child) void {
    if (@import("builtin").os.tag == .windows) {
        child.kill(io);
        return;
    }
    if (child.id) |pid| {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
    }
}

fn waitForTerm(child: *std.process.Child, token: ?*const std.atomic.Value(bool)) !std.process.Child.Term {
    while (true) {
        try checkCancelled(token);
        if (reapIfExited(child)) |term| return term;
        @import("../sync.zig").sleep(cancel_interval_ns);
    }
}

fn reapIfExited(child: *std.process.Child) ?std.process.Child.Term {
    const pid = child.id.?;
    var status: c_int = undefined;
    const nohang: c_int = @intCast(std.posix.W.NOHANG);
    if (std.c.waitpid(pid, &status, nohang) == 0) return null;
    child.id = null;
    if (child.stdin) |f| {
        f.close(fsio.get());
        child.stdin = null;
    }
    if (child.stdout) |f| {
        f.close(fsio.get());
        child.stdout = null;
    }
    if (child.stderr) |f| {
        f.close(fsio.get());
        child.stderr = null;
    }
    const s: u32 = @bitCast(status);
    if (std.posix.W.IFEXITED(s)) return .{ .exited = std.posix.W.EXITSTATUS(s) };
    if (std.posix.W.IFSIGNALED(s)) return .{ .signal = std.posix.W.TERMSIG(s) };
    if (std.posix.W.IFSTOPPED(s)) return .{ .stopped = std.posix.W.STOPSIG(s) };
    return .{ .unknown = s };
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
    try std.testing.expectEqual(@as(u8, 7), result.term.exited);
}
