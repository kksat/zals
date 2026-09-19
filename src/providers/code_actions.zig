//! Debug code actions (ADR-0028).
//!
//! Two `refactor` actions over an Ansible document:
//!
//! - **Add debug** — when the cursor is on a variable occurrence, insert a
//!   `ansible.builtin.debug` task right after the enclosing task (or at the
//!   start of the enclosing play's `tasks:` list when there is no task).
//! - **Remove debug** — when the cursor is inside a task whose module key is
//!   `debug` (or `*.debug`), delete that task.
//!
//! The provider is document-scoped and parses the document once. The variable
//! under the cursor comes from the shared variable model
//! (`variables.Index.occurrenceInForest`); the enclosing task comes from the
//! YAML DOM's parent pointers and source ranges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const dom = yaml.dom;
const Node = yaml.Node;
const keywords = yaml.keywords;
const variables = @import("../variables/root.zig");

/// The single code-action kind both actions use.
pub const kind = "refactor";

/// A resolved action: a title, a kind, and a byte-range edit.
pub const Action = struct {
    title: []const u8,
    kind: []const u8,
    /// Inclusive start byte offset of the edit range.
    start: usize,
    /// Exclusive end byte offset of the edit range.
    end: usize,
    new_text: []const u8,
};

/// LSP entry point for `textDocument/codeAction`.
pub fn codeActions(self: *Server, a: Allocator, params: Value) !Value {
    const td = json_util.field(params, "textDocument") orelse return empty(a);
    const uri = json_util.string(td, "uri") orelse return empty(a);
    const doc = self.documents.get(uri) orelse return empty(a);
    const range_v = json_util.field(params, "range") orelse return empty(a);
    const range = json_util.range(range_v) orelse return empty(a);
    const offset = doc.offsetAt(range.start) orelse return empty(a);

    const only = try onlyKinds(a, params);
    const path = try variables.scope.uriToPath(a, uri);
    const acts = try actions(a, doc.bytes(), path, offset, only);

    var arr = std.json.Array.init(a);
    for (acts) |act| try arr.append(try toValue(a, doc, uri, act));
    return .{ .array = arr };
}

fn empty(a: Allocator) !Value {
    return .{ .array = std.json.Array.init(a) };
}

/// The pure core: the actions available at `offset` in `text`.
///
/// `path` is the filesystem path behind `text`, used only to classify role
/// `defaults/`/`vars/`/`meta/` files. `only` is the client's `context.only`
/// filter, or null when the client asked for every kind.
pub fn actions(
    a: Allocator,
    text: []const u8,
    path: []const u8,
    offset: usize,
    only: ?[]const []const u8,
) ![]Action {
    if (!kindRequested(only)) return &.{};

    var forest = yaml.parse(a, text) catch return &.{};
    defer forest.deinit();

    var out = std.array_list.Managed(Action).init(a);
    const container = findContainer(forest.roots, text, offset);
    const task = if (container) |c| nearestTaskItem(c) else null;

    // Remove: the cursor is inside a debug task.
    if (task) |t| {
        if (isDebugTask(t)) {
            if (try removeAction(a, text, t)) |act| try out.append(act);
        }
    }

    // Add: the cursor is on a variable occurrence.
    if (try variables.Index.occurrenceInForest(a, &forest, path, offset)) |cur| {
        if (try addAction(a, text, task, container, cur.name)) |act| try out.append(act);
    }

    return out.toOwnedSlice();
}

