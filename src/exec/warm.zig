//! Warm fork-server runner (idea from
//! [speedrunner](https://github.com/anthonyGosme/speedrunner)).
//!
//! A Python CLI tool spends most of each call starting its interpreter and
//! importing its code. `Warm` keeps one daemon process per tool with all of
//! that done (started with the tool's own interpreter, taken from its console
//! script's shebang), and serves every call from a forked child that runs the
//! console script in-process. Calls that cannot be served — unknown tool,
//! unresolvable interpreter, daemon failure — fall back to the native `Posix`
//! runner, so behavior only ever degrades to the status quo. Cancellation
//! kills the daemon's process group (daemon plus in-flight tool child).
//!
//! One daemon serves one call at a time. A caller that finds the daemon busy
//! runs natively instead of queueing, so foreground requests never wait for
//! background work. Env and cwd reach the child per call. See
//! `warm_daemon.py` for the protocol and the fork-fidelity shims it applies.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const runner_mod = @import("runner.zig");
const Runner = runner_mod.Runner;
const Result = runner_mod.Result;
const Options = runner_mod.Options;

/// Embedded copy of the daemon script, written to a temp file at first use
/// (the interpreter needs a path to run; argv-size limits make `-c` fragile).
const daemon_source = @embedFile("warm_daemon.py");

/// A tool served warm: `name` matches `argv[0]` (as the plain name resolved
/// on PATH, or as a path to that same script), `preload` names the modules
/// the daemon imports eagerly.
pub const ToolSpec = struct {
    name: []const u8,
    preload: []const u8 = "",
};

/// The tools zals shells out to most: `ansible-doc` (catalog bootstrap and
/// module-doc batches) and `ansible-lint` (per-save validation).
pub const default_tools = [_]ToolSpec{
    .{ .name = "ansible-doc", .preload = "ansible.cli.doc" },
    .{ .name = "ansible-lint", .preload = "ansiblelint.__main__" },
};

const ready_timeout_ms: i32 = 30 * std.time.ms_per_s;
/// Clean shutdown lets an idle daemon exit and run its atexit cleanups
/// before this; a daemon that cannot exit in time is killed like a native
/// tool would be.
const shutdown_grace_ms: i64 = 250;
const poll_interval_ms: i32 = 25;
/// Same cap as the native runner; larger tool output falls back to native.
const max_output_bytes = 16 * 1024 * 1024;
const reply_header_len = 21; // kind(1) + i32 exit + u64 stdout len + u64 stderr len

