//! End-to-end stdio tests for `textDocument/prepareRename` and `textDocument/rename`
//! on root Ansible variables: quoted/escaped bindings, unsaved buffer overlays,
//! invalid identifier rejection, and non-root-variable exclusions.

const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const m = @import("e2e/model.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const rollout = "playbooks/rollout.yml";
const release = "playbooks/vars/release.yml";
const common = "playbooks/tasks/common.yml";
const preflight = "ansible_collections/example/rollout/roles/preflight/";
const pf_tasks = preflight ++ "tasks/main.yml";
const pf_defaults = preflight ++ "defaults/main.yml";
const pf_vars = preflight ++ "vars/main.yml";
const pf_specs = preflight ++ "meta/argument_specs.yml";

test "quoted and escaped root variable definitions preserve quotes on rename" {
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
    const init_res = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    const caps = lsp.field(init_res, "capabilities") orelse return error.MissingCapabilities;
    const rename_cap = lsp.field(caps, "renameProvider") orelse return error.MissingRenameCapability;
    const prep_cap = lsp.field(rename_cap, "prepareProvider") orelse return error.MissingPrepareCapability;
    try std.testing.expect(prep_cap == .bool and prep_cap.bool);

    try client.notify("initialized", .{});
    try client.waitForIndex();

    const defaults_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, pf_defaults });
    const vars_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, pf_vars });
    const specs_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, pf_specs });
    const tasks_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, pf_tasks });
    const rollout_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, rollout });

    const unsaved_defaults =
        \\---
        \\"quoted_port": 8080
        \\
    ;
    const unsaved_vars =
        \\---
        \\'quoted_port': 9090
        \\"\u0071uoted_port": 9091
        \\
    ;
    const unsaved_specs =
        \\---
        \\argument_specs:
        \\  main:
        \\    options:
        \\      "quoted_port":
        \\        type: int
        \\
    ;
    const unsaved_tasks =
        \\---
        \\- name: Check port
        \\  ansible.builtin.debug:
        \\    msg: "Listening on {{ quoted_port }}"
        \\  register: "quoted_port"
        \\  when: quoted_port > 0
        \\
    ;
    const unsaved_rollout =
        \\---
        \\- name: Rollout
        \\  hosts: all
        \\  vars:
        \\    "quoted_port": 7070
        \\  roles:
        \\    - role: example.rollout.preflight
        \\      "quoted_port": 6060
        \\
    ;

    try open(&client, defaults_uri, unsaved_defaults);
    try open(&client, vars_uri, unsaved_vars);
    try open(&client, specs_uri, unsaved_specs);
    try open(&client, tasks_uri, unsaved_tasks);
    try open(&client, rollout_uri, unsaved_rollout);

    // Every site's expected quote-free range.
    const expected_edits = [_]anchor.Location{
        // defaults: `"quoted_port": 8080` on line 1, inside quotes is col 1..12
        .{ .uri = defaults_uri, .range = range(1, 1, 1, 12) },
        // vars: `'quoted_port': 9090` on line 1, inside quotes is col 1..12
        .{ .uri = vars_uri, .range = range(1, 1, 1, 12) },
        // vars: `"\u0071uoted_port": 9091` on line 2, inside quotes is col 1..17
        .{ .uri = vars_uri, .range = range(2, 1, 2, 17) },
        // specs: `      "quoted_port":` on line 4, inside quotes is col 7..18
        .{ .uri = specs_uri, .range = range(4, 7, 4, 18) },
        // tasks: `    msg: "Listening on {{ quoted_port }}"` on line 3, col 26..37
        .{ .uri = tasks_uri, .range = range(3, 26, 3, 37) },
        // tasks: `  register: "quoted_port"` on line 4, inside quotes is col 13..24
        .{ .uri = tasks_uri, .range = range(4, 13, 4, 24) },
        // tasks: `  when: quoted_port > 0` on line 5, col 8..19
        .{ .uri = tasks_uri, .range = range(5, 8, 5, 19) },
        // rollout: `    "quoted_port": 7070` on line 4, inside quotes is col 5..16
        .{ .uri = rollout_uri, .range = range(4, 5, 4, 16) },
        // rollout: `      "quoted_port": 6060` on line 7, inside quotes is col 7..18
        .{ .uri = rollout_uri, .range = range(7, 7, 7, 18) },
    };

    const sorted_expected = try a.dupe(anchor.Location, &expected_edits);
    std.mem.sort(anchor.Location, sorted_expected, {}, lessLocation);

    // Query both prepareRename and rename from each of the 9 sites.
    const cursors = [_]struct { uri: []const u8, pos: anchor.Position, expected_range: anchor.Range }{
        .{ .uri = defaults_uri, .pos = .{ .line = 1, .character = 5 }, .expected_range = range(1, 1, 1, 12) },
        .{ .uri = vars_uri, .pos = .{ .line = 1, .character = 5 }, .expected_range = range(1, 1, 1, 12) },
        .{ .uri = vars_uri, .pos = .{ .line = 2, .character = 8 }, .expected_range = range(2, 1, 2, 17) },
        .{ .uri = specs_uri, .pos = .{ .line = 4, .character = 10 }, .expected_range = range(4, 7, 4, 18) },
        .{ .uri = tasks_uri, .pos = .{ .line = 3, .character = 30 }, .expected_range = range(3, 26, 3, 37) },
        .{ .uri = tasks_uri, .pos = .{ .line = 4, .character = 16 }, .expected_range = range(4, 13, 4, 24) },
        .{ .uri = tasks_uri, .pos = .{ .line = 5, .character = 12 }, .expected_range = range(5, 8, 5, 19) },
        .{ .uri = rollout_uri, .pos = .{ .line = 4, .character = 9 }, .expected_range = range(4, 5, 4, 16) },
        .{ .uri = rollout_uri, .pos = .{ .line = 7, .character = 11 }, .expected_range = range(7, 7, 7, 18) },
    };

    for (cursors) |c| {
        const prep = try client.request("textDocument/prepareRename", .{
            .textDocument = .{ .uri = c.uri },
            .position = c.pos,
        });
        const prep_range = try std.json.parseFromValueLeaky(anchor.Range, a, lsp.field(prep, "range") orelse return error.MissingRange, .{});
        try std.testing.expectEqualDeep(c.expected_range, prep_range);
        const placeholder = lsp.field(prep, "placeholder") orelse return error.MissingPlaceholder;
        try std.testing.expectEqualStrings("quoted_port", placeholder.string);

        const edit_res = try client.request("textDocument/rename", .{
            .textDocument = .{ .uri = c.uri },
            .position = c.pos,
            .newName = "backend_port",
        });
        const actual = try parseWorkspaceEdit(a, edit_res, "backend_port");
        std.mem.sort(anchor.Location, actual, {}, lessLocation);
        try expectLocations(sorted_expected, actual);
    }

    // Apply edits to the defaults and vars buffers and verify surrounding quotes remain intact.
    const final_edit = try client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = .{ .line = 1, .character = 5 },
        .newName = "backend_port",
    });
    const changes = (lsp.field(final_edit, "changes") orelse return error.MissingChanges).object;
    try std.testing.expectEqualStrings(
        "---\n\"backend_port\": 8080\n",
        try applyTextEdits(a, unsaved_defaults, changes.get(defaults_uri).?.array.items),
    );
    try std.testing.expectEqualStrings(
        "---\n'backend_port': 9090\n\"backend_port\": 9091\n",
        try applyTextEdits(a, unsaved_vars, changes.get(vars_uri).?.array.items),
    );
    try std.testing.expectEqualStrings(
        "---\n- name: Check port\n  ansible.builtin.debug:\n    msg: \"Listening on {{ backend_port }}\"\n  register: \"backend_port\"\n  when: backend_port > 0\n",
        try applyTextEdits(a, unsaved_tasks, changes.get(tasks_uri).?.array.items),
    );
}

