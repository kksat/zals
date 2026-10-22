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
//! The provider is document-scoped and parses the document once. The variable
//! under the cursor comes from the shared variable model
//! (`variables.index.occurrenceInForest`); the enclosing task comes from the
//! YAML DOM's parent pointers and source ranges.

const std = @import("std");
const plays = @import("../yaml/plays.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const yaml = @import("../yaml/root.zig");
const dom = yaml.dom;
const Node = yaml.Node;
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");

/// The code-action kind the debug actions use.
pub const kind = "refactor";

/// The code-action kind the extract actions use.
pub const extract_kind = "refactor.extract";

/// A resolved action: a title, a kind, and a byte-range edit.
pub const Action = struct {
    title: []const u8,
    kind: []const u8,
    /// Inclusive start byte offset of the edit range.
    start: usize,
    /// Exclusive end byte offset of the edit range.
    end: usize,
    new_text: []const u8,
    /// A file to create alongside the edit, for extract actions.
    create: ?CreateFile = null,
};

/// A file to create as part of an action's `WorkspaceEdit`.
pub const CreateFile = struct {
    /// Absolute filesystem path of the new file.
    path: []const u8,
    /// The new file's contents.
    text: []const u8,
};

/// The cursor or selection, as byte offsets into the document.
pub const Selection = struct {
    start: usize,
    end: usize,
};

/// Everything the extract actions need from the filesystem.
pub const ExtractEnv = struct {
    /// Directory the new file is created in (the current file's directory).
    dir: []const u8,
    /// Extension for the new file, including the dot.
    ext: []const u8,
    /// True when `path` already exists.
    exists: *const fn ([]const u8) bool,
};

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
    return ExtractEnv{ .dir = dir, .ext = ext, .exists = fileExists };
}

fn fileExists(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn empty(a: Allocator) !Value {
    return .{ .array = std.json.Array.init(a) };
}

/// The pure core: the actions available at `sel` in `text`.
///
/// `path` is the filesystem path behind `text`, used to classify role
/// `defaults/`/`vars/`/`meta/` files. `only` is the client's `context.only`
/// filter, or null when the client asked for every kind. `extract` carries the
/// filesystem context for the extract actions, or null when they are not
/// offered (for example, when the client cannot create files).
pub fn actions(
    a: Allocator,
    text: []const u8,
    path: []const u8,
    sel: Selection,
    only: ?[]const []const u8,
    extract: ?ExtractEnv,
) ![]Action {
    var forest = yaml.parse(a, text) catch return &.{};
    defer forest.deinit();

    var out = std.array_list.Managed(Action).init(a);
    const container = findContainer(forest.roots, text, sel.start);
    const task = if (container) |c| nearestTaskItem(c) else null;

    if (kindRequested(only, kind)) {
        // Remove: the cursor is inside a debug task.
        if (task) |t| {
            if (isDebugTask(t)) {
                if (try removeAction(a, text, t)) |act| try out.append(act);
            }
        }

        // Add: the cursor is on a variable occurrence.
        if (try variables.index.occurrenceInForest(a, &forest, path, sel.start)) |cur| {
            if (try addAction(a, text, task, container, cur.name)) |act| try out.append(act);
        }
    }

    // Extract: the cursor or selection is on task item(s).
    if (extract) |env| {
        if (kindRequested(only, extract_kind)) {
            const acts = try extractActions(a, text, &forest, sel, env);
            for (acts) |act| try out.append(act);
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
    const eol = detectEol(text);
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
        .kind = kind,
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
    const body = try taskText(a, taskIndent(text, task), var_name, eol);

    const task_line_end = lineEnd(text, stripTrailingNewlines(text, task.end));
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
        .end = blankRunEnd(text, after),
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
                    const line_start = lineStart(text, first.start);
                    const body = try taskText(a, lineIndent(text, line_start), var_name, eol);
                    // First task in the list: no blank line before it, one after.
                    return .{
                        .start = line_start,
                        .end = line_start,
                        .text = try std.fmt.allocPrint(a, "{s}{s}", .{ body, eol }),
                    };
                }
                // `tasks:` with no items: insert after the key's line.
                const body = try taskText(a, taskIndent(text, play) + 4, var_name, eol);
                return try afterLine(a, text, tasks_pair.end, body, eol);
            }
        }
    }
    // No `tasks:` section: create one at the end of the play.
    const body = try tasksHeaderText(a, taskIndent(text, play), var_name, eol);
    return try afterLine(a, text, play.end, body, eol);
}

