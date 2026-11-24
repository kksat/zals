const std = @import("std");
const Allocator = std.mem.Allocator;
const cel_env = @import("../cel/env.zig");
const yaml_keywords = @import("../yaml/keywords.zig");
const scope = @import("../variables/scope.zig");
const role_resolve = @import("../roles/resolve.zig");
const span_mod = @import("span.zig");
const yaml_recover = @import("yaml_recover.zig");
const value_mod = @import("value.zig");
const noqa_mod = @import("noqa.zig");
const command_mod = @import("command.zig");

pub const Span = span_mod.Span;
pub const FieldSpan = span_mod.FieldSpan;
pub const TypedValue = value_mod.TypedValue;
pub const ValueKind = value_mod.ValueKind;
pub const IssueKind = yaml_recover.IssueKind;
pub const CommandAnalysis = command_mod.CommandAnalysis;

pub const DocumentKind = enum(u8) {
    playbook,
    tasks,
    handlers,
    role_meta,
    galaxy_meta,
    argument_specs,
    vars_file,
    defaults,
    other,

    pub fn name(self: DocumentKind) []const u8 {
        return switch (self) {
            .playbook => "playbook",
            .tasks => "tasks",
            .handlers => "handlers",
            .role_meta => "role_meta",
            .galaxy_meta => "galaxy_meta",
            .argument_specs => "argument_specs",
            .vars_file => "vars_file",
            .defaults => "defaults",
            .other => "other",
        };
    }
};

pub const InvocationForm = enum(u8) {
    module_key,
    action_keyword,
    local_action_keyword,
    block,

    pub fn name(self: InvocationForm) []const u8 {
        return switch (self) {
            .module_key => "module_key",
            .action_keyword => "action",
            .local_action_keyword => "local_action",
            .block => "block",
        };
    }
};

pub const ArgEntry = struct {
    name: []const u8,
    val: TypedValue,
    span: Span,
};

pub const StringLeaf = struct {
    key: []const u8,
    value: []const u8,
    is_templated: bool,
    span: Span,
};

pub const Play = struct {
    index: usize,
    span: Span,
    field_spans: []const FieldSpan,
    keys: []const []const u8,
    has_name: bool = false,
    name: ?TypedValue = null,
    hosts: ?TypedValue = null,
    strategy: ?TypedValue = null,
    has_become: bool = false,
    has_become_user: bool = false,
    has_vars_prompt: bool = false,
    has_run_once: bool = false,
    run_once: ?TypedValue = null,
    task_count: usize = 0,
    is_import_playbook: bool = false,
    import_playbook_key: []const u8 = "",

    pub fn toCel(self: *const Play, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putInt(alloc, "index", @intCast(self.index));
        try b.putStringList(alloc, "keys", self.keys);
        try b.putBool(alloc, "has_name", self.has_name);
        if (self.name) |n| {
            try b.put(alloc, "name", try n.toCelTyped(alloc));
            try b.putString(alloc, "name_text", n.str_v);
        } else {
            try b.putNull(alloc, "name");
            try b.putString(alloc, "name_text", "");
        }
        if (self.hosts) |h| {
            try b.put(alloc, "hosts", try h.toCelTyped(alloc));
        } else {
            try b.putNull(alloc, "hosts");
        }
        if (self.strategy) |s| {
            try b.put(alloc, "strategy", try s.toCelTyped(alloc));
            try b.putString(alloc, "strategy_text", s.str_v);
        } else {
            try b.putNull(alloc, "strategy");
            try b.putString(alloc, "strategy_text", "");
        }
        try b.putBool(alloc, "has_become", self.has_become);
        try b.putBool(alloc, "has_become_user", self.has_become_user);
        try b.putBool(alloc, "has_vars_prompt", self.has_vars_prompt);
        try b.putBool(alloc, "has_run_once", self.has_run_once);
        if (self.run_once) |ro| {
            try b.put(alloc, "run_once", try ro.toCelTyped(alloc));
        } else {
            try b.putNull(alloc, "run_once");
        }
        try b.putInt(alloc, "task_count", @intCast(self.task_count));
        try b.putBool(alloc, "is_import_playbook", self.is_import_playbook);
        try b.putString(alloc, "import_playbook_key", self.import_playbook_key);
        return b.finish(alloc);
    }
};

pub const Task = struct {
    span: Span,
    field_spans: []const FieldSpan,
    keys: []const []const u8,
    invocation_form: InvocationForm,
    is_block: bool = false,
    raw_action: []const u8 = "",
    raw_action_key: []const u8 = "",
    short_action: []const u8 = "",
    action_namespace: []const u8 = "",
    is_free_form: bool = false,
    free_form_text: []const u8 = "",
    module_val_kind: ValueKind = .null_val,
    has_args_key: bool = false,
    args_val_kind: ValueKind = .null_val,
    args: []const ArgEntry = &.{},
    command: CommandAnalysis = .{},
    command_text: []const u8 = "",
    has_name: bool = false,
    name: ?TypedValue = null,
    is_duplicate_name: bool = false,
    when_list: []const TypedValue = &.{},
    changed_when_list: []const TypedValue = &.{},
    failed_when_list: []const TypedValue = &.{},
    until_list: []const TypedValue = &.{},
    has_changed_when: bool = false,
    has_failed_when: bool = false,
    has_ignore_errors: bool = false,
    ignore_errors: ?TypedValue = null,
    has_register: bool = false,
    register_val: ?TypedValue = null,
    has_no_log: bool = false,
    no_log: ?TypedValue = null,
    has_become: bool = false,
    has_become_user: bool = false,
    has_delegate_to: bool = false,
    delegate_to: ?TypedValue = null,
    has_run_once: bool = false,
    run_once: ?TypedValue = null,
    has_async: bool = false,
    async_val: ?TypedValue = null,
    has_poll: bool = false,
    poll_val: ?TypedValue = null,
    has_local_action: bool = false,
    loop_key: []const u8 = "",
    loop_val: ?TypedValue = null,
    in_handlers: bool = false,
    in_block: bool = false,
    nesting_depth: usize = 0,
    section: []const u8 = "tasks",
    play_strategy: []const u8 = "",
    play_name: []const u8 = "",
    string_leaves: []const StringLeaf = &.{},

    pub fn toCel(self: *const Task, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putStringList(alloc, "keys", self.keys);
        try b.putString(alloc, "invocation_form", self.invocation_form.name());
        try b.putBool(alloc, "is_block", self.is_block);
        try b.putString(alloc, "raw_action", self.raw_action);
        try b.putString(alloc, "raw_action_key", self.raw_action_key);
        try b.putString(alloc, "action", self.short_action);
        try b.putString(alloc, "short_action", self.short_action);
        try b.putString(alloc, "action_namespace", self.action_namespace);
        try b.putBool(alloc, "is_free_form", self.is_free_form);
        try b.putString(alloc, "free_form_text", self.free_form_text);
        try b.putString(alloc, "module_val_kind", self.module_val_kind.name());
        try b.putBool(alloc, "has_args_key", self.has_args_key);
        try b.putString(alloc, "args_val_kind", self.args_val_kind.name());

        var args_b = cel_env.MapBuilder.init();
        var arg_keys = std.ArrayList([]const u8).empty;
        var seen_args = std.StringHashMapUnmanaged(void).empty;
        for (self.args) |entry| {
            if (seen_args.contains(entry.name)) continue;
            try seen_args.put(alloc, entry.name, {});
            try arg_keys.append(alloc, entry.name);
            try args_b.put(alloc, entry.name, try entry.val.toCelTyped(alloc));
        }
        try b.put(alloc, "args", try args_b.finish(alloc));
        try b.putStringList(alloc, "arg_keys", arg_keys.items);

        var cmd_b = cel_env.MapBuilder.init();
        try cmd_b.putString(alloc, "text", self.command_text);
        try cmd_b.putString(alloc, "first_word", self.command.first_word);
        try cmd_b.putString(alloc, "basename", self.command.basename);
        try cmd_b.putString(alloc, "second_word", self.command.second_word);
        try cmd_b.putStringList(alloc, "words", self.command.words);
        try cmd_b.putBool(alloc, "has_inline_env_var", self.command.has_inline_env_var);
        try cmd_b.putBool(alloc, "has_shell_metachar", self.command.has_shell_metachar);
        try cmd_b.putBool(alloc, "has_pipe", self.command.has_pipe);
        try cmd_b.putBool(alloc, "has_pipefail", self.command.has_pipefail);
        try cmd_b.putBool(alloc, "has_multiline", self.command.has_multiline);
        try b.put(alloc, "command", try cmd_b.finish(alloc));

        try b.putBool(alloc, "has_name", self.has_name);
        if (self.name) |n| {
            try b.put(alloc, "name", try n.toCelTyped(alloc));
            try b.putString(alloc, "name_text", n.str_v);
        } else {
            try b.putNull(alloc, "name");
            try b.putString(alloc, "name_text", "");
        }
        try b.putBool(alloc, "is_duplicate_name", self.is_duplicate_name);

        try b.put(alloc, "when", try typedListToCel(alloc, self.when_list));
        try b.put(alloc, "changed_when", try typedListToCel(alloc, self.changed_when_list));
        try b.put(alloc, "failed_when", try typedListToCel(alloc, self.failed_when_list));
        try b.put(alloc, "until", try typedListToCel(alloc, self.until_list));
        try b.putBool(alloc, "has_changed_when", self.has_changed_when);
        try b.putBool(alloc, "has_failed_when", self.has_failed_when);
        try b.putBool(alloc, "has_ignore_errors", self.has_ignore_errors);
        try putOptTyped(&b, alloc, "ignore_errors", self.ignore_errors);
        try b.putBool(alloc, "has_register", self.has_register);
        try putOptTyped(&b, alloc, "register", self.register_val);
        try b.putBool(alloc, "has_no_log", self.has_no_log);
        try putOptTyped(&b, alloc, "no_log", self.no_log);
        try b.putBool(alloc, "has_become", self.has_become);
        try b.putBool(alloc, "has_become_user", self.has_become_user);
        try b.putBool(alloc, "has_delegate_to", self.has_delegate_to);
        try putOptTyped(&b, alloc, "delegate_to", self.delegate_to);
        try b.putBool(alloc, "has_run_once", self.has_run_once);
        try putOptTyped(&b, alloc, "run_once", self.run_once);
        try b.putBool(alloc, "has_async", self.has_async);
        try putOptTyped(&b, alloc, "async", self.async_val);
        try b.putBool(alloc, "has_poll", self.has_poll);
        try putOptTyped(&b, alloc, "poll", self.poll_val);
        try b.putBool(alloc, "has_local_action", self.has_local_action);
        try b.putString(alloc, "loop_key", self.loop_key);
        try putOptTyped(&b, alloc, "loop", self.loop_val);
        try b.putBool(alloc, "in_handlers", self.in_handlers);
        try b.putBool(alloc, "in_block", self.in_block);
        try b.putInt(alloc, "nesting_depth", @intCast(self.nesting_depth));
        try b.putString(alloc, "section", self.section);
        try b.putString(alloc, "play_strategy", self.play_strategy);
        try b.putString(alloc, "play_name", self.play_name);

        const leaves = try alloc.alloc(cel_env.Value, self.string_leaves.len);
        for (self.string_leaves, 0..) |leaf, i| {
            var lb = cel_env.MapBuilder.init();
            try lb.putString(alloc, "key", leaf.key);
            try lb.putString(alloc, "value", leaf.value);
            try lb.putBool(alloc, "is_templated", leaf.is_templated);
            leaves[i] = try lb.finish(alloc);
        }
        try b.put(alloc, "string_leaves", .{ .list_t = leaves });

        return b.finish(alloc);
    }
};

