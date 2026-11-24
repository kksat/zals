const std = @import("std");
const Value = std.json.Value;

const DiagClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    next_id: i64 = 1,
    index_ready: bool = false,
    diagnostics: std.StringHashMap(Value),

    fn start(a: std.mem.Allocator, binary: []const u8, path_env: []const u8, home: []const u8) !DiagClient {
        var env = try std.process.getEnvMap(a);
        defer env.deinit();
        try env.put("PATH", path_env);
        try env.put("HOME", home);
        try env.put("XDG_CACHE_HOME", try std.fs.path.join(a, &.{ home, ".cache" }));
        env.remove("VIRTUAL_ENV");
        env.remove("ANSIBLE_CONFIG");
        env.remove("ANSIBLE_COLLECTIONS_PATH");

        var child = std.process.Child.init(&.{ binary, "--stdio", "--log-level", "error" }, a);
        child.env_map = &env;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        child.env_map = null;
        return .{
            .allocator = a,
            .child = child,
            .diagnostics = std.StringHashMap(Value).init(a),
        };
    }

    fn deinit(self: *DiagClient) void {
        if (self.child.stdin) |f| {
            f.close();
            self.child.stdin = null;
        }
        _ = self.child.kill() catch {
            _ = self.child.wait() catch {};
        };
    }

    fn send(self: *DiagClient, payload: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
        const pipe = self.child.stdin orelse return error.ServerClosed;
        try pipe.writeAll(header);
        try pipe.writeAll(body);
    }

    fn notify(self: *DiagClient, method: []const u8, params: anytype) !void {
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    fn request(self: *DiagClient, method: []const u8, params: anytype) !Value {
        const id = self.next_id;
        self.next_id += 1;
        try self.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        while (true) {
            const msg = try self.readMessage();
            if (field(msg, "method")) |m| {
                if (m == .string) {
                    if (std.mem.eql(u8, m.string, "ansible/workspaceIndexReady")) {
                        self.index_ready = true;
                    } else if (std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
                        if (field(msg, "params")) |p| {
                            if (field(p, "uri")) |u| {
                                if (u == .string) {
                                    if (field(p, "diagnostics")) |d| {
                                        try self.diagnostics.put(u.string, d);
                                    }
                                }
                            }
                        }
                    }
                }
                continue;
            }
            const rid = field(msg, "id") orelse continue;
            if (rid == .integer and rid.integer == id) {
                return field(msg, "result") orelse Value.null;
            }
        }
    }

    fn pumpUntil(self: *DiagClient, uri: []const u8, check: *const fn (Value) bool) !Value {
        const began = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - began < 15_000) {
            if (self.diagnostics.get(uri)) |d| {
                if (check(d)) return d;
            }
            _ = try self.request("workspace/symbol", .{ .query = "__cel_pump__" });
            if (self.diagnostics.get(uri)) |d| {
                if (check(d)) return d;
            }
            std.Thread.sleep(15 * std.time.ns_per_ms);
        }
        return error.DiagnosticsTimeout;
    }

    fn readMessage(self: *DiagClient) !Value {
        const pipe = self.child.stdout orelse return error.ServerClosed;
        var length: ?usize = null;
        while (true) {
            var line = std.array_list.Managed(u8).init(self.allocator);
            while (true) {
                var byte: [1]u8 = undefined;
                try readExact(pipe, &byte);
                if (byte[0] == '\n') break;
                try line.append(byte[0]);
            }
            const header = std.mem.trim(u8, line.items, " \r");
            if (header.len == 0) break;
            if (std.mem.startsWith(u8, header, "Content-Length:")) {
                length = try std.fmt.parseInt(usize, std.mem.trim(u8, header["Content-Length:".len..], " \t"), 10);
            }
        }
        const n = length orelse return error.MissingContentLength;
        const body = try self.allocator.alloc(u8, n);
        try readExact(pipe, body);
        return try std.json.parseFromSliceLeaky(Value, self.allocator, body, .{});
    }
};

fn readExact(file: std.fs.File, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var ready = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&ready, 15_000) == 0) return error.ServerResponseTimeout;
        const count = try file.read(buffer[offset..]);
        if (count == 0) return error.ServerClosed;
        offset += count;
    }
}