pub const Warm = struct {
    allocator: Allocator,
    tools: []const ToolSpec,
    /// Serializes all daemon starts and requests (one call per daemon).
    mutex: std.Thread.Mutex = .{},
    daemons: std.StringHashMapUnmanaged(*Daemon) = .empty,
    /// Temp file holding `daemon_source`; removed on deinit.
    script_path: ?[]const u8 = null,
    disabled: bool = false,

    const vtable = Runner.VTable{ .run = run, .run_with_options = runWithOptions };

    pub fn init(allocator: Allocator, tools: []const ToolSpec) Warm {
        var disabled = builtin.os.tag == .windows;
        if (!disabled) {
            if (std.process.getEnvVarOwned(allocator, "ZALS_WARM")) |value| {
                defer allocator.free(value);
                // Any explicit "0" opts out; unset (or anything else) means warm.
                disabled = std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "0");
            } else |_| {}
        }
        return .{ .allocator = allocator, .tools = tools, .disabled = disabled };
    }

    /// The caller must ensure no request is in flight (join workers first).
    pub fn deinit(self: *Warm) void {
        var it = self.daemons.valueIterator();
        while (it.next()) |daemon| {
            daemon.*.stop(shutdown_grace_ms);
            self.allocator.free(daemon.*.script);
            self.allocator.free(daemon.*.preload);
            if (daemon.*.interpreter) |i| self.allocator.free(i);
            self.allocator.destroy(daemon.*);
        }
        self.daemons.deinit(self.allocator);
        if (self.script_path) |p| {
            std.fs.deleteFileAbsolute(p) catch {};
            self.allocator.free(p);
        }
    }

    pub fn runner(self: *Warm) Runner {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn run(ptr: *anyopaque, allocator: Allocator, argv: []const []const u8) anyerror!Result {
        return runWithOptions(ptr, allocator, argv, .{});
    }

    fn runWithOptions(ptr: *anyopaque, allocator: Allocator, argv: []const []const u8, options: Options) anyerror!Result {
        const self: *Warm = @ptrCast(@alignCast(ptr));
        // Cancel binding already happened in Runner.runWithOptions.
        try checkCancelled(options.cancel);
        if (!self.disabled) {
            // Never queue for the daemon: a call that arrives while another
            // one is being served (typically background docs prefetch, or a
            // long lint) runs natively right away, exactly as before. A busy
            // fallback keeps foreground requests as fast as the status quo
            // and lets warm serving win whenever the daemon is idle.
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();
                if (self.serveWarm(allocator, argv, options)) |result| {
                    return result;
                } else |err| {
                    if (err == error.Cancelled) return err;
                    // Daemon-level failure: run natively rather than fail the call.
                }
            }
        }
        const native = runner_mod.Posix.posixRunner();
        return native.runWithOptions(allocator, argv, options);
    }

    /// Must be called with the mutex held. Resolves, starts, and asks the
    /// daemon for `argv`; any error leaves the daemon stopped.
    fn serveWarm(self: *Warm, allocator: Allocator, argv: []const []const u8, options: Options) !Result {
        if (argv.len == 0) return error.NoTool;
        const spec = self.toolFor(argv[0]) orelse return error.ToolNotServed;
        // The console script the daemon runs: argv[0] itself when it is a
        // path (so settings like a custom lint path still serve warm), else
        // the spec name resolved on PATH — what a native exec would run.
        var owned_script: ?[]const u8 = null;
        defer if (owned_script) |s| self.allocator.free(s);
        const script = if (std.mem.indexOfScalar(u8, argv[0], '/') != null) blk: {
            // Only serve what a native exec could run, nothing more.
            if (!isExecutableFile(argv[0])) return error.ToolNotServed;
            break :blk argv[0];
        } else blk: {
            const s = resolveTool(self.allocator, spec.name) orelse return error.ToolNotFound;
            owned_script = s;
            break :blk s;
        };
        const daemon = try self.daemonFor(spec, script);
        // Any failure from here (start or request) stops the daemon so the
        // next call can start a fresh one instead of retrying a dead pipe.
        // Cancellation kills immediately: a request whose tool hangs must
        // not delay server shutdown past what a native spawn would.
        errdefer daemon.stop(0);
        if (daemon.child == null) try self.startDaemon(daemon, options.cancel);
        return self.request(allocator, daemon, argv, options);
    }

    fn toolFor(self: *Warm, arg0: []const u8) ?ToolSpec {
        for (self.tools) |spec| {
            if (std.mem.eql(u8, arg0, spec.name)) return spec;
        }
        // Path form: basename may name a tool (a custom path to the same
        // tool still serves warm; unrelated paths never match a name).
        const base = std.fs.path.basename(arg0);
        for (self.tools) |spec| {
            if (std.mem.eql(u8, base, spec.name)) return spec;
        }
        return null;
    }

    fn daemonFor(self: *Warm, spec: ToolSpec, script: []const u8) !*Daemon {
        if (self.daemons.get(script)) |daemon| return daemon;
        const daemon = try self.allocator.create(Daemon);
        errdefer self.allocator.destroy(daemon);
        const owned_script = try self.allocator.dupe(u8, script);
        errdefer self.allocator.free(owned_script);
        const preload = try self.allocator.dupe(u8, spec.preload);
        errdefer self.allocator.free(preload);
        daemon.* = .{ .script = owned_script, .preload = preload };
        // The map key borrows the owned `script`; valid until deinit.
        try self.daemons.put(self.allocator, daemon.script, daemon);
        return daemon;
    }

    fn startDaemon(self: *Warm, daemon: *Daemon, cancel: ?*const std.atomic.Value(bool)) !void {
        if (daemon.interpreter == null) daemon.interpreter = interpreterFor(self.allocator, daemon.script) orelse return error.NoPythonInterpreter;
        if (self.script_path == null) self.script_path = try writeDaemonScript(self.allocator);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            daemon.interpreter.?,
            self.script_path.?,
            "--script",
            daemon.script,
        });
        if (daemon.preload.len > 0) {
            try argv.append(self.allocator, "--preload");
            try argv.append(self.allocator, daemon.preload);
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // Daemon traces (stderr) stay visible for debugging; the tool's own
        // stderr is captured per call through the daemon's pipes.
        child.stderr_behavior = .Inherit;
        try child.spawn();
        daemon.child = child;
        errdefer daemon.stop(0);

        // Wait for the ready byte; preload and warmup happen before it.
        var ready: [1]u8 = undefined;
        try readExact(child.stdout.?.handle, &ready, cancel, ready_timeout_ms);
        if (ready[0] != '+') return error.WarmDaemonProtocol;
    }

    fn request(self: *Warm, allocator: Allocator, daemon: *Daemon, argv: []const []const u8, options: Options) !Result {
        _ = self;
        const child = &daemon.child.?;
        try writeRequest(child.stdin.?, allocator, argv, options);

        var header: [reply_header_len]u8 = undefined;
        try readExact(child.stdout.?.handle, &header, options.cancel, null);
        if (header[0] != 'R') {
            // Daemon-level refusal (bad request, fork failure): drain the
            // message and let the caller run natively.
            if (header[0] == 'E') {
                var len_buf: [4]u8 = undefined;
                try readExact(child.stdout.?.handle, &len_buf, options.cancel, null);
                const len = std.mem.readInt(u32, &len_buf, .little);
                const msg = try allocator.alloc(u8, len);
                defer allocator.free(msg);
                try readExact(child.stdout.?.handle, msg, options.cancel, null);
            }
            return error.WarmDaemonProtocol;
        }
        const exit = std.mem.readInt(i32, header[1..5], .little);
        const stdout_len = std.mem.readInt(u64, header[5..13], .little);
        const stderr_len = std.mem.readInt(u64, header[13..21], .little);
        if (stdout_len > max_output_bytes or stderr_len > max_output_bytes) return error.StdoutStreamTooLong;

        const stdout = try allocator.alloc(u8, @intCast(stdout_len));
        errdefer allocator.free(stdout);
        const stderr = try allocator.alloc(u8, @intCast(stderr_len));
        errdefer allocator.free(stderr);
        try readExact(child.stdout.?.handle, stdout, options.cancel, null);
        try readExact(child.stdout.?.handle, stderr, options.cancel, null);

        const term: std.process.Child.Term = if (exit >= 0)
            .{ .Exited = @intCast(exit) }
        else if (exit == -127)
            .{ .Unknown = 0 }
        else
            .{ .Signal = @intCast(-exit) };
        return .{ .stdout = stdout, .stderr = stderr, .term = term };
    }
};

