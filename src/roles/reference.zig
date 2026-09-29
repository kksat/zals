//! Detect a role-name reference at a cursor path.
//!
//! Recognised forms (cursor must be on the role-name *value*, not the key):
//! - `roles:` string entry (`- demo`) and map entry (`- role: demo`)
//! - `include_role` / `import_role` `name:` (map form and `name=demo` k=v form)
//! - `meta/main.yml` `dependencies:` string and `role:`/`name:` map entries
//! - `requirements.yml` `roles:` string, `name:`, and `src:` entries (a `src:`
//!   that is a URL, git, or path source is not a role name)
//!
//! Jinja-valued names (`"{{ my_role }}"`) are not references; the variable
//! provider handles them.

const std = @import("std");
const dom = @import("../yaml/dom.zig");
const Node = dom.Node;

pub const Reference = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

/// If `path` points at a role-name scalar, return its name and byte range.
/// `name` borrows from the forest arena or its source text.
pub fn detect(path: []*Node, text: []const u8) ?Reference {
    if (path.len < 2) return null;
    const node = path[path.len - 1];
    if (!node.isScalar()) return null;
    const parent = path[path.len - 2];

    // Cursor on a pair value.
    if (parent.isPair() and parent.val == node) {
        const key = keyOf(parent) orelse return null;
        if (isModuleKey(key, "include_role") or isModuleKey(key, "import_role")) {
            return kvRoleName(node, text);
        }
        const listed = inList(path, "roles") or inList(path, "dependencies");
        if (std.mem.eql(u8, key, "role")) {
            if (listed) return scalarRef(node, text);
        }
        if (std.mem.eql(u8, key, "name")) {
            if (inRoleModule(path) or listed) return scalarRef(node, text);
        }
        if (std.mem.eql(u8, key, "src")) {
            if (listed) {
                const value = node.stringValue() orelse return null;
                if (isSource(value)) return null;
                return scalarRef(node, text);
            }
        }
        return null;
    }

    // Cursor on a sequence item scalar (string form).
    if (parent.isSeq()) {
        if (path.len < 3) return null;
        const seq_pair = path[path.len - 3];
        if (!seq_pair.isPair()) return null;
        const key = keyOf(seq_pair) orelse return null;
        if (std.mem.eql(u8, key, "roles") or std.mem.eql(u8, key, "dependencies")) {
            return scalarRef(node, text);
        }
    }
    return null;
}

/// Whether the map holding the `role:` pair is an item of a `roles:` or
/// `dependencies:` sequence.
fn inList(path: []*Node, key: []const u8) bool {
    if (path.len < 5) return false;
    const seq = path[path.len - 4];
    const pair = path[path.len - 5];
    if (!seq.isSeq() or !pair.isPair()) return false;
    const k = keyOf(pair) orelse return false;
    return std.mem.eql(u8, k, key);
}

/// Whether the map holding the `name:` pair is the value of an
/// `include_role`/`import_role` key.
fn inRoleModule(path: []*Node) bool {
    if (path.len < 4) return false;
    const pair = path[path.len - 4];
    if (!pair.isPair()) return false;
    const k = keyOf(pair) orelse return false;
    return isModuleKey(k, "include_role") or isModuleKey(k, "import_role");
}

fn keyOf(pair: *Node) ?[]const u8 {
    const k = pair.key orelse return null;
    return k.stringValue();
}

fn scalarRef(node: *Node, text: []const u8) ?Reference {
    const name = node.stringValue() orelse return null;
    if (name.len == 0 or isJinja(name)) return null;
    const raw = rawText(node, text);
    const off = std.mem.indexOf(u8, raw, name) orelse return null;
    return .{ .name = name, .start = node.start + off, .end = node.start + off + name.len };
}

/// Parse the `name=demo` k=v form of `include_role`/`import_role`.
fn kvRoleName(node: *Node, text: []const u8) ?Reference {
    var raw = rawText(node, text);
    var base = node.start;
    // A whole-scalar quote wraps the k=v pairs: `"name=demo"`.
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) {
        raw = raw[1 .. raw.len - 1];
        base += 1;
    }
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |token| {
        if (!std.mem.startsWith(u8, token, "name=")) continue;
        var value = token["name=".len..];
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0 or isJinja(value)) return null;
        const off = std.mem.indexOf(u8, raw, value) orelse return null;
        return .{ .name = value, .start = base + off, .end = base + off + value.len };
    }
    return null;
}