fn field(v: Value, name: []const u8) ?Value {
    return if (v == .object) v.object.get(name) else null;
}

fn hasCode(diags: Value, expected: []const u8) bool {
    if (diags != .array) return false;
    for (diags.array.items) |item| {
        const code = field(item, "code") orelse continue;
        if (code == .string and std.mem.eql(u8, code.string, expected)) return true;
    }
    return false;
}

fn hasUnopenedFindings(diags: Value) bool {
    return hasCode(diags, "name[play]") and hasCode(diags, "no-changed-when") and hasCode(diags, "zals/parse-issue");
}

fn hasNoFindings(diags: Value) bool {
    return diags == .array and diags.array.items.len == 0;
}

fn hasOnlyNamePlay(diags: Value) bool {
    return hasCode(diags, "name[play]") and !hasCode(diags, "no-changed-when");
}

test "stdio native cel diagnostics cover unopened files, unsaved edits, suppression, close-to-disk, provider switch, and no external spawn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ws/.git");
    try tmp.dir.makePath("bin");

    const ws_root = try tmp.dir.realpathAlloc(a, "ws");
    const bin_dir = try tmp.dir.realpathAlloc(a, "bin");
    const marker_path = try std.fs.path.join(a, &.{ bin_dir, "forbidden-called" });

    const trap_script = try std.fmt.allocPrint(a, "#!/bin/sh\necho called > '{s}'\nexit 0\n", .{marker_path});
    for ([_][]const u8{ "ansible-lint", "ansible-playbook" }) |tool| {
        const sub = try std.fs.path.join(a, &.{ "bin", tool });
        try tmp.dir.writeFile(.{ .sub_path = sub, .data = trap_script });
        var f = try tmp.dir.openFile(sub, .{});
        defer f.close();
        try f.chmod(0o755);
    }

    const disk_src =
        \\- hosts: all
        \\  tasks:
        \\    - name: run echo
        \\      ansible.builtin.shell: echo hi
        \\    - name: broken task without action
        \\
    ;
    try tmp.dir.writeFile(.{ .sub_path = "ws/site.yml", .data = disk_src });

    const site_path = try std.fs.path.join(a, &.{ ws_root, "site.yml" });
    const site_uri = try std.fmt.allocPrint(a, "file://{s}", .{site_path});
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{ws_root});
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");

    var client = try DiagClient.start(a, binary, bin_dir, ws_root);
    defer client.deinit();

    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = root_uri,
        .capabilities = .{},
    });
    try client.notify("initialized", .{});

    const unopened = try client.pumpUntil(site_uri, hasUnopenedFindings);
    try std.testing.expect(hasCode(unopened, "name[play]"));
    try std.testing.expect(hasCode(unopened, "no-changed-when"));
    try std.testing.expect(hasCode(unopened, "zals/parse-issue"));

    const edited_src =
        \\- hosts: all
        \\  tasks:
        \\    - name: run echo # noqa: no-changed-when
        \\      ansible.builtin.shell: echo hi
        \\
    ;
    try client.notify("textDocument/didOpen", .{
        .textDocument = .{
            .uri = site_uri,
            .languageId = "ansible",
            .version = @as(i64, 1),
            .text = disk_src,
        },
    });
    try client.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = site_uri, .version = @as(i64, 2) },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = edited_src }},
    });
    const after_edit = try client.pumpUntil(site_uri, hasOnlyNamePlay);
    try std.testing.expect(hasCode(after_edit, "name[play]"));
    try std.testing.expect(!hasCode(after_edit, "no-changed-when"));
    try std.testing.expect(!hasCode(after_edit, "zals/parse-issue"));

    try client.notify("textDocument/didClose", .{
        .textDocument = .{ .uri = site_uri },
    });
    const after_close = try client.pumpUntil(site_uri, hasUnopenedFindings);
    try std.testing.expect(hasCode(after_close, "no-changed-when"));

    try client.notify("workspace/didChangeConfiguration", .{
        .settings = .{ .ansible = .{ .validation = .{ .cel = .{ .enabled = false } } } },
    });
    _ = try client.pumpUntil(site_uri, hasNoFindings);

    try client.notify("workspace/didChangeConfiguration", .{
        .settings = .{ .ansible = .{ .validation = .{ .cel = .{ .enabled = true } } } },
    });
    _ = try client.pumpUntil(site_uri, hasUnopenedFindings);

    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(marker_path, .{}));
}