pub const RoleRef = struct {
    name: []const u8,
    is_templated: bool = false,
    span: Span,
    field_spans: []const FieldSpan,
    when_list: []const TypedValue = &.{},
    site: []const u8,

    pub fn toCel(self: *const RoleRef, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "name", self.name);
        try b.putBool(alloc, "is_templated", self.is_templated);
        try b.put(alloc, "when", try typedListToCel(alloc, self.when_list));
        try b.putString(alloc, "site", self.site);
        return b.finish(alloc);
    }
};

pub const VarDef = struct {
    name: []const u8,
    key_kind: ValueKind,
    is_quoted: bool,
    is_templated: bool,
    is_ascii: bool,
    site: []const u8,
    span: Span,
    field_spans: []const FieldSpan,

    pub fn toCel(self: *const VarDef, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "name", self.name);
        try b.putString(alloc, "key_kind", self.key_kind.name());
        try b.putBool(alloc, "is_quoted", self.is_quoted);
        try b.putBool(alloc, "is_templated", self.is_templated);
        try b.putBool(alloc, "is_ascii", self.is_ascii);
        try b.putString(alloc, "site", self.site);
        return b.finish(alloc);
    }
};

pub const VideoLink = struct {
    is_map: bool,
    keys: []const []const u8 = &.{},
    url: ?TypedValue = null,
    title: ?TypedValue = null,
};

pub const RoleMeta = struct {
    span: Span,
    field_spans: []const FieldSpan,
    has_galaxy_info: bool = false,
    author: ?TypedValue = null,
    description: ?TypedValue = null,
    company: ?TypedValue = null,
    license: ?TypedValue = null,
    min_ansible_version: ?TypedValue = null,
    has_galaxy_tags: bool = false,
    galaxy_tags: ?TypedValue = null,
    has_categories: bool = false,
    categories: ?TypedValue = null,
    has_platforms: bool = false,
    platforms: ?TypedValue = null,
    video_links: []const VideoLink = &.{},

    pub fn toCel(self: *const RoleMeta, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putBool(alloc, "has_galaxy_info", self.has_galaxy_info);
        try putOptTyped(&b, alloc, "author", self.author);
        try putOptTyped(&b, alloc, "description", self.description);
        try putOptTyped(&b, alloc, "company", self.company);
        try putOptTyped(&b, alloc, "license", self.license);
        try putOptTyped(&b, alloc, "min_ansible_version", self.min_ansible_version);
        try b.putBool(alloc, "has_galaxy_tags", self.has_galaxy_tags);
        try putOptTyped(&b, alloc, "galaxy_tags", self.galaxy_tags);
        try b.putBool(alloc, "has_categories", self.has_categories);
        try putOptTyped(&b, alloc, "categories", self.categories);
        try b.putBool(alloc, "has_platforms", self.has_platforms);
        try putOptTyped(&b, alloc, "platforms", self.platforms);

        const vl_vals = try alloc.alloc(cel_env.Value, self.video_links.len);
        for (self.video_links, 0..) |vl, i| {
            var vb = cel_env.MapBuilder.init();
            try vb.putBool(alloc, "is_map", vl.is_map);
            try vb.putStringList(alloc, "keys", vl.keys);
            try putOptTyped(&vb, alloc, "url", vl.url);
            try putOptTyped(&vb, alloc, "title", vl.title);
            vl_vals[i] = try vb.finish(alloc);
        }
        try b.put(alloc, "video_links", .{ .list_t = vl_vals });
        return b.finish(alloc);
    }
};

pub const GalaxyDep = struct {
    name: []const u8,
    version: TypedValue,
};

pub const ArgumentSpecEntry = struct {
    name: []const u8,
    is_map: bool,
    keys: []const []const u8 = &.{},
    short_description: ?TypedValue = null,
    description: ?TypedValue = null,
    description_text: []const u8 = "",
    span: Span,
    field_spans: []const FieldSpan,

    pub fn toCel(self: *const ArgumentSpecEntry, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "name", self.name);
        try b.putBool(alloc, "is_map", self.is_map);
        try b.putStringList(alloc, "keys", self.keys);
        try putOptTyped(&b, alloc, "short_description", self.short_description);
        try putOptTyped(&b, alloc, "description", self.description);
        try b.putString(alloc, "description_text", self.description_text);
        return b.finish(alloc);
    }
};

pub const ArgumentSpec = struct {
    entry_point: []const u8,
    name: []const u8,
    path: []const u8,
    is_map: bool,
    keys: []const []const u8 = &.{},
    has_default: bool = false,
    has_required: bool = false,
    required: ?TypedValue = null,
    no_log: ?TypedValue = null,
    type_val: ?TypedValue = null,
    description: ?TypedValue = null,
    description_text: []const u8 = "",
    span: Span,
    field_spans: []const FieldSpan,

    pub fn toCel(self: *const ArgumentSpec, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "entry_point", self.entry_point);
        try b.putString(alloc, "name", self.name);
        try b.putString(alloc, "path", self.path);
        try b.putBool(alloc, "is_map", self.is_map);
        try b.putStringList(alloc, "keys", self.keys);
        try b.putBool(alloc, "has_default", self.has_default);
        try b.putBool(alloc, "has_required", self.has_required);
        try putOptTyped(&b, alloc, "required", self.required);
        try putOptTyped(&b, alloc, "no_log", self.no_log);
        try putOptTyped(&b, alloc, "type", self.type_val);
        try putOptTyped(&b, alloc, "description", self.description);
        try b.putString(alloc, "description_text", self.description_text);
        return b.finish(alloc);
    }
};

pub const GalaxyMeta = struct {
    span: Span,
    field_spans: []const FieldSpan,
    namespace: ?TypedValue = null,
    name: ?TypedValue = null,
    has_version: bool = false,
    version: ?TypedValue = null,
    has_tags: bool = false,
    tags: ?TypedValue = null,
    dependencies: []const GalaxyDep = &.{},
    has_repository: bool = false,
    repository: ?TypedValue = null,
    has_license: bool = false,
    license: ?TypedValue = null,
    has_license_file: bool = false,
    license_file: ?TypedValue = null,

    pub fn toCel(self: *const GalaxyMeta, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try putOptTyped(&b, alloc, "namespace", self.namespace);
        try putOptTyped(&b, alloc, "name", self.name);
        try b.putBool(alloc, "has_version", self.has_version);
        try putOptTyped(&b, alloc, "version", self.version);
        try b.putBool(alloc, "has_tags", self.has_tags);
        try putOptTyped(&b, alloc, "tags", self.tags);
        try b.putBool(alloc, "has_repository", self.has_repository);
        try putOptTyped(&b, alloc, "repository", self.repository);
        try b.putBool(alloc, "has_license", self.has_license);
        try putOptTyped(&b, alloc, "license", self.license);
        try b.putBool(alloc, "has_license_file", self.has_license_file);
        try putOptTyped(&b, alloc, "license_file", self.license_file);

        const deps = try alloc.alloc(cel_env.Value, self.dependencies.len);
        for (self.dependencies, 0..) |d, i| {
            var db = cel_env.MapBuilder.init();
            try db.putString(alloc, "name", d.name);
            try db.put(alloc, "version", try d.version.toCelTyped(alloc));
            deps[i] = try db.finish(alloc);
        }
        try b.put(alloc, "dependencies", .{ .list_t = deps });
        return b.finish(alloc);
    }
};

