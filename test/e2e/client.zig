//! Minimal stdio LSP client for a single, read-only zals session.
//! Notifications are consumed while awaiting responses; the Workspace index
//! readiness notification is a barrier before any navigation assertion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Client = struct {
    allocator: Allocator,
    child: std.process.Child,
    next_id: i64 = 1,
    index_ready: bool = false,

    pub const StartOptions = struct {
        collections_path: ?[]const u8 = null,
        use_fixture_config: bool = true,
        venv_override: ?[]const u8 = null,
    };

    pub fn start(a: Allocator, binary: []const u8, fixture: []const u8, deps: []const u8, home: []const u8) !Client {
        return startWithOptions(a, binary, fixture, deps, home, .{});
    }

    pub fn startWithOptions(a: Allocator, binary: []const u8, fixture: []const u8, deps: []const u8, home: []const u8, options: StartOptions) !Client {
        var env = try std.process.getEnvMap(a);
        defer env.deinit();
        const collection_paths = options.collections_path orelse try std.fmt.allocPrint(a, "{s}{c}{s}", .{ fixture, std.fs.path.delimiter, deps });
        if (collection_paths.len > 0) try env.put("ANSIBLE_COLLECTIONS_PATH", collection_paths) else env.remove("ANSIBLE_COLLECTIONS_PATH");
        env.remove("ANSIBLE_COLLECTIONS_PATHS");
        try env.put("ANSIBLE_ROLES_PATH", try std.fs.path.join(a, &.{ fixture, "roles" }));
        if (options.use_fixture_config) {
            try env.put("ANSIBLE_CONFIG", try std.fs.path.join(a, &.{ fixture, "ansible.cfg" }));
        } else env.remove("ANSIBLE_CONFIG");
        try env.put("HOME", home);
        // Isolate the docs cache too, even if the test runner has XDG configured.
        try env.put("XDG_CACHE_HOME", try std.fs.path.join(a, &.{ home, ".cache" }));
        env.remove("VIRTUAL_ENV");

        const argv: []const []const u8 = if (options.venv_override) |venv|
            &.{ binary, "--stdio", "--log-level", "error", "--venv", venv }
        else
            &.{ binary, "--stdio", "--log-level", "error" };
        var child = std.process.Child.init(argv, a);
        child.env_map = &env;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // Inherit diagnostics instead of risking a full, unread stderr pipe.
        child.stderr_behavior = .Inherit;
        try child.spawn();
        child.env_map = null;
        return .{ .allocator = a, .child = child };
    }

    pub fn deinit(self: *Client) void {
        if (self.child.stdin) |file| {
            file.close();
            self.child.stdin = null;
        }
        _ = self.child.kill() catch {
            _ = self.child.wait() catch {};
        };
    }

    pub fn request(self: *Client, method: []const u8, params: anytype) !Value {
        const id = self.next_id;
        self.next_id += 1;
        try self.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        while (true) {
            const msg = try self.readMessage();
            if (field(msg, "method")) |event| {
                if (event == .string and std.mem.eql(u8, event.string, "ansible/workspaceIndexReady")) {
                    self.index_ready = true;
                }
                continue;
            }
            const response_id = (field(msg, "id") orelse return error.InvalidResponse);
            if (response_id != .integer or response_id.integer != id) return error.UnexpectedResponseId;
            if (field(msg, "error")) |server_error| {
                const detail = try std.json.Stringify.valueAlloc(self.allocator, server_error, .{});
                std.debug.print("zals {s} returned a JSON-RPC error: {s}\n", .{ method, detail });
                return error.JsonRpcError;
            }
            return field(msg, "result") orelse error.MissingResult;
        }
    }

    pub fn requestError(self: *Client, method: []const u8, params: anytype) !Value {
        const id = self.next_id;
        self.next_id += 1;
        try self.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        while (true) {
            const msg = try self.readMessage();
            if (field(msg, "method")) |event| {
                if (event == .string and std.mem.eql(u8, event.string, "ansible/workspaceIndexReady")) {
                    self.index_ready = true;
                }
                continue;
            }
            const response_id = (field(msg, "id") orelse return error.InvalidResponse);
            if (response_id != .integer or response_id.integer != id) return error.UnexpectedResponseId;
            return field(msg, "error") orelse error.ExpectedJsonRpcError;
        }
    }

    pub fn notify(self: *Client, method: []const u8, params: anytype) !void {
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    /// A request drives the server's index handoff queue, as in the existing
    /// workspace smoke test. Simply waiting for a notification can deadlock
    /// while the server is blocked reading stdin.
    pub fn waitForIndex(self: *Client) !void {
        const began = std.time.milliTimestamp();
        while (!self.index_ready) {
            if (std.time.milliTimestamp() - began > 20_000) return error.WorkspaceIndexTimeout;
            _ = try self.request("workspace/symbol", .{ .query = "__zals_e2e_wait__" });
            if (!self.index_ready) std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn send(self: *Client, payload: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
        const pipe = self.child.stdin orelse return error.ServerClosed;
        try pipe.writeAll(header);
        try pipe.writeAll(body);
    }

    fn readMessage(self: *Client) !Value {
        const pipe = self.child.stdout orelse return error.ServerClosed;
        var length: ?usize = null;
        while (true) {
            var line = std.array_list.Managed(u8).init(self.allocator);
            while (true) {
                var byte: [1]u8 = undefined;
                try readExact(pipe, &byte);
                if (byte[0] == '\n') break;
                if (line.items.len >= 4096) return error.HeaderTooLarge;
                try line.append(byte[0]);
            }
            const header = std.mem.trim(u8, line.items, " \r");
            if (header.len == 0) break;
            const prefix = "Content-Length:";
            if (std.mem.startsWith(u8, header, prefix)) {
                length = try std.fmt.parseInt(usize, std.mem.trim(u8, header[prefix.len..], " \t"), 10);
            }
        }
        const n = length orelse return error.MissingContentLength;
        if (n > 8 * 1024 * 1024) return error.MessageTooLarge;
        const body = try self.allocator.alloc(u8, n);
        try readExact(pipe, body);
        return try std.json.parseFromSliceLeaky(Value, self.allocator, body, .{});
    }
};

fn readExact(file: std.fs.File, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var ready = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&ready, 20_000) == 0) return error.ServerResponseTimeout;
        const count = try file.read(buffer[offset..]);
        if (count == 0) return error.ServerClosed;
        offset += count;
    }
}

pub fn field(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