fn hasSource(diags: Value, expected: []const u8) bool {
    if (diags != .array) return false;
    for (diags.array.items) |item| {
        const src = field(item, "source") orelse continue;
        if (src == .string and std.mem.eql(u8, src.string, expected)) return true;
    }
    return false;
}

fn hasCustomPing(diags: Value) bool {
    return hasCode(diags, "custom/no-ping");
}

fn hasNoCustomPing(diags: Value) bool {
    return diags == .array and !hasCode(diags, "custom/no-ping");
}

fn hasRuleFileError(diags: Value) bool {
    return hasSource(diags, "zals-cel-rule");
}

fn hasBothProviders(diags: Value) bool {
    return hasSource(diags, "zals-cel") and hasSource(diags, "ansible-lint");
}

fn hasOnlyExternalProvider(diags: Value) bool {
    return !hasSource(diags, "zals-cel") and hasSource(diags, "ansible-lint");
}

test "stdio custom workspace rule trust, invalid-save deactivation, reload, and deletion lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ws/.git");
    try tmp.dir.makePath("ws/rules");
    try tmp.dir.makePath("bin");

    const ws_root = try tmp.dir.realpathAlloc(a, "ws");
    const bin_dir = try tmp.dir.realpathAlloc(a, "bin");

    try tmp.dir.writeFile(.{
        .sub_path = "ws/.ansible-lint",
        .data = "skip_list:\n  - name[play]\n  - no-changed-when\n",
    });
    const valid_rule =
        \\zals.Rule{
        \\  id: "custom/no-ping",
        \\  target: "task",
        \\  severity: "warning",
        \\  field: "action",
        \\  condition: node.short_action == "ping",
        \\  message: "Avoid ping in production."
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "ws/rules/no_ping.cel", .data = valid_rule });
    const site_src =
        \\- hosts: all
        \\  tasks:
        \\    - name: check host
        \\      ansible.builtin.ping:
        \\      tags:
        \\        - skip_ansible_lint
        \\
    ;
    try tmp.dir.writeFile(.{ .sub_path = "ws/site.yml", .data = site_src });

    const site_path = try std.fs.path.join(a, &.{ ws_root, "site.yml" });
    const rule_path = try std.fs.path.join(a, &.{ ws_root, "rules/no_ping.cel" });
    const site_uri = try std.fmt.allocPrint(a, "file://{s}", .{site_path});
    const rule_uri = try std.fmt.allocPrint(a, "file://{s}", .{rule_path});
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{ws_root});
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");

    var client = try DiagClient.start(a, binary, bin_dir, ws_root);
    defer client.deinit();

    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = root_uri,
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{
            .validation = .{ .cel = .{
                .workspaceRuleFiles = &[_][]const u8{"rules/no_ping.cel"},
                .allowWorkspaceRules = false,
            } },
        } },
    });
    try client.notify("initialized", .{});

    const denied = try client.pumpUntil(site_uri, hasOnlyNamePlay);
    try std.testing.expect(hasCode(denied, "name[play]"));
    try std.testing.expect(!hasCode(denied, "custom/no-ping"));

    try client.notify("workspace/didChangeConfiguration", .{
        .settings = .{ .ansible = .{ .validation = .{ .cel = .{
            .workspaceRuleFiles = &[_][]const u8{"rules/no_ping.cel"},
            .allowWorkspaceRules = true,
        } } } },
    });
    const allowed = try client.pumpUntil(site_uri, hasCustomPing);
    try std.testing.expect(hasCode(allowed, "name[play]"));
    try std.testing.expect(hasCode(allowed, "custom/no-ping"));

    try tmp.dir.writeFile(.{
        .sub_path = "ws/rules/no_ping.cel",
        .data = "zals.Rule{ id: \"custom/no-ping\", target: \"task\", severity: \"warning\", condition: bad_ident, message: \"x\" }",
    });
    try client.notify("textDocument/didSave", .{
        .textDocument = .{ .uri = rule_uri },
    });
    _ = try client.pumpUntil(rule_uri, hasRuleFileError);
    const after_invalid = try client.pumpUntil(site_uri, hasNoCustomPing);
    try std.testing.expect(hasCode(after_invalid, "name[play]"));

    try tmp.dir.writeFile(.{ .sub_path = "ws/rules/no_ping.cel", .data = valid_rule });
    try client.notify("textDocument/didSave", .{
        .textDocument = .{ .uri = rule_uri },
    });
    _ = try client.pumpUntil(rule_uri, hasNoFindings);
    _ = try client.pumpUntil(site_uri, hasCustomPing);

    try tmp.dir.deleteFile("ws/site.yml");
    try client.notify("workspace/didChangeWatchedFiles", .{
        .changes = &[_]struct { uri: []const u8, type: i64 }{.{ .uri = site_uri, .type = 3 }},
    });
    _ = try client.pumpUntil(site_uri, hasNoFindings);
}

