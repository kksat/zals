//! Synchronous document validation, independent of protocol publication.

const std = @import("std");
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
    lint_enabled: bool = true,
    lint_path: []const u8 = "ansible-lint",
    lint_arguments: []const u8 = "",
};

pub const Result = struct {
    diagnostics: []const types.Diagnostic = &.{},
    /// Null means not run, never clean. Failure/unavailability survives even
    /// when schema diagnostics exist or a tool yields no diagnostics.
    lint_status: ?lint.Status = null,
    syntax_status: ?lint.Status = null,
};

/// Validate an enabled document using borrowed options/schema and an injected
/// Runner. The caller handles globally disabled validation by publishing empty
/// diagnostics without needing a document. Results/strings live in `arena`.
///
/// External tools use the existing disk file if it can be opened, otherwise a
/// temporary copy of the buffer; schema validation always uses the buffer's
/// first YAML root and reports whole-document ranges. Temporary files are
/// removed on success and error (deletion is best-effort).
///
/// Disabled lint retains the existing policy: syntax-check runs only when
/// schema diagnostics are empty. Enabled-but-unavailable lint runs syntax-check
/// regardless of schema findings (ADR-0015), merging schema diagnostics first.
/// Only executable/spawn unavailability triggers that fallback: clean/findings,
/// invalid output, abnormal termination and other execution failures do not.
/// Tool/schema allocation errors propagate rather than masquerading as absence.
pub fn validate(
    arena: Allocator,
    snapshot: Snapshot,
    options: Options,
    runner: exec.Runner,
    document_schema: ?Value,
) !Result {
    const path = try paths.uriToPath(arena, snapshot.uri);
    const target = try existingOrTemp(arena, path, snapshot.bytes);
    defer target.deinit();

    var result = Result{};
    if (document_schema) |sch| {
        result.diagnostics = try schemaDiags(arena, snapshot, sch);
    }
    var syntax_fallback = !options.lint_enabled and result.diagnostics.len == 0;
    if (options.lint_enabled) {
        const outcome = try lint.lintFile(arena, runner, options.lint_path, options.lint_arguments, target.path);
        result.lint_status = outcome.status;
        result.diagnostics = try concatDiags(arena, result.diagnostics, outcome.diagnostics);
        syntax_fallback = outcome.status == .unavailable;
    }
    if (syntax_fallback) {
        const outcome = try lint.syntaxCheck(arena, runner, "ansible-playbook", target.path, snapshot.document_range);
        result.syntax_status = outcome.status;
        result.diagnostics = try concatDiags(arena, result.diagnostics, outcome.diagnostics);
    }
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
        if (self.temporary) std.fs.deleteFileAbsolute(self.path) catch {};
    }
};

fn existingOrTemp(a: Allocator, path: []const u8, bytes: []const u8) !Target {
    if (std.fs.openFileAbsolute(path, .{})) |f| {
        f.close();
        return .{ .path = path, .temporary = false };
    } else |_| {}
    const tmp = try std.fmt.allocPrint(a, "/tmp/zals-{d}.yml", .{std.crypto.random.int(u32)});
    var file = try std.fs.createFileAbsolute(tmp, .{});
    errdefer std.fs.deleteFileAbsolute(tmp) catch {};
    defer file.close();
    try file.writeAll(bytes);
    return .{ .path = tmp, .temporary = true };
}
