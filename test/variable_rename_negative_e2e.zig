//! Negative end-to-end tests for root Variable `prepareRename` and `rename`
//! (ADR-0046). Each test verifies something that must NOT happen: lookalike
//! files and constructs that must remain untouched when renaming a valid root
//! Variable, and cursor positions, states, or target names that must be
//! rejected.

const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Workspace = struct {
    arena: *std.heap.ArenaAllocator,
    ws_dir: std.testing.TmpDir,
    home_dir: std.testing.TmpDir,
    root: []const u8,
    client: lsp.Client,

    fn init(files: []const FileSpec) !Workspace {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        errdefer std.testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var ws_dir = std.testing.tmpDir(.{});
        errdefer ws_dir.cleanup();
        var home_dir = std.testing.tmpDir(.{});
        errdefer home_dir.cleanup();

        try ws_dir.dir.writeFile(.{ .sub_path = "negative-rename-root", .data = "" });
        for (files) |file| {
            if (std.fs.path.dirname(file.path)) |dir| try ws_dir.dir.makePath(dir);
            try ws_dir.dir.writeFile(.{ .sub_path = file.path, .data = file.text });
        }

        const root = try ws_dir.dir.realpathAlloc(a, ".");
        const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
        const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
        var client = try lsp.Client.startWithOptions(a, binary, root, deps, try home_dir.dir.realpathAlloc(a, "."), .{
            .collections_path = "",
            .use_fixture_config = false,
        });
        errdefer client.deinit();

        _ = try client.request("initialize", .{
            .processId = @as(?i64, null),
            .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{root}),
            .capabilities = .{},
            .initializationOptions = .{ .ansible = .{
                .workspace = .{ .rootMarker = "negative-rename-root" },
                .python = .{ .venvPath = "" },
                .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
            } },
        });
        try client.notify("initialized", .{});
        try client.waitForIndex();

        return .{
            .arena = arena,
            .ws_dir = ws_dir,
            .home_dir = home_dir,
            .root = root,
            .client = client,
        };
    }

    fn deinit(self: *Workspace) void {
        self.client.deinit();
        self.home_dir.cleanup();
        self.ws_dir.cleanup();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn uri(self: *Workspace, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "file://{s}/{s}", .{ self.root, rel });
    }

    fn open(self: *Workspace, rel: []const u8, text: []const u8) ![]const u8 {
        const u = try self.uri(rel);
        try self.client.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = u,
            .languageId = "yaml",
            .version = @as(u32, 1),
            .text = text,
        } });
        return u;
    }

    fn change(self: *Workspace, u: []const u8, text: []const u8) !void {
        try self.client.notify("textDocument/didChange", .{
            .textDocument = .{ .uri = u, .version = @as(u32, 2) },
            .contentChanges = &.{.{ .text = text }},
        });
    }
};

const FileSpec = struct {
    path: []const u8,
    text: []const u8,
};

