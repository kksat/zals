//! Variable definition-site detection over the YAML DOM.
//!
//! Recognises the in-scope sites from ADR-0024: `vars:` maps, `set_fact`,
//! `register`, `loop_control.loop_var`, `vars_prompt`, role invocation params,
//! role `defaults/`/`vars/` top-level keys, and `meta/main.yml`
//! `argument_specs` options.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../yaml/dom.zig");
const Node = dom.Node;
const keywords = @import("../yaml/keywords.zig");

pub const Site = enum {
    role_defaults,
    role_vars,
    argument_specs,
    play_vars,
    block_vars,
    task_vars,
    set_fact,
    register,
    vars_files,
    include_vars,
    loop_var,
    vars_prompt,
    role_param,

    /// Precedence rank for go-to-definition, highest first (ADR-0024).
    pub fn rank(self: Site) u8 {
        return switch (self) {
            .loop_var => 1,
            .role_param => 2,
            .set_fact, .register => 3,
            .include_vars => 4,
            .task_vars => 5,
            .block_vars => 6,
            .role_vars => 7,
            .vars_files => 8,
            .vars_prompt => 9,
            .play_vars => 10,
            .role_defaults => 11,
            .argument_specs => 12,
        };
    }
};

pub const Definition = struct {
    name: []const u8,
    start: usize,
    end: usize,
    site: Site,
};

pub const FileKind = enum { role_defaults, role_vars, role_meta, general };

/// Collect every definition in `forest`. `text` is the source the offsets refer
/// to (usually `forest.text`).
pub fn collect(
    allocator: Allocator,
    forest: *const dom.Forest,
    kind: FileKind,
    out: *std.array_list.Managed(Definition),
) !void {
    const text = forest.text;
    for (forest.roots) |root| {
        switch (kind) {
            .role_defaults => try topLevelKeys(root, .role_defaults, out),
            .role_vars => try topLevelKeys(root, .role_vars, out),
            .role_meta => try argumentSpecs(root, out),
            .general => {
                // A map-rooted file outside the conventional dirs is a
                // `vars_files`/`include_vars` target: its top-level keys are
                // variables. Playbooks and task files are seq-rooted.
                if (root.isMap()) try topLevelKeys(root, .vars_files, out);
                try walk(allocator, root, text, out);
            },
        }
    }
}

fn topLevelKeys(
    root: *const Node,
    site: Site,
    out: *std.array_list.Managed(Definition),
) !void {
    if (!root.isMap()) return;
    for (root.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        try out.append(.{ .name = name, .start = key.start, .end = key.end, .site = site });
    }
}

fn argumentSpecs(
    root: *const Node,
    out: *std.array_list.Managed(Definition),
) !void {
    const specs = dom.findPair(root, "argument_specs") orelse return;
    const specs_map = specs.val orelse return;
    if (!specs_map.isMap()) return;
    for (specs_map.items) |entry| {
        const entry_map = entry.val orelse continue;
        if (!entry_map.isMap()) continue;
        const options = dom.findPair(entry_map, "options") orelse continue;
        const options_map = options.val orelse continue;
        if (!options_map.isMap()) continue;
        try addMapKeys(options_map, .argument_specs, out);
    }
}

fn walk(
    allocator: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(Definition),
) !void {
    switch (node.kind) {
        .map => {
            for (node.items) |pair| {
                const key_node = pair.key orelse continue;
                const key = key_node.stringValue() orelse continue;
                const val = pair.val orelse continue;

                if (std.mem.eql(u8, key, "vars") and val.isMap()) {
                    try addMapKeys(val, varsSite(node), out);
                } else if (isModuleKey(key, "set_fact") and val.isMap()) {
                    try addMapKeys(val, .set_fact, out);
                } else if (std.mem.eql(u8, key, "register") and val.isScalar()) {
                    try addScalar(val, text, .register, out);
                } else if (std.mem.eql(u8, key, "loop_control") and val.isMap()) {
                    if (dom.findPair(val, "loop_var")) |p| {
                        if (p.val) |v| try addScalar(v, text, .loop_var, out);
                    }
                } else if (std.mem.eql(u8, key, "vars_prompt") and val.isSeq()) {
                    for (val.items) |item| {
                        if (!item.isMap()) continue;
                        if (dom.findPair(item, "name")) |p| {
                            if (p.val) |v| try addScalar(v, text, .vars_prompt, out);
                        }
                    }
                } else if (std.mem.eql(u8, key, "roles") and val.isSeq()) {
                    try roleParams(val, out);
                }
                try walk(allocator, val, text, out);
            }
        },
        .seq => for (node.items) |item| try walk(allocator, item, text, out),
        else => {},
    }
}

fn roleParams(
    seq: *const Node,
    out: *std.array_list.Managed(Definition),
) !void {
    for (seq.items) |item| {
        if (!item.isMap()) continue;
        for (item.items) |pair| {
            const key_node = pair.key orelse continue;
            const name = key_node.stringValue() orelse continue;
            if (std.mem.eql(u8, name, "role")) continue;
            if (keywords.isRoleKeyword(name)) continue;
            try out.append(.{ .name = name, .start = key_node.start, .end = key_node.end, .site = .role_param });
        }
    }
}

