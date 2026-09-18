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

    // TODO(M1): start the LSP server over stdio.
    _ = options.stdio;
}
