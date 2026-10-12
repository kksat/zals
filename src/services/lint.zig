//! ansible-lint (codeclimate) and ansible-playbook --syntax-check.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const exec = @import("../exec/root.zig");
const types = @import("../lsp/types.zig");
const json_util = @import("../lsp/json_util.zig");

/// Tool status is independent of diagnostic count. Only known executable/spawn
/// errors are unavailable; output/read/wait errors and unknown Runner errors are
/// failed. Allocation failure is always propagated, never a tool outcome.
pub const Status = union(enum) {
    clean,
    findings,
    unavailable: anyerror,
    failed: Failure,
};

pub const Failure = union(enum) {
    execution: anyerror,
    invalid_output,
    abnormal_exit: std.process.Child.Term,
};

/// Diagnostics and their strings live in the supplied request arena. A failed
/// status may retain usable findings; an empty slice alone never means clean.
pub const Outcome = struct {
    status: Status,
    diagnostics: []const types.Diagnostic = &.{},
};

/// Accept valid findings from any normal exit code (ansible-lint uses nonzero
/// for findings). Only a zero exit with a valid empty array is clean. Invalid
/// JSON/shape and abnormal termination remain failed, not unavailable.
pub fn lintFile(
    arena: Allocator,
    runner: exec.Runner,
    lint_path: []const u8,
    extra_args: []const u8,
    file_path: []const u8,
) !Outcome {
    var argv = std.array_list.Managed([]const u8).init(arena);
    try argv.append(lint_path);
    try argv.append("--offline");
    try argv.append("--nocolor");
    try argv.append("-f");
    try argv.append("codeclimate");
    if (extra_args.len > 0) {
        var it = std.mem.tokenizeScalar(u8, extra_args, ' ');
        while (it.next()) |arg| try argv.append(arg);
    }
    try argv.append(file_path);

    const result = runner.run(arena, argv.items) catch |err| return executionFailure(err);
    const parsed = std.json.parseFromSliceLeaky(Value, arena, result.stdout, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .status = .{ .failed = .invalid_output } };
    };
    const outcome = try parseCodeclimate(arena, parsed);
    if (outcome.status == .failed) return outcome;
    return switch (result.term) {
        .Exited => |code| if (code == 0 or outcome.diagnostics.len > 0)
            outcome
        else
            .{ .status = .{ .failed = .{ .abnormal_exit = result.term } } },
        else => .{ .status = .{ .failed = .{ .abnormal_exit = result.term } }, .diagnostics = outcome.diagnostics },
    };
}

fn parseCodeclimate(arena: Allocator, value: Value) !Outcome {
    const arr = switch (value) {
        .array => |a| a,
        else => return .{ .status = .{ .failed = .invalid_output } },
    };
    var valid = true;
    var out = std.array_list.Managed(types.Diagnostic).init(arena);
    for (arr.items) |item| {
        const desc = json_util.string(item, "description") orelse json_util.string(item, "check_name") orelse {
            valid = false;
            continue;
        };
        const severity = severityOf(json_util.string(item, "severity"));
        var range = types.Range{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        };
        if (json_util.field(item, "location")) |loc| {
            if (json_util.field(loc, "lines")) |lines| {
                const begin = json_util.integer(lines, "begin") orelse 1;
                const line: u32 = @intCast(@max(begin, 1) - 1);
                range = .{
                    .start = .{ .line = line, .character = 0 },
                    .end = .{ .line = line, .character = 0 },
                };
            }
        }
        try out.append(.{
            .range = range,
            .severity = severity,
            .source = "ansible-lint",
            .message = desc,
            .code = json_util.string(item, "check_name"),
        });
    }
    return .{
        .status = if (!valid) .{ .failed = .invalid_output } else if (out.items.len == 0) .clean else .findings,
        .diagnostics = try out.toOwnedSlice(),
    };
}

fn severityOf(s: ?[]const u8) ?types.DiagnosticSeverity {
    const name = s orelse return .warning;
    if (std.mem.eql(u8, name, "blocker") or std.mem.eql(u8, name, "critical") or std.mem.eql(u8, name, "major"))
        return .err;
    if (std.mem.eql(u8, name, "minor")) return .warning;
    if (std.mem.eql(u8, name, "info")) return .information;
    return .warning;
}

/// Successful syntax-check is clean; a normal nonzero exit with text produces
/// one whole-document diagnostic. Empty failures or abnormal termination are
/// explicitly failed, retaining any diagnostic text just as lint does.
pub fn syntaxCheck(
    arena: Allocator,
    runner: exec.Runner,
    ansible_playbook: []const u8,
    file_path: []const u8,
    document_range: types.Range,
) !Outcome {
    const argv = [_][]const u8{ ansible_playbook, "--syntax-check", file_path };
    const result = runner.run(arena, &argv) catch |err| return executionFailure(err);
    if (result.success()) return .{ .status = .clean };
    const failed: Status = .{ .failed = .{ .abnormal_exit = result.term } };
    const msg = if (result.stderr.len > 0) result.stderr else result.stdout;
    if (msg.len == 0) return .{ .status = failed };
    const trimmed = std.mem.trim(u8, msg, " \n\r\t");
    var diags = try arena.alloc(types.Diagnostic, 1);
    diags[0] = .{
        .range = document_range,
        .severity = .err,
        .source = "ansible-playbook",
        .message = trimmed,
    };
    return .{
        .status = if (result.term == .Exited) .findings else failed,
        .diagnostics = diags,
    };
}

fn executionFailure(err: anyerror) !Outcome {
    if (err == error.OutOfMemory) return err;
    // Runner has no phase tag. Recognize executable lookup/exec and spawn setup
    // errors conservatively; do not reinterpret arbitrary injected errors,
    // stream limits, read failures, or unexpected wait errors as unavailability.
    const unavailable = switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.InvalidExe,
        error.FileSystem,
        error.IsDir,
        error.NotDir,
        error.FileBusy,
        error.NameTooLong,
        error.InvalidName,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NoDevice,
        error.InvalidWtf8,
        error.InvalidBatchScriptArg,
        error.CurrentWorkingDirectoryUnlinked,
        => true,
        else => false,
    };
    return .{ .status = if (unavailable) .{ .unavailable = err } else .{ .failed = .{ .execution = err } } };
}

/// Compatibility export; document validation uses this canonical conversion.
pub const uriToPath = @import("../paths.zig").uriToPath;