test "rename rejects invalid variable names and returns null on non-root-variables" {
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
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();

    const resolver = anchor.Resolver{ .allocator = a, .fixture = fixture, .deps = deps };
    const valid_source = try resolver.cursor(m.cursor(pf_defaults, "<app_port>: 8080"));
    try open(&client, valid_source.uri, try resolver.readText(pf_defaults));

    const invalid_names = [_][]const u8{
        "",
        "123port",
        "app-port",
        "app.port",
        "app port",
        "$app_port",
        "true",
        "false",
        "none",
        "True",
        "False",
        "None",
        "and",
        "or",
        "not",
        "in",
        "is",
        "if",
        "for",
    };
    for (invalid_names) |bad_name| {
        const err_obj = try client.requestError("textDocument/rename", .{
            .textDocument = .{ .uri = valid_source.uri },
            .position = valid_source.position,
            .newName = bad_name,
        });
        const code = lsp.field(err_obj, "code") orelse return error.MissingErrorCode;
        try std.testing.expectEqual(@as(i64, -32602), code.integer);
    }

    // Non-root-variable cursors must return null for both prepareRename and rename.
    const non_root_anchors = [_]m.Anchor{
        // Ordinary field reads and definitions
        m.cursor("roles/field_nav/tasks/main.yml", "🛰 {{ field_item.<resourcegroup_name> }} /"),
        m.cursor("roles/field_nav/tasks/main.yml", "🛰 {{ static_item['<resourcegroup_name>'] }} /"),
        m.cursor("roles/field_nav/tasks/main.yml", "/ {{ static_backup[\"<resourcegroup_name>\"] }}"),
        m.cursor("roles/field_nav/defaults/main.yml", "  - <resourcegroup_name>: default-group"),
        m.cursor("roles/field_nav/vars/main.yml", "  \"<resourcegroup_name>\": vars-group"),
        m.cursor("roles/field_nav/meta/argument_specs.yml", "          <resourcegroup_name>:"),
        // Passed role parameter field
        m.cursor("playbooks/field-inputs.yml", "            <region_name>: passed-main-region"),
        // Role reference, file reference, module key, task keyword
        m.cursor(rollout, "- role: <example.rollout.preflight>"),
        m.cursor(pf_tasks, "include_tasks: <steps.yml>"),
        m.cursor(pf_tasks, "<ansible.builtin.debug>:"),
        m.cursor(pf_tasks, "<when>: deployment_enabled | bool"),
    };
    var opened = std.StringHashMap(void).init(a);
    try opened.put(pf_defaults, {});
    for (non_root_anchors) |origin| {
        const cur = try resolver.cursor(origin);
        if (!opened.contains(origin.path)) {
            try open(&client, cur.uri, try resolver.readText(origin.path));
            try opened.put(origin.path, {});
        }
        const prep = try client.request("textDocument/prepareRename", .{
            .textDocument = .{ .uri = cur.uri },
            .position = cur.position,
        });
        try std.testing.expect(prep == .null);

        const ren = try client.request("textDocument/rename", .{
            .textDocument = .{ .uri = cur.uri },
            .position = cur.position,
            .newName = "valid_new_name",
        });
        try std.testing.expect(ren == .null);
    }
}