test "stdio multi-provider independence keeps both cel and external findings without deduplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ws/.git");
    try tmp.dir.makePath("bin");

    const ws_root = try tmp.dir.realpathAlloc(a, "ws");
    const bin_dir = try tmp.dir.realpathAlloc(a, "bin");
    const site_path = try std.fs.path.join(a, &.{ ws_root, "site.yml" });
    const site_uri = try std.fmt.allocPrint(a, "file://{s}", .{site_path});
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{ws_root});

    const fake_lint = try std.fmt.allocPrint(
        a,
        "#!/bin/sh\necho '[{{\"description\":\"external unnamed play\",\"check_name\":\"name[play]\",\"severity\":\"major\",\"location\":{{\"path\":\"{s}\",\"lines\":{{\"begin\":1}}}}}}]'\nexit 2\n",
        .{site_path},
    );
    try tmp.dir.writeFile(.{ .sub_path = "bin/ansible-lint", .data = fake_lint });
    {
        var f = try tmp.dir.openFile("bin/ansible-lint", .{});
        defer f.close();
        try f.chmod(0o755);
    }

    const site_src = "- hosts: all\n  tasks: []\n";
    try tmp.dir.writeFile(.{ .sub_path = "ws/site.yml", .data = site_src });

    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var client = try DiagClient.start(a, binary, bin_dir, ws_root);
    defer client.deinit();

    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = root_uri,
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{
            .validation = .{
                .enabled = true,
                .cel = .{ .enabled = true },
                .lint = .{ .enabled = true },
            },
        } },
    });
    try client.notify("initialized", .{});
    try client.notify("textDocument/didOpen", .{
        .textDocument = .{
            .uri = site_uri,
            .languageId = "ansible",
            .version = @as(i64, 1),
            .text = site_src,
        },
    });

    const both = try client.pumpUntil(site_uri, hasBothProviders);
    try std.testing.expect(both.array.items.len >= 2);

    try client.notify("workspace/didChangeConfiguration", .{
        .settings = .{ .ansible = .{ .validation = .{
            .enabled = true,
            .cel = .{ .enabled = false },
            .lint = .{ .enabled = true },
        } } },
    });
    const ext_only = try client.pumpUntil(site_uri, hasOnlyExternalProvider);
    try std.testing.expect(hasSource(ext_only, "ansible-lint"));
    try std.testing.expect(!hasSource(ext_only, "zals-cel"));
}

fn hasSpecCrossFileFindings(diags: Value) bool {
    return hasCode(diags, "argument-specs[default-value-mismatch]") and
        hasCode(diags, "argument-specs[default-template-mismatch]") and
        hasCode(diags, "argument-specs[required-with-default]") and
        hasCode(diags, "argument-specs[spec-default-not-in-defaults]");
}

fn hasSpecFixedValueMismatch(diags: Value) bool {
    return !hasCode(diags, "argument-specs[default-value-mismatch]") and
        hasCode(diags, "argument-specs[default-template-mismatch]");
}

fn hasDefaultsVarNotInSpec(diags: Value) bool {
    return hasCode(diags, "argument-specs[defaults-var-not-in-spec]");
}