pub const ParseIssue = struct {
    kind: IssueKind,
    message: []const u8,
    span: Span,

    pub fn toCel(self: *const ParseIssue, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "kind", self.kind.name());
        try b.putString(alloc, "message", self.message);
        return b.finish(alloc);
    }
};

pub const DocumentAst = struct {
    backing: Allocator,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    display_path: []const u8,
    filename: []const u8,
    extension: []const u8,
    kind: DocumentKind,
    source: []const u8,
    fingerprint: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    plays: []const Play,
    tasks: []const Task,
    role_refs: []const RoleRef,
    var_defs: []const VarDef,
    role_meta: ?RoleMeta,
    galaxy_meta: ?GalaxyMeta,
    argument_spec_entries: []const ArgumentSpecEntry,
    argument_specs: []const ArgumentSpec,
    has_argument_specs: bool,
    parse_issues: []const ParseIssue,
    noqa_directives: []const noqa_mod.Directive,

    pub fn deinit(self: *DocumentAst) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    pub fn documentToCel(self: *const DocumentAst, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putString(alloc, "path", self.display_path);
        try b.putString(alloc, "filename", self.filename);
        try b.putString(alloc, "extension", self.extension);
        try b.putString(alloc, "kind", self.kind.name());
        try b.putInt(alloc, "play_count", @intCast(self.plays.len));
        try b.putInt(alloc, "task_count", @intCast(self.tasks.len));
        try b.putInt(alloc, "parse_issue_count", @intCast(self.parse_issues.len));
        try b.putBool(alloc, "has_argument_specs", self.has_argument_specs);
        return b.finish(alloc);
    }
};

fn putOptTyped(b: *cel_env.MapBuilder, alloc: Allocator, key: []const u8, val: ?TypedValue) !void {
    if (val) |v| {
        try b.put(alloc, key, try v.toCelTyped(alloc));
    } else {
        try b.putNull(alloc, key);
    }
}

fn typedListToCel(alloc: Allocator, items: []const TypedValue) !cel_env.Value {
    const out = try alloc.alloc(cel_env.Value, items.len);
    for (items, 0..) |it, i| {
        out[i] = try it.toCelTyped(alloc);
    }
    return .{ .list_t = out };
}

pub fn build(
    backing: Allocator,
    path: []const u8,
    display_path: []const u8,
    source: []const u8,
) !DocumentAst {
    const arena = try backing.create(std.heap.ArenaAllocator);
    errdefer backing.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    const owned_source = try a.dupe(u8, source);
    const owned_path = try a.dupe(u8, path);
    const owned_display = try a.dupe(u8, display_path);
    const filename = std.fs.path.basename(owned_path);
    const extension = std.fs.path.extension(filename);

    var fp: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(owned_source, &fp, .{});

    const recovered = try yaml_recover.parse(a, owned_source);
    const noqa_dirs = try noqa_mod.extractDirectives(a, recovered.comments);

    var builder = AstBuilder{
        .alloc = a,
        .path = owned_path,
        .filename = filename,
        .plays = .empty,
        .tasks = .empty,
        .role_refs = .empty,
        .var_defs = .empty,
        .issues = .empty,
        .role_meta = null,
        .galaxy_meta = null,
        .argument_spec_entries = .empty,
        .argument_specs = .empty,
    };

    for (recovered.issues) |raw_issue| {
        try builder.issues.append(a, .{
            .kind = raw_issue.kind,
            .message = raw_issue.message,
            .span = (Span{ .start = raw_issue.start, .end = raw_issue.end }).clamp(owned_source.len),
        });
    }

    const doc_kind = classifyDocument(owned_path, filename, recovered.documents);
    for (recovered.documents) |doc| {
        try builder.lowerDocument(doc, doc_kind);
    }

    return .{
        .backing = backing,
        .arena = arena,
        .path = owned_path,
        .display_path = owned_display,
        .filename = filename,
        .extension = extension,
        .kind = doc_kind,
        .source = owned_source,
        .fingerprint = fp,
        .plays = try builder.plays.toOwnedSlice(a),
        .tasks = try builder.tasks.toOwnedSlice(a),
        .role_refs = try builder.role_refs.toOwnedSlice(a),
        .var_defs = try builder.var_defs.toOwnedSlice(a),
        .role_meta = builder.role_meta,
        .galaxy_meta = builder.galaxy_meta,
        .has_argument_specs = builder.argument_spec_entries.items.len > 0,
        .argument_spec_entries = try builder.argument_spec_entries.toOwnedSlice(a),
        .argument_specs = try builder.argument_specs.toOwnedSlice(a),
        .parse_issues = try builder.issues.toOwnedSlice(a),
        .noqa_directives = noqa_dirs,
    };
}

fn classifyDocument(path: []const u8, filename: []const u8, docs: []const yaml_recover.YamlDoc) DocumentKind {
    if (std.mem.eql(u8, filename, "galaxy.yml") or std.mem.eql(u8, filename, "galaxy.yaml")) {
        return .galaxy_meta;
    }
    if (std.mem.eql(u8, filename, "argument_specs.yml") or std.mem.eql(u8, filename, "argument_specs.yaml")) {
        return .argument_specs;
    }
    const role_root = role_resolve.enclosingRole(path);
    const fk = scope.fileKind(path, role_root);
    switch (fk) {
        .role_meta => {
            if (std.mem.eql(u8, filename, "main.yml") or std.mem.eql(u8, filename, "main.yaml")) {
                return .role_meta;
            }
            return .other;
        },
        .role_tasks => return .tasks,
        .role_handlers => return .handlers,
        .role_defaults => return .defaults,
        .role_vars, .vars_file => return .vars_file,
        .general => {},
    }

    if (inDirectoryNamed(path, "meta") and (std.mem.eql(u8, filename, "main.yml") or std.mem.eql(u8, filename, "main.yaml"))) {
        return .role_meta;
    }
    if (inDirectoryNamed(path, "handlers")) return .handlers;
    if (inDirectoryNamed(path, "tasks")) return .tasks;
    if (inDirectoryNamed(path, "defaults")) return .defaults;

    for (docs) |doc| {
        const root = doc.root orelse continue;
        if (root.kind != .seq) continue;
        for (root.items) |item| {
            if (item.kind == .map and isPlayMap(item)) return .playbook;
        }
        for (root.items) |item| {
            if (item.kind == .map) return .tasks;
        }
    }
    return .other;
}

fn inDirectoryNamed(path: []const u8, dir_name: []const u8) bool {
    const dir = std.fs.path.dirname(path) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(dir), dir_name);
}

fn isPlayMap(map: *const yaml_recover.YamlNode) bool {
    if (map.kind != .map) return false;
    inline for (.{ "import_playbook", "ansible.builtin.import_playbook", "ansible.legacy.import_playbook" }) |k| {
        if (map.findPair(k) != null) return true;
    }
    for (map.items) |pair| {
        const k = pair.key orelse continue;
        if (k.kind != .scalar) continue;
        const name = k.value orelse continue;
        if (yaml_keywords.isPlayExclusiveKeyword(name)) return true;
    }
    return false;
}