test "renaming variables named like metadata keys never touches role meta, galaxy, requirements, EE, runtime, molecule, compose, mkdocs, changelog, or inventory files" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text =
            \\---
            \\version: "1.0"
            \\galaxy_info: "app-info"
            \\dependencies: []
            \\collections: []
            \\plugin_routing: "none"
            \\platforms: []
            \\services: []
            \\site_name: "portal"
            \\releases: []
            \\all: "everything"
            \\
            ,
        },
        .{
            .path = "roles/app/tasks/main.yml",
            .text =
            \\---
            \\- name: Read collision-prone variable names
            \\  ansible.builtin.debug:
            \\    msg: "{{ version }} {{ galaxy_info }} {{ dependencies }} {{ collections }} {{ plugin_routing }} {{ platforms }} {{ services }} {{ site_name }} {{ releases }} {{ all }}"
            \\
            ,
        },
        // Non-Variable files and Role metadata files with identical top-level keys.
        .{
            .path = "roles/app/meta/main.yml",
            .text =
            \\---
            \\galaxy_info:
            \\  author: acme
            \\  description: role metadata
            \\  min_ansible_version: "2.15"
            \\dependencies:
            \\  - role: common
            \\
            ,
        },
        .{
            .path = "galaxy.yml",
            .text =
            \\---
            \\namespace: acme
            \\name: bundle
            \\version: 1.0.0
            \\dependencies: {}
            \\
            ,
        },
        .{
            .path = "requirements.yml",
            .text =
            \\---
            \\collections:
            \\  - name: community.general
            \\    version: 8.0.0
            \\roles:
            \\  - name: geerlingguy.docker
            \\    version: 7.0.0
            \\
            ,
        },
        .{
            .path = "execution-environment.yml",
            .text =
            \\---
            \\version: 3
            \\dependencies:
            \\  galaxy: requirements.yml
            \\
            ,
        },
        .{
            .path = "meta/runtime.yml",
            .text =
            \\---
            \\requires_ansible: ">=2.15.0"
            \\plugin_routing:
            \\  modules: {}
            \\
            ,
        },
        .{
            .path = "molecule/default/molecule.yml",
            .text =
            \\---
            \\platforms:
            \\  - name: instance
            \\
            ,
        },
        .{
            .path = "docker-compose.yml",
            .text =
            \\---
            \\version: "3.8"
            \\services:
            \\  web:
            \\    image: nginx
            \\
            ,
        },
        .{
            .path = "mkdocs.yml",
            .text =
            \\---
            \\site_name: Documentation
            \\
            ,
        },
        .{
            .path = "changelogs/changelog.yaml",
            .text =
            \\---
            \\releases:
            \\  1.0.0:
            \\    release_summary: Initial
            \\
            ,
        },
        .{
            .path = "inventory.yml",
            .text =
            \\---
            \\all:
            \\  hosts:
            \\    localhost: {}
            \\
            ,
        },
        .{
            .path = "roles/app/templates/config.yml.j2",
            .text =
            \\---
            \\version: "template-map-key"
            \\services: {}
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const tasks_uri = try ws.open(files[1].path, files[1].text);

    // Every non-Variable / metadata file must remain untouched across all renames.
    const untouched_paths = [_][]const u8{
        "roles/app/meta/main.yml",
        "galaxy.yml",
        "requirements.yml",
        "execution-environment.yml",
        "meta/runtime.yml",
        "molecule/default/molecule.yml",
        "docker-compose.yml",
        "mkdocs.yml",
        "changelogs/changelog.yaml",
        "inventory.yml",
        "roles/app/templates/config.yml.j2",
    };

    const vars_to_rename = [_]struct { line: u32, name: []const u8 }{
        .{ .line = 1, .name = "version" },
        .{ .line = 2, .name = "galaxy_info" },
        .{ .line = 3, .name = "dependencies" },
        .{ .line = 4, .name = "collections" },
        .{ .line = 5, .name = "plugin_routing" },
        .{ .line = 6, .name = "platforms" },
        .{ .line = 7, .name = "services" },
        .{ .line = 8, .name = "site_name" },
        .{ .line = 9, .name = "releases" },
        .{ .line = 10, .name = "all" },
    };

    for (vars_to_rename) |v| {
        const new_name = try std.fmt.allocPrint(a, "renamed_{s}", .{v.name});
        const res = try ws.client.request("textDocument/rename", .{
            .textDocument = .{ .uri = defaults_uri },
            .position = anchor.Position{ .line = v.line, .character = 2 },
            .newName = new_name,
        });
        const edits = try parseWorkspaceEdit(a, res, new_name);
        for (untouched_paths) |untouched| {
            const forbidden_uri = try ws.uri(untouched);
            for (edits) |loc| {
                if (std.mem.eql(u8, loc.uri, forbidden_uri)) {
                    std.debug.print("rename of '{s}' unexpectedly edited {s}\n", .{ v.name, untouched });
                    return error.UnexpectedEditInMetadataFile;
                }
            }
        }
        // Only defaults/main.yml and tasks/main.yml may be edited (1 binding + 1 read).
        try std.testing.expectEqual(@as(usize, 2), edits.len);
        try std.testing.expectEqualStrings(defaults_uri, edits[0].uri);
        try std.testing.expectEqualStrings(tasks_uri, edits[1].uri);
    }

    // Cursors placed directly on keys in those metadata/non-Variable files must return null.
    for (untouched_paths) |untouched| {
        for (files) |f| if (std.mem.eql(u8, f.path, untouched)) {
            const u = try ws.open(f.path, f.text);
            const pos = anchor.Position{ .line = 1, .character = 2 };
            try std.testing.expect(try ws.client.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = u }, .position = pos }) == .null);
            try std.testing.expect(try ws.client.request("textDocument/rename", .{ .textDocument = .{ .uri = u }, .position = pos, .newName = "never_applied" }) == .null);
        };
    }
}