fn kindRequested(only: ?[]const []const u8) bool {
    const list = only orelse return true;
    for (list) |requested| {
        if (kindMatches(kind, requested)) return true;
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
// Add
// ---------------------------------------------------------------------------

const Insertion = struct {
    offset: usize,
    /// Indent of the inserted task's `-` (or of the play for a `tasks:` header).
    indent: usize,
    prepend_newline: bool,
    /// Emit a `tasks:` header before the task (play with no `tasks:` section).
    with_tasks_header: bool,
};

fn addAction(
    a: Allocator,
    text: []const u8,
    task: ?*Node,
    container: ?*Node,
    var_name: []const u8,
) !?Action {
    const eol = detectEol(text);
    const ins = blk: {
        if (task) |t| break :blk taskInsertion(text, t);
        const play = if (container) |c| enclosingPlay(c) else null;
        const p = play orelse return null;
        if (isImportPlaybook(p)) return null;
        break :blk playInsertion(text, p);
    } orelse return null;

    return .{
        .title = try std.fmt.allocPrint(a, "Add debug statement for '{s}'", .{var_name}),
        .kind = kind,
        .start = ins.offset,
        .end = ins.offset,
        .new_text = try taskText(a, ins, var_name, eol),
    };
}

/// Insert after the task: at the next sibling's line start, or after the
/// task's last line when it is last in its sequence.
fn taskInsertion(text: []const u8, task: *Node) ?Insertion {
    const seq = task.parent orelse return null;
    if (!seq.isSeq()) return null;
    const idx = indexOf(seq, task) orelse return null;
    if (idx + 1 < seq.items.len) {
        const next = seq.items[idx + 1];
        const line_start = lineStart(text, next.start);
        return .{
            .offset = line_start,
            .indent = lineIndent(text, line_start),
            .prepend_newline = false,
            .with_tasks_header = false,
        };
    }
    return afterLastLine(text, task.end, taskIndent(text, task));
}

/// Insert at the start of the play's `tasks:` list, creating the section when
/// the play has none.
fn playInsertion(text: []const u8, play: *Node) ?Insertion {
    if (dom.findPair(play, "tasks")) |tasks_pair| {
        if (tasks_pair.val) |tasks_val| {
            if (tasks_val.isSeq()) {
                if (tasks_val.items.len > 0) {
                    const first = tasks_val.items[0];
                    const line_start = lineStart(text, first.start);
                    return .{
                        .offset = line_start,
                        .indent = lineIndent(text, line_start),
                        .prepend_newline = false,
                        .with_tasks_header = false,
                    };
                }
                // `tasks:` with no items: insert after the key's line.
                var ins = afterLastLine(text, tasks_pair.end, taskIndent(text, play) + 4) orelse return null;
                ins.with_tasks_header = false;
                return ins;
            }
        }
    }
    // No `tasks:` section: create one at the end of the play.
    var ins = afterLastLine(text, play.end, taskIndent(text, play)) orelse return null;
    ins.with_tasks_header = true;
    return ins;
}

/// Insert at the start of the line after the line containing `end`. When the
/// document has no trailing newline, insert at the end and prepend one.
fn afterLastLine(text: []const u8, end: usize, indent: usize) ?Insertion {
    const line_end = lineEnd(text, stripTrailingNewlines(text, end));
    if (line_end < text.len) {
        return .{
            .offset = line_end + 1,
            .indent = indent,
            .prepend_newline = false,
            .with_tasks_header = false,
        };
    }
    return .{
        .offset = text.len,
        .indent = indent,
        .prepend_newline = true,
        .with_tasks_header = false,
    };
}

fn taskText(a: Allocator, ins: Insertion, var_name: []const u8, eol: []const u8) ![]const u8 {
    const pad = try spaces(a, ins.indent);
    const prefix = if (ins.prepend_newline) eol else "";
    if (ins.with_tasks_header) {
        return std.fmt.allocPrint(
            a,
            "{s}{s}  tasks:{s}{s}    - name: Debug variable {s}{s}{s}      ansible.builtin.debug:{s}{s}        var: {s}{s}",
            .{ prefix, pad, eol, pad, var_name, eol, pad, eol, pad, var_name, eol },
        );
    }
    return std.fmt.allocPrint(
        a,
        "{s}{s}- name: Debug variable {s}{s}{s}  ansible.builtin.debug:{s}{s}    var: {s}{s}",
        .{ prefix, pad, var_name, eol, pad, eol, pad, var_name, eol },
    );
}

// ---------------------------------------------------------------------------
// Remove
// ---------------------------------------------------------------------------

fn removeAction(a: Allocator, text: []const u8, task: *Node) !?Action {
    const seq = task.parent orelse return null;
    if (!seq.isSeq()) return null;
    const idx = indexOf(seq, task) orelse return null;

    const start = lineStart(text, task.start);
    const end = if (idx + 1 < seq.items.len)
        lineStart(text, seq.items[idx + 1].start)
    else blk: {
        const line_end = lineEnd(text, stripTrailingNewlines(text, task.end));
        break :blk if (line_end < text.len) line_end + 1 else text.len;
    };
    if (end <= start) return null;

    return .{
        .title = try a.dupe(u8, "Remove debug statement"),
        .kind = kind,
        .start = start,
        .end = end,
        .new_text = "",
    };
}

// ---------------------------------------------------------------------------
// DOM classification
// ---------------------------------------------------------------------------

/// The deepest map whose parent is a sequence and whose line range contains
/// `offset`. This is the task, block, play, role invocation, or `vars_prompt`
/// entry the cursor sits in.
fn findContainer(roots: []*Node, text: []const u8, offset: usize) ?*Node {
    var best: ?*Node = null;
    for (roots) |root| {
        if (findContainerNode(root, text, offset)) |m| best = m;
    }
    return best;
}

fn findContainerNode(node: *Node, text: []const u8, offset: usize) ?*Node {
    var best: ?*Node = null;
    switch (node.kind) {
        .map => {
            if (node.parent != null and node.parent.?.kind == .seq and lineRangeContains(text, node, offset)) {
                best = node;
            }
            for (node.items) |pair| {
                if (pair.key) |k| {
                    if (findContainerNode(k, text, offset)) |m| best = m;
                }
                if (pair.val) |v| {
                    if (findContainerNode(v, text, offset)) |m| best = m;
                }
            }
        },
        .seq => for (node.items) |item| {
            if (findContainerNode(item, text, offset)) |m| best = m;
        },
        .pair => {
            if (node.key) |k| {
                if (findContainerNode(k, text, offset)) |m| best = m;
            }
            if (node.val) |v| {
                if (findContainerNode(v, text, offset)) |m| best = m;
            }
        },
        else => {},
    }
    return best;
}

/// True when `map` is a direct item of a task-list sequence: a task section
/// (`tasks`, `pre_tasks`, `post_tasks`, `handlers`, `block`, `rescue`,
/// `always`) or an item of a task file's root sequence.
fn isTaskItem(map: *Node) bool {
    const seq = map.parent orelse return false;
    if (!seq.isSeq()) return false;
    if (seq.parent == null) return !isPlay(map);
    const pair = seq.parent.?;
    if (!pair.isPair()) return false;
    const key = pair.key orelse return false;
    const name = key.stringValue() orelse return false;
    return isTaskSection(name);
}

fn isTaskSection(name: []const u8) bool {
    return std.mem.eql(u8, name, "tasks") or
        std.mem.eql(u8, name, "pre_tasks") or
        std.mem.eql(u8, name, "post_tasks") or
        std.mem.eql(u8, name, "handlers") or
        std.mem.eql(u8, name, "block") or
        std.mem.eql(u8, name, "rescue") or
        std.mem.eql(u8, name, "always");
}

fn isPlay(map: *Node) bool {
    for (map.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        if (keywords.isPlayExclusiveKeyword(name)) return true;
        if (std.mem.eql(u8, name, "import_playbook")) return true;
    }
    return false;
}

fn isImportPlaybook(map: *Node) bool {
    return dom.findPair(map, "import_playbook") != null;
}

fn enclosingPlay(node: *Node) ?*Node {
    var cur: ?*Node = node;
    while (cur) |n| {
        if (n.isMap() and isPlay(n)) return n;
        cur = n.parent;
    }
    return null;
}

/// The nearest ancestor (or self) that is a task item. Walks past nested maps
/// such as a `with_items` item or a module's argument map.
fn nearestTaskItem(node: *Node) ?*Node {
    var cur: ?*Node = node;
    while (cur) |n| {
        if (n.isMap() and isTaskItem(n)) return n;
        cur = n.parent;
    }
    return null;
}

fn isDebugTask(map: *Node) bool {
    const key = moduleKey(map) orelse return false;
    const name = key.stringValue() orelse return false;
    return isModuleKey(name, "debug");
}

/// The first key of a task map that is not a task keyword — the module key.
fn moduleKey(map: *Node) ?*Node {
    for (map.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        if (keywords.isTaskKeyword(name)) continue;
        return key;
    }
    return null;
}

fn isModuleKey(key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, key, name)) return true;
    if (key.len > name.len + 1 and key[key.len - name.len - 1] == '.') {
        return std.mem.endsWith(u8, key, name);
    }
    return false;
}