const Daemon = struct {
    /// Owned key in `Warm.daemons`: the resolved console-script path.
    script: []const u8,
    preload: []const u8,
    /// Interpreter from the console script's shebang.
    interpreter: ?[]const u8 = null,
    child: ?std.process.Child = null,

    /// Stop the daemon. With a grace period, an idle daemon exits on stdin
    /// EOF and runs its atexit cleanups; when the grace expires, or when
    /// `grace_ms` is zero (cancellation, failures), the process group is
    /// killed outright, taking any in-flight tool child with it.
    fn stop(self: *Daemon, grace_ms: i64) void {
        var child = self.child orelse return;
        self.child = null;
        if (grace_ms > 0) {
            if (child.stdin) |stdin| {
                stdin.close();
                child.stdin = null;
            }
            const deadline = std.time.milliTimestamp() + grace_ms;
            while (std.time.milliTimestamp() < deadline) {
                const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
                if (result.pid != 0) {
                    // waitpid reaped it; cache the status so Child.wait only
                    // performs its normal stream cleanup (same trick as the
                    // native runner's cancellation path).
                    child.term = termOf(result.status);
                    _ = child.wait() catch {};
                    return;
                }
                std.Thread.sleep(@as(u64, @intCast(poll_interval_ms)) * std.time.ns_per_ms);
            }
        }
        killGroup(&child);
        _ = child.wait() catch {};
    }
};

fn termOf(status: u32) std.process.Child.Term {
    if (std.posix.W.IFEXITED(status)) return .{ .Exited = std.posix.W.EXITSTATUS(status) };
    if (std.posix.W.IFSIGNALED(status)) return .{ .Signal = std.posix.W.TERMSIG(status) };
    if (std.posix.W.IFSTOPPED(status)) return .{ .Stopped = std.posix.W.STOPSIG(status) };
    return .{ .Unknown = status };
}