test "renaming variables named like argument_specs structural keys never edits schema keywords" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text =
            \\---
            \\options: "opt-val"
            \\type: "type-val"
            \\description: "desc-val"
            \\default: "def-val"
            \\required: "req-val"
            \\argument_specs: "specs-val"
            \\
            ,
        },
        .{
            .path = "roles/app/meta/argument_specs.yml",
            .text =
            \\---
            \\argument_specs:
            \\  main:
            \\    short_description: Main entry point
            \\    options:
            \\      service_port:
            \\        type: int
            \\        description: Port number
            \\        default: 8080
            \\        required: false
            \\        options:
            \\          nested_opt:
            \\            type: str
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const specs_uri = try ws.open(files[1].path, files[1].text);

    for ([_]struct { line: u32, name: []const u8 }{
        .{ .line = 1, .name = "options" },
        .{ .line = 2, .name = "type" },
        .{ .line = 3, .name = "description" },
        .{ .line = 4, .name = "default" },
        .{ .line = 5, .name = "required" },
        .{ .line = 6, .name = "argument_specs" },
    }) |item| {
        const new_name = try std.fmt.allocPrint(a, "custom_{s}", .{item.name});
        const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
            .textDocument = .{ .uri = defaults_uri },
            .position = anchor.Position{ .line = item.line, .character = 2 },
            .newName = new_name,
        }), new_name);
        for (edits) |loc| {
            if (std.mem.eql(u8, loc.uri, specs_uri)) {
                std.debug.print("rename of '{s}' unexpectedly edited argument_specs.yml at line {d}\n", .{ item.name, loc.range.start.line });
                return error.UnexpectedSchemaKeywordEdit;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), edits.len);
        try std.testing.expectEqualStrings(defaults_uri, edits[0].uri);
    }

    // Cursors on structural keys in argument_specs.yml (`argument_specs`, `main`, `options`, `type`, `description`, `default`, `required`) must return null.
    for ([_]anchor.Position{
        .{ .line = 1, .character = 2 }, // argument_specs
        .{ .line = 2, .character = 4 }, // main
        .{ .line = 4, .character = 6 }, // options
        .{ .line = 6, .character = 9 }, // type
        .{ .line = 7, .character = 10 }, // description
        .{ .line = 8, .character = 10 }, // default
        .{ .line = 9, .character = 10 }, // required
    }) |pos| {
        try std.testing.expect(try ws.client.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = specs_uri }, .position = pos }) == .null);
        try std.testing.expect(try ws.client.request("textDocument/rename", .{ .textDocument = .{ .uri = specs_uri }, .position = pos, .newName = "renamed_schema" }) == .null);
    }
}