const AstBuilder = struct {
    alloc: Allocator,
    path: []const u8,
    filename: []const u8,
    plays: std.ArrayList(Play),
    tasks: std.ArrayList(Task),
    role_refs: std.ArrayList(RoleRef),
    var_defs: std.ArrayList(VarDef),
    issues: std.ArrayList(ParseIssue),
    role_meta: ?RoleMeta,
    galaxy_meta: ?GalaxyMeta,
    argument_spec_entries: std.ArrayList(ArgumentSpecEntry),
    argument_specs: std.ArrayList(ArgumentSpec),

    fn addStructureIssue(self: *AstBuilder, node: *const yaml_recover.YamlNode, msg: []const u8) !void {
        try self.issues.append(self.alloc, .{
            .kind = .ansible_structure,
            .message = msg,
            .span = .{ .start = node.start, .end = node.end },
        });
    }

    fn lowerDocument(self: *AstBuilder, doc: yaml_recover.YamlDoc, doc_kind: DocumentKind) !void {
        if (doc.root) |root| {
            switch (doc_kind) {
                .galaxy_meta => {
                    if (root.kind == .map) {
                        self.galaxy_meta = try self.lowerGalaxyMeta(root);
                    }
                },
                .role_meta => {
                    if (root.kind == .map) {
                        self.role_meta = try self.lowerRoleMeta(root);
                    }
                },
                .argument_specs => {
                    if (root.kind == .map) {
                        try self.lowerArgumentSpecs(root);
                    }
                },
                .vars_file, .defaults => {
                    if (root.kind == .map) {
                        try self.collectMapVarDefs(root, if (doc_kind == .defaults) "role_defaults" else "vars_file");
                    }
                },
                .playbook => {
                    if (root.kind == .seq) {
                        for (root.items) |item| {
                            if (item.kind == .map) {
                                try self.lowerPlay(item);
                            } else {
                                try self.addStructureIssue(item, "expected a play mapping in playbook sequence");
                            }
                        }
                    } else if (root.kind == .map and isPlayMap(root)) {
                        try self.addStructureIssue(root, "playbook root must be a sequence of plays");
                    }
                },
                .tasks, .handlers => {
                    if (root.kind == .seq) {
                        try self.lowerTaskList(
                            root.items,
                            doc_kind == .handlers,
                            false,
                            0,
                            if (doc_kind == .handlers) "handlers" else "tasks",
                            "",
                            "",
                            null,
                        );
                    }
                },
                .other => {
                    if (root.kind == .seq) {
                        var any_play = false;
                        for (root.items) |item| {
                            if (item.kind == .map and isPlayMap(item)) {
                                any_play = true;
                                break;
                            }
                        }
                        if (any_play) {
                            for (root.items) |item| {
                                if (item.kind == .map) try self.lowerPlay(item);
                            }
                        }
                    }
                },
            }
        }

        if (doc.recovered_items.len > 0) {
            try self.lowerRecoveredItems(doc.recovered_items, doc_kind);
        }
    }

    fn lowerRecoveredItems(self: *AstBuilder, items: []*yaml_recover.YamlNode, doc_kind: DocumentKind) !void {
        for (items) |item| {
            if (item.kind == .seq) {
                try self.lowerRecoveredItems(item.items, doc_kind);
                continue;
            }
            if (item.kind != .map) continue;
            if (isPlayMap(item)) {
                try self.lowerPlay(item);
            } else {
                var slice = [_]*yaml_recover.YamlNode{item};
                try self.lowerTaskList(
                    &slice,
                    doc_kind == .handlers,
                    false,
                    0,
                    "recovered",
                    "",
                    "",
                    null,
                );
            }
        }
    }

    fn lowerPlay(self: *AstBuilder, map: *const yaml_recover.YamlNode) !void {
        var keys = std.ArrayList([]const u8).empty;
        var fspans = std.ArrayList(FieldSpan).empty;
        var play = Play{
            .index = self.plays.items.len,
            .span = .{ .start = map.start, .end = map.end },
            .field_spans = &.{},
            .keys = &.{},
        };

        const tasks_before = self.tasks.items.len;
        var immediate_names = std.StringHashMapUnmanaged(void).empty;

        for (map.items) |pair| {
            const k = pair.key orelse continue;
            const kname = k.value orelse continue;
            try keys.append(self.alloc, kname);
            try fspans.append(self.alloc, .{ .name = kname, .span = .{ .start = k.start, .end = k.end } });

            if (std.mem.eql(u8, kname, "name")) {
                play.has_name = true;
                play.name = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "hosts")) {
                play.hosts = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "strategy")) {
                play.strategy = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "become")) {
                play.has_become = true;
            } else if (std.mem.eql(u8, kname, "become_user")) {
                play.has_become_user = true;
            } else if (std.mem.eql(u8, kname, "vars_prompt")) {
                play.has_vars_prompt = true;
                if (pair.val) |vp| {
                    if (vp.kind == .seq) {
                        for (vp.items) |entry| {
                            if (entry.kind == .map) {
                                if (entry.findPair("name")) |np| {
                                    if (np.val) |nv| try self.addVarDefFromScalar(nv, "vars_prompt");
                                }
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, kname, "run_once")) {
                play.has_run_once = true;
                play.run_once = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "vars")) {
                if (pair.val) |v| {
                    if (v.kind == .map) try self.collectMapVarDefs(v, "play_vars");
                }
            } else if (std.mem.eql(u8, kname, "import_playbook") or
                std.mem.eql(u8, kname, "ansible.builtin.import_playbook") or
                std.mem.eql(u8, kname, "ansible.legacy.import_playbook"))
            {
                play.is_import_playbook = true;
                play.import_playbook_key = kname;
            }
        }

        const play_strategy = if (play.strategy) |s| s.str_v else "";
        const play_name = if (play.name) |n| n.str_v else "";

        for (map.items) |pair| {
            const k = pair.key orelse continue;
            const kname = k.value orelse continue;
            const val = pair.val orelse continue;
            if (std.mem.eql(u8, kname, "pre_tasks") or
                std.mem.eql(u8, kname, "tasks") or
                std.mem.eql(u8, kname, "post_tasks") or
                std.mem.eql(u8, kname, "handlers"))
            {
                if (val.kind == .seq) {
                    try self.lowerTaskList(
                        val.items,
                        std.mem.eql(u8, kname, "handlers"),
                        false,
                        0,
                        kname,
                        play_strategy,
                        play_name,
                        if (play.has_name and !std.mem.eql(u8, kname, "handlers")) &immediate_names else null,
                    );
                } else if (!(val.kind == .scalar and val.scalar_style == .empty)) {
                    try self.addStructureIssue(val, "task section must be a list of tasks");
                }
            } else if (std.mem.eql(u8, kname, "roles")) {
                if (val.kind == .seq) {
                    for (val.items) |entry| {
                        try self.lowerRoleEntry(entry);
                    }
                }
            }
        }

        play.task_count = self.tasks.items.len - tasks_before;
        play.keys = try keys.toOwnedSlice(self.alloc);
        play.field_spans = try fspans.toOwnedSlice(self.alloc);
        try self.plays.append(self.alloc, play);
    }

    fn lowerTaskList(
        self: *AstBuilder,
        items: []*yaml_recover.YamlNode,
        in_handlers: bool,
        in_block: bool,
        nesting_depth: usize,
        section: []const u8,
        play_strategy: []const u8,
        play_name: []const u8,
        immediate_names: ?*std.StringHashMapUnmanaged(void),
    ) anyerror!void {
        for (items) |item| {
            if (item.kind != .map) {
                try self.addStructureIssue(item, "expected a task mapping in task list");
                continue;
            }
            try self.lowerTaskMap(
                item,
                in_handlers,
                in_block,
                nesting_depth,
                section,
                play_strategy,
                play_name,
                immediate_names,
            );
        }
    }

    fn lowerTaskMap(
        self: *AstBuilder,
        map: *const yaml_recover.YamlNode,
        in_handlers: bool,
        in_block: bool,
        nesting_depth: usize,
        section: []const u8,
        play_strategy: []const u8,
        play_name: []const u8,
        immediate_names: ?*std.StringHashMapUnmanaged(void),
    ) anyerror!void {
        const block_pair = map.findPair("block");
        const rescue_pair = map.findPair("rescue");
        const always_pair = map.findPair("always");
        const is_block = block_pair != null or rescue_pair != null or always_pair != null;

        var action_count: usize = 0;
        var action_pair: ?*const yaml_recover.YamlNode = null;
        var invocation_form: InvocationForm = if (is_block) .block else .module_key;

        if (!is_block) {
            for (map.items) |pair| {
                const k = pair.key orelse continue;
                const kname = k.value orelse continue;
                if (std.mem.eql(u8, kname, "action")) {
                    action_count += 1;
                    action_pair = pair;
                    invocation_form = .action_keyword;
                } else if (std.mem.eql(u8, kname, "local_action")) {
                    action_count += 1;
                    action_pair = pair;
                    invocation_form = .local_action_keyword;
                } else if (!yaml_keywords.isTaskKeyword(kname) and !isLegacyTaskKeyword(kname)) {
                    action_count += 1;
                    action_pair = pair;
                    invocation_form = .module_key;
                }
            }
            if (action_count == 0) {
                try self.addStructureIssue(map, "task mapping has no action or module");
                return;
            }
            if (action_count > 1) {
                try self.addStructureIssue(map, "task mapping has conflicting action/module keys");
                return;
            }
        }

        var keys = std.ArrayList([]const u8).empty;
        var fspans = std.ArrayList(FieldSpan).empty;
        var task = Task{
            .span = .{ .start = map.start, .end = map.end },
            .field_spans = &.{},
            .keys = &.{},
            .invocation_form = invocation_form,
            .is_block = is_block,
            .in_handlers = in_handlers,
            .in_block = in_block,
            .nesting_depth = nesting_depth,
            .section = section,
            .play_strategy = play_strategy,
            .play_name = play_name,
        };

        var args_list = std.ArrayList(ArgEntry).empty;
        var args_pair_node: ?*const yaml_recover.YamlNode = null;

        for (map.items) |pair| {
            const k = pair.key orelse continue;
            const kname = k.value orelse continue;
            try keys.append(self.alloc, kname);
            try fspans.append(self.alloc, .{ .name = kname, .span = .{ .start = k.start, .end = k.end } });

            if (std.mem.eql(u8, kname, "name")) {
                task.has_name = true;
                task.name = try value_mod.fromYaml(self.alloc, pair.val);
                if (immediate_names) |seen| {
                    if (task.name) |tv| {
                        if (tv.str_v.len > 0) {
                            if (seen.contains(tv.str_v)) {
                                task.is_duplicate_name = true;
                            } else {
                                try seen.put(self.alloc, tv.str_v, {});
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, kname, "when")) {
                task.when_list = try extractConditionList(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "changed_when")) {
                task.has_changed_when = true;
                task.changed_when_list = try extractConditionList(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "failed_when")) {
                task.has_failed_when = true;
                task.failed_when_list = try extractConditionList(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "until")) {
                task.until_list = try extractConditionList(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "ignore_errors")) {
                task.has_ignore_errors = true;
                task.ignore_errors = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "register")) {
                task.has_register = true;
                task.register_val = try value_mod.fromYaml(self.alloc, pair.val);
                if (pair.val) |rv| try self.addVarDefFromScalar(rv, "register");
            } else if (std.mem.eql(u8, kname, "no_log")) {
                task.has_no_log = true;
                task.no_log = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "become")) {
                task.has_become = true;
            } else if (std.mem.eql(u8, kname, "become_user")) {
                task.has_become_user = true;
            } else if (std.mem.eql(u8, kname, "delegate_to")) {
                task.has_delegate_to = true;
                task.delegate_to = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "run_once")) {
                task.has_run_once = true;
                task.run_once = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "async")) {
                task.has_async = true;
                task.async_val = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "poll")) {
                task.has_poll = true;
                task.poll_val = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "local_action")) {
                task.has_local_action = true;
            } else if (std.mem.eql(u8, kname, "loop") or std.mem.startsWith(u8, kname, "with_")) {
                task.loop_key = kname;
                task.loop_val = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "args")) {
                task.has_args_key = true;
                args_pair_node = pair;
                const tv = try value_mod.fromYaml(self.alloc, pair.val);
                task.args_val_kind = tv.kind;
            } else if (std.mem.eql(u8, kname, "vars")) {
                if (pair.val) |v| {
                    if (v.kind == .map) try self.collectMapVarDefs(v, "task_vars");
                }
            }
        }

        if (action_pair) |ap| {
            const ak = ap.key.?;
            const ak_name = ak.value orelse "";
            task.raw_action_key = ak_name;
            try fspans.append(self.alloc, .{ .name = "action", .span = .{ .start = ak.start, .end = ak.end } });
            try self.populateAction(&task, ap, &args_list, &fspans);
        }

        if (args_pair_node) |apn| {
            if (apn.val) |av| {
                if (av.kind == .map) {
                    try appendMapArgs(self.alloc, av, &args_list, &fspans);
                } else if (av.kind == .scalar and av.scalar_style != .empty) {
                    task.is_free_form = true;
                }
            }
        }

        if (std.mem.eql(u8, task.short_action, "set_fact")) {
            for (args_list.items) |entry| {
                if (std.mem.eql(u8, entry.name, "cacheable")) continue;
                try self.var_defs.append(self.alloc, .{
                    .name = entry.name,
                    .key_kind = .string_val,
                    .is_quoted = false,
                    .is_templated = value_mod.hasJinjaDelimiters(entry.name),
                    .is_ascii = isAscii(entry.name),
                    .site = "set_fact",
                    .span = entry.span,
                    .field_spans = &.{},
                });
            }
        }

        if (std.mem.eql(u8, task.short_action, "include_role") or std.mem.eql(u8, task.short_action, "import_role")) {
            for (args_list.items) |entry| {
                if (std.mem.eql(u8, entry.name, "name")) {
                    try self.role_refs.append(self.alloc, .{
                        .name = entry.val.str_v,
                        .is_templated = entry.val.is_templated,
                        .span = entry.span,
                        .field_spans = &.{},
                        .when_list = task.when_list,
                        .site = task.short_action,
                    });
                }
            }
        }

        if (std.mem.eql(u8, task.short_action, "command") or
            std.mem.eql(u8, task.short_action, "shell") or
            std.mem.eql(u8, task.short_action, "raw"))
        {
            var cmd_text: []const u8 = task.free_form_text;
            for (args_list.items) |entry| {
                if (std.mem.eql(u8, entry.name, "cmd") or std.mem.eql(u8, entry.name, "_raw_params")) {
                    if (entry.val.str_v.len > 0) cmd_text = entry.val.str_v;
                }
            }
            task.command_text = cmd_text;
            task.command = try command_mod.analyze(self.alloc, cmd_text);
        }

        var leaves = std.ArrayList(StringLeaf).empty;
        try collectStringLeaves(self.alloc, map, "", &leaves, 0);
        task.string_leaves = try leaves.toOwnedSlice(self.alloc);
        task.args = try args_list.toOwnedSlice(self.alloc);
        task.keys = try keys.toOwnedSlice(self.alloc);
        task.field_spans = try fspans.toOwnedSlice(self.alloc);

        try self.tasks.append(self.alloc, task);

        if (is_block) {
            const sub_sections = [_]struct { name: []const u8, pair: ?*const yaml_recover.YamlNode }{
                .{ .name = "block", .pair = block_pair },
                .{ .name = "rescue", .pair = rescue_pair },
                .{ .name = "always", .pair = always_pair },
            };
            for (sub_sections) |sec| {
                const sp = sec.pair orelse continue;
                const sv = sp.val orelse continue;
                if (sv.kind == .seq) {
                    try self.lowerTaskList(
                        sv.items,
                        in_handlers,
                        true,
                        nesting_depth + 1,
                        sec.name,
                        play_strategy,
                        play_name,
                        null,
                    );
                } else if (!(sv.kind == .scalar and sv.scalar_style == .empty)) {
                    try self.addStructureIssue(sv, "block section must be a list of tasks");
                }
            }
        }
    }

    fn populateAction(
        self: *AstBuilder,
        task: *Task,
        ap: *const yaml_recover.YamlNode,
        args_list: *std.ArrayList(ArgEntry),
        fspans: *std.ArrayList(FieldSpan),
    ) !void {
        const ak_name = ap.key.?.value orelse "";
        const val_node = ap.val;
        const val_typed = try value_mod.fromYaml(self.alloc, val_node);
        task.module_val_kind = val_typed.kind;

        if (task.invocation_form == .module_key) {
            task.raw_action = ak_name;
            splitActionName(ak_name, &task.action_namespace, &task.short_action);
            if (val_node) |vn| {
                if (vn.kind == .map) {
                    try appendMapArgs(self.alloc, vn, args_list, fspans);
                } else if (vn.kind == .scalar and vn.scalar_style != .empty) {
                    const text = vn.value orelse "";
                    if (text.len > 0) {
                        task.is_free_form = true;
                        task.free_form_text = text;
                        try parseFreeFormArgs(self.alloc, text, .{ .start = vn.start, .end = vn.end }, args_list);
                    }
                }
            }
        } else {
            if (val_node) |vn| {
                if (vn.kind == .map) {
                    if (vn.findPair("module")) |mp| {
                        if (mp.val) |mv| {
                            const mod_name = mv.value orelse "";
                            task.raw_action = mod_name;
                            splitActionName(mod_name, &task.action_namespace, &task.short_action);
                        }
                    }
                    try appendMapArgs(self.alloc, vn, args_list, fspans);
                } else if (vn.kind == .scalar and vn.scalar_style != .empty) {
                    const text = std.mem.trim(u8, vn.value orelse "", " \t\r\n");
                    var split = std.mem.tokenizeAny(u8, text, " \t\r\n");
                    if (split.next()) |mod_name| {
                        task.raw_action = mod_name;
                        splitActionName(mod_name, &task.action_namespace, &task.short_action);
                        const rest = std.mem.trimLeft(u8, split.rest(), " \t");
                        if (rest.len > 0) {
                            task.is_free_form = true;
                            task.free_form_text = rest;
                            try parseFreeFormArgs(self.alloc, rest, .{ .start = vn.start, .end = vn.end }, args_list);
                        }
                    }
                }
            }
        }
    }

    fn lowerRoleEntry(self: *AstBuilder, entry: *const yaml_recover.YamlNode) !void {
        if (entry.kind == .scalar) {
            const name = entry.value orelse "";
            try self.role_refs.append(self.alloc, .{
                .name = name,
                .is_templated = value_mod.hasJinjaDelimiters(name),
                .span = .{ .start = entry.start, .end = entry.end },
                .field_spans = &.{},
                .site = "roles",
            });
            return;
        }
        if (entry.kind != .map) return;

        var fspans = std.ArrayList(FieldSpan).empty;
        var name: []const u8 = "";
        var name_templated = false;
        var when_list: []const TypedValue = &.{};

        for (entry.items) |pair| {
            const k = pair.key orelse continue;
            const kname = k.value orelse continue;
            try fspans.append(self.alloc, .{ .name = kname, .span = .{ .start = k.start, .end = k.end } });
            if (std.mem.eql(u8, kname, "role") or std.mem.eql(u8, kname, "name")) {
                if (pair.val) |v| {
                    name = v.value orelse "";
                    name_templated = value_mod.hasJinjaDelimiters(name);
                }
            } else if (std.mem.eql(u8, kname, "when")) {
                when_list = try extractConditionList(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "vars")) {
                if (pair.val) |v| {
                    if (v.kind == .map) try self.collectMapVarDefs(v, "role_vars");
                }
            }
        }
        try self.role_refs.append(self.alloc, .{
            .name = name,
            .is_templated = name_templated,
            .span = .{ .start = entry.start, .end = entry.end },
            .field_spans = try fspans.toOwnedSlice(self.alloc),
            .when_list = when_list,
            .site = "roles",
        });
    }

    fn collectMapVarDefs(self: *AstBuilder, map: *const yaml_recover.YamlNode, site: []const u8) !void {
        for (map.items) |pair| {
            const k = pair.key orelse continue;
            const kt = try value_mod.fromYaml(self.alloc, k);
            const name = k.value orelse k.raw;
            try self.var_defs.append(self.alloc, .{
                .name = name,
                .key_kind = kt.kind,
                .is_quoted = kt.is_quoted,
                .is_templated = kt.is_templated,
                .is_ascii = isAscii(name),
                .site = site,
                .span = .{ .start = k.start, .end = k.end },
                .field_spans = &.{},
            });
        }
    }

    fn addVarDefFromScalar(self: *AstBuilder, node: *const yaml_recover.YamlNode, site: []const u8) !void {
        if (node.kind != .scalar) return;
        const tv = try value_mod.fromYaml(self.alloc, node);
        const name = node.value orelse node.raw;
        if (name.len == 0) return;
        try self.var_defs.append(self.alloc, .{
            .name = name,
            .key_kind = tv.kind,
            .is_quoted = tv.is_quoted,
            .is_templated = tv.is_templated,
            .is_ascii = isAscii(name),
            .site = site,
            .span = .{ .start = node.start, .end = node.end },
            .field_spans = &.{},
        });
    }

    fn lowerRoleMeta(self: *AstBuilder, root: *const yaml_recover.YamlNode) !RoleMeta {
        var meta = RoleMeta{
            .span = .{ .start = root.start, .end = root.end },
            .field_spans = &.{},
        };
        var fspans = std.ArrayList(FieldSpan).empty;

        if (root.findPair("dependencies")) |dp| {
            if (dp.val) |dv| {
                if (dv.kind == .seq) {
                    for (dv.items) |entry| try self.lowerRoleEntry(entry);
                }
            }
        }

        const gi_pair = root.findPair("galaxy_info") orelse {
            meta.field_spans = try fspans.toOwnedSlice(self.alloc);
            return meta;
        };
        const gi = gi_pair.val orelse {
            meta.field_spans = try fspans.toOwnedSlice(self.alloc);
            return meta;
        };
        if (gi.kind != .map) {
            meta.field_spans = try fspans.toOwnedSlice(self.alloc);
            return meta;
        }
        meta.has_galaxy_info = true;
        meta.span = .{ .start = gi.start, .end = gi.end };

        for (gi.items) |pair| {
            const k = pair.key orelse continue;
            const kname = k.value orelse continue;
            try fspans.append(self.alloc, .{ .name = kname, .span = .{ .start = k.start, .end = k.end } });
            if (std.mem.eql(u8, kname, "author")) {
                meta.author = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "description")) {
                meta.description = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "company")) {
                meta.company = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "license")) {
                meta.license = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "min_ansible_version")) {
                meta.min_ansible_version = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "galaxy_tags")) {
                meta.has_galaxy_tags = true;
                meta.galaxy_tags = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "categories")) {
                meta.has_categories = true;
                meta.categories = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "platforms")) {
                meta.has_platforms = true;
                meta.platforms = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "video_links")) {
                if (pair.val) |vl_node| {
                    if (vl_node.kind == .seq) {
                        var vls = std.ArrayList(VideoLink).empty;
                        for (vl_node.items) |it| {
                            if (it.kind != .map) {
                                try vls.append(self.alloc, .{ .is_map = false });
                                continue;
                            }
                            var vl_keys = std.ArrayList([]const u8).empty;
                            var url_v: ?TypedValue = null;
                            var title_v: ?TypedValue = null;
                            for (it.items) |vp| {
                                const vk = vp.key orelse continue;
                                const vkn = vk.value orelse continue;
                                try vl_keys.append(self.alloc, vkn);
                                if (std.mem.eql(u8, vkn, "url")) url_v = try value_mod.fromYaml(self.alloc, vp.val);
                                if (std.mem.eql(u8, vkn, "title")) title_v = try value_mod.fromYaml(self.alloc, vp.val);
                            }
                            try vls.append(self.alloc, .{
                                .is_map = true,
                                .keys = try vl_keys.toOwnedSlice(self.alloc),
                                .url = url_v,
                                .title = title_v,
                            });
                        }
                        meta.video_links = try vls.toOwnedSlice(self.alloc);
                    }
                }
            }
        }
        meta.field_spans = try fspans.toOwnedSlice(self.alloc);
        return meta;
    }

    fn lowerGalaxyMeta(self: *AstBuilder, root: *const yaml_recover.YamlNode) !GalaxyMeta {
        var meta = GalaxyMeta{
            .span = .{ .start = root.start, .end = root.end },
            .field_spans = &.{},
        };
        var fspans = std.ArrayList(FieldSpan).empty;

        for (root.items) |pair| {
            const k = pair.key orelse continue;
            const kname = k.value orelse continue;
            try fspans.append(self.alloc, .{ .name = kname, .span = .{ .start = k.start, .end = k.end } });
            if (std.mem.eql(u8, kname, "namespace")) {
                meta.namespace = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "name")) {
                meta.name = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "version")) {
                meta.has_version = true;
                meta.version = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "tags")) {
                meta.has_tags = true;
                meta.tags = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "repository")) {
                meta.has_repository = true;
                meta.repository = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "license")) {
                meta.has_license = true;
                meta.license = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "license_file")) {
                meta.has_license_file = true;
                meta.license_file = try value_mod.fromYaml(self.alloc, pair.val);
            } else if (std.mem.eql(u8, kname, "dependencies")) {
                if (pair.val) |dv| {
                    if (dv.kind == .map) {
                        var deps = std.ArrayList(GalaxyDep).empty;
                        for (dv.items) |dp| {
                            const dk = dp.key orelse continue;
                            const dkn = dk.value orelse continue;
                            try deps.append(self.alloc, .{
                                .name = dkn,
                                .version = try value_mod.fromYaml(self.alloc, dp.val),
                            });
                        }
                        meta.dependencies = try deps.toOwnedSlice(self.alloc);
                    }
                }
            }
        }
        meta.field_spans = try fspans.toOwnedSlice(self.alloc);
        return meta;
    }
    fn lowerArgumentSpecs(self: *AstBuilder, root: *const yaml_recover.YamlNode) !void {
        const specs_pair = root.findPair("argument_specs") orelse return;
        const specs = specs_pair.val orelse return;
        if (specs.kind != .map) return;

        for (specs.items) |pair| {
            const k = pair.key orelse continue;
            const entry_name = k.value orelse k.raw;
            var entry = ArgumentSpecEntry{
                .name = entry_name,
                .is_map = false,
                .span = .{ .start = k.start, .end = k.end },
                .field_spans = &.{},
            };

            if (pair.val) |v| {
                if (v.kind == .map) {
                    entry.is_map = true;
                    var keys = std.ArrayList([]const u8).empty;
                    var fspans = std.ArrayList(FieldSpan).empty;
                    for (v.items) |ep| {
                        const ek = ep.key orelse continue;
                        const ek_name = ek.value orelse ek.raw;
                        try keys.append(self.alloc, ek_name);
                        try fspans.append(self.alloc, .{ .name = ek_name, .span = .{ .start = ek.start, .end = ek.end } });
                        if (std.mem.eql(u8, ek_name, "short_description")) {
                            entry.short_description = try value_mod.fromYaml(self.alloc, ep.val);
                        } else if (std.mem.eql(u8, ek_name, "description")) {
                            entry.description = try value_mod.fromYaml(self.alloc, ep.val);
                        }
                    }
                    entry.keys = try keys.toOwnedSlice(self.alloc);
                    entry.field_spans = try fspans.toOwnedSlice(self.alloc);
                    if (entry.description) |d| {
                        entry.description_text = try joinDescriptionText(self.alloc, d);
                    }

                    if (v.findPair("options")) |op| {
                        if (op.val) |ov| {
                            if (ov.kind == .map) {
                                try self.lowerArgumentSpecOptions(entry_name, "", ov);
                            }
                        }
                    }
                }
            }
            try self.argument_spec_entries.append(self.alloc, entry);
        }
    }

    fn lowerArgumentSpecOptions(
        self: *AstBuilder,
        entry_point: []const u8,
        prefix: []const u8,
        options_map: *const yaml_recover.YamlNode,
    ) !void {
        for (options_map.items) |pair| {
            const k = pair.key orelse continue;
            const opt_name = k.value orelse k.raw;
            const opt_path = if (prefix.len == 0)
                opt_name
            else
                try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ prefix, opt_name });

            var spec = ArgumentSpec{
                .entry_point = entry_point,
                .name = opt_name,
                .path = opt_path,
                .is_map = false,
                .span = .{ .start = k.start, .end = k.end },
                .field_spans = &.{},
            };
            var nested_options: ?*const yaml_recover.YamlNode = null;

            if (pair.val) |v| {
                if (v.kind == .map) {
                    spec.is_map = true;
                    var keys = std.ArrayList([]const u8).empty;
                    var fspans = std.ArrayList(FieldSpan).empty;
                    for (v.items) |op| {
                        const ok = op.key orelse continue;
                        const ok_name = ok.value orelse ok.raw;
                        try keys.append(self.alloc, ok_name);
                        try fspans.append(self.alloc, .{ .name = ok_name, .span = .{ .start = ok.start, .end = ok.end } });
                        if (std.mem.eql(u8, ok_name, "default")) {
                            spec.has_default = true;
                        } else if (std.mem.eql(u8, ok_name, "required")) {
                            spec.has_required = true;
                            spec.required = try value_mod.fromYaml(self.alloc, op.val);
                        } else if (std.mem.eql(u8, ok_name, "no_log")) {
                            spec.no_log = try value_mod.fromYaml(self.alloc, op.val);
                        } else if (std.mem.eql(u8, ok_name, "type")) {
                            spec.type_val = try value_mod.fromYaml(self.alloc, op.val);
                        } else if (std.mem.eql(u8, ok_name, "description")) {
                            spec.description = try value_mod.fromYaml(self.alloc, op.val);
                        } else if (std.mem.eql(u8, ok_name, "options")) {
                            nested_options = op.val;
                        }
                    }
                    spec.keys = try keys.toOwnedSlice(self.alloc);
                    spec.field_spans = try fspans.toOwnedSlice(self.alloc);
                    if (spec.description) |d| {
                        spec.description_text = try joinDescriptionText(self.alloc, d);
                    }
                }
            }

            try self.argument_specs.append(self.alloc, spec);

            if (nested_options) |nested| {
                if (nested.kind == .map) {
                    try self.lowerArgumentSpecOptions(entry_point, opt_path, nested);
                }
            }
        }
    }
};

