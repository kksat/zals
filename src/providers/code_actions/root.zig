//! Debug and extract code actions (ADR-0028, ADR-0030).
//!
//! Debug (`refactor`):
//!
//! - **Add debug** — when the cursor is on a variable occurrence, insert a
//!   `ansible.builtin.debug` task right after the enclosing task (or at the
//!   start of the enclosing play's `tasks:` list when there is no task).
//! - **Remove debug** — when the cursor is inside a task whose module key is
//!   `debug` (or `*.debug`), delete that task.
//!
//! Extract (`refactor.extract`):
//!
//! - **Extract to include_tasks / import_tasks** — move the task(s) under the
//!   cursor or selection into a new sibling task file and replace them with an
//!   `ansible.builtin.include_tasks` / `ansible.builtin.import_tasks` task.
//!
//! The provider is document-scoped, parses the document once, filters by
//! `context.only`, and encodes `WorkspaceEdit` `documentChanges`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../../lsp/json_util.zig");
const types = @import("../../lsp/types.zig");
const Server = @import("../../lsp/server.zig").Server;
const Document = @import("../../workspace/document.zig").Document;
const yaml = @import("../../yaml/root.zig");
const variables = @import("../../variables/root.zig");
const paths = @import("../../paths.zig");
const model = @import("model.zig");
const debug = @import("debug.zig");
const extract = @import("extract.zig");

pub const kind = model.kind;
pub const extract_kind = model.extract_kind;
pub const Action = model.Action;
pub const CreateFile = model.CreateFile;
pub const Selection = model.Selection;
pub const ExtractEnv = model.ExtractEnv;

/// LSP entry point for `textDocument/codeAction`.
pub fn codeActions(self: *Server, a: Allocator, params: Value) !Value {
    const td = json_util.field(params, "textDocument") orelse return empty(a);
    const uri = json_util.string(td, "uri") orelse return empty(a);
    const doc = self.documents.get(uri) orelse return empty(a);
    const range_v = json_util.field(params, "range") orelse return empty(a);
    const range = json_util.range(range_v) orelse return empty(a);
    const start = doc.offsetAt(range.start) orelse return empty(a);
    const end = doc.offsetAt(range.end) orelse return empty(a);
    const sel = Selection{ .start = start, .end = @max(start, end) };

    const only = try onlyKinds(a, params);
    const path = try variables.scope.uriToPath(a, uri);
    const acts = try actions(a, doc.bytes(), path, sel, only, extractEnv(self, path));

    var arr = std.json.Array.init(a);
    for (acts) |act| try arr.append(try toValue(a, doc, uri, act));
    return .{ .array = arr };
}

/// The extract environment for `path`, or null when the client cannot create
/// files or the path has no directory.
fn extractEnv(self: *Server, path: []const u8) ?ExtractEnv {
    if (!self.supports_create_file) return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    var ext = std.fs.path.extension(path);
    if (ext.len == 0) ext = ".yml";
    return ExtractEnv{ .dir = dir, .ext = ext, .exists = paths.isFile };
}

fn empty(a: Allocator) !Value {
    return .{ .array = std.json.Array.init(a) };
}

/// The pure core: the actions available at `sel` in `text`.
///
/// `path` is the filesystem path behind `text`, used to classify role
/// `defaults/`/`vars/`/`meta/` files. `only` is the client's `context.only`
/// filter, or null when the client asked for every kind. `extract_env` carries
/// the filesystem context for the extract actions, or null when they are not
/// offered (for example, when the client cannot create files).
pub fn actions(
    a: Allocator,
    text: []const u8,
    path: []const u8,
    sel: Selection,
    only: ?[]const []const u8,
    extract_env: ?ExtractEnv,
) ![]Action {
    var forest = yaml.parse(a, text) catch return &.{};
    defer forest.deinit();

    var out = std.array_list.Managed(Action).init(a);

    if (kindRequested(only, kind)) {
        try debug.collect(a, &out, text, &forest, path, sel.start);
    }

    if (extract_env) |env| {
        if (kindRequested(only, extract_kind)) {
            try extract.collect(a, &out, text, &forest, sel, env);
        }
    }

    return out.toOwnedSlice();
}

fn kindRequested(only: ?[]const []const u8, action_kind: []const u8) bool {
    const list = only orelse return true;
    for (list) |requested| {
        if (kindMatches(action_kind, requested)) return true;
    }
    return false;
}

/// True when `action` is `requested` or a sub-kind of it.
fn kindMatches(action: []const u8, requested: []const u8) bool {
    if (std.mem.eql(u8, action, requested)) return true;
    return action.len > requested.len and
        action[requested.len] == '.' and
        std.mem.startsWith(u8, action, requested);
}

