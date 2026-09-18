//! ansible-lint (codeclimate) and ansible-playbook --syntax-check.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const exec = @import("../exec/root.zig");
const types = @import("../lsp/types.zig");
const json_util = @import("../lsp/json_util.zig");
const Document = @import("../workspace/document.zig").Document;

pub fn lintFile(
    arena: Allocator,
    runner: exec.Runner,
    lint_path: []const u8,
    extra_args: []const u8,
    file_path: []const u8,
) ![]types.Diagnostic {
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

    const result = runner.run(arena, argv.items) catch return &.{};
    // stdout lives in `arena` only if runner allocated with arena; posix runner
    // uses the passed allocator, so we must free via arena (same).
    const parsed = std.json.parseFromSliceLeaky(Value, arena, result.stdout, .{}) catch return &.{};
    return parseCodeclimate(arena, parsed);
}

fn parseCodeclimate(arena: Allocator, value: Value) ![]types.Diagnostic {
    const arr = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    var out = std.array_list.Managed(types.Diagnostic).init(arena);
    for (arr.items) |item| {
        const desc = json_util.string(item, "description") orelse json_util.string(item, "check_name") orelse continue;
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
    return try out.toOwnedSlice();
}

fn severityOf(s: ?[]const u8) ?types.DiagnosticSeverity {
    const name = s orelse return .warning;
    if (std.mem.eql(u8, name, "blocker") or std.mem.eql(u8, name, "critical") or std.mem.eql(u8, name, "major"))
        return .err;
    if (std.mem.eql(u8, name, "minor")) return .warning;
    if (std.mem.eql(u8, name, "info")) return .information;
    return .warning;
}

pub fn syntaxCheck(
    arena: Allocator,
    runner: exec.Runner,
    ansible_playbook: []const u8,
    file_path: []const u8,
    doc: *const Document,
) ![]types.Diagnostic {
    const argv = [_][]const u8{ ansible_playbook, "--syntax-check", file_path };
    const result = runner.run(arena, &argv) catch return &.{};
    if (result.success()) return &.{};
    const msg = if (result.stderr.len > 0) result.stderr else result.stdout;
    if (msg.len == 0) return &.{};
    const trimmed = std.mem.trim(u8, msg, " \n\r\t");
    var diags = try arena.alloc(types.Diagnostic, 1);
    diags[0] = .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = doc.positionAt(doc.bytes().len),
        },
        .severity = .err,
        .source = "ansible-playbook",
        .message = trimmed,
    };
    return diags;
}

/// Convert `file://` URI to a filesystem path. Very small: strips the prefix
/// and percent-decodes `%20` only.
pub fn uriToPath(arena: Allocator, uri: []const u8) ![]const u8 {
    var path = uri;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') {
        path = path[1..]; // Windows /C:/...
    }
    if (std.mem.indexOf(u8, path, "%20") == null) return path;
    var buf = std.array_list.Managed(u8).init(arena);
    var i: usize = 0;
    while (i < path.len) {
        if (i + 2 < path.len and path[i] == '%' and path[i + 1] == '2' and path[i + 2] == '0') {
            try buf.append(' ');
            i += 3;
        } else {
            try buf.append(path[i]);
            i += 1;
        }
    }
    return try buf.toOwnedSlice();
}
