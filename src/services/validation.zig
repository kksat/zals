//! Synchronous document validation, independent of protocol publication.

const std = @import("std");
const builtin = @import("builtin");
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
    /// Environment lookup for the temporary-copy directory, injectable for
    /// tests.
    env: Env = processEnv,
};

/// Environment lookup, injectable for tests. Returns an owned copy or null.
pub const Env = *const fn (allocator: Allocator, name: []const u8) ?[]u8;

pub fn processEnv(allocator: Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

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
/// temporary copy of the buffer in the platform's temporary directory
/// (`TMPDIR` on POSIX, `TEMP`/`TMP` on Windows; see `existingOrTemp`); schema
/// validation always uses the buffer's first YAML root and reports
/// whole-document ranges. Temporary files are removed on success and error
/// (deletion is best-effort).
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
    const target = try existingOrTemp(arena, path, snapshot.bytes, options.env);
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

    /// `path` may be relative to the server's working directory when the
    /// temporary directory itself is relative, so delete through the cwd.
    fn deinit(self: Target) void {
        if (self.temporary) std.fs.cwd().deleteFile(self.path) catch {};
    }
};

/// The directory for temporary validation copies: `TMPDIR` on POSIX,
/// `TEMP`/`TMP` on Windows, else the platform default. An empty value falls
/// through to the next candidate.
fn tempDir(a: Allocator, env: Env) []const u8 {
    const names: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "TEMP", "TMP" }
    else
        &.{"TMPDIR"};
    for (names) |name| {
        if (env(a, name)) |owned| {
            if (owned.len > 0) return owned;
            a.free(owned);
        }
    }
    return if (builtin.os.tag == .windows) "." else "/tmp";
}

/// The lint/syntax-check target: the document's own file when it exists on
/// disk (validation runs at open and save, when the buffer matches the disk),
/// else an exclusively-created `zals-<random>.yml` in the platform's temporary
/// directory holding the buffer's bytes. The 0o600 mode keeps unsaved buffer
/// contents private in a shared temporary directory.
fn existingOrTemp(a: Allocator, path: []const u8, bytes: []const u8, env: Env) !Target {
    if (std.fs.openFileAbsolute(path, .{})) |f| {
        f.close();
        return .{ .path = path, .temporary = false };
    } else |_| {}
    const dir = tempDir(a, env);
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        const name = try std.fmt.allocPrint(a, "zals-{x}.yml", .{std.crypto.random.int(u32)});
        const tmp = try std.fs.path.join(a, &.{ dir, name });
        const file = std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer std.fs.cwd().deleteFile(tmp) catch {};
        defer file.close();
        try file.writeAll(bytes);
        return .{ .path = tmp, .temporary = true };
    }
    return error.TempFileUnavailable;
}

const testing = std.testing;

var test_env_dir: []const u8 = "";

fn testEnv(a: Allocator, name: []const u8) ?[]u8 {
    if (std.mem.eql(u8, name, "TMPDIR")) return a.dupe(u8, test_env_dir) catch null;
    return null;
}

fn emptyEnv(_: Allocator, _: []const u8) ?[]u8 {
    return null;
}

test "temporary copy is created exclusively in the configured directory and removed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_env_dir = try tmp.dir.realpathAlloc(a, ".");
    defer test_env_dir = "";

    const target = try existingOrTemp(a, "/nonexistent/zals-validation-doc.yml", "bytes: 1\n", testEnv);
    try testing.expect(target.temporary);
    try testing.expectEqualStrings(test_env_dir, std.fs.path.dirname(target.path).?);

    var file = try std.fs.cwd().openFile(target.path, .{});
    defer file.close();
    const body = try file.readToEndAlloc(a, 1024);
    try testing.expectEqualStrings("bytes: 1\n", body);

    target.deinit();
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(target.path, .{}));
}

test "repeated temporary copies get distinct names" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_env_dir = try tmp.dir.realpathAlloc(a, ".");
    defer test_env_dir = "";

    const first = try existingOrTemp(a, "/nonexistent/a.yml", "a", testEnv);
    const second = try existingOrTemp(a, "/nonexistent/b.yml", "b", testEnv);
    defer second.deinit();
    defer first.deinit();
    try testing.expect(!std.mem.eql(u8, first.path, second.path));
}

test "an existing disk file is preferred over a temporary copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(.{ .sub_path = "site.yml", .data = "- hosts: all\n" });
    const path = try tmp.dir.realpathAlloc(a, "site.yml");

    const target = try existingOrTemp(a, path, "unsaved", emptyEnv);
    try testing.expect(!target.temporary);
    try testing.expectEqualStrings(path, target.path);
}

test "tempDir prefers TMPDIR and falls back to the platform default" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    test_env_dir = "/custom/tmp";
    defer test_env_dir = "";
    try testing.expectEqualStrings("/custom/tmp", tempDir(a, testEnv));
    try testing.expectEqualStrings("/tmp", tempDir(a, emptyEnv));
}