test "renaming a root variable never modifies same-named Variable fields, nested data keys, or nested argument_specs options" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text =
            \\---
            \\region: us-east-1
            \\server:
            \\  region: eu-west-1
            \\  vars:
            \\    region: ap-south-1
            \\  set_fact:
            \\    region: ca-central-1
            \\  roles:
            \\    - role: nested_decoy
            \\      region: sa-east-1
            \\
            ,
        },
        .{
            .path = "roles/app/meta/argument_specs.yml",
            .text =
            \\---
            \\argument_specs:
            \\  main:
            \\    options:
            \\      region:
            \\        type: str
            \\      server:
            \\        type: dict
            \\        options:
            \\          region:
            \\            type: str
            \\
            ,
        },
        .{
            .path = "roles/app/tasks/main.yml",
            .text =
            \\---
            \\- name: Read root region and field region
            \\  ansible.builtin.debug:
            \\    msg: "{{ region }} {{ server.region }} {{ server['region'] }} {{ server[\"region\"] }}"
            \\  when: server.region == region
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const specs_uri = try ws.open(files[1].path, files[1].text);
    const tasks_uri = try ws.open(files[2].path, files[2].text);

    const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = anchor.Position{ .line = 1, .character = 2 },
        .newName = "cloud_region",
    }), "cloud_region");

    // Must edit ONLY:
    // 1. defaults/main.yml line 1 (`region: us-east-1`), NOT lines 3, 5, 7, 10
    // 2. meta/argument_specs.yml line 4 (`options: region:`), NOT line 9 (`server.options.region`)
    // 3. tasks/main.yml line 3 (`{{ region }}`) and line 4 (`== region`), NOT `server.region` or `server['region']`
    try expectLocations(&.{
        .{ .uri = defaults_uri, .range = range(1, 0, 1, 6) },
        .{ .uri = specs_uri, .range = range(4, 6, 4, 12) },
        .{ .uri = tasks_uri, .range = range(3, 13, 3, 19) },
        .{ .uri = tasks_uri, .range = range(4, 25, 4, 31) },
    }, edits);
}

test "renaming a root variable never modifies comments, plain strings, Jinja string literals, Jinja raw blocks, filters, tests, or method calls" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text =
            \\---
            \\# port comment in defaults
            \\port: 8080
            \\
            ,
        },
        .{
            .path = "roles/app/tasks/main.yml",
            .text =
            \\---
            \\# port comment in tasks
            \\- name: port in task name is plain text
            \\  ansible.builtin.debug:
            \\    msg: "plain port text {# {{ port }} in jinja comment #} {% raw %}{{ port }}{% endraw %} {{ 'port' }} {{ \"port\" }} {{ value | port }} {{ value is port }} {{ obj.port() }} {{ port }}"
            \\  when: "value != 'port' and port > 0"
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const tasks_uri = try ws.open(files[1].path, files[1].text);

    const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = anchor.Position{ .line = 2, .character = 2 },
        .newName = "listen_port",
    }), "listen_port");

    // Only the binding in defaults (line 2), the trailing `{{ port }}` in msg (line 4),
    // and `port > 0` in when (line 5) may be edited.
    try expectLocations(&.{
        .{ .uri = defaults_uri, .range = range(2, 0, 2, 4) },
        .{ .uri = tasks_uri, .range = range(4, 179, 4, 183) },
        .{ .uri = tasks_uri, .range = range(5, 29, 5, 33) },
    }, edits);
}

