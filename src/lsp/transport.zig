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

test "reader accepts case-insensitive length, whitespace, and content type headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("headers", .{ .read = true });
    defer file.close();
    try file.writeAll("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncOnTeNt-LeNgTh:\t 2 \t\r\n\r\n{}");
    try file.seekTo(0);
    var reader = Transport.init(file, file);
    const msg = (try reader.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("{}", msg);
    try std.testing.expect((try reader.readMessage(std.testing.allocator)) == null);
}

test "reader separates consecutive frames including an empty body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("frames", .{ .read = true });
    defer file.close();
    var writer = Transport.init(file, file);
    const bodies = [_][]const u8{ "{\"text\":\"é😀\"}", "", "{\"id\":2}" };
    for (bodies) |body| try writer.writeMessage(body);
    try file.seekTo(0);
    var reader = Transport.init(file, file);
    for (bodies) |body| {
        const msg = (try reader.readMessage(std.testing.allocator)).?;
        defer std.testing.allocator.free(msg);
        try std.testing.expectEqualStrings(body, msg);
    }
    try std.testing.expect((try reader.readMessage(std.testing.allocator)) == null);
}

test "writer counts utf-8 bytes in Content-Length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("unicode", .{ .read = true });
    defer file.close();
    var writer = Transport.init(file, file);
    try writer.writeMessage("é😀");
    try file.seekTo(0);
    const bytes = try file.readToEndAlloc(std.testing.allocator, 100);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("Content-Length: 6\r\n\r\né😀", bytes);
}

test "reader refills its buffer for large bodies without consuming the next frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("large", .{ .read = true });
    defer file.close();
    const body = try std.testing.allocator.alloc(u8, 2 * 16 * 1024 + 37);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);
    var writer = Transport.init(file, file);
    try writer.writeMessage(body);
    try writer.writeMessage("next");
    try file.seekTo(0);
    var reader = Transport.init(file, file);
    const first = (try reader.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualSlices(u8, body, first);
    const second = (try reader.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("next", second);
    try std.testing.expect((try reader.readMessage(std.testing.allocator)) == null);
}

test "reader rejects missing or malformed lengths and truncated frames" {
    const cases = [_]struct { frame: []const u8, expected: anyerror }{
        .{ .frame = "Content-Type: application/json\r\n\r\n{}", .expected = error.MissingContentLength },
        .{ .frame = "Content-Length: nope\r\n\r\n{}", .expected = error.InvalidContentLength },
        .{ .frame = "Content-Length: -1\r\n\r\n", .expected = error.InvalidContentLength },
        .{ .frame = "Content-Length: 999999999999999999999999999999\r\n\r\n", .expected = error.InvalidContentLength },
        .{ .frame = "Content-Length: 2\r\n", .expected = error.UnexpectedEndOfStream },
        .{ .frame = "Content-Len", .expected = error.UnexpectedEndOfStream },
        .{ .frame = "Content-Length: 3\r\n\r\n{}", .expected = error.EndOfStream },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const file = try tmp.dir.createFile("invalid", .{ .read = true });
        defer file.close();
        try file.writeAll(case.frame);
        try file.seekTo(0);
        var reader = Transport.init(file, file);
        try std.testing.expectError(case.expected, reader.readMessage(std.testing.allocator));
    }
}