/// Replace the blank-line run after the line containing `end` with a blank
/// line, `body`, and a blank line.
fn afterLine(a: Allocator, text: []const u8, end: usize, body: []const u8, eol: []const u8) !Edit {
    const line_end = lineEnd(text, stripTrailingNewlines(text, end));
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
        .end = blankRunEnd(text, after),
        .text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ eol, body, eol }),
    };
}

fn taskText(a: Allocator, indent: usize, var_name: []const u8, eol: []const u8) ![]const u8 {
    const pad = try spaces(a, indent);
    return std.fmt.allocPrint(
        a,
        "{s}- name: Debug variable {s}{s}{s}  ansible.builtin.debug:{s}{s}    var: {s}{s}",
        .{ pad, var_name, eol, pad, eol, pad, var_name, eol },
    );
}

fn tasksHeaderText(a: Allocator, play_indent: usize, var_name: []const u8, eol: []const u8) ![]const u8 {
    const pad = try spaces(a, play_indent);
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
    const idx = indexOf(seq, task) orelse return null;
    const eol = detectEol(text);

    const debug_first = lineStart(text, task.start);
    const debug_last_end = lineEnd(text, stripTrailingNewlines(text, task.end));
    const has_prev = idx > 0;
    const has_next = idx + 1 < seq.items.len;

    var start = debug_first;
    if (has_prev) {
        start = lineEnd(text, stripTrailingNewlines(text, seq.items[idx - 1].end));
    }

    var end = if (debug_last_end < text.len) debug_last_end + 1 else text.len;
    if (has_next) {
        end = lineStart(text, seq.items[idx + 1].start);
    } else {
        end = blankRunEnd(text, end);
    }
    if (end <= start) return null;

    // A comment in the gap is preserved: fall back to deleting the debug's own
    // lines rather than normalising the surrounding blank lines.
    if (hasCommentLine(text, start, end)) {
        start = debug_first;
        end = if (debug_last_end < text.len) debug_last_end + 1 else text.len;
        if (end <= start) return null;
        return .{
            .title = try a.dupe(u8, "Remove debug statement"),
            .kind = kind,
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
        .kind = kind,
        .start = start,
        .end = end,
        .new_text = replacement,
    };
}

// ---------------------------------------------------------------------------
// Extract
// ---------------------------------------------------------------------------

/// The two extract actions for the task(s) under `sel`, or an empty slice when
/// there is nothing to extract.
fn extractActions(
    a: Allocator,
    text: []const u8,
    forest: *yaml.Forest,
    sel: Selection,
    env: ExtractEnv,
) ![]Action {
    const seq = findExtractSequence(forest.roots, text, sel) orelse return &.{};
    const items = try intersectingItems(a, text, seq, sel);
    if (items.len == 0) return &.{};

    const first = items[0];
    const last = items[items.len - 1];
    const indent = taskIndent(text, first);
    const eol = detectEol(text);

    // The moved span starts at the first item's line, extended upward over a
    // directly-attached comment block, and ends after the last item's line.
    const first_line = lineStart(text, first.start);
    const span_start = attachedCommentStart(text, first_line);
    const last_line_end = lineEnd(text, stripTrailingNewlines(text, last.end));
    const span_end = if (last_line_end < text.len) last_line_end + 1 else text.len;

    const body = try dedent(a, text, span_start, span_end, indent);
    var file_text = try std.fmt.allocPrint(a, "---{s}{s}", .{ eol, body });
    if (file_text.len == 0 or file_text[file_text.len - 1] != '\n') {
        file_text = try std.fmt.allocPrint(a, "{s}{s}", .{ file_text, eol });
    }

    const picked = try pickFilename(a, env);

    const first_idx = indexOf(seq, first) orelse return &.{};
    const last_idx = indexOf(seq, last) orelse return &.{};
    const has_prev = first_idx > 0;
    const has_next = last_idx + 1 < seq.items.len;

    // Replace from the end of the previous sibling's line (or the span start)
    // through the start of the next sibling's line (or the span end).
    var start = span_start;
    if (has_prev) {
        const pe = lineEnd(text, stripTrailingNewlines(text, seq.items[first_idx - 1].end));
        start = if (pe < text.len) pe + 1 else text.len;
    }
    var end = span_end;
    if (has_next) end = lineStart(text, seq.items[last_idx + 1].start);

    const noun = if (items.len > 1) "tasks" else "task";
    const kws = [_][]const u8{ "include_tasks", "import_tasks" };
    const verbs = [_][]const u8{ "Include", "Import" };

    const acts = try a.alloc(Action, 2);
    for (kws, verbs, 0..) |keyword, verb, i| {
        const include_text = try includeTaskText(a, indent, picked.name, keyword, verb, eol);
        acts[i] = .{
            .title = try std.fmt.allocPrint(a, "Extract {s} to {s} ({s})", .{ noun, keyword, picked.name }),
            .kind = extract_kind,
            .start = start,
            .end = end,
            .new_text = try replacementText(a, eol, include_text, has_prev, has_next),
            .create = .{ .path = picked.path, .text = file_text },
        };
    }
    return acts;
}

fn includeTaskText(
    a: Allocator,
    indent: usize,
    name: []const u8,
    keyword: []const u8,
    verb: []const u8,
    eol: []const u8,
) ![]const u8 {
    const pad = try spaces(a, indent);
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

/// `text[start..end]` with up to `indent` leading whitespace characters removed
/// from each line, preserving line endings.
fn dedent(a: Allocator, text: []const u8, start: usize, end: usize, indent: usize) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(a);
    var i = start;
    while (i < end) {
        const le = lineEnd(text, i);
        const line_end = @min(le, end);
        var ws: usize = 0;
        while (i + ws < line_end and (text[i + ws] == ' ' or text[i + ws] == '\t')) : (ws += 1) {}
        const strip = @min(ws, indent);
        try buf.appendSlice(text[i + strip .. line_end]);
        if (le < end) try buf.append('\n');
        i = if (le < end) le + 1 else end;
    }
    return buf.toOwnedSlice();
}

/// The start of the run of comment lines directly above `first_line_start`,
/// stopping at a blank line or a non-comment line.
fn attachedCommentStart(text: []const u8, first_line_start: usize) usize {
    var start = first_line_start;
    while (start > 0) {
        const prev_start = lineStart(text, start - 1);
        const prev_end = lineEnd(text, prev_start);
        if (!isCommentLine(text[prev_start..prev_end])) break;
        start = prev_start;
    }
    return start;
}

fn isCommentLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i < line.len and line[i] == '#';
}

