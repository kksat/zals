//! Server settings, using upstream's `ansible.*` names and defaults.
//!
//! Strings live in an arena that is reset on every update, so callers must not
//! hold pointers across an update.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");

pub const Settings = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    ansible_path: []const u8 = "ansible",
    use_fqcn: bool = true,
    provide_redirect_modules: bool = true,
    provide_module_option_aliases: bool = true,
    validation_enabled: bool = true,
    lint_enabled: bool = true,
    lint_path: []const u8 = "ansible-lint",
    lint_arguments: []const u8 = "",
    auto_fix_on_save: bool = false,
    python_interpreter_path: []const u8 = "",
    python_activation_script: []const u8 = "",
    /// `ansible.python.venvPath`. The one virtual environment whose
    /// collections are searched, relative to the Workspace root. Default
    /// `.venv`.
    venv_path: []const u8 = ".venv",
    /// `ansible.workspace.missingGitWarning`. One session warning when an
    /// opened folder has no Workspace.
    missing_git_warning: bool = true,
    /// `ansible.workspace.rootMarker`. File or directory name that marks a
    /// Workspace. Default `.git`. A blank value or a path falls back to `.git`.
    root_marker: []const u8 = ".git",

    pub fn init(allocator: Allocator) Settings {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }

    /// Re-read settings from a `didChangeConfiguration` params object. Missing
    /// fields fall back to defaults.
    pub fn update(self: *Settings, params: Value) !void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const root = json_util.field(params, "settings") orelse params;
        const ansible = json_util.field(root, "ansible") orelse root;

        const core = json_util.field(ansible, "ansible");
        const completion = json_util.field(ansible, "completion");
        const validation = json_util.field(ansible, "validation");
        const lint = if (validation) |v| json_util.field(v, "lint") else null;
        const python = json_util.field(ansible, "python");
        const workspace = json_util.field(ansible, "workspace");

        self.ansible_path = try dupeOpt(a, if (core) |c| json_util.string(c, "path") else null, "ansible");
        self.use_fqcn = optBool(core, "useFullyQualifiedCollectionNames", true);
        self.provide_redirect_modules = optBool(completion, "provideRedirectModules", true);
        self.provide_module_option_aliases = optBool(completion, "provideModuleOptionAliases", true);
        self.validation_enabled = optBool(validation, "enabled", true);
        self.lint_enabled = optBool(lint, "enabled", true);
        self.lint_path = try dupeOpt(a, if (lint) |l| json_util.string(l, "path") else null, "ansible-lint");
        self.lint_arguments = try dupeOpt(a, if (lint) |l| json_util.string(l, "arguments") else null, "");
        self.auto_fix_on_save = optBool(lint, "autoFixOnSave", false);
        self.python_interpreter_path = try dupeOpt(a, if (python) |p| json_util.string(p, "interpreterPath") else null, "");
        self.python_activation_script = try dupeOpt(a, if (python) |p| json_util.string(p, "activationScript") else null, "");
        self.venv_path = try dupeOpt(a, if (python) |p| json_util.string(p, "venvPath") else null, ".venv");
        self.missing_git_warning = optBool(workspace, "missingGitWarning", true);
        self.root_marker = try dupeOpt(a, if (workspace) |w| json_util.string(w, "rootMarker") else null, ".git");
    }
};

fn optBool(v: ?Value, key: []const u8, default: bool) bool {
    const x = v orelse return default;
    return json_util.boolean(x, key) orelse default;
}

fn dupeOpt(a: Allocator, value: ?[]const u8, default: []const u8) ![]const u8 {
    return a.dupe(u8, value orelse default);
}

const testing = std.testing;

test "missing git warning defaults on and can be disabled" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.missing_git_warning);

    const parsed = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"workspace":{"missingGitWarning":false}}}
    ,
        .{},
    );
    defer parsed.deinit();
    try settings.update(parsed.value);
    try testing.expect(!settings.missing_git_warning);
    try testing.expectEqualStrings(".git", settings.root_marker);

    const marker = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"workspace":{"rootMarker":"ansible.cfg"}}}
    ,
        .{},
    );
    defer marker.deinit();
    try settings.update(marker.value);
    try testing.expectEqualStrings("ansible.cfg", settings.root_marker);
    try testing.expect(settings.missing_git_warning);
}

test "venv path defaults to .venv and can be changed" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expectEqualStrings(".venv", settings.venv_path);

    const parsed = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"python":{"venvPath":".venv-ansible-2.16"}}}
    ,
        .{},
    );
    defer parsed.deinit();
    try settings.update(parsed.value);
    try testing.expectEqualStrings(".venv-ansible-2.16", settings.venv_path);
}