test "rename reflects unsaved didChange edits across open buffers" {
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
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();

    const resolver = anchor.Resolver{ .allocator = a, .fixture = fixture, .deps = deps };
    const common_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, common });
    const defaults_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, pf_defaults });
    try open(&client, common_uri, try resolver.readText(common));
    try open(&client, defaults_uri, try resolver.readText(pf_defaults));

    // Shift `app_port` in defaults and add a second read in common.yml via didChange.
    const edited_defaults =
        \\# Unsaved comment shifting lines
        \\# Second comment line
        \\release_tag: candidate
        \\app_port: 8080
        \\deployment_enabled: true
        \\
    ;
    const edited_common =
        \\---
        \\- name: Shared task
        \\  ansible.builtin.debug:
        \\    msg: "{{ release_tag }} on {{ app_port }} and {{ app_port }}"
        \\
    ;
    try change(&client, defaults_uri, edited_defaults);
    try change(&client, common_uri, edited_common);

    const expected = [_]anchor.Location{
        try resolver.location(m.span(pf_tasks, "port {{ <app_port> }}")),
        try resolver.location(m.span(pf_specs, "      <app_port>:")),
        .{ .uri = defaults_uri, .range = range(3, 0, 3, 8) },
        .{ .uri = common_uri, .range = range(3, 34, 3, 42) },
        .{ .uri = common_uri, .range = range(3, 53, 3, 61) },
    };
    const sorted_expected = try a.dupe(anchor.Location, &expected);
    std.mem.sort(anchor.Location, sorted_expected, {}, lessLocation);

    const res = try client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = .{ .line = 3, .character = 4 },
        .newName = "http_listen_port",
    });
    const actual = try parseWorkspaceEdit(a, res, "http_listen_port");
    std.mem.sort(anchor.Location, actual, {}, lessLocation);
    try expectLocations(sorted_expected, actual);
}