test "renaming a root variable never modifies Ansible directive keys, module names, module options, role references, or task file paths" {
    const files = [_]FileSpec{
        .{
            .path = "roles/web/defaults/main.yml",
            .text =
            \\---
            \\web: "enabled"
            \\msg: "hello"
            \\debug: "verbose"
            \\when: "always"
            \\
            ,
        },
        .{
            .path = "roles/web/tasks/main.yml",
            .text =
            \\---
            \\- name: Run web tasks
            \\  ansible.builtin.include_tasks: web.yml
            \\- name: Print msg
            \\  debug:
            \\    msg: "{{ web }} {{ msg }} {{ debug }} {{ when }}"
            \\  when: web != ""
            \\
            ,
        },
        .{
            .path = "roles/web/tasks/web.yml",
            .text = "---\n- debug:\n    msg: ok\n",
        },
        .{
            .path = "site.yml",
            .text =
            \\---
            \\- hosts: all
            \\  roles:
            \\    - role: web
            \\  tasks:
            \\    - ansible.builtin.include_role:
            \\        name: web
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const tasks_uri = try ws.open(files[1].path, files[1].text);
    const site_uri = try ws.open(files[3].path, files[3].text);

    // Rename `web`: must NOT touch `role: web`, `name: web`, or `include_tasks: web.yml`.
    const web_edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = anchor.Position{ .line = 1, .character = 1 },
        .newName = "web_flag",
    }), "web_flag");
    for (web_edits) |loc| {
        if (std.mem.eql(u8, loc.uri, site_uri)) return error.UnexpectedRoleReferenceEdit;
    }
    try expectLocations(&.{
        .{ .uri = defaults_uri, .range = range(1, 0, 1, 3) },
        .{ .uri = tasks_uri, .range = range(5, 13, 5, 16) },
        .{ .uri = tasks_uri, .range = range(6, 8, 6, 11) },
    }, web_edits);

    // Rename `msg`, `debug`, `when`: must NOT touch module key `debug:`, module option `msg:`, or task keyword `when:`.
    for ([_]struct { line: u32, name: []const u8, msg_col: u32 }{
        .{ .line = 2, .name = "msg", .msg_col = 23 },
        .{ .line = 3, .name = "debug", .msg_col = 33 },
        .{ .line = 4, .name = "when", .msg_col = 45 },
    }) |item| {
        const new_name = try std.fmt.allocPrint(a, "var_{s}", .{item.name});
        const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
            .textDocument = .{ .uri = defaults_uri },
            .position = anchor.Position{ .line = item.line, .character = 1 },
            .newName = new_name,
        }), new_name);
        try expectLocations(&.{
            .{ .uri = defaults_uri, .range = range(item.line, 0, item.line, @intCast(item.name.len)) },
            .{ .uri = tasks_uri, .range = range(5, item.msg_col, 5, item.msg_col + @as(u32, @intCast(item.name.len))) },
        }, edits);
    }
}

