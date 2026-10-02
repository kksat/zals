//! Controlled unsaved buffers, never fixture mutations, at the public stdio seam.
const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const m = @import("e2e/model.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const play = "playbooks/field-inputs.yml";
const receiver = "ansible_collections/fixture/inputs/roles/receiver/";
const other = "ansible_collections/fixture/other/roles/receiver/";
const spec_path = receiver ++ "meta/argument_specs.yml";
const vars_path = receiver ++ "vars/main.yml";
const unsaved_spec =
    \\# Unsaved field contract
    \\# Shifted and quoted key
    \\argument_specs:
    \\  main:
    \\    options:
    \\      input_config:
    \\        type: dict
    \\        options:
    \\          endpoint:
    \\            type: dict
    \\            options:
    \\              "region_name":
    \\                type: str
    \\                description: Unsaved endpoint region contract.
    \\
;
const unsaved_vars =
    \\# Unsaved concrete field value
    \\input_value: receiver-vars
    \\input_config:
    \\  endpoint:
    \\    "region_name": unsaved-region-value
    \\
;
const reads: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(receiver ++ "tasks/setup.yaml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(other ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(play, "{{ local.<region_name> }}"),
};
// Complete unchanged disk sites in the declarations-on oracle, independently
// enumerated rather than derived from the reads-only answer. Two explicitly
// authored buffer coordinates are appended below, not disk schema/vars sites.
const unchanged_sites: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(receiver ++ "tasks/setup.yaml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(other ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(play, "{{ local.<region_name> }}"),
    m.span(play, "          <region_name>: passed-role-map-region"),
    m.span(play, "            <region_name>: passed-role-vars-region"),
    m.span(play, "            <region_name>: passed-main-region"),
    m.span(play, "            <region_name>: passed-setup-region"),
    m.span(play, "            <region_name>: passed-kv-region"),
    m.span(play, "            <region_name>: passed-other-region"),
    m.span(play, "              <region_name>: passed-list-region"),
    m.span(play, "            \"<region_name>\": passed-yaml-region"),
    m.span(play, "            <region_name>: unresolved-region"),
    m.span(play, "            <region_name>: wrong-path-region"),
    m.span(play, "            <region_name>: non-role-vars-region"),
    m.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default"),
    m.span(receiver ++ "defaults/main.yml", "    <region_name>: wrong-root-region"),
    m.span(receiver ++ "defaults/main.yml", "      <region_name>: receiver-list-region"),
    m.span(other ++ "defaults/main.yml", "    <region_name>: other-region-default"),
    m.span("roles/yaml_receiver/defaults/main.yaml", "    \"<region_name>\": yaml-region-default"),
    m.span(other ++ "meta/argument_specs.yml", "              <region_name>:\n                type: str\n                description: Other endpoint region contract."),
    m.span("roles/yaml_receiver/meta/main.yaml", "              \"<region_name>\":\n                type: str\n                description: YAML endpoint region contract."),
};

test "passed field actions and Workspace references prefer changed schema and value buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/e2e-workspace");
    const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    const home = try home_dir.dir.realpathAlloc(a, ".");
    var client = try lsp.Client.start(a, binary, fixture, deps, home);
    defer client.deinit();
    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{ .workspace = .{ .rootMarker = "fixture-workspace-root" }, .python = .{ .venvPath = "" }, .validation = .{ .enabled = false } } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();
    const resolver = anchor.Resolver{ .allocator = a, .fixture = fixture, .deps = deps };
    const caller = try resolver.cursor(m.cursor(play, "            <region_name>: passed-main-region"));
    try open(&client, caller.uri, try resolver.readText(play));
    const spec_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, spec_path });
    const vars_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, vars_path });
    try open(&client, spec_uri, try resolver.readText(spec_path));
    try open(&client, vars_uri, try resolver.readText(vars_path));
    try change(&client, spec_uri, unsaved_spec);
    try change(&client, vars_uri, unsaved_vars);

    // Exact independently written UTF-16 spans in the controlled buffers.
    const schema: anchor.Location = .{ .uri = spec_uri, .range = .{ .start = .{ .line = 11, .character = 15 }, .end = .{ .line = 11, .character = 26 } } };
    const concrete: anchor.Location = .{ .uri = vars_uri, .range = .{ .start = .{ .line = 4, .character = 5 }, .end = .{ .line = 4, .character = 16 } } };
    const params = .{ .textDocument = .{ .uri = caller.uri }, .position = caller.position };
    try expectLocations(&.{schema}, try locations(a, try client.request("textDocument/definition", params)));
    const default_location = try resolver.location(m.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default"));
    try expectLocations(&.{ concrete, default_location }, try locations(a, try client.request("textDocument/implementation", params)));
    const hover = try client.request("textDocument/hover", params);
    const hover_range = try std.json.parseFromValueLeaky(anchor.Range, a, lsp.field(hover, "range") orelse return error.MissingHoverRange, .{});
    const caller_location = try resolver.location(m.span(play, "            <region_name>: passed-main-region"));
    try std.testing.expectEqualDeep(caller_location.range, hover_range);
    const contents = lsp.field(hover, "contents") orelse return error.MissingContents;
    const text = (lsp.field(contents, "value") orelse return error.MissingMarkup).string;
    try std.testing.expect(std.mem.indexOf(u8, text, "Unsaved endpoint region contract.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Main endpoint region contract.") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Wrong root region contract.") == null);

    const expected_reads = try resolve(a, resolver, reads);
    var with_declarations = std.array_list.Managed(anchor.Location).init(a);
    try with_declarations.appendSlice(try resolve(a, resolver, unchanged_sites));
    try with_declarations.append(schema);
    try with_declarations.append(concrete);
    std.mem.sort(anchor.Location, expected_reads, {}, lessLocation);
    std.mem.sort(anchor.Location, with_declarations.items, {}, lessLocation);
    const origins = [_]anchor.Cursor{
        caller,
        .{ .uri = spec_uri, .position = .{ .line = 11, .character = 25 } },
        .{ .uri = vars_uri, .position = .{ .line = 4, .character = 15 } },
    };
    for (origins) |origin| {
        const modes = [_]struct { include: bool, expected: []const anchor.Location }{
            .{ .include = false, .expected = expected_reads },
            .{ .include = true, .expected = with_declarations.items },
        };
        for (modes) |mode| {
            const response = try client.request("textDocument/references", .{ .textDocument = .{ .uri = origin.uri }, .position = origin.position, .context = .{ .includeDeclaration = mode.include } });
            const actual = try locations(a, response);
            std.mem.sort(anchor.Location, actual, {}, lessLocation);
            try expectLocations(mode.expected, actual);
        }
    }
}

test "passed field implementations use callee vars-load facts from unsaved task and value buffers" {
    try calleeLoadScenario("playbooks/vars/reserved.yml",
        \\# Unsaved loaded dictionary
        \\input_config:
        \\  endpoint:
        \\    "region_name": loaded-callee-region
        \\
    , .{ .start = .{ .line = 3, .character = 5 }, .end = .{ .line = 3, .character = 16 } });
}

test "passed field implementations retain explicit JSON vars loads and their unsaved buffers" {
    try calleeLoadScenario("playbooks/vars/receiver-field-values.json",
        \\{
        \\  "input_config": {
        \\    "endpoint": {
        \\      "region_name": "loaded-json-buffer"
        \\    }
        \\  }
        \\}
        \\
    , .{ .start = .{ .line = 3, .character = 7 }, .end = .{ .line = 3, .character = 18 } });
}

fn calleeLoadScenario(load_path: []const u8, buffer: []const u8, expected_range: anchor.Range) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/e2e-workspace");
    const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    const home = try home_dir.dir.realpathAlloc(a, ".");
    var client = try lsp.Client.start(a, binary, fixture, deps, home);
    defer client.deinit();
    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{ .workspace = .{ .rootMarker = "fixture-workspace-root" }, .python = .{ .venvPath = "" }, .validation = .{ .enabled = false } } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();
    const resolver = anchor.Resolver{ .allocator = a, .fixture = fixture, .deps = deps };
    const caller = try resolver.cursor(m.cursor(play, "            <region_name>: passed-main-region"));
    try open(&client, caller.uri, try resolver.readText(play));
    const tasks_uri = try std.fmt.allocPrint(a, "file://{s}/{s}tasks/main.yml", .{ fixture, receiver });
    const loaded_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, load_path });
    try open(&client, tasks_uri, try resolver.readText(receiver ++ "tasks/main.yml"));
    try open(&client, loaded_uri, try resolver.readText(load_path));
    try change(&client, tasks_uri, try std.fmt.allocPrint(a, "- name: Unsaved callee load outside its conventional directories\n  include_vars: ../../../../../../{s}\n", .{load_path}));
    try change(&client, loaded_uri, buffer);
    // Independently authored original-buffer UTF-16 coordinates, not learned
    // from the response. Include-vars precedence precedes role vars/defaults.
    const loaded: anchor.Location = .{ .uri = loaded_uri, .range = expected_range };
    const variable = try resolver.location(m.span(vars_path, "    <region_name>: receiver-region-vars"));
    const default = try resolver.location(m.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default"));
    const response = try client.request("textDocument/implementation", .{ .textDocument = .{ .uri = caller.uri }, .position = caller.position });
    try expectLocations(&.{ loaded, variable, default }, try locations(a, response));
}