fn indexOf(seq: *Node, item: *Node) ?usize {
    for (seq.items, 0..) |it, i| {
        if (it == item) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

fn detectEol(text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "\r\n") != null) return "\r\n";
    return "\n";
}

fn spaces(a: Allocator, n: usize) ![]const u8 {
    const buf = try a.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// Start of the line containing `offset`.
fn lineStart(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0 and text[i - 1] != '\n') : (i -= 1) {}
    return i;
}

/// Index of the `\n` at or after `offset`, or `text.len`.
fn lineEnd(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i < text.len and text[i] != '\n') : (i += 1) {}
    return i;
}

/// `end` with any trailing `\n`/`\r` removed. The tree-sitter DOM can extend a
/// sequence's last map to include its trailing newline.
fn stripTrailingNewlines(text: []const u8, end: usize) usize {
    var e = @min(end, text.len);
    while (e > 0 and (text[e - 1] == '\n' or text[e - 1] == '\r')) : (e -= 1) {}
    return e;
}

fn lineIndent(text: []const u8, line_start: usize) usize {
    var i = line_start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i - line_start;
}

fn taskIndent(text: []const u8, task: *Node) usize {
    return lineIndent(text, lineStart(text, task.start));
}

fn lineRangeContains(text: []const u8, node: *Node, offset: usize) bool {
    const end = lineEnd(text, stripTrailingNewlines(text, contentEnd(node)));
    return lineStart(text, node.start) <= offset and offset <= end;
}