fn hasDefaultsExtraEntryPoint(diags: Value) bool {
    return hasCode(diags, "argument-specs[defaults-extra-entry-point]");
}

fn hasMissingSpecFile(diags: Value) bool {
    return hasCode(diags, "argument-specs[missing-file]");
}

test "stdio cross-file role context checks directory-style defaults, live sibling cascade, and missing-file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ws/.git");
    try tmp.dir.makePath("ws/roles/demo/meta");
    try tmp.dir.makePath("ws/roles/demo/defaults/main");
    try tmp.dir.makePath("ws/roles/legacy/meta");
    try tmp.dir.makePath("ws/roles/legacy/defaults");
    try tmp.dir.makePath("bin");

    const ws_root = try tmp.dir.realpathAlloc(a, "ws");
    const bin_dir = try tmp.dir.realpathAlloc(a, "bin");

    try tmp.dir.writeFile(.{
        .sub_path = "ws/roles/demo/meta/argument_specs.yml",
        .data =
        \\argument_specs:
        \\  main:
        \\    options:
        \\      port:
        \\        type: int
        \\        default: 80
        \\      cfg:
        \\        type: dict
        \\        default:
        \\          host: localhost
        \\      req_var:
        \\        type: str
        \\        required: true
        \\      missing_def:
        \\        type: str
        \\        default: abc
        \\
        ,
    });
    const base_defaults =
        \\port: 80
        \\cfg:
        \\  host: "{{ ansible_host }}"
        \\req_var: provided
        \\undocumented_var: oops
        \\
    ;
    const override_defaults = "port: \"80\"\n";
    try tmp.dir.writeFile(.{ .sub_path = "ws/roles/demo/defaults/main/01_base.yml", .data = base_defaults });
    try tmp.dir.writeFile(.{ .sub_path = "ws/roles/demo/defaults/main/02_override.yml", .data = override_defaults });
    try tmp.dir.writeFile(.{ .sub_path = "ws/roles/demo/defaults/extra.yml", .data = "extra_var: 1\n" });

    try tmp.dir.writeFile(.{
        .sub_path = "ws/roles/legacy/meta/main.yml",
        .data = "galaxy_info:\n  author: Jane\n  description: Legacy role\n  license: MIT\n  galaxy_tags: [web]\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "ws/roles/legacy/defaults/main.yml",
        .data = "legacy_var: 1\n",
    });

    const spec_uri = try std.fmt.allocPrint(a, "file://{s}/roles/demo/meta/argument_specs.yml", .{ws_root});
    const base_uri = try std.fmt.allocPrint(a, "file://{s}/roles/demo/defaults/main/01_base.yml", .{ws_root});
    const override_uri = try std.fmt.allocPrint(a, "file://{s}/roles/demo/defaults/main/02_override.yml", .{ws_root});
    const extra_uri = try std.fmt.allocPrint(a, "file://{s}/roles/demo/defaults/extra.yml", .{ws_root});
    const legacy_meta_uri = try std.fmt.allocPrint(a, "file://{s}/roles/legacy/meta/main.yml", .{ws_root});
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{ws_root});
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");

    var client = try DiagClient.start(a, binary, bin_dir, ws_root);
    defer client.deinit();

    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = root_uri,
        .capabilities = .{},
    });
    try client.notify("initialized", .{});

    _ = try client.pumpUntil(spec_uri, hasSpecCrossFileFindings);
    _ = try client.pumpUntil(base_uri, hasDefaultsVarNotInSpec);
    _ = try client.pumpUntil(extra_uri, hasDefaultsExtraEntryPoint);
    _ = try client.pumpUntil(legacy_meta_uri, hasMissingSpecFile);

    try client.notify("textDocument/didOpen", .{
        .textDocument = .{
            .uri = override_uri,
            .languageId = "ansible",
            .version = @as(i64, 1),
            .text = override_defaults,
        },
    });
    try client.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = override_uri, .version = @as(i64, 2) },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = "port: 80\n" }},
    });
    _ = try client.pumpUntil(spec_uri, hasSpecFixedValueMismatch);

    try client.notify("textDocument/didClose", .{
        .textDocument = .{ .uri = override_uri },
    });
    _ = try client.pumpUntil(spec_uri, hasSpecCrossFileFindings);
}