const LineSpan = struct { start: usize, end: usize };

/// The deepest task-list sequence whose line range fully contains `sel`.
fn findExtractSequence(roots: []*Node, text: []const u8, sel: Selection) ?*Node {
    const lines = selectionLines(text, sel);
    var best: ?*Node = null;
    var best_span: usize = std.math.maxInt(usize);
    for (roots) |root| findExtractSeqNode(root, text, lines, &best, &best_span);
    return best;
}

fn findExtractSeqNode(node: *Node, text: []const u8, lines: LineSpan, best: *?*Node, best_span: *usize) void {
    if (node.isSeq() and isTaskListSeq(node)) {
        const s = lineOf(text, node.start);
        const e = lineOf(text, contentEnd(node));
        if (s <= lines.start and lines.end <= e) {
            const span = e - s;
            if (span < best_span.*) {
                best.* = node;
                best_span.* = span;
            }
        }
    }
    switch (node.kind) {
        .map => for (node.items) |pair| {
            if (pair.key) |k| findExtractSeqNode(k, text, lines, best, best_span);
            if (pair.val) |v| findExtractSeqNode(v, text, lines, best, best_span);
        },
        .seq => for (node.items) |item| findExtractSeqNode(item, text, lines, best, best_span),
        .pair => {
            if (node.key) |k| findExtractSeqNode(k, text, lines, best, best_span);
            if (node.val) |v| findExtractSeqNode(v, text, lines, best, best_span);
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
    const lines = selectionLines(text, sel);
    var out = std.array_list.Managed(*Node).init(a);
    for (seq.items) |item| {
        const s = lineOf(text, item.start);
        const e = lineOf(text, contentEnd(item));
        if (s <= lines.end and lines.start <= e) try out.append(item);
    }
    return out.toOwnedSlice();
}

/// The selection's start and end lines. A selection ending at the start of a
/// line belongs to the previous line.
fn selectionLines(text: []const u8, sel: Selection) LineSpan {
    const start = lineOf(text, sel.start);
    var end = lineOf(text, sel.end);
    if (end > start and sel.end == lineStart(text, sel.end)) end -= 1;
    return .{ .start = start, .end = end };
}

fn lineOf(text: []const u8, offset: usize) usize {
    var line: usize = 0;
    const clamped = @min(offset, text.len);
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    return line;
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

/// The end of the run of blank lines starting at `start` (the start of a line).
fn blankRunEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        const le = lineEnd(text, i);
        if (!isBlankLine(text[i..le])) break;
        i = if (le < text.len) le + 1 else text.len;
    }
    return i;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// True when any line in `[start, end)` is a comment line.
fn hasCommentLine(text: []const u8, start: usize, end: usize) bool {
    var i = start;
    while (i < end) {
        const le = @min(lineEnd(text, i), end);
        var j = i;
        while (j < le and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
        if (j < le and text[j] == '#') return true;
        i = if (le < end) le + 1 else end;
    }
    return false;
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

fn run(a: Allocator, src: []const u8, path: []const u8, needle: []const u8) ![]Action {
    const offset = std.mem.indexOf(u8, src, needle) orelse return error.NotFound;
    return actions(a, src, path, .{ .start = offset, .end = offset }, null, null);
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

test "no debug or extract action for any built-in import_playbook spelling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "import_playbook", "ansible.builtin.import_playbook", "ansible.legacy.import_playbook" }) |name| {
        const src = try std.fmt.allocPrint(a, "- {s}: \"{{{{ playbook_name }}}}\"\n  vars: {{x: 1}}\n", .{name});
        for ([_][]const u8{ "playbook_name", "x: 1" }) |at| {
            const off = std.mem.indexOf(u8, src, at).?;
            const acts = try actions(a, src, "/p/site.yml", .{ .start = off, .end = off }, null, .{ .dir = "/p", .ext = ".yml", .exists = testExists });
            try testing.expectEqual(@as(usize, 0), acts.len);
        }
        const acts = try actions(a, src, "/p/site.yml", .{ .start = 0, .end = src.len }, null, .{ .dir = "/p", .ext = ".yml", .exists = testExists });
        try testing.expectEqual(@as(usize, 0), acts.len);
    }
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

// ---------------------------------------------------------------------------
// Extract tests
// ---------------------------------------------------------------------------

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
    const all = try actions(a, src, path, .{ .start = start, .end = end }, null, .{
        .dir = dir,
        .ext = ext,
        .exists = testExists,
    });
    var out = std.array_list.Managed(Action).init(a);
    for (all) |act| {
        if (std.mem.eql(u8, act.kind, extract_kind)) try out.append(act);
    }
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
    test_existing = &.{};

    const offset = std.mem.indexOf(u8, src, "foo").?;
    const sel = Selection{ .start = offset, .end = offset };
    const only = [_][]const u8{"refactor.extract"};
    const acts = try actions(a, src, "/p/tasks/main.yml", sel, &only, .{
        .dir = "/p/tasks",
        .ext = ".yml",
        .exists = testExists,
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
    test_existing = &.{};

    const offset = std.mem.indexOf(u8, src, "foo").?;
    const sel = Selection{ .start = offset, .end = offset };
    const only = [_][]const u8{"refactor.rewrite"};
    const acts = try actions(a, src, "/p/tasks/main.yml", sel, &only, .{
        .dir = "/p/tasks",
        .ext = ".yml",
        .exists = testExists,
    });
    try testing.expectEqual(@as(usize, 0), acts.len);
}