fn open(client: *lsp.Client, uri: []const u8, text: []const u8) !void {
    try client.notify("textDocument/didOpen", .{ .textDocument = .{
        .uri = uri,
        .languageId = "yaml",
        .version = @as(u32, 1),
        .text = text,
    } });
}

fn change(client: *lsp.Client, uri: []const u8, text: []const u8) !void {
    try client.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = uri, .version = @as(u32, 2) },
        .contentChanges = &.{.{ .text = text }},
    });
}

fn range(start_line: u32, start_char: u32, end_line: u32, end_char: u32) anchor.Range {
    return .{
        .start = .{ .line = start_line, .character = start_char },
        .end = .{ .line = end_line, .character = end_char },
    };
}

fn parseWorkspaceEdit(a: Allocator, result: Value, expected_text: []const u8) ![]anchor.Location {
    if (result == .null) return &.{};
    const changes = lsp.field(result, "changes") orelse return error.MissingWorkspaceEditChanges;
    if (changes != .object) return error.InvalidWorkspaceEditChanges;
    var locations = std.array_list.Managed(anchor.Location).init(a);
    var it = changes.object.iterator();
    while (it.next()) |entry| {
        const uri = entry.key_ptr.*;
        if (entry.value_ptr.* != .array) return error.InvalidTextEditArray;
        for (entry.value_ptr.array.items) |edit| {
            const new_text = lsp.field(edit, "newText") orelse return error.MissingTextEditNewText;
            try std.testing.expectEqualStrings(expected_text, new_text.string);
            const r = lsp.field(edit, "range") orelse return error.MissingTextEditRange;
            try locations.append(.{
                .uri = uri,
                .range = try std.json.parseFromValueLeaky(anchor.Range, a, r, .{}),
            });
        }
    }
    return locations.toOwnedSlice();
}

fn applyTextEdits(a: Allocator, text: []const u8, edits: []const Value) ![]const u8 {
    const SpanEdit = struct {
        start: usize,
        end: usize,
        new_text: []const u8,
    };
    var spans = try a.alloc(SpanEdit, edits.len);
    for (edits, 0..) |edit, i| {
        const r = try std.json.parseFromValueLeaky(anchor.Range, a, lsp.field(edit, "range").?, .{});
        const new_text = lsp.field(edit, "newText").?.string;
        spans[i] = .{
            .start = try byteOffsetAt(text, r.start),
            .end = try byteOffsetAt(text, r.end),
            .new_text = new_text,
        };
    }
    std.mem.sort(SpanEdit, spans, {}, struct {
        fn less(_: void, x: SpanEdit, y: SpanEdit) bool {
            return x.start < y.start;
        }
    }.less);
    var out = std.array_list.Managed(u8).init(a);
    var cursor: usize = 0;
    for (spans) |s| {
        try out.appendSlice(text[cursor..s.start]);
        try out.appendSlice(s.new_text);
        cursor = s.end;
    }
    try out.appendSlice(text[cursor..]);
    return out.toOwnedSlice();
}

fn byteOffsetAt(text: []const u8, pos: anchor.Position) !usize {
    var line: u32 = 0;
    var character: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (line == pos.line and character == pos.character) return i;
        const width = try std.unicode.utf8ByteSequenceLength(text[i]);
        const point = try std.unicode.utf8Decode(text[i .. i + width]);
        if (point == '\n') {
            line += 1;
            character = 0;
        } else {
            character += if (point > 0xffff) @as(u32, 2) else 1;
        }
        i += width;
    }
    if (line == pos.line and character == pos.character) return i;
    return error.PositionOutOfBounds;
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
