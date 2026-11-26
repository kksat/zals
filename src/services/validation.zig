//! Synchronous document validation, independent of protocol publication.

const std = @import("std");
const fsio = @import("../fsio.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const exec = @import("../exec/root.zig");
const paths = @import("../paths.zig");
const types = @import("../lsp/types.zig");
const lint = @import("lint.zig");
const schema = @import("schema.zig");
const yaml = @import("../yaml/root.zig");

/// Borrowed immutable inputs for one call. `document_range` is the entire
/// buffer's range in the negotiated LSP position encoding, not a disk range.
pub const Snapshot = struct {
    uri: []const u8,
    bytes: []const u8,
    document_range: types.Range,
};

pub const Options = struct {
    schema_enabled: bool = true,
    lint_enabled: bool = false,
    lint_path: []const u8 = "ansible-lint",
    lint_arguments: []const u8 = "",
};

pub const Result = struct {
    diagnostics: []const types.Diagnostic = &.{},
    schema_diagnostics: []const types.Diagnostic = &.{},
    external_diagnostics: []const types.Diagnostic = &.{},
    lint_status: ?lint.Status = null,
    syntax_status: ?lint.Status = null,
};

pub fn validate(
    arena: Allocator,
    snapshot: Snapshot,
    options: Options,
    runner: exec.Runner,
    document_schema: ?Value,
) !Result {
    var result = Result{};
    if (options.schema_enabled) {
        if (document_schema) |sch| {
            result.schema_diagnostics = try schemaDiags(arena, snapshot, sch);
        }
    }
    if (options.lint_enabled) {
        const path = try paths.uriToPath(arena, snapshot.uri);
        const target = try existingOrTemp(arena, path, snapshot.bytes);
        defer target.deinit();

        const outcome = try lint.lintFile(arena, runner, options.lint_path, options.lint_arguments, target.path);
        result.lint_status = outcome.status;
        result.external_diagnostics = outcome.diagnostics;
        if (outcome.status == .unavailable) {
            const syntax_outcome = try lint.syntaxCheck(arena, runner, "ansible-playbook", target.path, snapshot.document_range);
            result.syntax_status = syntax_outcome.status;
            result.external_diagnostics = try concatDiags(arena, result.external_diagnostics, syntax_outcome.diagnostics);
        }
    }
    result.diagnostics = try concatDiags(arena, result.schema_diagnostics, result.external_diagnostics);
    return result;
}

fn concatDiags(a: Allocator, left: []const types.Diagnostic, right: []const types.Diagnostic) ![]const types.Diagnostic {
    if (left.len == 0) return right;
    if (right.len == 0) return left;
    const out = try a.alloc(types.Diagnostic, left.len + right.len);
    @memcpy(out[0..left.len], left);
    @memcpy(out[left.len..], right);
    return out;
}

fn schemaDiags(a: Allocator, snapshot: Snapshot, sch: Value) ![]const types.Diagnostic {
    var forest = yaml.parse(a, snapshot.bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        return &.{};
    };
    defer forest.deinit();
    if (forest.roots.len == 0) return &.{};
    const instance = try yaml.jsonify.toJson(a, forest.roots[0]);
    const found = try schema.validate(a, sch, instance);
    if (found.len == 0) return &.{};
    var out = try a.alloc(types.Diagnostic, found.len);
    for (found, 0..) |d, i| {
        out[i] = .{
            .range = snapshot.document_range,
            .severity = .err,
            .source = "ansible-schema",
            .message = d.message,
        };
    }
    return out;
}

const Target = struct {
    path: []const u8,
    temporary: bool,

    fn deinit(self: Target) void {
        if (self.temporary) std.Io.Dir.deleteFileAbsolute(fsio.get(), self.path) catch {};
    }
};

fn existingOrTemp(a: Allocator, path: []const u8, bytes: []const u8) !Target {
    if (std.Io.Dir.openFileAbsolute(fsio.get(), path, .{})) |f| {
        f.close(fsio.get());
        return .{ .path = path, .temporary = false };
    } else |_| {}
    const tmp = try std.fmt.allocPrint(a, "/tmp/zals-{d}.yml", .{fsio.randomInt(u32)});
    var file = try std.Io.Dir.createFileAbsolute(fsio.get(), tmp, .{});
    errdefer std.Io.Dir.deleteFileAbsolute(fsio.get(), tmp) catch {};
    defer file.close(fsio.get());
    try file.writeStreamingAll(fsio.get(), bytes);
    return .{ .path = tmp, .temporary = true };
}