test "renaming a root variable never modifies import_playbook vars, unloaded general YAML files, unlinked vars_files targets, nested Workspaces, virtual environments, or Python module sources" {
    const files = [_]FileSpec{
        .{
            .path = "site.yml",
            .text =
            \\---
            \\- import_playbook: imported.yml
            \\  vars:
            \\    app_port: 9000
            \\- hosts: all
            \\  vars_files:
            \\    - settings/loaded.yml
            \\  vars:
            \\    app_port: 8080
            \\  tasks:
            \\    - ansible.builtin.debug:
            \\        msg: "{{ app_port }}"
            \\
            ,
        },
        .{
            .path = "settings/loaded.yml",
            .text = "---\napp_port: 8081\n",
        },
        .{
            .path = "settings/unloaded.yml",
            .text = "---\napp_port: 8082\n",
        },
        // Nested Workspace with its own root marker.
        .{
            .path = "nested-project/negative-rename-root",
            .text = "",
        },
        .{
            .path = "nested-project/roles/web/defaults/main.yml",
            .text = "---\napp_port: 8083\n",
        },
        // Virtual environment with pyvenv.cfg.
        .{
            .path = "custom-env/pyvenv.cfg",
            .text = "home = /usr/bin\n",
        },
        .{
            .path = "custom-env/roles/web/defaults/main.yml",
            .text = "---\napp_port: 8084\n",
        },
        // Python module source under plugins/modules/ containing YAML-like DOCUMENTATION.
        .{
            .path = "plugins/modules/probe.py",
            .text =
            \\---
            \\app_port: 8085
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const site_uri = try ws.open(files[0].path, files[0].text);
    const loaded_uri = try ws.open(files[1].path, files[1].text);
    const unloaded_uri = try ws.open(files[2].path, files[2].text);
    _ = try ws.open(files[7].path, files[7].text);

    // While `settings/loaded.yml` is loaded by `site.yml`, renaming `app_port`
    // edits `site.yml` (line 8 play var + line 11 read, NOT line 3 import_playbook var)
    // and `settings/loaded.yml` (line 1), and NEVER touches `settings/unloaded.yml`,
    // `nested-project/`, `custom-env/`, or `plugins/modules/probe.py`.
    const initial_edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = site_uri },
        .position = anchor.Position{ .line = 8, .character = 6 },
        .newName = "service_port",
    }), "service_port");
    try expectLocations(&.{
        .{ .uri = loaded_uri, .range = range(1, 0, 1, 8) },
        .{ .uri = site_uri, .range = range(8, 4, 8, 12) },
        .{ .uri = site_uri, .range = range(11, 17, 11, 25) },
    }, initial_edits);

    // Removing `vars_files` from `site.yml` in an unsaved edit unbinds `settings/loaded.yml`,
    // so renaming `app_port` must no longer edit `settings/loaded.yml`.
    try ws.change(site_uri,
        \\---
        \\- import_playbook: imported.yml
        \\  vars:
        \\    app_port: 9000
        \\- hosts: all
        \\  vars:
        \\    app_port: 8080
        \\  tasks:
        \\    - ansible.builtin.debug:
        \\        msg: "{{ app_port }}"
        \\
    );
    const after_unlink_edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = site_uri },
        .position = anchor.Position{ .line = 6, .character = 6 },
        .newName = "service_port",
    }), "service_port");
    try expectLocations(&.{
        .{ .uri = site_uri, .range = range(6, 4, 6, 12) },
        .{ .uri = site_uri, .range = range(9, 17, 9, 25) },
    }, after_unlink_edits);

    // And a cursor in the now-unloaded `settings/loaded.yml` or `settings/unloaded.yml` must return null.
    for ([_][]const u8{ loaded_uri, unloaded_uri }) |u| {
        const pos = anchor.Position{ .line = 1, .character = 2 };
        try std.testing.expect(try ws.client.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = u }, .position = pos }) == .null);
        try std.testing.expect(try ws.client.request("textDocument/rename", .{ .textDocument = .{ .uri = u }, .position = pos, .newName = "service_port" }) == .null);
    }
}

test "renaming a root variable never modifies prefix, suffix, substring, or case-variant variable names" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text =
            \\---
            \\port: 80
            \\app_port: 8080
            \\port_number: 8081
            \\app_port_number: 8082
            \\PORT: 9000
            \\Port: 9001
            \\
            ,
        },
        .{
            .path = "roles/app/tasks/main.yml",
            .text =
            \\---
            \\- name: Read lookalike identifiers
            \\  ansible.builtin.debug:
            \\    msg: "{{ port }} {{ app_port }} {{ port_number }} {{ app_port_number }} {{ PORT }} {{ Port }}"
            \\  when: app_port > port and port_number != PORT
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const tasks_uri = try ws.open(files[1].path, files[1].text);

    const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = anchor.Position{ .line = 1, .character = 2 },
        .newName = "http_port",
    }), "http_port");

    // Only `port` on defaults line 1, tasks line 3 col 13..17, and tasks line 4 col 19..23 may be edited.
    try expectLocations(&.{
        .{ .uri = defaults_uri, .range = range(1, 0, 1, 4) },
        .{ .uri = tasks_uri, .range = range(3, 13, 3, 17) },
        .{ .uri = tasks_uri, .range = range(4, 19, 4, 23) },
    }, edits);
}

