const m = @import("../model.zig");

pub const all = [_]m.Case{
    .{
        .name = "collection/Installed requirement: definition opens MANIFEST.json",
        .method = .definition,
        .from = m.cursor("requirements.yml", "- <fixture.metrics>"),
        .expected = &.{m.fileStart("@deps/ansible_collections/fixture/metrics/MANIFEST.json")},
    },
    .{
        .name = "collection/absent dependency: definition has no target",
        .method = .definition,
        .from = m.cursor("ansible_collections/example/rollout/galaxy.yml", "  <fixture.missing>: \">=1.0.0\""),
        .expected = &.{},
    },
};
