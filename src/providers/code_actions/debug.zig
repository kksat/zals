//! Debug task code actions: add a variable debug task or remove an enclosing
//! debug task (ADR-0028).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../yaml/root.zig");
const dom = yaml.dom;
const Node = yaml.Node;
const plays = @import("../../yaml/plays.zig");
const variables = @import("../../variables/root.zig");
const model = @import("model.zig");
const Action = model.Action;
const lines = @import("lines.zig");

/// Append applicable remove/add debug actions at `offset` in `text`.
pub fn collect(
    a: Allocator,
    out: *std.array_list.Managed(Action),
    text: []const u8,
    forest: *yaml.Forest,
    path: []const u8,
    offset: usize,
) !void {
    const container = findContainer(forest.roots, text, offset);
    const task = if (container) |c| nearestTaskItem(c) else null;

    // Remove: the cursor is inside a debug task.
    if (task) |t| {
        if (isDebugTask(t)) {
            if (try removeAction(a, text, t)) |act| try out.append(act);
        }
    }

    // Add: the cursor is on a variable occurrence.
    if (try variables.index.occurrenceInForest(a, forest, path, offset)) |cur| {
        if (try addAction(a, text, task, container, cur.name)) |act| try out.append(act);
    }
}

// ---------------------------------------------------------------------------
// Add
// ---------------------------------------------------------------------------

const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

fn addAction(
    a: Allocator,
    text: []const u8,
    task: ?*Node,
    container: ?*Node,
    var_name: []const u8,
) !?Action {
    const eol = lines.detectEol(text);
    var edit: Edit = undefined;
    if (task) |t| {
        edit = (try taskInsertion(a, text, t, var_name, eol)) orelse return null;
    } else {
        const play = if (container) |c| enclosingPlay(c) else null;
        const p = play orelse return null;
        if (plays.classify(p, .{}).kind == .playbook_import) return null;
        edit = (try playInsertion(a, text, p, var_name, eol)) orelse return null;
    }

    return .{
        .title = try std.fmt.allocPrint(a, "Add debug statement for '{s}'", .{var_name}),
        .kind = model.kind,
        .start = edit.start,
        .end = edit.end,
        .new_text = edit.text,
    };
}

/// Insert after the task, surrounded by a blank line before and after. The
/// blank-line run that already follows the task is replaced, so the result has
/// exactly one blank line on each side.
fn taskInsertion(
    a: Allocator,
    text: []const u8,
    task: *Node,
    var_name: []const u8,
    eol: []const u8,
) !?Edit {
    const seq = task.parent orelse return null;
    if (!seq.isSeq()) return null;
    const body = try taskText(a, lines.taskIndent(text, task), var_name, eol);

    const task_line_end = lines.lineEnd(text, lines.stripTrailingNewlines(text, task.end));
    if (task_line_end >= text.len) {
        // No trailing newline: terminate the task's line, then a blank line.
        return .{
            .start = text.len,
            .end = text.len,
            .text = try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ eol, eol, body, eol }),
        };
    }
    const after = task_line_end + 1;
    return .{
        .start = after,
        .end = lines.blankRunEnd(text, after),
        .text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ eol, body, eol }),
    };
}

/// Insert at the start of the play's `tasks:` list, creating the section when
/// the play has none.
fn playInsertion(
    a: Allocator,
    text: []const u8,
    play: *Node,
    var_name: []const u8,
    eol: []const u8,
) !?Edit {
    if (dom.findPair(play, "tasks")) |tasks_pair| {
        if (tasks_pair.val) |tasks_val| {
            if (tasks_val.isSeq()) {
                if (tasks_val.items.len > 0) {
                    const first = tasks_val.items[0];
                    const line_start = lines.lineStart(text, first.start);
                    const body = try taskText(a, lines.lineIndent(text, line_start), var_name, eol);
                    // First task in the list: no blank line before it, one after.
                    return .{
                        .start = line_start,
                        .end = line_start,
                        .text = try std.fmt.allocPrint(a, "{s}{s}", .{ body, eol }),
                    };
                }
                // `tasks:` with no items: insert after the key's line.
                const body = try taskText(a, lines.taskIndent(text, play) + 4, var_name, eol);
                return try afterLine(a, text, tasks_pair.end, body, eol);
            }
        }
    }
    // No `tasks:` section: create one at the end of the play.
    const body = try tasksHeaderText(a, lines.taskIndent(text, play), var_name, eol);
    return try afterLine(a, text, play.end, body, eol);
}