fn joinDescriptionText(alloc: Allocator, description: TypedValue) ![]const u8 {
    switch (description.kind) {
        .string_val, .template_val => return description.str_v,
        .list_val => {
            var out = std.ArrayList(u8).empty;
            for (description.list_v, 0..) |item, i| {
                if (i > 0) try out.appendSlice(alloc, "\n\n");
                switch (item.kind) {
                    .string_val, .template_val => try out.appendSlice(alloc, item.str_v),
                    else => {},
                }
            }
            return out.toOwnedSlice(alloc);
        },
        else => return "",
    }
}

fn splitActionName(raw: []const u8, namespace_out: *[]const u8, short_out: *[]const u8) void {
    if (std.mem.startsWith(u8, raw, "ansible.builtin.")) {
        namespace_out.* = "ansible.builtin";
        short_out.* = raw["ansible.builtin.".len..];
    } else if (std.mem.startsWith(u8, raw, "ansible.legacy.")) {
        namespace_out.* = "ansible.legacy";
        short_out.* = raw["ansible.legacy.".len..];
    } else if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| {
        namespace_out.* = raw[0..dot];
        short_out.* = raw;
    } else {
        namespace_out.* = "";
        short_out.* = raw;
    }
}

fn appendMapArgs(
    alloc: Allocator,
    map: *const yaml_recover.YamlNode,
    args_list: *std.ArrayList(ArgEntry),
    fspans: *std.ArrayList(FieldSpan),
) !void {
    for (map.items) |pair| {
        const k = pair.key orelse continue;
        const kname = k.value orelse continue;
        const tv = try value_mod.fromYaml(alloc, pair.val);
        const sp = Span{ .start = k.start, .end = k.end };
        try args_list.append(alloc, .{ .name = kname, .val = tv, .span = sp });
        try fspans.append(alloc, .{ .name = kname, .span = sp });
    }
}

