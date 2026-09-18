const std = @import("std");
const zals = @import("zals");

const version = "0.0.0";

const usage =
    \\Usage: zals [options]
    \\
    \\Options:
    \\  --stdio              Communicate over stdio (default)
    \\  --log-file <path>    Write server logs to a file
    \\  --log-level <level>  error | warn | info | debug
    \\  --version            Print version and exit
    \\  -h, --help           Print this help and exit
    \\
;

var log_file: ?std.fs.File = null;
var runtime_log_level: std.log.Level = .info;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(runtime_log_level)) return;
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, level_txt ++ prefix2 ++ format ++ "\n", args) catch blk: {
        break :blk level_txt ++ prefix2 ++ format ++ "\n";
    };
    const fd = if (log_file) |f| f.handle else std.posix.STDERR_FILENO;
    _ = std.posix.write(fd, msg) catch {};
}

fn applyLogLevel(level: zals.cli.LogLevel) std.log.Level {
    return switch (level) {
        .@"error" => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = zals.cli.Options{};
    zals.cli.parse(args[1..], &options) catch |err| {
        std.debug.print("zals: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(2);
    };

    if (options.show_version) {
        std.debug.print("{s}\n", .{version});
        return;
    }
    if (options.show_help) {
        std.debug.print("{s}", .{usage});
        return;
    }

    runtime_log_level = applyLogLevel(options.log_level);
    if (options.log_file) |path| {
        log_file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    }
    defer if (log_file) |f| f.close();

    const transport = zals.lsp.Transport.init(
        std.fs.File.stdin().handle,
        std.fs.File.stdout().handle,
    );
    var server = zals.lsp.Server.init(allocator, transport);
    defer server.deinit();
    try server.run();
}
