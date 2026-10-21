//! Variable occurrences in one YAML document (ADR-0024, ADR-0025, ADR-0041):
//! Jinja root and field reads, and the occurrence under a cursor in an
//! already-parsed forest. Searches over many files run on Workspace facts
//! (`workspace/view.zig`), for a Workspace and for a Role or Playbook scope
//! alike.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../yaml/dom.zig");
const Node = dom.Node;
const jinja = @import("jinja.zig");
const scalar_expression = @import("scalar_expression.zig");
const definitions_mod = @import("definitions.zig");
const scope = @import("scope.zig");
const roles = @import("../roles/resolve.zig");

pub const Definition = definitions_mod.Definition;
pub const Site = definitions_mod.Site;

pub const OccurrenceKind = enum { definition, reference };

pub const Cursor = struct {
    name: []const u8,
    kind: OccurrenceKind,
    /// Byte range of this occurrence. `end` is exclusive. Zero when a caller
    /// only needed the name.
    start: usize = 0,
    end: usize = 0,
    /// A key that binds only if a vars load targets its file (ADR-0045). The
    /// caller decides, because loads live in other files.
    requires_load: bool = false,
};

/// The variable occurrence under `offset` in an already-parsed `forest`.
///
/// Names borrow `forest` or normalization storage owned by `a`; keep both
/// alive while using the cursor. Used by providers that parse the document
/// once and need both the variable and its YAML context.
pub fn occurrenceInForest(
    a: Allocator,
    forest: *const dom.Forest,
    path: []const u8,
    offset: usize,
) !?Cursor {
    var defs = std.array_list.Managed(Definition).init(a);
    try definitions_mod.collect(a, forest, scope.fileKind(path, roles.enclosingRole(path)), &defs);
    for (defs.items) |d| {
        if (d.start <= offset and offset <= d.end) {
            return .{ .name = d.name, .kind = .definition, .start = d.start, .end = d.end };
        }
    }
    var refs = std.array_list.Managed(jinja.Ident).init(a);
    for (forest.roots) |root| try collectRefs(a, root, forest.text, &refs);
    for (refs.items) |r| {
        if (r.start <= offset and offset <= r.end) {
            return .{ .name = r.name, .kind = .reference, .start = r.start, .end = r.end };
        }
    }
    return null;
}

fn isBareExprKey(key: []const u8) bool {
    const set = [_][]const u8{ "when", "changed_when", "failed_when", "until", "loop", "that" };
    for (set) |s| if (std.mem.eql(u8, key, s)) return true;
    return std.mem.startsWith(u8, key, "with_");
}

fn collectRefs(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
) !void {
    try walkRefs(a, node, text, out, false, .roots);
}

/// Every variable reference in `forest`: Jinja root identifiers and names in
/// bare-expression keys.
pub fn collectReferences(a: Allocator, forest: *const dom.Forest, out: *std.array_list.Managed(jinja.Ident)) !void {
    for (forest.roots) |root| try collectRefs(a, root, forest.text, out);
}

pub fn collectFieldReferences(a: Allocator, forest: *const dom.Forest, out: *std.array_list.Managed(jinja.Ident)) !void {
    for (forest.roots) |root| try walkRefs(a, root, forest.text, out, false, .fields);
}

const RefNames = scalar_expression.Names;

fn walkRefs(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
    bare: bool,
    names: RefNames,
) !void {
    switch (node.kind) {
        .map => {
            for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse continue else continue;
                const val = pair.val orelse continue;
                const is_bare = isBareExprKey(key);
                if (is_bare) try scanBare(a, val, text, out, names);
                try walkRefs(a, val, text, out, is_bare, names);
            }
        },
        .seq => for (node.items) |item| try walkRefs(a, item, text, out, bare, names),
        .scalar => if (!bare) try scalar_expression.scan(a, node, text, names, false, out),
        else => {},
    }
}

fn scanBare(
    a: Allocator,
    node: *const Node,
    text: []const u8,
    out: *std.array_list.Managed(jinja.Ident),
    names: RefNames,
) !void {
    if (node.isScalar()) {
        try scalar_expression.scan(a, node, text, names, true, out);
    } else if (node.isSeq()) {
        for (node.items) |item| {
            if (!item.isScalar()) continue;
            try scalar_expression.scan(a, item, text, names, true, out);
        }
    }
}