fn parseFreeFormArgs(
    alloc: Allocator,
    text: []const u8,
    span: Span,
    args_list: *std.ArrayList(ArgEntry),
) !void {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) : (i += 1) {}
        if (i >= text.len) break;
        const start = i;
        var in_single = false;
        var in_double = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (!in_double and c == '\'') in_single = !in_single;
            if (!in_single and c == '"') in_double = !in_double;
            if (!in_single and !in_double and (c == ' ' or c == '\t' or c == '\r' or c == '\n')) break;
        }
        const tok = text[start..i];
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            const k = tok[0..eq];
            if (isSimpleKey(k)) {
                var v = tok[eq + 1 ..];
                var quoted = false;
                if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
                    v = v[1 .. v.len - 1];
                    quoted = true;
                }
                const templated = value_mod.hasJinjaDelimiters(v);
                try args_list.append(alloc, .{
                    .name = k,
                    .val = .{
                        .kind = if (templated) .template_val else .string_val,
                        .is_templated = templated,
                        .is_quoted = quoted,
                        .raw = tok[eq + 1 ..],
                        .span = span,
                        .str_v = v,
                    },
                    .span = span,
                });
            }
        }
    }
}

fn isSimpleKey(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn extractConditionList(alloc: Allocator, node: ?*const yaml_recover.YamlNode) ![]const TypedValue {
    const n = node orelse return &.{};
    if (n.kind == .seq) {
        const list = try alloc.alloc(TypedValue, n.items.len);
        for (n.items, 0..) |it, i| {
            list[i] = try value_mod.fromYaml(alloc, it);
        }
        return list;
    }
    const single = try value_mod.fromYaml(alloc, n);
    if (single.kind == .null_val) return &.{};
    const out = try alloc.alloc(TypedValue, 1);
    out[0] = single;
    return out;
}

fn collectStringLeaves(
    alloc: Allocator,
    node: *const yaml_recover.YamlNode,
    current_key: []const u8,
    out: *std.ArrayList(StringLeaf),
    depth: usize,
) anyerror!void {
    if (depth > 16 or out.items.len >= 256) return;
    switch (node.kind) {
        .scalar => {
            if (node.value) |v| {
                if (v.len > 0) {
                    try out.append(alloc, .{
                        .key = current_key,
                        .value = v,
                        .is_templated = value_mod.hasJinjaDelimiters(v),
                        .span = .{ .start = node.start, .end = node.end },
                    });
                }
            }
        },
        .seq => {
            for (node.items) |it| try collectStringLeaves(alloc, it, current_key, out, depth + 1);
        },
        .map => {
            for (node.items) |pair| {
                const k = pair.key orelse continue;
                const kname = k.value orelse "";
                if (std.mem.eql(u8, kname, "block") or std.mem.eql(u8, kname, "rescue") or std.mem.eql(u8, kname, "always")) continue;
                try collectStringLeaves(alloc, k, kname, out, depth + 1);
                if (pair.val) |v| try collectStringLeaves(alloc, v, kname, out, depth + 1);
            }
        },
        else => {},
    }
}

fn isLegacyTaskKeyword(k: []const u8) bool {
    return std.mem.eql(u8, k, "always_run") or
        std.mem.eql(u8, k, "sudo") or
        std.mem.eql(u8, k, "sudo_user") or
        std.mem.eql(u8, k, "su") or
        std.mem.eql(u8, k, "su_user");
}

fn isAscii(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

test "structural admission retains valid tasks and records parse issues for invalid shapes" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: unknown module is admitted
        \\      my.custom.uninstalled_module:
        \\        arg: "{{ some_var }}"
        \\    - name: null args module is admitted
        \\      ansible.builtin.debug:
        \\    - name: only name is not a task
        \\    - name: conflicting actions
        \\      ansible.builtin.debug:
        \\        msg: a
        \\      ansible.builtin.ping:
        \\    - bare_scalar_is_invalid
        \\    - block: not-a-list
        \\      rescue:
        \\        - name: recovered rescue child
        \\          ansible.builtin.ping:
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/site.yml", "site.yml", src);
    defer doc.deinit();

    try std.testing.expectEqual(DocumentKind.playbook, doc.kind);
    try std.testing.expectEqual(@as(usize, 1), doc.plays.len);
    try std.testing.expectEqual(@as(usize, 4), doc.tasks.len);
    try std.testing.expectEqualStrings("my.custom.uninstalled_module", doc.tasks[0].raw_action);
    try std.testing.expectEqualStrings("debug", doc.tasks[1].short_action);
    try std.testing.expect(doc.tasks[2].is_block);
    try std.testing.expectEqualStrings("ping", doc.tasks[3].short_action);
    try std.testing.expectEqualStrings("rescue", doc.tasks[3].section);
    try std.testing.expectEqual(@as(usize, 4), doc.parse_issues.len);
    for (doc.parse_issues) |iss| {
        try std.testing.expectEqual(IssueKind.ansible_structure, iss.kind);
    }
}

test "empty editing values like when: are not mislabeled as syntax errors" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: editing in progress
        \\      ansible.builtin.debug:
        \\        msg: hi
        \\      when:
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/site.yml", "site.yml", src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.parse_issues.len);
    try std.testing.expectEqual(@as(usize, 1), doc.tasks.len);
}

