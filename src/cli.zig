const std = @import("std");

pub const LogLevel = enum { @"error", warn, info, debug };

pub const Options = struct {
    /// Communicate over stdio. Currently the only supported transport.
    stdio: bool = true,
    log_file: ?[]const u8 = null,
    log_level: LogLevel = .info,
    show_version: bool = false,
    show_help: bool = false,
};

pub const ParseError = error{
    UnknownArgument,
    MissingValue,
    InvalidLogLevel,
};

/// Parse command-line arguments (excluding argv[0]) into `options`.
pub fn parse(args: []const []const u8, options: *Options) ParseError!void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stdio")) {
            options.stdio = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            options.show_version = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.show_help = true;
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.log_file = args[i];
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.log_level =
                std.meta.stringToEnum(LogLevel, args[i]) orelse
                return error.InvalidLogLevel;
        } else {
            return error.UnknownArgument;
        }
    }
}

test "parse defaults" {
    var options = Options{};
    try parse(&.{}, &options);
    try std.testing.expect(options.stdio);
    try std.testing.expectEqual(LogLevel.info, options.log_level);
    try std.testing.expect(options.log_file == null);
}

test "parse version and help" {
    var options = Options{};
    try parse(&.{ "--version", "--help" }, &options);
    try std.testing.expect(options.show_version);
    try std.testing.expect(options.show_help);
}

test "parse log options" {
    var options = Options{};
    try parse(&.{ "--log-file", "/tmp/zals.log", "--log-level", "debug" }, &options);
    try std.testing.expectEqualStrings("/tmp/zals.log", options.log_file.?);
    try std.testing.expectEqual(LogLevel.debug, options.log_level);
}

test "parse rejects unknown argument" {
    var options = Options{};
    try std.testing.expectError(error.UnknownArgument, parse(&.{"--nope"}, &options));
}

test "parse rejects missing value" {
    var options = Options{};
    try std.testing.expectError(error.MissingValue, parse(&.{"--log-file"}, &options));
}

test "parse rejects invalid log level" {
    var options = Options{};
    try std.testing.expectError(error.InvalidLogLevel, parse(&.{ "--log-level", "loud" }, &options));
}
