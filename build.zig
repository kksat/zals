const std = @import("std");

const tree_sitter_c = [_][]const u8{
    "vendor/tree-sitter/src/alloc.c",
    "vendor/tree-sitter/src/get_changed_ranges.c",
    "vendor/tree-sitter/src/language.c",
    "vendor/tree-sitter/src/lexer.c",
    "vendor/tree-sitter/src/node.c",
    "vendor/tree-sitter/src/parser.c",
    "vendor/tree-sitter/src/query.c",
    "vendor/tree-sitter/src/stack.c",
    "vendor/tree-sitter/src/subtree.c",
    "vendor/tree-sitter/src/tree.c",
    "vendor/tree-sitter/src/tree_cursor.c",
    "vendor/tree-sitter/src/wasm_store.c",
    "vendor/tree-sitter-yaml/src/parser.c",
    "vendor/tree-sitter-yaml/src/scanner.c",
    "vendor/tree-sitter-yaml/src/schema.core.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Vendored tree-sitter runtime + tree-sitter-yaml grammar (ADR-0004).
    const ts = b.addLibrary(.{
        .name = "tree_sitter",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    ts.addCSourceFiles(.{ .files = &tree_sitter_c, .flags = &.{"-std=gnu11"} });
    ts.addIncludePath(b.path("vendor/tree-sitter/include"));
    ts.addIncludePath(b.path("vendor/tree-sitter/src"));
    ts.addIncludePath(b.path("vendor/tree-sitter-yaml/src"));
    ts.linkLibC();

    // Core library: everything except the CLI entry point.
    const schemas = b.createModule(.{
        .root_source_file = b.path("vendor/schemas/embed.zig"),
        .target = target,
    });
    const mod = b.addModule("zals", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schemas", .module = schemas },
        },
    });
    mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    mod.addIncludePath(b.path("vendor/tree-sitter-yaml/src"));

    // CLI entry point.
    const exe = b.addExecutable(.{
        .name = "zals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zals", .module = mod },
            },
        }),
    });
    exe.linkLibrary(ts);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Tests.
    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.linkLibrary(ts);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.linkLibrary(ts);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Independent real-stdio suites; none is mixed into the unit-test target.
    const e2e_step = b.step("e2e", "Run all stdio end-to-end suites");
    const suites = [_]struct {
        name: []const u8,
        source: []const u8,
        description: []const u8,
        inputs: []const []const u8,
        needs_ansible: bool = false,
    }{
        .{
            .name = "navigation-e2e",
            .source = "test/e2e.zig",
            .description = "Run static semantic navigation end-to-end tests",
            .inputs = &.{ "test/fixtures/e2e-workspace", "test/dependencies" },
        },
        .{
            .name = "field-expressions-e2e",
            .source = "test/field_expressions_e2e.zig",
            .description = "Run field-expression syntax and non-match navigation tests",
            .inputs = &.{"test/fixtures/field-expressions-workspace"},
        },
        .{
            .name = "selected-venv-e2e",
            .source = "test/selected_venv_e2e.zig",
            .description = "Run selected virtual environment and module docs tests",
            .inputs = &.{"test/fixtures/selected-venv"},
            .needs_ansible = true,
        },
        .{
            .name = "collection-symbols-e2e",
            .source = "test/collection_symbols_e2e.zig",
            .description = "Run Workspace collection layout and member symbol tests",
            .inputs = &.{ "test/fixtures/collection-symbols-workspace", "test/dependencies" },
        },
        .{
            .name = "navigation-uris-e2e",
            .source = "test/navigation_uris_e2e.zig",
            .description = "Run absolute and escaped navigation file URI tests",
            .inputs = &.{"test/fixtures/navigation-uris"},
        },
        .{
            .name = "role-parameter-edits-e2e",
            .source = "test/role_parameter_edits_e2e.zig",
            .description = "Run unsaved role argument-spec navigation tests",
            .inputs = &.{ "test/fixtures/e2e-workspace", "test/dependencies" },
        },
    };
    for (suites) |suite| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(suite.source),
            .target = target,
            .optimize = optimize,
        }) });
        const run_tests = b.addRunArtifact(tests);
        run_tests.step.dependOn(b.getInstallStep());
        run_tests.setCwd(b.path("."));
        // A cached success must never hide changed server or fixture inputs.
        run_tests.addFileInput(exe.getEmittedBin());
        for (suite.inputs) |input| addE2eInputs(b, run_tests, input);
        // Ansible is an external runtime dependency, not a tracked file input.
        // Re-run module-docs scenarios even if only the installed tools changed.
        run_tests.has_side_effects = suite.needs_ansible;
        const suite_step = b.step(suite.name, suite.description);
        suite_step.dependOn(&run_tests.step);
        e2e_step.dependOn(&run_tests.step);
    }
}

fn addE2eInputs(b: *std.Build, run: *std.Build.Step.Run, path: []const u8) void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch @panic("missing E2E fixture directory");
    defer dir.close();
    var walker = dir.walk(b.allocator) catch @panic("cannot walk E2E fixtures");
    defer walker.deinit();
    while (walker.next() catch @panic("cannot read E2E fixture")) |entry| {
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ path, entry.path })));
    }
}