test "renaming a root variable never modifies non-expression task scalars, file paths, or tags" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text = "---\nartifact_name: release.tar.gz\n",
        },
        .{
            .path = "roles/app/tasks/main.yml",
            .text =
            \\---
            \\- name: artifact_name in task name
            \\  ansible.builtin.copy:
            \\    src: artifact_name
            \\    dest: /opt/artifact_name
            \\  environment:
            \\    STATIC_NAME: artifact_name
            \\  tags:
            \\    - artifact_name
            \\  when: artifact_name != "artifact_name"
            \\- name: Template read
            \\  ansible.builtin.debug:
            \\    msg: "Deploying {{ artifact_name }} from artifact_name"
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const tasks_uri = try ws.open(files[1].path, files[1].text);

    const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = anchor.Position{ .line = 1, .character = 4 },
        .newName = "archive_filename",
    }), "archive_filename");

    // Must edit only defaults line 1, the bare expression `when: artifact_name` (not `"artifact_name"`),
    // and `{{ artifact_name }}` in msg (not the literal text around it or `src`/`dest`/`tags`).
    try expectLocations(&.{
        .{ .uri = defaults_uri, .range = range(1, 0, 1, 13) },
        .{ .uri = tasks_uri, .range = range(9, 8, 9, 21) },
        .{ .uri = tasks_uri, .range = range(12, 23, 12, 36) },
    }, edits);
}

test "renaming a root variable after unsaved didChange removes bindings or reads never edits stale disk occurrences" {
    const files = [_]FileSpec{
        .{
            .path = "roles/app/defaults/main.yml",
            .text = "---\napp_port: 8080\n",
        },
        .{
            .path = "roles/app/vars/main.yml",
            .text = "---\napp_port: 9090\n",
        },
        .{
            .path = "roles/app/tasks/main.yml",
            .text =
            \\---
            \\- name: First task
            \\  ansible.builtin.debug:
            \\    msg: "{{ app_port }}"
            \\- name: Second task
            \\  ansible.builtin.debug:
            \\    msg: "{{ app_port }}"
            \\
            ,
        },
    };

    var ws = try Workspace.init(&files);
    defer ws.deinit();
    const a = ws.arena.allocator();

    const defaults_uri = try ws.open(files[0].path, files[0].text);
    const vars_uri = try ws.open(files[1].path, files[1].text);
    const tasks_uri = try ws.open(files[2].path, files[2].text);

    // Replace the binding in vars/main.yml and the first read in tasks/main.yml via unsaved didChange.
    try ws.change(vars_uri, "---\nother_port: 9090\n");
    try ws.change(tasks_uri,
        \\---
        \\- name: First task
        \\  ansible.builtin.debug:
        \\    msg: "{{ other_port }}"
        \\- name: Second task
        \\  ansible.builtin.debug:
        \\    msg: "{{ app_port }}"
        \\
    );

    const edits = try parseWorkspaceEdit(a, try ws.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = defaults_uri },
        .position = anchor.Position{ .line = 1, .character = 3 },
        .newName = "listen_port",
    }), "listen_port");

    // Must NOT edit vars/main.yml or line 3 of tasks/main.yml.
    for (edits) |loc| {
        if (std.mem.eql(u8, loc.uri, vars_uri)) return error.EditedStaleDiskBinding;
    }
    try expectLocations(&.{
        .{ .uri = defaults_uri, .range = range(1, 0, 1, 8) },
        .{ .uri = tasks_uri, .range = range(6, 13, 6, 21) },
    }, edits);
}