test "block scalar containing task-like text does not fabricate tasks" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: write sample
        \\      ansible.builtin.copy:
        \\        dest: /tmp/sample.yml
        \\        content: |
        \\          - name: fake task inside block scalar
        \\            ansible.builtin.shell: rm -rf /
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/site.yml", "site.yml", src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.parse_issues.len);
    try std.testing.expectEqual(@as(usize, 1), doc.tasks.len);
    try std.testing.expectEqualStrings("copy", doc.tasks[0].short_action);
}

test "broken task between valid siblings recovers siblings and records syntax issue" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: before
        \\      ansible.builtin.debug:
        \\        msg: ok
        \\    - name: [broken
        \\    - name: after
        \\      ansible.builtin.ping:
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/site.yml", "site.yml", src);
    defer doc.deinit();
    try std.testing.expect(doc.parse_issues.len >= 1);
    var saw_before = false;
    var saw_after = false;
    for (doc.tasks) |t| {
        if (t.name) |n| {
            if (std.mem.eql(u8, n.str_v, "before")) saw_before = true;
            if (std.mem.eql(u8, n.str_v, "after")) saw_after = true;
        }
    }
    try std.testing.expect(saw_before);
    try std.testing.expect(saw_after);
}

test "role metadata and galaxy metadata lowering" {
    const role_src =
        \\galaxy_info:
        \\  author: your name
        \\  description: your role description
        \\  license: MIT
        \\  galaxy_tags:
        \\    - web
        \\  video_links:
        \\    - url: https://www.youtube.com/watch?v=12345
        \\      title: demo
        \\
    ;
    var role_doc = try build(std.testing.allocator, "/ws/roles/demo/meta/main.yml", "roles/demo/meta/main.yml", role_src);
    defer role_doc.deinit();
    try std.testing.expectEqual(DocumentKind.role_meta, role_doc.kind);
    try std.testing.expect(role_doc.role_meta != null);
    try std.testing.expectEqualStrings("your name", role_doc.role_meta.?.author.?.str_v);
    try std.testing.expectEqual(@as(usize, 1), role_doc.role_meta.?.video_links.len);

    const galaxy_src =
        \\namespace: acme
        \\name: demo
        \\version: "1.0.0"
        \\tags:
        \\  - linux
        \\dependencies:
        \\  ansible.posix: ">=1.0.0"
        \\repository: https://example.com/repo
        \\license:
        \\  - GPL-3.0-or-later
        \\
    ;
    var gal_doc = try build(std.testing.allocator, "/ws/galaxy.yml", "galaxy.yml", galaxy_src);
    defer gal_doc.deinit();
    try std.testing.expectEqual(DocumentKind.galaxy_meta, gal_doc.kind);
    try std.testing.expect(gal_doc.galaxy_meta != null);
    try std.testing.expectEqualStrings("1.0.0", gal_doc.galaxy_meta.?.version.?.str_v);
    try std.testing.expectEqual(@as(usize, 1), gal_doc.galaxy_meta.?.dependencies.len);
}

