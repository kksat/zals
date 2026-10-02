//! A separate stdio scenario for open-document overlays. The static semantic
//! navigation runner remains read-only; this scenario edits buffers, not disk.
const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const m = @import("e2e/model.zig");

const play = "playbooks/role-inputs.yml";
const spec_path = "ansible_collections/fixture/inputs/roles/receiver/meta/argument_specs.yml";
const unsaved_spec =
    \\# Unsaved argument-spec documentation
    \\# The option moved from its indexed disk position.
    \\argument_specs:
    \\  main:
    \\    options:
    \\      input_value:
    \\        type: str
    \\        description: Unsaved receiver input
    \\
;

test "role parameter navigation prefers unsaved argument specs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/e2e-workspace");
    const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var temp_home = std.testing.tmpDir(.{});
    defer temp_home.cleanup();
    const home = try temp_home.dir.realpathAlloc(a, ".");
    var client = try lsp.Client.start(a, binary, fixture, deps, home);
    defer client.deinit();
    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false },
        } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();
    const resolver = anchor.Resolver{ .allocator = a, .fixture = fixture, .deps = deps };
    const source = try resolver.cursor(m.cursor(play, "<input_value>: from-include"));
    try client.notify("textDocument/didOpen", .{ .textDocument = .{
        .uri = source.uri,
        .languageId = "yaml",
        .version = @as(u32, 1),
        .text = try resolver.readText(play),
    } });
    const spec_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, spec_path });
    try client.notify("textDocument/didOpen", .{ .textDocument = .{
        .uri = spec_uri,
        .languageId = "yaml",
        .version = @as(u32, 1),
        .text = unsaved_spec,
    } });
    const params = .{ .textDocument = .{ .uri = source.uri }, .position = source.position };
    const definition = try client.request("textDocument/definition", params);
    const loc = if (definition == .array and definition.array.items.len == 1) definition.array.items[0] else definition;
    const uri = lsp.field(loc, "uri") orelse return error.MissingLocationUri;
    try std.testing.expectEqualStrings(spec_uri, uri.string);
    const range = lsp.field(loc, "range") orelse return error.MissingLocationRange;
    const start = lsp.field(range, "start") orelse return error.MissingRangeStart;
    const end = lsp.field(range, "end") orelse return error.MissingRangeEnd;
    // Independently written coordinates in the controlled unsaved buffer.
    try std.testing.expectEqual(@as(i64, 5), (lsp.field(start, "line") orelse return error.MissingLine).integer);
    try std.testing.expectEqual(@as(i64, 6), (lsp.field(start, "character") orelse return error.MissingCharacter).integer);
    try std.testing.expectEqual(@as(i64, 5), (lsp.field(end, "line") orelse return error.MissingLine).integer);
    try std.testing.expectEqual(@as(i64, 17), (lsp.field(end, "character") orelse return error.MissingCharacter).integer);
    const hover = try client.request("textDocument/hover", params);
    const contents = lsp.field(hover, "contents") orelse return error.MissingHoverContents;
    const text = lsp.field(contents, "value") orelse return error.MissingMarkupValue;
    try std.testing.expect(std.mem.indexOf(u8, text.string, "Unsaved receiver input") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.string, "Main receiver input") == null);
}