fn open(client: *lsp.Client, uri: []const u8, text: []const u8) !void {
    try client.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "yaml", .version = @as(u32, 1), .text = text } });
}
fn change(client: *lsp.Client, uri: []const u8, text: []const u8) !void {
    try client.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = @as(u32, 2) }, .contentChanges = &.{.{ .text = text }} });
}
fn resolve(a: Allocator, resolver: anchor.Resolver, sites: []const m.ExpectedLocation) ![]anchor.Location {
    const out = try a.alloc(anchor.Location, sites.len);
    for (sites, 0..) |site, i| out[i] = try resolver.location(site);
    return out;
}
fn locations(a: Allocator, value: Value) ![]anchor.Location {
    if (value == .null) return &.{};
    if (value == .array) {
        const out = try a.alloc(anchor.Location, value.array.items.len);
        for (value.array.items, 0..) |item, i| out[i] = try std.json.parseFromValueLeaky(anchor.Location, a, item, .{});
        return out;
    }
    const out = try a.alloc(anchor.Location, 1);
    out[0] = try std.json.parseFromValueLeaky(anchor.Location, a, value, .{});
    return out;
}
fn expectLocations(expected: []const anchor.Location, actual: []const anchor.Location) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left.uri, right.uri);
        try std.testing.expectEqualDeep(left.range, right.range);
    }
}
fn lessLocation(_: void, left: anchor.Location, right: anchor.Location) bool {
    const order = std.mem.order(u8, left.uri, right.uri);
    if (order != .eq) return order == .lt;
    if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
    if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
    if (left.range.end.line != right.range.end.line) return left.range.end.line < right.range.end.line;
    return left.range.end.character < right.range.end.character;
}