test "argument specs lowering produces entry and option nodes with dotted paths" {
    const src =
        \\argument_specs:
        \\  main:
        \\    short_description: Demo role
        \\    description:
        \\      - First paragraph.
        \\      - Second paragraph.
        \\    unknown_key: oops
        \\    options:
        \\      demo_password:
        \\        type: str
        \\        description: Unmarked secret.
        \\      demo_conf:
        \\        type: dict
        \\        description: Config.
        \\        options:
        \\          smtp_secret:
        \\            type: str
        \\            no_log: true
        \\      conflict:
        \\        type: str
        \\        default: present
        \\        required: true
        \\      not_a_map: oops
        \\  broken: just a string
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/roles/demo/meta/argument_specs.yml", "roles/demo/meta/argument_specs.yml", src);
    defer doc.deinit();
    try std.testing.expectEqual(DocumentKind.argument_specs, doc.kind);
    try std.testing.expect(doc.has_argument_specs);
    try std.testing.expectEqual(@as(usize, 2), doc.argument_spec_entries.len);

    const main_entry = doc.argument_spec_entries[0];
    try std.testing.expectEqualStrings("main", main_entry.name);
    try std.testing.expect(main_entry.is_map);
    try std.testing.expectEqual(@as(usize, 4), main_entry.keys.len);
    try std.testing.expectEqualStrings("Demo role", main_entry.short_description.?.str_v);
    try std.testing.expectEqualStrings("First paragraph.\n\nSecond paragraph.", main_entry.description_text);

    const broken_entry = doc.argument_spec_entries[1];
    try std.testing.expectEqualStrings("broken", broken_entry.name);
    try std.testing.expect(!broken_entry.is_map);

    try std.testing.expectEqual(@as(usize, 5), doc.argument_specs.len);
    const password = doc.argument_specs[0];
    try std.testing.expectEqualStrings("demo_password", password.name);
    try std.testing.expectEqualStrings("demo_password", password.path);
    try std.testing.expectEqualStrings("main", password.entry_point);
    try std.testing.expect(password.is_map);
    try std.testing.expectEqualStrings("str", password.type_val.?.str_v);
    try std.testing.expectEqualStrings("Unmarked secret.", password.description_text);
    try std.testing.expect(!password.has_default);
    try std.testing.expect(!password.has_required);

    const conf = doc.argument_specs[1];
    try std.testing.expectEqualStrings("demo_conf", conf.name);

    const nested = doc.argument_specs[2];
    try std.testing.expectEqualStrings("smtp_secret", nested.name);
    try std.testing.expectEqualStrings("demo_conf.smtp_secret", nested.path);
    try std.testing.expect(nested.no_log != null and nested.no_log.?.bool_v);

    const conflict = doc.argument_specs[3];
    try std.testing.expect(conflict.has_default);
    try std.testing.expect(conflict.has_required);
    try std.testing.expect(conflict.required.?.bool_v);

    const not_a_map = doc.argument_specs[4];
    try std.testing.expectEqualStrings("not_a_map", not_a_map.name);
    try std.testing.expect(!not_a_map.is_map);
    try std.testing.expectEqual(@as(usize, 0), not_a_map.keys.len);

    const plain = doc.argument_specs[0];
    try std.testing.expect(plain.field_spans.len > 0);

    var missing_doc = try build(std.testing.allocator, "/ws/roles/demo/meta/argument_specs.yml", "roles/demo/meta/argument_specs.yml", "other_key: 1\n");
    defer missing_doc.deinit();
    try std.testing.expectEqual(DocumentKind.argument_specs, missing_doc.kind);
    try std.testing.expect(!missing_doc.has_argument_specs);
}

test "alternate invocation forms preserve original spelling and normalize args" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: action free form
        \\      action: ansible.builtin.copy src=/a dest=/b mode="0644"
        \\    - name: local action mapping
        \\      local_action:
        \\        module: ansible.legacy.command
        \\        cmd: echo hi
        \\    - name: args mapping with free form
        \\      command: /usr/bin/git status
        \\      args:
        \\        chdir: /tmp
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/site.yml", "site.yml", src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.tasks.len);

    try std.testing.expectEqual(InvocationForm.action_keyword, doc.tasks[0].invocation_form);
    try std.testing.expectEqualStrings("ansible.builtin.copy", doc.tasks[0].raw_action);
    try std.testing.expectEqualStrings("copy", doc.tasks[0].short_action);
    try std.testing.expect(doc.tasks[0].is_free_form);

    try std.testing.expectEqual(InvocationForm.local_action_keyword, doc.tasks[1].invocation_form);
    try std.testing.expect(doc.tasks[1].has_local_action);
    try std.testing.expectEqualStrings("command", doc.tasks[1].short_action);
    try std.testing.expectEqualStrings("echo", doc.tasks[1].command.basename);

    try std.testing.expectEqual(InvocationForm.module_key, doc.tasks[2].invocation_form);
    try std.testing.expectEqualStrings("git", doc.tasks[2].command.basename);
    try std.testing.expect(doc.tasks[2].has_args_key);
}

test "multi-document yaml, crlf, and unicode preserve boundaries and offsets" {
    const src = "---\r\n- hosts: all\r\n  tasks:\r\n    - name: café\r\n      ansible.builtin.debug:\r\n        msg: ok\r\n---\r\n- hosts: web\r\n  tasks:\r\n    - name: second doc\r\n      ansible.builtin.ping:\r\n";
    var doc = try build(std.testing.allocator, "/ws/multi.yml", "multi.yml", src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.parse_issues.len);
    try std.testing.expectEqual(@as(usize, 2), doc.plays.len);
    try std.testing.expectEqual(@as(usize, 2), doc.tasks.len);
    try std.testing.expectEqualStrings("café", doc.tasks[0].name.?.str_v);
    try std.testing.expectEqualStrings("second doc", doc.tasks[1].name.?.str_v);
}

test "unfinished quote triggers bounded recovery with parse issue" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: "unterminated quote
        \\      ansible.builtin.debug:
        \\        msg: broken
        \\
    ;
    var doc = try build(std.testing.allocator, "/ws/bad.yml", "bad.yml", src);
    defer doc.deinit();
    try std.testing.expect(doc.parse_issues.len >= 1);
    try std.testing.expectEqual(IssueKind.yaml_syntax, doc.parse_issues[0].kind);
}
