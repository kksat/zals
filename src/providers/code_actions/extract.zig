//! Extract-tasks code actions: move task(s) under the cursor or selection into
//! a sibling `taskN.<ext>` file and replace with `include_tasks`/`import_tasks`
//! (ADR-0030).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../yaml/root.zig");
const Node = yaml.Node;
const plays = @import("../../yaml/plays.zig");
const model = @import("model.zig");
const Action = model.Action;
const Selection = model.Selection;
const ExtractEnv = model.ExtractEnv;
const lines = @import("lines.zig");

/// Append the `include_tasks` and `import_tasks` extract actions for the
/// task(s) intersecting `sel` in `forest`, when applicable.
pub fn collect(
    a: Allocator,
    out: *std.array_list.Managed(Action),
    text: []const u8,
    forest: *yaml.Forest,
    sel: Selection,
    env: ExtractEnv,
) !void {
    const seq = findExtractSequence(forest.roots, text, sel) orelse return;
    const items = try intersectingItems(a, text, seq, sel);
    if (items.len == 0) return;

    const first = items[0];
    const last = items[items.len - 1];
    const indent = lines.taskIndent(text, first);
    const eol = lines.detectEol(text);

    // The moved span starts at the first item's line, extended upward over a
    // directly-attached comment block, and ends after the last item's line.
    const first_line = lines.lineStart(text, first.start);
    const span_start = lines.attachedCommentStart(text, first_line);
    const last_line_end = lines.lineEnd(text, lines.stripTrailingNewlines(text, last.end));
    const span_end = if (last_line_end < text.len) last_line_end + 1 else text.len;

    const body = try lines.dedent(a, text, span_start, span_end, indent);
    var file_text = try std.fmt.allocPrint(a, "---{s}{s}", .{ eol, body });
    if (file_text.len == 0 or file_text[file_text.len - 1] != '\n') {
        file_text = try std.fmt.allocPrint(a, "{s}{s}", .{ file_text, eol });
    }

    const picked = try pickFilename(a, env);

    const first_idx = lines.indexOf(seq, first) orelse return;
    const last_idx = lines.indexOf(seq, last) orelse return;
    const has_prev = first_idx > 0;
    const has_next = last_idx + 1 < seq.items.len;

    // Replace from the end of the previous sibling's line (or the span start)
    // through the start of the next sibling's line (or the span end).
    var start = span_start;
    if (has_prev) {
        const pe = lines.lineEnd(text, lines.stripTrailingNewlines(text, seq.items[first_idx - 1].end));
        start = if (pe < text.len) pe + 1 else text.len;
    }
    var end = span_end;
    if (has_next) end = lines.lineStart(text, seq.items[last_idx + 1].start);

    const noun = if (items.len > 1) "tasks" else "task";
    const kws = [_][]const u8{ "include_tasks", "import_tasks" };
    const verbs = [_][]const u8{ "Include", "Import" };

    for (kws, verbs) |keyword, verb| {
        const include_text = try includeTaskText(a, indent, picked.name, keyword, verb, eol);
        try out.append(.{
            .title = try std.fmt.allocPrint(a, "Extract {s} to {s} ({s})", .{ noun, keyword, picked.name }),
            .kind = model.extract_kind,
            .start = start,
            .end = end,
            .new_text = try replacementText(a, eol, include_text, has_prev, has_next),
            .create = .{ .path = picked.path, .text = file_text },
        });
    }
}

fn includeTaskText(
    a: Allocator,
    indent: usize,
    name: []const u8,
    keyword: []const u8,
    verb: []const u8,
    eol: []const u8,
) ![]const u8 {
    const pad = try lines.spaces(a, indent);
    return std.fmt.allocPrint(
        a,
        "{s}- name: {s} file '{s}'{s}{s}  ansible.builtin.{s}: {s}{s}",
        .{ pad, verb, name, eol, pad, keyword, name, eol },
    );
}

/// The include task, with exactly one blank line on each side that has a
/// sibling.
fn replacementText(
    a: Allocator,
    eol: []const u8,
    include_text: []const u8,
    has_prev: bool,
    has_next: bool,
) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(a);
    if (has_prev) try buf.appendSlice(eol);
    try buf.appendSlice(include_text);
    if (has_next) try buf.appendSlice(eol);
    return buf.toOwnedSlice();
}

const Picked = struct { name: []const u8, path: []const u8 };

/// The first free `taskN.<ext>` in `env.dir`.
fn pickFilename(a: Allocator, env: ExtractEnv) !Picked {
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = try std.fmt.allocPrint(a, "task{d}{s}", .{ n, env.ext });
        const path = try std.fs.path.join(a, &.{ env.dir, name });
        if (!env.exists(path)) return .{ .name = name, .path = path };
    }
}