/// The daemon puts itself in its own process group; kill the group so a
/// cancelled call takes the in-flight tool child with it.
fn killGroup(child: *std.process.Child) void {
    if (builtin.os.tag == .windows) {
        _ = child.kill() catch {};
        return;
    }
    std.posix.kill(-child.id, std.posix.SIG.KILL) catch {
        // Process-group leader died or never formed; kill the pid directly.
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
    };
}

fn checkCancelled(token: ?*const std.atomic.Value(bool)) !void {
    if (token) |cancel| {
        if (cancel.load(.acquire)) return error.Cancelled;
    }
}

/// Read exactly `buf.len` bytes from `fd`, honoring cancellation while
/// waiting. `timeout_ms` bounds the total wait (used for the ready byte);
/// tool calls have no deadline, like the native runner.
fn readExact(fd: std.posix.fd_t, buf: []u8, cancel: ?*const std.atomic.Value(bool), timeout_ms: ?i32) !void {
    var filled: usize = 0;
    const deadline: ?i64 = if (timeout_ms) |t| std.time.milliTimestamp() + t else null;
    while (filled < buf.len) {
        try checkCancelled(cancel);
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = try std.posix.poll(&fds, poll_interval_ms);
        if (deadline) |d| {
            if (std.time.milliTimestamp() > d) return error.WarmDaemonTimeout;
        }
        if (n == 0) continue;
        const r = std.posix.read(fd, buf[filled..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (r == 0) return error.EndOfStream;
        filled += r;
    }
}

fn writeRequest(stdin: std.fs.File, allocator: Allocator, argv: []const []const u8, options: Options) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("argv");
    try jw.beginArray();
    for (argv) |arg| try jw.write(arg);
    try jw.endArray();
    if (options.env_map) |env| {
        try jw.objectField("env");
        try jw.beginObject();
        var it = env.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
        try jw.endObject();
    }
    if (options.cwd) |cwd| {
        try jw.objectField("cwd");
        try jw.write(cwd);
    }
    try jw.endObject();
    try aw.writer.writeByte('\n');
    const bytes = try aw.toOwnedSlice();
    defer allocator.free(bytes);
    stdin.writeAll(bytes) catch |err| switch (err) {
        error.BrokenPipe => return error.WarmDaemonDied,
        else => return err,
    };
}

/// Write the embedded daemon script to a unique file under the temp dir.
/// The file is transient (removed on deinit) and must outlive zals only for
/// as long as the daemon runs, so the temp dir is the right home for it —
/// unlike a cache dir, it is never swept underneath a running process.
fn writeDaemonScript(allocator: Allocator) ![]u8 {
    var dir: []const u8 = "/tmp";
    var owned: ?[]const u8 = null;
    defer if (owned) |t| allocator.free(t);
    if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |tmp| {
        dir = tmp;
        owned = tmp;
    } else |_| {}
    if (!std.fs.path.isAbsolute(dir)) {
        if (owned) |t| allocator.free(t);
        owned = try std.fs.cwd().realpathAlloc(allocator, dir);
        dir = owned.?;
    }
    const name = try std.fmt.allocPrint(allocator, "zals-warm-daemon-{d}.py", .{std.crypto.random.int(u64)});
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    errdefer allocator.free(path);
    std.fs.cwd().makePath(dir) catch return error.NoTempDir;
    var base = try std.fs.openDirAbsolute(dir, .{});
    defer base.close();
    // Unique name: create exclusively so concurrent zals instances never share.
    var file = try base.createFile(name, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(daemon_source);
    return path;
}

/// Resolve `name` on PATH (or take it as a path when it contains a slash).
/// Returns an owned path to an executable regular file, or null.
fn resolveTool(allocator: Allocator, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return if (isExecutableFile(name)) (allocator.dupe(u8, name) catch null) else null;
    }
    var env = std.process.getEnvMap(allocator) catch return null;
    defer env.deinit();
    const path_value = env.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_value, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        if (!isExecutableFile(full)) {
            allocator.free(full);
            continue;
        }
        return full;
    }
    return null;
}

fn isExecutableFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    if (stat.kind != .file) return false;
    return (stat.mode & 0o111) != 0;
}

