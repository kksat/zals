const std = @import("std");
const builtin = @import("builtin");
const zals = @import("zals");

const version = "1.0.0"; // x-release-please-version

const usage =
    \\Usage: zals [options]
    \\
    \\Options:
    \\  --stdio              Communicate over stdio (default)
    \\  --log-file <path>    Write server logs to a file
    \\  --log-level <level>  error | warn | info | debug
    \\  --venv <path>        Virtual environment whose collections are searched
    \\                       (default: .venv, or ansible.python.venvPath)
    \\  --yaml-lower <path>  Parse YAML, print its JSON lowering, and exit
    \\  --version            Print version and exit
    \\  -h, --help           Print this help and exit
    \\
;

var log_file: ?std.Io.File = null;
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
    if (@backingInt(message_level) > @backingInt(runtime_log_level)) return;
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, level_txt ++ prefix2 ++ format ++ "\n", args) catch blk: {
        break :blk level_txt ++ prefix2 ++ format ++ "\n";
    };
    if (log_file) |f| {
        f.writeStreamingAll(zals.fsio.get(), msg) catch {};
    } else {
        std.Io.File.stderr().writeStreamingAll(zals.fsio.get(), msg) catch {};
    }
}

fn applyLogLevel(level: zals.cli.LogLevel) std.log.Level {
    return switch (level) {
        .@"error" => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

pub fn main(init: std.process.Init) !void {
    zals.fsio.set(init.io, init.minimal.environ);
    const io = zals.fsio.get();

    var gpa: if (builtin.mode == .debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .debug) .{} else {};
    defer if (builtin.mode == .debug) {
        _ = gpa.deinit();
    };
    const allocator = if (builtin.mode == .debug) gpa.allocator() else std.heap.c_allocator;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    _ = args_it.next();
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    while (args_it.next()) |arg| try args.append(allocator, arg);

    var options = zals.cli.Options{};
    zals.cli.parse(args.items, &options) catch |err| {
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
    if (options.yaml_lower) |path| {
        try runYamlLower(allocator, io, path);
        return;
    }

    runtime_log_level = applyLogLevel(options.log_level);
    if (options.log_file) |path| {
        log_file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    }
    defer if (log_file) |f| f.close(io);

    const transport = zals.lsp.Transport.init(
        io,
        std.Io.File.stdin(),
        std.Io.File.stdout(),
    );
    var server = try zals.lsp.Server.init(allocator, transport, options.venv);
    defer server.deinit();
    try server.run();
}

fn runYamlLower(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const text = try zals.fsio.readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(text);
    var forest = try zals.yaml.parse(allocator, text);
    defer forest.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = if (forest.roots.len > 0)
        try zals.yaml.jsonify.toJson(arena.allocator(), forest.roots[0])
    else
        std.json.Value.null;
    const out = try zals.yaml.python_json.render(arena.allocator(), value);
    try std.Io.File.stdout().writeStreamingAll(io, out);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