/// The deepest task-list sequence whose line range fully contains `sel`.
fn findExtractSequence(roots: []*Node, text: []const u8, sel: Selection) ?*Node {
    const sel_lines = lines.selectionLines(text, sel);
    var best: ?*Node = null;
    var best_span: usize = std.math.maxInt(usize);
    for (roots) |root| findExtractSeqNode(root, text, sel_lines, &best, &best_span);
    return best;
}

fn findExtractSeqNode(node: *Node, text: []const u8, sel_lines: lines.LineSpan, best: *?*Node, best_span: *usize) void {
    if (node.isSeq() and isTaskListSeq(node)) {
        const s = lines.lineOf(text, node.start);
        const e = lines.lineOf(text, lines.contentEnd(node));
        if (s <= sel_lines.start and sel_lines.end <= e) {
            const span = e - s;
            if (span < best_span.*) {
                best.* = node;
                best_span.* = span;
            }
        }
    }
    switch (node.kind) {
        .map => for (node.items) |pair| {
            if (pair.key) |k| findExtractSeqNode(k, text, sel_lines, best, best_span);
            if (pair.val) |v| findExtractSeqNode(v, text, sel_lines, best, best_span);
        },
        .seq => for (node.items) |item| findExtractSeqNode(item, text, sel_lines, best, best_span),
        .pair => {
            if (node.key) |k| findExtractSeqNode(k, text, sel_lines, best, best_span);
            if (node.val) |v| findExtractSeqNode(v, text, sel_lines, best, best_span);
        },
        else => {},
    }
}

/// True when `seq` is a task list: a task file's root sequence, or the value of
/// a task-section key.
fn isTaskListSeq(seq: *Node) bool {
    if (!seq.isSeq()) return false;
    if (seq.parent == null) {
        if (seq.items.len == 0) return false;
        return switch (plays.classify(seq.items[0], .{}).kind) {
            .task, .block => true,
            else => false,
        };
    }
    const pair = seq.parent.?;
    const map = pair.parent orelse return false;
    var lists = plays.taskLists(map, plays.classify(map, .{}));
    while (lists.next()) |list| if (list.seq == seq) return true;
    return false;
}