/// The interpreter a Python console script runs with: the shebang of the
/// script itself (pip/pipx write absolute interpreter paths there). Returns
/// an owned path, or null when the script is not Python-launchable.
fn interpreterFor(allocator: Allocator, script: []const u8) ?[]const u8 {
    var file = std.fs.cwd().openFile(script, .{}) catch return null;
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = file.read(&buf) catch return null;
    const shebang = std.mem.sliceTo(buf[0..n], '\n');
    if (!std.mem.startsWith(u8, shebang, "#!")) return null;
    var tokens = std.mem.tokenizeAny(u8, shebang[2..], " \t");
    const interp = tokens.next() orelse return null;
    if (std.mem.eql(u8, interp, "/usr/bin/env")) {
        // #!/usr/bin/env python3: resolve like exec would.
        const name = tokens.next() orelse return null;
        if (tokens.next() != null) return null; // env flags we cannot replay
        const resolved = resolveTool(allocator, name) orelse return null;
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved) catch null;
    }
    if (!std.mem.startsWith(u8, interp, "/")) return null;
    if (std.mem.indexOf(u8, interp, "python") == null) return null;
    if (!isExecutableFile(interp)) return null;
    return allocator.dupe(u8, interp) catch null;
}

test "warm runner serves a python console script warm" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const python = resolveTool(allocator, "python3") orelse return error.SkipZigTest;
    defer allocator.free(python);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try std.fmt.allocPrint(allocator,
        \\#!{s}
        \\import json, os, sys
        \\print(json.dumps({{"flag": sys.argv[1], "arg": sys.argv[2], "cwd": os.getcwd(), "marker": os.environ.get("ZALS_WARM_TEST")}}))
        \\sys.stderr.write("note")
        \\sys.exit(7)
    , .{python});
    defer allocator.free(script);
    try tmp.dir.writeFile(.{ .sub_path = "zals-warm-test", .data = script });
    const script_path = try tmp.dir.realpathAlloc(allocator, "zals-warm-test");
    defer allocator.free(script_path);
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    // A native exec of argv[0] would need the exec bit; so does the warm path.
    {
        var f = try std.fs.cwd().openFile(script_path, .{});
        defer f.close();
        try f.chmod(0o755);
    }

    var warm = Warm.init(allocator, &.{.{ .name = "zals-warm-test" }});
    defer warm.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("ZALS_WARM_TEST", "served");

    const result = try warm.runner().runWithOptions(allocator, &.{
        script_path, "--flag", "value",
    }, .{ .env_map = &env, .cwd = tmp_path });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 7), result.term.Exited);
    try std.testing.expectEqualStrings("note", result.stderr);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("arg").?.string);
    try std.testing.expectEqualStrings("--flag", parsed.value.object.get("flag").?.string);
    try std.testing.expectEqualStrings("served", parsed.value.object.get("marker").?.string);
    try std.testing.expectEqualStrings(tmp_path, parsed.value.object.get("cwd").?.string);
}

test "warm runner falls back to native when the tool cannot run warm" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Not on PATH and not Python: no daemon can serve it, so the native
    // runner must execute it directly.
    try tmp.dir.writeFile(.{
        .sub_path = "zals-warm-test",
        .data = "#!/bin/sh\necho native\nexit 3\n",
    });
    const abs = try tmp.dir.realpathAlloc(allocator, "zals-warm-test");
    defer allocator.free(abs);
    // Ensure executable (tmpDir files are 0o600 on some platforms).
    {
        var f = try std.fs.cwd().openFile(abs, .{});
        defer f.close();
        try f.chmod(0o755);
    }

    var warm = Warm.init(allocator, &.{.{ .name = "zals-warm-test" }});
    defer warm.deinit();
    const result = try warm.runner().run(allocator, &.{abs});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 3), result.term.Exited);
    try std.testing.expectEqualStrings("native\n", result.stdout);
}

