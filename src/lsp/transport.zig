//! LSP base-protocol framing over a byte stream.
//!
//! Messages are framed with `Content-Length: <n>\r\n\r\n<body>`. The reader is
//! buffered; the writer is a thin wrapper over `write(2)` with a retry loop.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Transport = struct {
    in_file: std.fs.File,
    out_file: std.fs.File,
    in_buf: [16 * 1024]u8 = undefined,
    in_len: usize = 0,
    in_pos: usize = 0,
    write_mutex: std.Thread.Mutex = .{},

    pub fn init(in_file: std.fs.File, out_file: std.fs.File) Transport {
        return .{ .in_file = in_file, .out_file = out_file };
    }

    /// Wait for the next input without stranding background readiness events.
    /// Buffered bytes must win over polling the fd (a read can contain several
    /// LSP messages). EOF/error readiness is passed to readMessage as usual.
    pub fn waitForInput(self: *Transport, timeout_ms: i32) !bool {
        if (self.in_pos < self.in_len) return true;
        if (@import("builtin").os.tag == .windows) {
            const windows = std.os.windows;
            const Pipe = struct {
                extern "kernel32" fn PeekNamedPipe(
                    windows.HANDLE,
                    ?*anyopaque,
                    windows.DWORD,
                    ?*windows.DWORD,
                    ?*windows.DWORD,
                    ?*windows.DWORD,
                ) callconv(.winapi) windows.BOOL;
            };
            var available: windows.DWORD = 0;
            // A closed pipe or non-pipe input should fall through to read.
            if (Pipe.PeekNamedPipe(self.in_file.handle, null, 0, null, &available, null) == 0 or available > 0) return true;
            std.Thread.sleep(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
            return false;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = self.in_file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        return try std.posix.poll(&fds, timeout_ms) != 0;
    }

    fn fill(self: *Transport) !void {
        if (self.in_pos < self.in_len) return;
        const n = self.in_file.read(&self.in_buf) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        self.in_len = n;
        self.in_pos = 0;
    }

    fn readByte(self: *Transport) !u8 {
        try self.fill();
        const b = self.in_buf[self.in_pos];
        self.in_pos += 1;
        return b;
    }

    /// Read one framed message body. Returns null on clean EOF.
    pub fn readMessage(self: *Transport, allocator: Allocator) !?[]u8 {
        var content_length: ?usize = null;

        // Read headers line by line until the blank line.
        var line_buf: [256]u8 = undefined;
        while (true) {
            var len: usize = 0;
            // Read a line terminated by \n, stripping a trailing \r.
            while (true) {
                const b = self.readByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (len == 0 and content_length == null) return null;
                        return error.UnexpectedEndOfStream;
                    },
                    else => return err,
                };
                if (b == '\n') break;
                if (len < line_buf.len) {
                    line_buf[len] = b;
                    len += 1;
                }
            }
            if (len > 0 and line_buf[len - 1] == '\r') len -= 1;
            const line = line_buf[0..len];
            if (line.len == 0) break; // end of headers

            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trim(u8, line["content-length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidContentLength;
            }
            // Other headers (Content-Type) are ignored.
        }

        const n = content_length orelse return error.MissingContentLength;
        const body = try allocator.alloc(u8, n);
        errdefer allocator.free(body);
        var read: usize = 0;
        while (read < n) {
            try self.fill();
            const avail = self.in_len - self.in_pos;
            const take = @min(avail, n - read);
            @memcpy(body[read .. read + take], self.in_buf[self.in_pos .. self.in_pos + take]);
            self.in_pos += take;
            read += take;
        }
        return body;
    }

    fn writeAll(self: *Transport, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            written += self.out_file.write(bytes[written..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
        }
    }

    /// Write one framed message. Safe to call from multiple threads.
    pub fn writeMessage(self: *Transport, bytes: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{bytes.len});
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.writeAll(header);
        try self.writeAll(bytes);
    }
};

test "frame round trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("frame", .{ .read = true });
    defer file.close();

    var writer = Transport.init(file, file);
    try writer.writeMessage("{\"jsonrpc\":\"2.0\"}");
    try file.seekTo(0);

    var reader = Transport.init(file, file);
    const msg = (try reader.readMessage(allocator)).?;
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", msg);
}

test "input waiting honors already buffered messages" {
    const file = std.fs.File.stdin();
    var transport = Transport.init(file, std.fs.File.stdout());
    transport.in_len = 2;
    transport.in_pos = 1;
    try std.testing.expect(try transport.waitForInput(0));
}