fn onlyKinds(a: Allocator, params: Value) !?[]const []const u8 {
    const ctx = json_util.field(params, "context") orelse return null;
    const arr = json_util.array(ctx, "only") orelse return null;
    var out = std.array_list.Managed([]const u8).init(a);
    for (arr.items) |item| {
        if (item == .string) try out.append(item.string);
    }
    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

fn toValue(a: Allocator, doc: *const Document, uri: []const u8, act: Action) !Value {
    var o = json_util.obj(a);
    try o.put("title", json_util.str(act.title));
    try o.put("kind", json_util.str(act.kind));
    try o.put("edit", try editValue(a, doc, uri, act));
    return .{ .object = o };
}

fn editValue(a: Allocator, doc: *const Document, uri: []const u8, act: Action) !Value {
    var edit = json_util.obj(a);

    var changes = std.json.Array.init(a);
    if (act.create) |c| {
        const new_uri = try paths.pathToUri(a, c.path);

        // Create the empty file first.
        var create = json_util.obj(a);
        try create.put("kind", json_util.str("create"));
        try create.put("uri", json_util.str(new_uri));
        var opts = json_util.obj(a);
        try opts.put("overwrite", json_util.booleanValue(false));
        try create.put("options", .{ .object = opts });
        try changes.append(.{ .object = create });

        // Then fill it. A newly created file has no version.
        var ntd = json_util.obj(a);
        try ntd.put("uri", json_util.str(new_uri));
        try ntd.put("version", Value.null);
        var nte = json_util.obj(a);
        try nte.put("range", try rangeValue(a, .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        }));
        try nte.put("newText", json_util.str(c.text));
        var nedits = std.json.Array.init(a);
        try nedits.append(.{ .object = nte });
        var nchange = json_util.obj(a);
        try nchange.put("textDocument", .{ .object = ntd });
        try nchange.put("edits", .{ .array = nedits });
        try changes.append(.{ .object = nchange });
    }

    var td = json_util.obj(a);
    try td.put("uri", json_util.str(uri));
    try td.put("version", json_util.num(doc.version));

    var te = json_util.obj(a);
    try te.put("range", try rangeValue(a, doc.rangeFromOffsets(act.start, act.end)));
    try te.put("newText", json_util.str(act.new_text));

    var edits = std.json.Array.init(a);
    try edits.append(.{ .object = te });

    var change = json_util.obj(a);
    try change.put("textDocument", .{ .object = td });
    try change.put("edits", .{ .array = edits });
    try changes.append(.{ .object = change });

    try edit.put("documentChanges", .{ .array = changes });
    return .{ .object = edit };
}

fn rangeValue(a: Allocator, r: types.Range) !Value {
    var o = json_util.obj(a);
    try o.put("start", try posValue(a, r.start));
    try o.put("end", try posValue(a, r.end));
    return .{ .object = o };
}

fn posValue(a: Allocator, p: types.Position) !Value {
    var o = json_util.obj(a);
    try o.put("line", json_util.num(p.line));
    try o.put("character", json_util.num(p.character));
    return .{ .object = o };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = @import("model.zig");
    _ = @import("lines.zig");
    _ = @import("debug.zig");
    _ = @import("extract.zig");
}

fn neverExists(_: []const u8) bool {
    return false;
}

test "no debug or extract action for any built-in import_playbook spelling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "import_playbook", "ansible.builtin.import_playbook", "ansible.legacy.import_playbook" }) |name| {
        const src = try std.fmt.allocPrint(a, "- {s}: \"{{{{ playbook_name }}}}\"\n  vars: {{x: 1}}\n", .{name});
        for ([_][]const u8{ "playbook_name", "x: 1" }) |at| {
            const off = std.mem.indexOf(u8, src, at).?;
            const acts = try actions(a, src, "/p/site.yml", .{ .start = off, .end = off }, null, .{ .dir = "/p", .ext = ".yml", .exists = neverExists });
            try testing.expectEqual(@as(usize, 0), acts.len);
        }
        const acts = try actions(a, src, "/p/site.yml", .{ .start = 0, .end = src.len }, null, .{ .dir = "/p", .ext = ".yml", .exists = neverExists });
        try testing.expectEqual(@as(usize, 0), acts.len);
    }
}

test "context.only filters by kind" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const offset = std.mem.indexOf(u8, src, "foo").?;
    const sel = Selection{ .start = offset, .end = offset };
    const quickfix = [_][]const u8{"quickfix"};
    try testing.expectEqual(@as(usize, 0), (try actions(a, src, "/p/tasks/main.yml", sel, &quickfix, null)).len);
    const refactor = [_][]const u8{"refactor"};
    try testing.expectEqual(@as(usize, 1), (try actions(a, src, "/p/tasks/main.yml", sel, &refactor, null)).len);
    const rewrite = [_][]const u8{"refactor.rewrite"};
    try testing.expectEqual(@as(usize, 0), (try actions(a, src, "/p/tasks/main.yml", sel, &rewrite, null)).len);
}

test "no extract when create is unsupported" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: nginx
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const offset = std.mem.indexOf(u8, src, "name: A").?;
    const acts = try actions(a, src, "/p/tasks/main.yml", .{ .start = offset, .end = offset }, null, null);
    try testing.expectEqual(@as(usize, 0), acts.len);
}

test "context.only refactor.extract offers only extract" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const offset = std.mem.indexOf(u8, src, "foo").?;
    const sel = Selection{ .start = offset, .end = offset };
    const only = [_][]const u8{"refactor.extract"};
    const acts = try actions(a, src, "/p/tasks/main.yml", sel, &only, .{
        .dir = "/p/tasks",
        .ext = ".yml",
        .exists = neverExists,
    });
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings("refactor.extract", acts[0].kind);
}

test "context.only refactor.rewrite excludes extract" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const offset = std.mem.indexOf(u8, src, "foo").?;
    const sel = Selection{ .start = offset, .end = offset };
    const only = [_][]const u8{"refactor.rewrite"};
    const acts = try actions(a, src, "/p/tasks/main.yml", sel, &only, .{
        .dir = "/p/tasks",
        .ext = ".yml",
        .exists = neverExists,
    });
    try testing.expectEqual(@as(usize, 0), acts.len);
}