test "warm runner recovers to native after the daemon dies" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const python = resolveTool(allocator, "python3") orelse return error.SkipZigTest;
    defer allocator.free(python);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try std.fmt.allocPrint(allocator, "#!{s}\nprint(\"served\")\n", .{python});
    defer allocator.free(script);
    try tmp.dir.writeFile(.{ .sub_path = "zals-warm-test", .data = script });
    const script_path = try tmp.dir.realpathAlloc(allocator, "zals-warm-test");
    defer allocator.free(script_path);
    // The native fallback after the daemon dies executes this file directly.
    {
        var f = try std.fs.cwd().openFile(script_path, .{});
        defer f.close();
        try f.chmod(0o755);
    }

    var warm = Warm.init(allocator, &.{.{ .name = "zals-warm-test" }});
    defer warm.deinit();

    const first = warm.serveWarm(allocator, &.{script_path}, .{}) catch |err| {
        std.debug.print("warm: first call not served (error {s})\n", .{@errorName(err)});
        return error.FirstCallNotWarm;
    };
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("served\n", first.stdout);

    // Kill the daemon behind the runner's back. Depending on scheduling, the
    // next call may hit the dead pipe (native fallback) or race the kill and
    // be served warm; both must return the right output.
    var killed_pid: std.process.Child.Id = 0;
    {
        warm.mutex.lock();
        defer warm.mutex.unlock();
        var it = warm.daemons.valueIterator();
        if (it.next()) |daemon| {
            if (daemon.*.child) |child| {
                var victim = child;
                killGroup(&victim);
                killed_pid = victim.id;
            }
        }
    }
    const second = try warm.runner().run(allocator, &.{script_path});
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("served\n", second.stdout);

    // Force whatever remains of the daemon to a stopped state (reaped or
    // gently exited), so the restart assertion below cannot race the kill.
    {
        warm.mutex.lock();
        defer warm.mutex.unlock();
        var it = warm.daemons.valueIterator();
        if (it.next()) |daemon| daemon.*.stop(shutdown_grace_ms);
    }

    // The next call must start a fresh daemon and serve warm again.
    const third = warm.serveWarm(allocator, &.{script_path}, .{}) catch |err| {
        std.debug.print("warm: restart not served (error {s})\n", .{@errorName(err)});
        return error.RestartNotWarm;
    };
    defer third.deinit(allocator);
    try std.testing.expectEqualStrings("served\n", third.stdout);
    {
        warm.mutex.lock();
        defer warm.mutex.unlock();
        var it = warm.daemons.valueIterator();
        const daemon = it.next().?.*;
        try std.testing.expect(daemon.child != null);
        try std.testing.expect(daemon.child.?.id != killed_pid);
    }
}

test "toolFor matches names and basenames, not unrelated paths" {
    var warm = Warm.init(std.testing.allocator, &.{.{ .name = "ansible-doc" }});
    defer warm.deinit();
    try std.testing.expect(warm.toolFor("ansible-doc") != null);
    try std.testing.expect(warm.toolFor("ansible-lint") == null);
    try std.testing.expect(warm.toolFor("/custom/ansible-doc") != null); // identity checked later
    try std.testing.expect(warm.toolFor("/custom/other") == null);
}

test "interpreterFor reads python shebangs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const python = resolveTool(allocator, "python3") orelse return error.SkipZigTest;
    defer allocator.free(python);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs_data = try std.fmt.allocPrint(allocator, "#!{s}\n", .{python});
    defer allocator.free(abs_data);
    try tmp.dir.writeFile(.{ .sub_path = "abs", .data = abs_data });
    try tmp.dir.writeFile(.{ .sub_path = "env", .data = "#!/usr/bin/env python3\n" });
    try tmp.dir.writeFile(.{ .sub_path = "sh", .data = "#!/bin/sh\n" });
    const abs = try tmp.dir.realpathAlloc(allocator, "abs");
    defer allocator.free(abs);
    const env = try tmp.dir.realpathAlloc(allocator, "env");
    defer allocator.free(env);
    const sh = try tmp.dir.realpathAlloc(allocator, "sh");
    defer allocator.free(sh);

    // Absolute shebang: taken as-is.
    const got_abs = interpreterFor(allocator, abs) orelse return error.TestUnexpectedResult;
    defer allocator.free(got_abs);
    try std.testing.expectEqualStrings(python, got_abs);

    // env shebang resolves through PATH.
    const got_env = interpreterFor(allocator, env) orelse return error.TestUnexpectedResult;
    defer allocator.free(got_env);
    try std.testing.expectEqualStrings(python, got_env);

    // Non-python shebangs are not served warm.
    try std.testing.expect(interpreterFor(allocator, sh) == null);
}