/// Replace the blank-line run after the line containing `end` with a blank
/// line, `body`, and a blank line.
fn afterLine(a: Allocator, text: []const u8, end: usize, body: []const u8, eol: []const u8) !Edit {
    const line_end = lines.lineEnd(text, lines.stripTrailingNewlines(text, end));
    if (line_end >= text.len) {
        return .{
            .start = text.len,
            .end = text.len,
            .text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ eol, body, eol }),
        };
    }
    const after = line_end + 1;
    return .{
        .start = after,
        .end = lines.blankRunEnd(text, after),
        .text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ eol, body, eol }),
    };
}

fn taskText(a: Allocator, indent: usize, var_name: []const u8, eol: []const u8) ![]const u8 {
    const pad = try lines.spaces(a, indent);
    return std.fmt.allocPrint(
        a,
        "{s}- name: Debug variable {s}{s}{s}  ansible.builtin.debug:{s}{s}    var: {s}{s}",
        .{ pad, var_name, eol, pad, eol, pad, var_name, eol },
    );
}

fn tasksHeaderText(a: Allocator, play_indent: usize, var_name: []const u8, eol: []const u8) ![]const u8 {
    const pad = try lines.spaces(a, play_indent);
    return std.fmt.allocPrint(
        a,
        "{s}  tasks:{s}{s}    - name: Debug variable {s}{s}{s}      ansible.builtin.debug:{s}{s}        var: {s}{s}",
        .{ pad, eol, pad, var_name, eol, pad, eol, pad, var_name, eol },
    );
}

// ---------------------------------------------------------------------------
// Remove
// ---------------------------------------------------------------------------