/// The end of the node's deepest content, ignoring trailing comments that the
/// tree-sitter DOM attaches to a sequence's last map.
fn contentEnd(node: *Node) usize {
    switch (node.kind) {
        .map => {
            var end = node.start;
            for (node.items) |pair| end = @max(end, contentEnd(pair));
            return end;
        },
        .seq => {
            var end = node.start;
            for (node.items) |item| end = @max(end, contentEnd(item));
            return end;
        },
        .pair => {
            if (node.val) |v| return contentEnd(v);
            if (node.key) |k| return k.end;
            return node.end;
        },
        else => return node.end,
    }
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

    var changes = std.json.Array.init(a);
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

fn run(a: Allocator, src: []const u8, path: []const u8, needle: []const u8) ![]Action {
    const offset = std.mem.indexOf(u8, src, needle) orelse return error.NotFound;
    return actions(a, src, path, offset, null);
}

test "add debug after a task" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: "{{ foo }}"
        \\
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/play.yml", "foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings("Add debug statement for 'foo'", acts[0].title);
    try testing.expectEqualStrings("refactor", acts[0].kind);
    try testing.expectEqualStrings(
        "- name: Debug variable foo\n  ansible.builtin.debug:\n    var: foo\n",
        acts[0].new_text,
    );
    // Inserted at the start of B's line (after the blank line).
    try testing.expectEqual(std.mem.indexOf(u8, src, "- name: B").?, acts[0].start);
    try testing.expectEqual(acts[0].start, acts[0].end);
}

test "add debug after the last task in a block" {
    const src =
        \\- name: A
        \\  block:
        \\    - name: Inner
        \\      ansible.builtin.package:
        \\        name: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings(
        "    - name: Debug variable foo\n      ansible.builtin.debug:\n        var: foo\n",
        acts[0].new_text,
    );
    // Inserted at end of file (no trailing newline).
    try testing.expectEqual(src.len, acts[0].start);
}

test "add debug at the start of the play tasks list" {
    const src =
        \\- hosts: all
        \\  vars:
        \\    foo: 1
        \\  tasks:
        \\    - name: A
        \\      ansible.builtin.debug:
        \\        msg: hi
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/play.yml", "foo: 1");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings(
        "    - name: Debug variable foo\n      ansible.builtin.debug:\n        var: foo\n",
        acts[0].new_text,
    );
    try testing.expectEqual(std.mem.indexOf(u8, src, "    - name: A").?, acts[0].start);
}

