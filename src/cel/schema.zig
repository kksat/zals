const std = @import("std");

pub const schema_version: i64 = 1;

pub const TargetKind = enum(u8) {
    document,
    play,
    task,
    role_ref,
    var_def,
    role_meta,
    galaxy_meta,
    argument_spec_entry,
    argument_spec,
    parse_issue,

    pub fn name(self: TargetKind) []const u8 {
        return switch (self) {
            .document => "document",
            .play => "play",
            .task => "task",
            .role_ref => "role_ref",
            .var_def => "var_def",
            .role_meta => "role_meta",
            .galaxy_meta => "galaxy_meta",
            .argument_spec_entry => "argument_spec_entry",
            .argument_spec => "argument_spec",
            .parse_issue => "parse_issue",
        };
    }

    pub fn parse(s: []const u8) ?TargetKind {
        inline for (std.meta.fields(TargetKind)) |f| {
            if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn validFields(self: TargetKind) []const []const u8 {
        return switch (self) {
            .document => &.{
                "root",
            },
            .play => &.{
                "self",
                "name",
                "hosts",
                "become",
                "become_user",
                "strategy",
                "run_once",
                "vars_prompt",
                "collections",
                "tasks",
                "pre_tasks",
                "post_tasks",
                "handlers",
                "roles",
                "import_playbook",
            },
            .task => &.{
                "self",
                "name",
                "action",
                "local_action",
                "args",
                "when",
                "changed_when",
                "failed_when",
                "until",
                "ignore_errors",
                "no_log",
                "become",
                "become_user",
                "delegate_to",
                "run_once",
                "loop",
                "with_items",
                "register",
                "mode",
                "state",
                "version",
                "revision",
                "src",
                "dest",
                "content",
                "cmd",
                "executable",
                "block",
                "rescue",
                "always",
            },
            .role_ref => &.{
                "self",
                "name",
                "role",
                "when",
            },
            .var_def => &.{
                "self",
                "name",
                "value",
            },
            .role_meta => &.{
                "self",
                "author",
                "description",
                "company",
                "license",
                "min_ansible_version",
                "galaxy_tags",
                "categories",
                "platforms",
                "video_links",
            },
            .galaxy_meta => &.{
                "self",
                "namespace",
                "name",
                "version",
                "tags",
                "dependencies",
                "repository",
                "license",
                "license_file",
            },
            .argument_spec_entry => &.{
                "self",
                "author",
                "attributes",
                "deprecated",
                "description",
                "examples",
                "notes",
                "options",
                "requirements",
                "seealso",
                "short_description",
                "todo",
                "version_added",
            },
            .argument_spec => &.{
                "self",
                "aliases",
                "apply_defaults",
                "choices",
                "context",
                "default",
                "deprecated_aliases",
                "description",
                "elements",
                "mutually_exclusive",
                "no_log",
                "options",
                "removed_at_date",
                "removed_from_collection",
                "removed_in_version",
                "required",
                "required_by",
                "required_if",
                "required_one_of",
                "required_together",
                "type",
                "version_added",
                "version_added_collection",
            },
            .parse_issue => &.{
                "self",
            },
        };
    }

    pub fn isValidField(self: TargetKind, field: []const u8) bool {
        for (self.validFields()) |candidate| {
            if (std.mem.eql(u8, candidate, field)) return true;
        }
        return false;
    }
};

pub const TargetMask = packed struct(u10) {
    document: bool = false,
    play: bool = false,
    task: bool = false,
    role_ref: bool = false,
    var_def: bool = false,
    role_meta: bool = false,
    galaxy_meta: bool = false,
    argument_spec_entry: bool = false,
    argument_spec: bool = false,
    parse_issue: bool = false,

    pub fn add(self: *TargetMask, kind: TargetKind) void {
        switch (kind) {
            .document => self.document = true,
            .play => self.play = true,
            .task => self.task = true,
            .role_ref => self.role_ref = true,
            .var_def => self.var_def = true,
            .role_meta => self.role_meta = true,
            .galaxy_meta => self.galaxy_meta = true,
            .argument_spec_entry => self.argument_spec_entry = true,
            .argument_spec => self.argument_spec = true,
            .parse_issue => self.parse_issue = true,
        }
    }

    pub fn contains(self: TargetMask, kind: TargetKind) bool {
        return switch (kind) {
            .document => self.document,
            .play => self.play,
            .task => self.task,
            .role_ref => self.role_ref,
            .var_def => self.var_def,
            .role_meta => self.role_meta,
            .galaxy_meta => self.galaxy_meta,
            .argument_spec_entry => self.argument_spec_entry,
            .argument_spec => self.argument_spec,
            .parse_issue => self.parse_issue,
        };
    }

    pub fn isEmpty(self: TargetMask) bool {
        return @as(u10, @bitCast(self)) == 0;
    }
};

pub const Severity = enum(u8) {
    @"error" = 1,
    warning = 2,
    info = 3,
    hint = 4,

    pub fn parse(s: []const u8) ?Severity {
        if (std.mem.eql(u8, s, "error")) return .@"error";
        if (std.mem.eql(u8, s, "warning")) return .warning;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "hint")) return .hint;
        return null;
    }

    pub fn name(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
            .hint => "hint",
        };
    }
};

pub const declared_bindings = [_][]const u8{
    "node",
    "location",
    "document",
    "context",
    "metadata",
    "options",
};

pub fn isDeclaredBinding(name: []const u8) bool {
    for (declared_bindings) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

pub fn isValidRuleId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == '-' or c == '_' or c == '/' or c == '[' or c == ']' or c == '.' or c == ':';
        if (!ok) return false;
    }
    return true;
}

test "target kind parse and field validation" {
    try std.testing.expectEqual(TargetKind.task, TargetKind.parse("task").?);
    try std.testing.expectEqual(TargetKind.parse_issue, TargetKind.parse("parse_issue").?);
    try std.testing.expect(TargetKind.parse("unknown") == null);
    try std.testing.expect(TargetKind.task.isValidField("action"));
    try std.testing.expect(!TargetKind.task.isValidField("nonexistent"));
    try std.testing.expect(TargetKind.parse_issue.isValidField("self"));
}

test "target mask operations" {
    var mask: TargetMask = .{};
    try std.testing.expect(mask.isEmpty());
    mask.add(.task);
    mask.add(.role_ref);
    try std.testing.expect(!mask.isEmpty());
    try std.testing.expect(mask.contains(.task));
    try std.testing.expect(mask.contains(.role_ref));
    try std.testing.expect(!mask.contains(.play));
}
