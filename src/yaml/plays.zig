//! Ansible structure over the YAML DOM. Classification walks parent links in
//! O(depth), allocates nothing, and only recognises maps in sequence lists.
//! Unknown task-file roots stay ambiguous so completion can offer Play keys.

const std = @import("std");
const dom = @import("dom.zig");
const Node = dom.Node;
const keywords = @import("keywords.zig");

pub const File = struct {
    handlers: bool = false,
    role_tasks: bool = false,
};

pub const Shape = enum { playbook, task_list, other };
pub const Kind = enum { play, playbook_import, block, task, role_invocation, none };
pub const Class = struct {
    kind: Kind,
    handler: bool = false,
    ambiguous: bool = false,
};

/// Content-first document shape (ADR-0027). One Play makes a Playbook;
/// otherwise a root sequence containing maps is a task list.
pub fn shape(root: *const Node) Shape {
    if (!root.isSeq()) return .other;
    var maps = false;
    for (root.items) |item| {
        if (!item.isMap()) continue;
        maps = true;
        if (playKind(item) != null) return .playbook;
    }
    return if (maps) .task_list else .other;
}

fn playKind(map: *const Node) ?Kind {
    inline for (.{ "import_playbook", "ansible.builtin.import_playbook", "ansible.legacy.import_playbook" }) |name| {
        if (dom.findPair(map, name) != null) return .playbook_import;
    }
    for (map.items) |pair| {
        const name = (pair.key orelse continue).stringValue() orelse continue;
        if (keywords.isPlayExclusiveKeyword(name)) return .play;
    }
    return null;
}

pub fn classify(map: *const Node, file: File) Class {
    if (!map.isMap()) return .{ .kind = .none };
    const seq = map.parent orelse return .{ .kind = .none };
    if (!seq.isSeq()) return .{ .kind = .none };
    var handler = file.handlers;
    var ambiguous = false;
    if (seq.parent) |pair| {
        const name = (pair.key orelse return .{ .kind = .none }).stringValue() orelse return .{ .kind = .none };
        if (std.mem.eql(u8, name, "roles")) return .{ .kind = .role_invocation };
        if (!taskSection(name)) return .{ .kind = .none };
        if (pair.parent) |owner| handler = classify(owner, file).handler;
        if (std.mem.eql(u8, name, "handlers")) handler = true;
    } else {
        if (!file.role_tasks and !file.handlers) {
            if (playKind(map)) |kind| return .{ .kind = kind };
            ambiguous = true;
        }
    }
    const block = dom.findPair(map, "block") != null or dom.findPair(map, "rescue") != null or dom.findPair(map, "always") != null;
    return .{ .kind = if (block) .block else .task, .handler = handler, .ambiguous = ambiguous };
}

fn taskSection(name: []const u8) bool {
    for ([_][]const u8{ "tasks", "pre_tasks", "post_tasks", "handlers", "block", "rescue", "always" }) |key| {
        if (std.mem.eql(u8, name, key)) return true;
    }
    return false;
}

pub const TaskList = struct { key: *Node, seq: *Node, handler: bool };
pub const TaskLists = struct {
    map: *const Node,
    class: Class,
    index: usize = 0,

    pub fn next(self: *TaskLists) ?TaskList {
        while (self.index < self.map.items.len) {
            const pair = self.map.items[self.index];
            self.index += 1;
            const key = pair.key orelse continue;
            const name = key.stringValue() orelse continue;
            const seq = pair.val orelse continue;
            if (!seq.isSeq() or !taskSection(name)) continue;
            return .{ .key = key, .seq = seq, .handler = self.class.handler or std.mem.eql(u8, name, "handlers") };
        }
        return null;
    }
};

/// Ansible task containers only, in source order. Keyword and Module argument
/// values are data; callers retain control over their own downward traversal.
pub fn taskLists(map: *const Node, class: Class) TaskLists {
    return .{ .map = map, .class = class, .index = switch (class.kind) {
        .play, .playbook_import, .block, .task => 0,
        .role_invocation, .none => map.items.len,
    } };
}

pub const ModuleRef = struct {
    name: []const u8,
    node: *Node,
    /// False for action/local_action values. Consumers whose contract is
    /// specifically a Module key (ADR-0027/0028) can keep that restriction.
    is_key: bool,
};

/// First Module key, or the first word of a scalar action/local_action value.
/// This extraction does not opt consumers into action-style Debug removal.
pub fn module(task: *const Node) ?ModuleRef {
    for (task.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        if (std.mem.eql(u8, name, "action") or std.mem.eql(u8, name, "local_action")) {
            const val = pair.val orelse continue;
            const value = val.stringValue() orelse continue;
            var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
            return .{ .name = words.next() orelse continue, .node = val, .is_key = false };
        }
        if (!keywords.isTaskKeyword(name)) return .{ .name = name, .node = key, .is_key = true };
    }
    return null;
}

/// Compatibility rule: a short name or any nonempty dotted namespace. Keep
/// arbitrary *.name matches until a separate namespace-policy change (D7).
pub fn isAction(name: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, name, short) or
        (name.len > short.len + 1 and name[name.len - short.len - 1] == '.' and std.mem.endsWith(u8, name, short));
}

const testing = std.testing;