fn varsSite(map: *const Node) Site {
    if (dom.findPair(map, "hosts") != null or
        dom.findPair(map, "tasks") != null or
        dom.findPair(map, "roles") != null or
        dom.findPair(map, "pre_tasks") != null or
        dom.findPair(map, "post_tasks") != null) return .play_vars;
    if (dom.findPair(map, "block") != null or
        dom.findPair(map, "rescue") != null or
        dom.findPair(map, "always") != null) return .block_vars;
    return .task_vars;
}

fn isModuleKey(key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, key, name)) return true;
    if (key.len > name.len + 1 and key[key.len - name.len - 1] == '.') {
        return std.mem.endsWith(u8, key, name);
    }
    return false;
}

fn addMapKeys(
    map: *const Node,
    site: Site,
    out: *std.array_list.Managed(Definition),
) !void {
    for (map.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        try out.append(.{ .name = name, .start = key.start, .end = key.end, .site = site });
    }
}

fn addScalar(
    node: *const Node,
    text: []const u8,
    site: Site,
    out: *std.array_list.Managed(Definition),
) !void {
    const name = node.stringValue() orelse return;
    const range = scalarRange(node, text, name);
    try out.append(.{ .name = name, .start = range.start, .end = range.end, .site = site });
}

/// Range of `name` within a scalar node's raw source, so quoted values report
/// the identifier without the quotes.
pub fn scalarRange(node: *const Node, text: []const u8, name: []const u8) struct { start: usize, end: usize } {
    if (node.end <= text.len and node.start <= node.end) {
        const raw = text[node.start..node.end];
        if (std.mem.indexOf(u8, raw, name)) |off| {
            return .{ .start = node.start + off, .end = node.start + off + name.len };
        }
        // Escaped spellings need not contain the decoded name verbatim. Their
        // source span still selects the key contents, never its YAML quotes.
        if (raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"') and raw[raw.len - 1] == raw[0]) {
            return .{ .start = node.start + 1, .end = node.end - 1 };
        }
    }
    return .{ .start = node.start, .end = node.end };
}

const testing = std.testing;
const yaml = @import("../yaml/root.zig");

fn collectGeneral(src: []const u8) ![]Definition {
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    var list = std.array_list.Managed(Definition).init(testing.allocator);
    errdefer list.deinit();
    try collect(testing.allocator, &forest, .general, &list);
    return list.toOwnedSlice();
}

test "vars, set_fact, register, loop_var" {
    const src =
        \\- hosts: all
        \\  vars:
        \\    play_var: 1
        \\  tasks:
        \\    - name: t
        \\      vars:
        \\        task_var: 2
        \\      set_fact:
        \\        fact_var: 3
        \\      register: reg_var
        \\      loop: [1, 2]
        \\      loop_control:
        \\        loop_var: item_var
        \\
    ;
    const defs = try collectGeneral(src);
    defer testing.allocator.free(defs);
    try testing.expectEqual(@as(usize, 5), defs.len);
    try testing.expectEqualStrings("play_var", defs[0].name);
    try testing.expectEqual(Site.play_vars, defs[0].site);
    try testing.expectEqualStrings("task_var", defs[1].name);
    try testing.expectEqual(Site.task_vars, defs[1].site);
    try testing.expectEqualStrings("fact_var", defs[2].name);
    try testing.expectEqual(Site.set_fact, defs[2].site);
    try testing.expectEqualStrings("reg_var", defs[3].name);
    try testing.expectEqual(Site.register, defs[3].site);
    try testing.expectEqualStrings("item_var", defs[4].name);
    try testing.expectEqual(Site.loop_var, defs[4].site);
}

test "role defaults top-level keys" {
    const src =
        \\foo: 1
        \\bar:
        \\  nested: 2
        \\
    ;
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    var list = std.array_list.Managed(Definition).init(testing.allocator);
    defer list.deinit();
    try collect(testing.allocator, &forest, .role_defaults, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("foo", list.items[0].name);
    try testing.expectEqualStrings("bar", list.items[1].name);
}

test "argument_specs options" {
    const src =
        \\argument_specs:
        \\  main:
        \\    options:
        \\      foo:
        \\        type: str
        \\      bar:
        \\        type: int
        \\
    ;
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    var list = std.array_list.Managed(Definition).init(testing.allocator);
    defer list.deinit();
    try collect(testing.allocator, &forest, .role_meta, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("foo", list.items[0].name);
    try testing.expectEqualStrings("bar", list.items[1].name);
}

test "role invocation params" {
    const src =
        \\- hosts: all
        \\  roles:
        \\    - role: myrole
        \\      foo: bar
        \\      become: true
        \\
    ;
    const defs = try collectGeneral(src);
    defer testing.allocator.free(defs);
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("foo", defs[0].name);
    try testing.expectEqual(Site.role_param, defs[0].site);
}

test "vars_prompt names" {
    const src =
        \\- hosts: all
        \\  vars_prompt:
        \\    - name: username
        \\      prompt: "Enter"
        \\
    ;
    const defs = try collectGeneral(src);
    defer testing.allocator.free(defs);
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("username", defs[0].name);
    try testing.expectEqual(Site.vars_prompt, defs[0].site);
}