fn rawText(node: *Node, text: []const u8) []const u8 {
    if (node.end <= text.len and node.start <= node.end) return text[node.start..node.end];
    return "";
}

/// A requirements `src:` that names a download location, not a role.
fn isSource(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "://") != null) return true;
    if (std.mem.startsWith(u8, s, "git+") or std.mem.startsWith(u8, s, "git@")) return true;
    if (std.mem.indexOfAny(u8, s, "/,") != null) return true;
    return std.mem.endsWith(u8, s, ".tar.gz") or std.mem.endsWith(u8, s, ".tgz");
}

fn isJinja(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "{{") != null or std.mem.indexOf(u8, s, "{%") != null;
}

fn isModuleKey(key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, key, name)) return true;
    if (key.len > name.len + 1 and key[key.len - name.len - 1] == '.') {
        return std.mem.endsWith(u8, key, name);
    }
    return false;
}

const testing = std.testing;
const yaml = @import("../yaml/root.zig");

/// Detect at the first occurrence of `needle` and return a duped name.
fn detectName(src: []const u8, needle: []const u8) !?[]const u8 {
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    const off = std.mem.indexOf(u8, src, needle) orelse return null;
    const path = (try yaml.getPathAt(forest.allocator(), forest.roots[0], off, true)) orelse return null;
    const ref = detect(path, forest.text) orelse return null;
    return try testing.allocator.dupe(u8, ref.name);
}

fn expectName(src: []const u8, needle: []const u8, expected: []const u8) !void {
    const name = (try detectName(src, needle)) orelse return error.NotFound;
    defer testing.allocator.free(name);
    try testing.expectEqualStrings(expected, name);
}

test "roles string form" {
    try expectName("- hosts: all\n  roles:\n    - demo\n", "demo", "demo");
}

test "roles map form" {
    try expectName("- hosts: all\n  roles:\n    - role: demo\n", "demo", "demo");
}

test "include_role map form" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - include_role:
        \\        name: demo
        \\
    ;
    try expectName(src, "demo", "demo");
}

test "import_role map form" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - ansible.builtin.import_role:
        \\        name: demo
        \\
    ;
    try expectName(src, "demo", "demo");
}

test "include_role k=v form" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - include_role: name=demo
        \\
    ;
    try expectName(src, "demo", "demo");
}

test "include_role k=v form quoted" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - include_role: "name=demo"
        \\
    ;
    try expectName(src, "demo", "demo");
}

test "dependencies string form" {
    try expectName("dependencies:\n  - demo\n", "demo", "demo");
}

test "dependencies map form" {
    try expectName("dependencies:\n  - role: demo\n", "demo", "demo");
}

test "jinja name is skipped" {
    const src = "- hosts: all\n  roles:\n    - \"{{ my_role }}\"\n";
    try testing.expect((try detectName(src, "my_role")) == null);
}

test "cursor on key is not a reference" {
    const src = "- hosts: all\n  roles:\n    - role: demo\n";
    try testing.expect((try detectName(src, "role:")) == null);
}

test "task name is not a role reference" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - name: demo
        \\      ping:
        \\
    ;
    try testing.expect((try detectName(src, "demo")) == null);
}

test "requirements roles entries" {
    try expectName("roles:\n  - geerlingguy.nginx\n", "geerlingguy", "geerlingguy.nginx");
    try expectName("roles:\n  - name: geerlingguy.nginx\n", "geerlingguy", "geerlingguy.nginx");
    try expectName("roles:\n  - src: geerlingguy.nginx\n", "geerlingguy", "geerlingguy.nginx");
    const url = "roles:\n  - src: https://github.com/x/role.git\n";
    try testing.expect((try detectName(url, "https")) == null);
}

test "dependencies name entry" {
    try expectName("dependencies:\n  - name: common\n", "common", "common");
}