fn removeAction(a: Allocator, text: []const u8, task: *Node) !?Action {
    const seq = task.parent orelse return null;
    if (!seq.isSeq()) return null;
    const idx = lines.indexOf(seq, task) orelse return null;
    const eol = lines.detectEol(text);

    const debug_first = lines.lineStart(text, task.start);
    const debug_last_end = lines.lineEnd(text, lines.stripTrailingNewlines(text, task.end));
    const has_prev = idx > 0;
    const has_next = idx + 1 < seq.items.len;

    var start = debug_first;
    if (has_prev) {
        start = lines.lineEnd(text, lines.stripTrailingNewlines(text, seq.items[idx - 1].end));
    }

    var end = if (debug_last_end < text.len) debug_last_end + 1 else text.len;
    if (has_next) {
        end = lines.lineStart(text, seq.items[idx + 1].start);
    } else {
        end = lines.blankRunEnd(text, end);
    }
    if (end <= start) return null;

    // A comment in the gap is preserved: fall back to deleting the debug's own
    // lines rather than normalising the surrounding blank lines.
    if (lines.hasCommentLine(text, start, end)) {
        start = debug_first;
        end = if (debug_last_end < text.len) debug_last_end + 1 else text.len;
        if (end <= start) return null;
        return .{
            .title = try a.dupe(u8, "Remove debug statement"),
            .kind = model.kind,
            .start = start,
            .end = end,
            .new_text = "",
        };
    }

    // Leave exactly one blank line between the surrounding tasks.
    var replacement: []const u8 = "";
    if (has_prev and has_next) {
        replacement = try std.fmt.allocPrint(a, "{s}{s}", .{ eol, eol });
    } else if (has_prev) {
        replacement = if (end < text.len)
            try std.fmt.allocPrint(a, "{s}{s}", .{ eol, eol })
        else
            try a.dupe(u8, eol);
    }

    return .{
        .title = try a.dupe(u8, "Remove debug statement"),
        .kind = model.kind,
        .start = start,
        .end = end,
        .new_text = replacement,
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
            if (node.parent != null and node.parent.?.kind == .seq and lines.lineRangeContains(text, node, offset)) {
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

fn enclosingPlay(node: *Node) ?*Node {
    var cur: ?*Node = node;
    while (cur) |n| {
        switch (plays.classify(n, .{}).kind) {
            .play, .playbook_import => return n,
            else => {},
        }
        cur = n.parent;
    }
    return null;
}

/// The nearest ancestor (or self) that is a task item. Walks past nested maps
/// such as a `with_items` item or a module's argument map.
fn nearestTaskItem(node: *Node) ?*Node {
    var cur: ?*Node = node;
    while (cur) |n| {
        switch (plays.classify(n, .{}).kind) {
            .task, .block => return n,
            else => {},
        }
        cur = n.parent;
    }
    return null;
}

fn isDebugTask(map: *Node) bool {
    const ref = plays.module(map) orelse return false;
    // ADR-0028 is keyed to a Module key, not action/local_action (D5).
    return ref.is_key and plays.isAction(ref.name, "debug");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn run(a: Allocator, src: []const u8, path: []const u8, needle: []const u8) ![]Action {
    const offset = std.mem.indexOf(u8, src, needle) orelse return error.NotFound;
    var forest = try yaml.parse(a, src);
    defer forest.deinit();
    var out = std.array_list.Managed(Action).init(a);
    try collect(a, &out, src, &forest, path, offset);
    return out.toOwnedSlice();
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
        "\n- name: Debug variable foo\n  ansible.builtin.debug:\n    var: foo\n\n",
        acts[0].new_text,
    );
    // Replaces the blank-line gap before B.
    const blank = std.mem.indexOf(u8, src, "\n\n- name: B").?;
    try testing.expectEqual(blank + 1, acts[0].start);
    try testing.expectEqual(blank + 2, acts[0].end);
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
        "\n    - name: Debug variable foo\n      ansible.builtin.debug:\n        var: foo\n\n",
        acts[0].new_text,
    );
    try testing.expectEqual(src.len, acts[0].end);
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
        "    - name: Debug variable foo\n      ansible.builtin.debug:\n        var: foo\n\n",
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
        "\n  tasks:\n    - name: Debug variable foo\n      ansible.builtin.debug:\n        var: foo\n\n",
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
    try testing.expectEqualStrings("\n\n", acts[0].new_text);
    // Replaces from the end of A's line through the start of B's line.
    try testing.expectEqual(std.mem.indexOf(u8, src, "msg: hi\n").? + "msg: hi".len, acts[0].start);
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

test "remove normalizes zero blank lines to one" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\- name: Debug variable foo
        \\  ansible.builtin.debug:
        \\    var: foo
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
    try testing.expectEqualStrings("\n\n", acts[0].new_text);
}

test "remove collapses two blank lines to one" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
        \\
        \\- name: Debug variable foo
        \\  ansible.builtin.debug:
        \\    var: foo
        \\
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
    try testing.expectEqualStrings("\n\n", acts[0].new_text);
}

test "add inserts a blank line when the tasks are adjacent" {
    const src =
        \\- name: A
        \\  ansible.builtin.package:
        \\    name: "{{ foo }}"
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const acts = try run(a, src, "/p/tasks/main.yml", "foo");
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqualStrings(
        "\n- name: Debug variable foo\n  ansible.builtin.debug:\n    var: foo\n\n",
        acts[0].new_text,
    );
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
        "\n- name: Debug variable foo\n  ansible.builtin.debug:\n    var: foo\n\n",
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
        "\r\n- name: Debug variable foo\r\n  ansible.builtin.debug:\r\n    var: foo\r\n\r\n",
        acts[0].new_text,
    );
}