test "add debug creates a tasks section when the play has none" {
    const src =
        \\- hosts: all
        \\  vars:
        \\    foo: 1
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/play.yml", "foo: 1");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings(
        "  tasks:\n    - name: Debug variable foo\n      ansible.builtin.debug:\n        var: foo\n",
        acts[0].new_text,
    );
}

test "add debug falls back to the play for role invocation params" {
    const src =
        \\- hosts: all
        \\  roles:
        \\    - role: demo
        \\      app_port: "{{ base_port }}"
        \\  tasks:
        \\    - name: A
        \\      ansible.builtin.debug:
        \\        msg: hi
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/play.yml", "base_port");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqual(std.mem.indexOf(u8, src, "    - name: A").?, acts[0].start);
}

test "no add action in a role defaults file" {
    const src =
        \\foo: 1
        \\bar: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/r/defaults/main.yml", "foo }}");
    try testing.expectEqual(@as(usize, 0), acts.len);
}

test "no add action for import_playbook" {
    const src =
        \\- import_playbook: "{{ playbook_name }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/site.yml", "playbook_name");
    try testing.expectEqual(@as(usize, 0), acts.len);
}

test "remove a debug task" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
        \\- name: Debug variable foo
        \\  ansible.builtin.debug:
        \\    var: foo
        \\
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: bye
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "var: foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings("Remove debug statement", acts[0].title);
    try testing.expectEqualStrings("", acts[0].new_text);
    try testing.expectEqual(std.mem.indexOf(u8, src, "- name: Debug variable foo").?, acts[0].start);
    // Deletes through the start of B's line, swallowing the blank line.
    try testing.expectEqual(std.mem.indexOf(u8, src, "- name: B").?, acts[0].end);
}

test "remove a debug task that is last in a block" {
    const src =
        \\- name: A
        \\  block:
        \\    - name: Debug variable foo
        \\      ansible.builtin.debug:
        \\        var: foo
        \\  rescue:
        \\    - name: Recover
        \\      ansible.builtin.debug:
        \\        msg: hi
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "var: foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    // Bounded by the block: stops before `rescue:`.
    try testing.expectEqual(std.mem.indexOf(u8, src, "    - name: Debug variable foo").?, acts[0].start);
    try testing.expectEqual(std.mem.indexOf(u8, src, "  rescue:").?, acts[0].end);
}

test "both actions when the cursor is on a variable inside a debug task" {
    const src =
        \\- name: Debug variable foo
        \\  ansible.builtin.debug:
        \\    msg: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "foo }}");
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings("Remove debug statement", acts[0].title);
    try testing.expectEqualStrings("Add debug statement for 'foo'", acts[1].title);
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
    const quickfix = [_][]const u8{"quickfix"};
    try testing.expectEqual(@as(usize, 0), (try actions(a, src, "/p/tasks/main.yml", offset, &quickfix)).len);
    const refactor = [_][]const u8{"refactor"};
    try testing.expectEqual(@as(usize, 1), (try actions(a, src, "/p/tasks/main.yml", offset, &refactor)).len);
    const rewrite = [_][]const u8{"refactor.rewrite"};
    try testing.expectEqual(@as(usize, 0), (try actions(a, src, "/p/tasks/main.yml", offset, &rewrite)).len);
}

test "no action on a non-variable" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: nginx
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "name: A");
    try testing.expectEqual(@as(usize, 0), acts.len);
}

test "add debug after a task with a with_items item map" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: "{{ item.name }}"
        \\  with_items:
        \\    - name: "{{ foo }}"
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings(
        "- name: Debug variable foo\n  ansible.builtin.debug:\n    var: foo\n",
        acts[0].new_text,
    );
}

test "no action on a trailing comment after the last task" {
    const src =
        \\- name: Debug variable foo
        \\  ansible.builtin.debug:
        \\    var: foo
        \\# trailing comment
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "trailing comment");
    try testing.expectEqual(@as(usize, 0), acts.len);
}

test "crlf line endings are preserved" {
    const src = "- name: A\r\n  ansible.builtin.package:\r\n    name: \"{{ foo }}\"\r\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings(
        "- name: Debug variable foo\r\n  ansible.builtin.debug:\r\n    var: foo\r\n",
        acts[0].new_text,
    );
}
