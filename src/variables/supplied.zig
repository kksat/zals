//! Names whose meaning Ansible or Jinja supplies at runtime: magic and
//! connection variables, implicit loop variables, and template globals.
//! A same-named binding in the Workspace does not make one of these an
//! ordinary user variable, so rewriting its reads changes behavior.

const std = @import("std");

const names = [_][]const u8{
    // Ansible magic variables.
    "group_names",              "groups",         "hostvars",
    "inventory_dir",            "inventory_file", "inventory_hostname",
    "inventory_hostname_short", "omit",           "play_hosts",
    "playbook_dir",             "role_name",      "role_names",
    "role_path",                "item",           "environment",
    // Jinja special names and globals, plus Ansible's template globals.
    "loop",                     "self",           "caller",
    "varargs",                  "kwargs",         "super",
    "range",                    "dict",           "lipsum",
    "cycler",                   "joiner",         "namespace",
    "lookup",                   "query",          "q",
    "now",                      "undef",
};

/// True for names that Ansible or Jinja define themselves. Every `ansible_*`
/// name is reserved for facts, connection, and magic variables.
pub fn isSupplied(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "ansible_")) return true;
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "magic, connection, loop, and template-global names are supplied" {
    for ([_][]const u8{ "item", "hostvars", "inventory_hostname", "ansible_user", "ansible_facts", "loop", "lookup", "range", "omit" }) |name| {
        try std.testing.expect(isSupplied(name));
    }
    for ([_][]const u8{ "app_port", "items", "lookup_path", "my_ansible_user", "ansible" }) |name| {
        try std.testing.expect(!isSupplied(name));
    }
}
