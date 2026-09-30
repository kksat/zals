const m = @import("../model.zig");

pub const all = [_]m.Case{
    .{
        .name = "role/FQCN map entry: implementation opens main tasks",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "- role: <example.rollout.preflight>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/preflight/tasks/main.yml")},
    },
    .{
        .name = "role/FQCN map entry: definition prefers argument specs",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "- role: <example.rollout.preflight>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/preflight/meta/argument_specs.yml")},
    },
};