test "structure classification table" {
    const Case = struct {
        text: []const u8,
        at: []const u8 = "",
        file: File = .{},
        shape: Shape,
        kind: Kind,
        handler: bool = false,
        ambiguous: bool = false,
        lists: usize = 0,
    };
    for ([_]Case{
        .{ .text = "- hosts: all\n  tasks: []\n", .shape = .playbook, .kind = .play, .lists = 1 },
        .{ .text = "- tasks: []\n", .shape = .playbook, .kind = .play, .lists = 1 },
        .{ .text = "- import_playbook: other.yml\n", .shape = .playbook, .kind = .playbook_import },
        .{ .text = "- ansible.builtin.import_playbook: other.yml\n", .shape = .playbook, .kind = .playbook_import },
        .{ .text = "- ansible.legacy.import_playbook: other.yml\n", .shape = .playbook, .kind = .playbook_import },
        .{ .text = "- name: uncertain\n", .shape = .task_list, .kind = .task, .ambiguous = true },
        .{ .text = "- ping:\n", .file = .{ .role_tasks = true }, .shape = .task_list, .kind = .task },
        .{ .text = "- tasks: []\n", .file = .{ .role_tasks = true }, .shape = .playbook, .kind = .task, .lists = 1 },
        .{ .text = "- rescue: []\n", .shape = .task_list, .kind = .block, .ambiguous = true, .lists = 1 },
        .{ .text = "- block:\n    - rescue: []\n", .at = "rescue", .shape = .task_list, .kind = .block, .lists = 1 },
        .{ .text = "- hosts: all\n  handlers:\n    - block:\n        - debug: hi\n", .at = "debug", .shape = .playbook, .kind = .task, .handler = true },
        .{ .text = "- debug: hi\n", .file = .{ .handlers = true }, .shape = .task_list, .kind = .task, .handler = true },
        .{ .text = "- hosts: all\n  roles:\n    - role: demo\n", .at = "role: demo", .shape = .playbook, .kind = .role_invocation },
        .{ .text = "- hosts: all\n  tasks:\n    - ping:\n", .at = "ping", .shape = .playbook, .kind = .task },
        .{ .text = "- debug:\n    msg: hi\n", .at = "msg", .shape = .task_list, .kind = .none },
        .{ .text = "key: value\n", .shape = .other, .kind = .none },
        .{ .text = "- scalar\n", .shape = .other, .kind = .none },
    }) |case| {
        var forest = try @import("root.zig").parse(testing.allocator, case.text);
        defer forest.deinit();
        const root = forest.roots[0];
        try testing.expectEqual(case.shape, shape(root));
        const path = (try forest.pathAt(std.mem.indexOf(u8, case.text, case.at).?, true)).?;
        var node = if (case.at.len == 0 and root.isSeq()) root.items[0] else path[path.len - 1];
        while (!node.isMap() and node.parent != null) node = node.parent.?;
        const class = classify(node, case.file);
        try testing.expectEqual(case.kind, class.kind);
        try testing.expectEqual(case.handler, class.handler);
        try testing.expectEqual(case.ambiguous, class.ambiguous);
        var lists = taskLists(node, class);
        var count: usize = 0;
        while (lists.next()) |_| count += 1;
        try testing.expectEqual(case.lists, count);
    }
}

test "task lists retain source order and Handler context" {
    var forest = try @import("root.zig").parse(testing.allocator, "- hosts: all\n  pre_tasks: []\n  handlers: []\n  tasks: []\n  vars: {tasks: []}\n");
    defer forest.deinit();
    const map = forest.roots[0].items[0];
    var lists = taskLists(map, classify(map, .{}));
    for ([_][]const u8{ "pre_tasks", "handlers", "tasks" }) |name| {
        const list = lists.next().?;
        try testing.expectEqualStrings(name, list.key.stringValue().?);
        try testing.expectEqual(std.mem.eql(u8, name, "handlers"), list.handler);
    }
    try testing.expect(lists.next() == null);
}

test "Module extraction and compatibility action namespaces" {
    for ([_]struct { text: []const u8, name: ?[]const u8, is_key: bool = true }{
        .{ .text = "- name: t\n  ansible.builtin.debug: hi\n", .name = "ansible.builtin.debug" },
        .{ .text = "- action: ansible.builtin.debug msg=hi\n", .name = "ansible.builtin.debug", .is_key = false },
        .{ .text = "- local_action: debug msg=hi\n", .name = "debug", .is_key = false },
        .{ .text = "- name: t\n  with_items: []\n", .name = null },
    }) |case| {
        var forest = try @import("root.zig").parse(testing.allocator, case.text);
        defer forest.deinit();
        const ref = module(forest.roots[0].items[0]);
        if (case.name) |name| {
            try testing.expectEqualStrings(name, ref.?.name);
            try testing.expectEqual(case.is_key, ref.?.is_key);
        } else try testing.expect(ref == null);
    }
    for ([_][]const u8{ "debug", "ansible.builtin.debug", "ansible.legacy.debug", "third.party.debug" }) |name| try testing.expect(isAction(name, "debug"));
    for ([_][]const u8{ "notdebug", ".debug", "debug.more" }) |name| try testing.expect(!isAction(name, "debug"));
}
