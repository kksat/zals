//! Per-file navigation facts stored in the Workspace index (ADR-0031).
//!
//! `extract` parses one file and records names and byte ranges only, so an
//! entry never keeps a parse tree. Every string is allocated with the caller's
//! allocator (an entry arena).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");

pub const Definition = variables.definitions.Definition;

/// A named occurrence and its byte range.
pub const Span = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

pub const Facts = struct {
    var_defs: []const Definition = &.{},
    var_refs: []const Span = &.{},
};

/// Facts for the file at `path` with contents `text`.
pub fn extract(a: Allocator, path: []const u8, text: []const u8) !Facts {
    var forest = yaml.parse(a, text) catch return .{};
    defer forest.deinit();

    var defs = std.array_list.Managed(Definition).init(a);
    variables.definitions.collect(a, &forest, variables.scope.fileKind(path), &defs) catch {};
    for (defs.items) |*d| d.name = try a.dupe(u8, d.name);

    var idents = std.array_list.Managed(variables.jinja.Ident).init(a);
    variables.index.collectReferences(a, &forest, &idents) catch {};
    const refs = try a.alloc(Span, idents.items.len);
    for (idents.items, 0..) |r, i| refs[i] = .{ .name = try a.dupe(u8, r.name), .start = r.start, .end = r.end };

    return .{
        .var_defs = try defs.toOwnedSlice(),
        .var_refs = refs,
    };
}

const testing = std.testing;

test "extract records variable definitions and references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\- hosts: all
        \\  vars:
        \\    app_port: 8080
        \\  tasks:
        \\    - debug: msg="{{ app_port }}"
        \\
    ;
    const f = try extract(a, "/w/site.yml", text);
    try testing.expectEqual(@as(usize, 1), f.var_defs.len);
    try testing.expectEqualStrings("app_port", f.var_defs[0].name);
    try testing.expectEqual(@as(usize, 1), f.var_refs.len);
    try testing.expectEqualStrings("app_port", f.var_refs[0].name);
}