/// The direct items of `seq` whose line range intersects `sel`.
fn intersectingItems(a: Allocator, text: []const u8, seq: *Node, sel: Selection) ![]*Node {
    const sel_lines = lines.selectionLines(text, sel);
    var out = std.array_list.Managed(*Node).init(a);
    for (seq.items) |item| {
        const s = lines.lineOf(text, item.start);
        const e = lines.lineOf(text, lines.contentEnd(item));
        if (s <= sel_lines.end and sel_lines.start <= e) try out.append(item);
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var test_existing: []const []const u8 = &.{};

fn testExists(path: []const u8) bool {
    for (test_existing) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn extractRun(
    a: Allocator,
    src: []const u8,
    path: []const u8,
    start_needle: []const u8,
    end_needle: ?[]const u8,
) ![]Action {
    const start = std.mem.indexOf(u8, src, start_needle) orelse return error.NotFound;
    const end = if (end_needle) |n|
        (std.mem.indexOf(u8, src, n) orelse return error.NotFound) + n.len
    else
        start;
    const dir = std.fs.path.dirname(path).?;
    const ext = std.fs.path.extension(path);
    var forest = try yaml.parse(a, src);
    defer forest.deinit();
    var out = std.array_list.Managed(Action).init(a);
    try collect(a, &out, src, &forest, .{ .start = start, .end = end }, .{
        .dir = dir,
        .ext = ext,
        .exists = testExists,
    });
    return out.toOwnedSlice();
}

test "extract a single task with the cursor" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: bye
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: A", null);
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings("Extract task to include_tasks (task1.yml)", acts[0].title);
    try testing.expectEqualStrings("refactor.extract", acts[0].kind);
    try testing.expectEqualStrings("Extract task to import_tasks (task1.yml)", acts[1].title);
    try testing.expectEqualStrings("refactor.extract", acts[1].kind);
    try testing.expectEqualStrings(
        "- name: Include file 'task1.yml'\n  ansible.builtin.include_tasks: task1.yml\n\n",
        acts[0].new_text,
    );
    try testing.expectEqualStrings(
        "- name: Import file 'task1.yml'\n  ansible.builtin.import_tasks: task1.yml\n\n",
        acts[1].new_text,
    );
    try testing.expectEqualStrings("/p/tasks/task1.yml", acts[0].create.?.path);
    try testing.expectEqualStrings(
        "---\n- name: A\n  ansible.builtin.debug:\n    msg: hi\n",
        acts[0].create.?.text,
    );
}

test "extract a selection of tasks" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: bye
        \\
        \\- name: C
        \\  ansible.builtin.debug:
        \\    msg: c
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: A", "msg: bye");
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings("Extract tasks to include_tasks (task1.yml)", acts[0].title);
    try testing.expectEqualStrings(
        "---\n- name: A\n  ansible.builtin.debug:\n    msg: hi\n\n- name: B\n  ansible.builtin.debug:\n    msg: bye\n",
        acts[0].create.?.text,
    );
    try testing.expectEqualStrings(
        "- name: Include file 'task1.yml'\n  ansible.builtin.include_tasks: task1.yml\n\n",
        acts[0].new_text,
    );
}

test "extract a nested task inside a block" {
    const src =
        \\- name: Outer
        \\  block:
        \\    - name: Inner
        \\      ansible.builtin.debug:
        \\        msg: hi
        \\    - name: Inner2
        \\      ansible.builtin.debug:
        \\        msg: bye
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: Inner", null);
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings(
        "---\n- name: Inner\n  ansible.builtin.debug:\n    msg: hi\n",
        acts[0].create.?.text,
    );
    try testing.expectEqualStrings(
        "    - name: Include file 'task1.yml'\n      ansible.builtin.include_tasks: task1.yml\n\n",
        acts[0].new_text,
    );
}

test "extract a whole block when the cursor is on the block level" {
    const src =
        \\- name: Outer
        \\  block:
        \\    - name: Inner
        \\      ansible.builtin.debug:
        \\        msg: hi
        \\  rescue:
        \\    - name: Recover
        \\      ansible.builtin.debug:
        \\        msg: bye
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: Outer", null);
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings(
        "---\n- name: Outer\n  block:\n    - name: Inner\n      ansible.builtin.debug:\n        msg: hi\n  rescue:\n    - name: Recover\n      ansible.builtin.debug:\n        msg: bye\n",
        acts[0].create.?.text,
    );
}

test "extract moves an attached comment" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
        \\# about B
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: bye
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: B", null);
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings(
        "---\n# about B\n- name: B\n  ansible.builtin.debug:\n    msg: bye\n",
        acts[0].create.?.text,
    );
    try testing.expectEqualStrings(
        "\n- name: Include file 'task1.yml'\n  ansible.builtin.include_tasks: task1.yml\n",
        acts[0].new_text,
    );
}

test "extract leaves a detached comment" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
        \\# about B
        \\
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: bye
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: B", null);
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings(
        "---\n- name: B\n  ansible.builtin.debug:\n    msg: bye\n",
        acts[0].create.?.text,
    );
}

test "extract picks the first free taskN" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{ "/p/tasks/task1.yml", "/p/tasks/task2.yml" };

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: A", null);
    try testing.expectEqualStrings("Extract task to include_tasks (task3.yml)", acts[0].title);
    try testing.expectEqualStrings("/p/tasks/task3.yml", acts[0].create.?.path);
}

test "extract preserves crlf" {
    const src = "- name: A\r\n  ansible.builtin.debug:\r\n    msg: hi\r\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: A", null);
    try testing.expectEqual(@as(usize, 2), acts.len);
    try testing.expectEqualStrings(
        "---\r\n- name: A\r\n  ansible.builtin.debug:\r\n    msg: hi\r\n",
        acts[0].create.?.text,
    );
    try testing.expectEqualStrings(
        "- name: Include file 'task1.yml'\r\n  ansible.builtin.include_tasks: task1.yml\r\n",
        acts[0].new_text,
    );
}

test "extract normalizes blank lines" {
    const src =
        \\- name: A
        \\  ansible.builtin.debug:
        \\    msg: hi
        \\- name: B
        \\  ansible.builtin.debug:
        \\    msg: bye
        \\- name: C
        \\  ansible.builtin.debug:
        \\    msg: c
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/tasks/main.yml", "name: B", null);
    try testing.expectEqualStrings(
        "\n- name: Include file 'task1.yml'\n  ansible.builtin.include_tasks: task1.yml\n\n",
        acts[0].new_text,
    );
}

test "no extract on a non-task" {
    const src =
        \\- hosts: all
        \\  vars:
        \\    foo: 1
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    test_existing = &.{};

    const acts = try extractRun(a, src, "/p/play.yml", "foo: 1", null);
    try testing.expectEqual(@as(usize, 0), acts.len);
}
