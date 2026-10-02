//! Independent, read-only field-expression contract at the public stdio LSP seam.
//! Oracles are authored spans, never discovered from server output or fixture scans.
const std = @import("std");
const m = @import("e2e/model.zig");
const anchor = @import("e2e/anchor.zig");
const lsp = @import("e2e/client.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const defaults = "roles/expressions/defaults/main.yml";
const tasks = "roles/expressions/tasks/main.yml";

const quoted_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 {{ record.<field_name> }} /"),
    m.span(tasks, "{{ other['<field_name>'] }}"),
    m.span(tasks, "{{ spare[\"<field_name>\"] }}"),
};
const quoted_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 {{ record.<field_name> }} /"),
    m.span(tasks, "{{ other['<field_name>'] }}"),
    m.span(tasks, "{{ spare[\"<field_name>\"] }}"),
    m.span(defaults, "  - <field_name>: first"),
    m.span(defaults, "  <field_name>: second"),
};

test "stdio static quoted subscripts share the dot-read and binding-key field group" {
    try checkGroup(&.{
        m.cursor(tasks, "🛰 {{ record.<field_name> }} /"),
        m.cursor(tasks, "{{ other['<field_name>'] }}"),
        m.cursor(tasks, "{{ spare[\"<field_name>\"] }}"),
        m.cursor(defaults, "  - <field_name>: first"),
        m.cursor(defaults, "  <field_name>: second"),
    }, quoted_reads, quoted_with_definitions);
}

/// Both reference modes have separate, complete written answers. Every origin
/// sees the same Workspace-wide leaf-NAME group, not receiver object identity.
fn checkGroup(origins: []const m.Anchor, reads: []const m.ExpectedLocation, with_definitions: []const m.ExpectedLocation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/field-expressions-workspace");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var temp_home = std.testing.tmpDir(.{});
    defer temp_home.cleanup();
    const home = try temp_home.dir.realpathAlloc(a, ".");
    var client = try lsp.Client.startWithOptions(a, binary, fixture, fixture, home, .{
        .collections_path = fixture,
    });
    defer client.deinit();
    const init_result = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{}, // Default UTF-16.
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    const caps = lsp.field(init_result, "capabilities") orelse return error.MissingCapabilities;
    const references = lsp.field(caps, "referencesProvider") orelse return error.MissingReferencesProvider;
    try std.testing.expect(references == .bool and references.bool);
    if (lsp.field(caps, "positionEncoding")) |encoding| {
        try std.testing.expect(encoding == .string);
        try std.testing.expectEqualStrings("utf-16", encoding.string);
    }
    try client.notify("initialized", .{});
    try client.waitForIndex();

    const resolver: anchor.Resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture };
    var opened = std.StringHashMap(void).init(a);
    var failures: usize = 0;
    for (origins) |origin| {
        const source = try resolver.cursor(origin);
        if (!opened.contains(origin.path)) {
            try client.notify("textDocument/didOpen", .{ .textDocument = .{
                .uri = source.uri,
                .languageId = if (std.mem.endsWith(u8, origin.path, ".j2")) "jinja2" else "yaml",
                .version = @as(u32, 1),
                .text = try resolver.readText(origin.path),
            } });
            try opened.put(origin.path, {});
        }
        // Never derive one oracle by adding/removing declarations from another.
        const modes = [_]struct { include: bool, expected: []const m.ExpectedLocation }{
            .{ .include = false, .expected = reads },
            .{ .include = true, .expected = with_definitions },
        };
        for (modes) |mode| {
            const result = try client.request("textDocument/references", .{
                .textDocument = .{ .uri = source.uri },
                .position = source.position,
                .context = .{ .includeDeclaration = mode.include },
            });
            const actual = try parseLocations(a, result);
            const expected = try a.alloc(anchor.Location, mode.expected.len);
            for (mode.expected, 0..) |location, i| expected[i] = try resolver.location(location);
            std.mem.sort(anchor.Location, actual, {}, locationLessThan);
            std.mem.sort(anchor.Location, expected, {}, locationLessThan);
            expectLocations(expected, actual) catch |err| {
                std.debug.print("FAIL {s}: {s} (includeDeclaration={}): {s}\n", .{
                    origin.path, origin.snippet, mode.include, @errorName(err),
                });
                printLocations("expected", expected);
                printLocations("actual", actual);
                failures += 1;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn parseLocations(a: Allocator, result: Value) ![]anchor.Location {
    return switch (result) {
        .null => &.{},
        .array => |items| blk: {
            const locations = try a.alloc(anchor.Location, items.items.len);
            for (items.items, 0..) |item, i| {
                locations[i] = try std.json.parseFromValueLeaky(anchor.Location, a, item, .{});
            }
            break :blk locations;
        },
        else => error.InvalidReferenceResult,
    };
}

fn expectLocations(expected: []const anchor.Location, actual: []const anchor.Location) !void {
    // Compare complete lists, preserving duplicates, not set membership/counts.
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left.uri, right.uri);
        try std.testing.expectEqualDeep(left.range, right.range);
    }
}

fn printLocations(label: []const u8, locations: []const anchor.Location) void {
    std.debug.print("  {s} ({d}):\n", .{ label, locations.len });
    for (locations) |location| std.debug.print("    {s} {d}:{d}-{d}:{d}\n", .{
        location.uri,            location.range.start.line,    location.range.start.character,
        location.range.end.line, location.range.end.character,
    });
}

fn locationLessThan(_: void, left: anchor.Location, right: anchor.Location) bool {
    const uri_order = std.mem.order(u8, left.uri, right.uri);
    if (uri_order != .eq) return uri_order == .lt;
    if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
    if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
    if (left.range.end.line != right.range.end.line) return left.range.end.line < right.range.end.line;
    return left.range.end.character < right.range.end.character;
}