test "renaming a root variable in one Workspace of a multi-root session never modifies a sibling Workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root_dir = std.testing.tmpDir(.{});
    defer root_dir.cleanup();
    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();

    const tree = [_]FileSpec{
        .{ .path = "ws_a/negative-rename-root", .text = "" },
        .{ .path = "ws_a/roles/web/defaults/main.yml", .text = "---\nshared_port: 8080\n" },
        .{ .path = "ws_a/roles/web/tasks/main.yml", .text = "---\n- debug:\n    msg: \"{{ shared_port }}\"\n" },
        .{ .path = "ws_b/negative-rename-root", .text = "" },
        .{ .path = "ws_b/roles/web/defaults/main.yml", .text = "---\nshared_port: 9090\n" },
        .{ .path = "ws_b/roles/web/tasks/main.yml", .text = "---\n- debug:\n    msg: \"{{ shared_port }}\"\n" },
    };
    for (tree) |file| {
        if (std.fs.path.dirname(file.path)) |dir| try root_dir.dir.makePath(dir);
        try root_dir.dir.writeFile(.{ .sub_path = file.path, .data = file.text });
    }

    const base = try root_dir.dir.realpathAlloc(a, ".");
    const ws_a = try std.fs.path.join(a, &.{ base, "ws_a" });
    const ws_b = try std.fs.path.join(a, &.{ base, "ws_b" });
    const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");

    var client = try lsp.Client.startWithOptions(a, binary, base, deps, try home_dir.dir.realpathAlloc(a, "."), .{
        .collections_path = "",
        .use_fixture_config = false,
    });
    defer client.deinit();

    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .workspaceFolders = &.{
            .{ .uri = try std.fmt.allocPrint(a, "file://{s}", .{ws_a}), .name = "ws_a" },
            .{ .uri = try std.fmt.allocPrint(a, "file://{s}", .{ws_b}), .name = "ws_b" },
        },
        .capabilities = .{ .workspace = .{ .workspaceFolders = true } },
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "negative-rename-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    try client.notify("initialized", .{});
    // Wait for both Workspace roots to finish indexing.
    try client.waitForIndex();
    try client.waitForIndex();

    const a_defaults = try std.fmt.allocPrint(a, "file://{s}/roles/web/defaults/main.yml", .{ws_a});
    const a_tasks = try std.fmt.allocPrint(a, "file://{s}/roles/web/tasks/main.yml", .{ws_a});
    const b_defaults = try std.fmt.allocPrint(a, "file://{s}/roles/web/defaults/main.yml", .{ws_b});
    const b_tasks = try std.fmt.allocPrint(a, "file://{s}/roles/web/tasks/main.yml", .{ws_b});

    for ([_]struct { uri: []const u8, text: []const u8 }{
        .{ .uri = a_defaults, .text = tree[1].text },
        .{ .uri = a_tasks, .text = tree[2].text },
        .{ .uri = b_defaults, .text = tree[4].text },
        .{ .uri = b_tasks, .text = tree[5].text },
    }) |doc| {
        try client.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = doc.uri,
            .languageId = "yaml",
            .version = @as(u32, 1),
            .text = doc.text,
        } });
    }

    const edits = try parseWorkspaceEdit(a, try client.request("textDocument/rename", .{
        .textDocument = .{ .uri = a_defaults },
        .position = anchor.Position{ .line = 1, .character = 3 },
        .newName = "ws_a_port",
    }), "ws_a_port");

    for (edits) |loc| {
        if (std.mem.eql(u8, loc.uri, b_defaults) or std.mem.eql(u8, loc.uri, b_tasks)) {
            return error.EditedSiblingWorkspace;
        }
    }
    try expectLocations(&.{
        .{ .uri = a_defaults, .range = range(1, 0, 1, 11) },
        .{ .uri = a_tasks, .range = range(2, 13, 2, 24) },
    }, edits);
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
        const u = entry.key_ptr.*;
        if (entry.value_ptr.* != .array) return error.InvalidTextEditArray;
        for (entry.value_ptr.array.items) |edit| {
            const new_text = lsp.field(edit, "newText") orelse return error.MissingTextEditNewText;
            try std.testing.expectEqualStrings(expected_text, new_text.string);
            const r = lsp.field(edit, "range") orelse return error.MissingTextEditRange;
            try locations.append(.{
                .uri = u,
                .range = try std.json.parseFromValueLeaky(anchor.Range, a, r, .{}),
            });
        }
    }
    std.mem.sort(anchor.Location, locations.items, {}, lessLocation);
    return locations.toOwnedSlice();
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
