//! Literal mapping keys inside recognized variable value bindings.
const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const definitions = @import("definitions.zig");

pub const Definition = struct {
    name: []const u8,
    start: usize,
    end: usize,
    site: definitions.Site,
    /// Root variable, followed by mapping keys; list elements add no component.
    path: []const []const u8,
};

/// Every concrete field key below a recognized root binding. Names and paths
/// are owned by `a`, not the YAML forest, so index facts can outlive the parse.
pub fn collect(a: Allocator, forest: *const yaml.Forest, file_path: []const u8, kind: definitions.FileKind, out: *std.array_list.Managed(Definition)) !void {
    if (kind == .general and isMetadata(file_path)) return;
    var roots = std.array_list.Managed(definitions.Definition).init(a);
    defer roots.deinit();
    try definitions.collect(a, forest, kind, &roots);
    for (roots.items) |root_def| {
        for (forest.roots) |root| {
            const pair = pairWithKeyAt(root, root_def.start) orelse continue;
            const value = pair.val orelse continue;
            const fields = if (root_def.site == .argument_specs) optionsOf(value) orelse continue else value;
            const root_name = try a.dupe(u8, root_def.name);
            try valueKeys(a, fields, forest.text, root_def.site, &.{root_name}, out);
            break;
        }
    }
}

/// Only an option's nested `options:` declares fields; schema properties such
/// as `type`, `description`, and `default` are not variable mapping keys.
fn optionsOf(node: *const yaml.Node) ?*const yaml.Node {
    if (!node.isMap()) return null;
    return (yaml.dom.findPair(node, "options") orelse return null).val;
}

fn isMetadata(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    for ([_][]const u8{ "requirements.yml", "requirements.yaml", "execution-environment.yml", "execution-environment.yaml", "galaxy.yml", "galaxy.yaml" }) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    const parent = std.fs.path.dirname(path) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(parent), "meta")) return false;
    for ([_][]const u8{ "main.yml", "main.yaml", "runtime.yml", "runtime.yaml", "argument_specs.yml", "argument_specs.yaml" }) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return false;
}

fn pairWithKeyAt(node: *const yaml.Node, start: usize) ?*const yaml.Node {
    switch (node.kind) {
        .map, .seq => for (node.items) |item| {
            if (pairWithKeyAt(item, start)) |pair| return pair;
        },
        .pair => {
            if (node.key) |key| if (key.start <= start and start < key.end) return node;
            if (node.val) |value| return pairWithKeyAt(value, start);
        },
        else => {},
    }
    return null;
}

fn valueKeys(a: Allocator, node: *const yaml.Node, text: []const u8, site: definitions.Site, parent: []const []const u8, out: *std.array_list.Managed(Definition)) !void {
    switch (node.kind) {
        .map => for (node.items) |pair| {
            const key = pair.key orelse continue;
            const name = key.stringValue() orelse continue;
            if (name.len == 0) continue;
            const path = try a.alloc([]const u8, parent.len + 1);
            @memcpy(path[0..parent.len], parent);
            path[parent.len] = try a.dupe(u8, name);
            const range = definitions.scalarRange(key, text, name);
            try out.append(.{
                .name = path[parent.len],
                .start = range.start,
                .end = range.end,
                .site = site,
                .path = path,
            });
            if (pair.val) |value| {
                const children = if (site == .argument_specs) optionsOf(value) orelse continue else value;
                try valueKeys(a, children, text, site, path, out);
            }
        },
        .seq => for (node.items) |item| try valueKeys(a, item, text, site, parent, out),
        else => {},
    }
}
