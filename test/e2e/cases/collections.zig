const m = @import("../model.zig");

const rollout = "playbooks/rollout.yml";
const rollback = "playbooks/rollback.yml";
const dependency = "playbooks/dependency.yml";
const nonstandard = "negative/nonstandard-paths.yml";
const negative = "negative/collections.yml";
const negative_roles = "negative/roles.yml";
const req = "requirements.yml";
const ee = "execution-environment.yml";
const galaxy = "ansible_collections/example/rollout/galaxy.yml";
const shared_galaxy = "ansible_collections/example/shared/galaxy.yml";
const runtime = "ansible_collections/example/rollout/meta/runtime.yml";
const preflight_meta = "ansible_collections/example/rollout/roles/preflight/meta/main.yml";
const notify_tasks = "ansible_collections/example/rollout/roles/notify/tasks/main.yml";
const rollback_tasks = "ansible_collections/example/rollout/roles/rollback/tasks/main.yml";
const metrics_manifest = "@deps/ansible_collections/fixture/metrics/MANIFEST.json";
const notes_readme = "@deps/ansible_collections/fixture/notes/README.md";

// Complete Workspace reference groups, written independently of zals. FQCN
// sites select the namespace.collection prefix, not the role or module suffix.
const rollout_refs: []const m.ExpectedLocation = &.{
    m.span(nonstandard, "name: <example.rollout>.notify"),
    m.span(rollback, "- <example.rollout>.rollback"),
    m.span(rollback, "name: <example.rollout>.snapshot"),
    m.span(rollout, "    - <example.rollout>\n  vars_files:"),
    m.span(rollout, "- role: <example.rollout>.preflight"),
    m.span(rollout, "- <example.rollout>.verify"),
    m.span(rollout, "name: <example.rollout>.migrate"),
    m.span(rollout, "ansible.builtin.import_role: \"name=<example.rollout>.snapshot\""),
    m.span(req, "src: <example.rollout>.snapshot"),
    m.span(req, "- <example.rollout>.verify"),
    m.span(preflight_meta, "- <example.rollout>.snapshot"),
    m.span(rollback_tasks, "name: <example.rollout>.snapshot"),
};
const shared_refs: []const m.ExpectedLocation = &.{
    m.span(req, "name: <example.shared>"),
    m.span(galaxy, "  <example.shared>: \">=1.0.0\""),
    m.span(preflight_meta, "  - <example.shared>\ndependencies:"),
    m.span(preflight_meta, "- role: <example.shared>.notify"),
    m.span(notify_tasks, "name: <example.shared>.notify"),
    m.span(runtime, "- <example.shared>.notify"),
    m.span(rollout, "- name: Run a collection-scoped task\n      collections:\n        - <example.shared>"),
    m.span(rollout, "- name: Explain the rollout block\n      collections:\n        - <example.shared>"),
    m.span(rollback, "name: <example.shared>.notify"),
};
const metrics_refs: []const m.ExpectedLocation = &.{
    m.span(ee, "name: <fixture.metrics>"),
    m.span(galaxy, "  <fixture.metrics>: \">=1.0.0\""),
    m.span(preflight_meta, "- name: <fixture.metrics>.report"),
    m.span(notify_tasks, "name: <fixture.metrics>.report"),
    m.span(runtime, "redirect: <fixture.metrics>.report"),
    m.span(dependency, "    - <fixture.metrics>\n  roles:"),
    m.span(dependency, "    - <fixture.metrics>.report"),
    m.span(rollback, "name: <fixture.metrics>.report"),
    m.span(rollout, "      <fixture.metrics>.record:"),
    m.span(req, "  - <fixture.metrics>"),
};
const missing_refs: []const m.ExpectedLocation = &.{
    m.span(galaxy, "  <fixture.missing>: \">=1.0.0\""),
    m.span(negative, "    - <fixture.missing>"),
    m.span(negative, "      <fixture.missing>.fake_module:"),
    m.span(req, "name: <fixture.missing>"),
};

pub const all = [_]m.Case{
    .{
        .name = "collection/play declaration: definition opens Workspace galaxy.yml",
        .method = .definition,
        .from = m.cursor(rollout, "    - <example.rollout>\n  vars_files:"),
        .expected = &.{m.fileStart(galaxy)},
    },
    .{
        .name = "collection/play declaration: references include FQCN role prefixes",
        .method = .references,
        .from = m.cursor(rollout, "    - <example.rollout>\n  vars_files:"),
        .expected = rollout_refs,
    },
    .{
        .name = "collection/FQCN role prefix: definition is the collection, not the Role",
        .method = .definition,
        .from = m.cursor(rollout, "- role: <example.rollout>.preflight"),
        .expected = &.{m.fileStart(galaxy)},
    },
    .{
        .name = "collection/FQCN role prefix: references include explicit collection declarations",
        .method = .references,
        .from = m.cursor(rollout, "- role: <example.rollout>.preflight"),
        .expected = rollout_refs,
    },
    .{
        .name = "collection/requirements map name: definition opens the second Workspace collection",
        .method = .definition,
        .from = m.cursor(req, "name: <example.shared>"),
        .expected = &.{m.fileStart(shared_galaxy)},
    },
    .{
        .name = "collection/requirements map name: references span all declaration and FQCN sites",
        .method = .references,
        .from = m.cursor(req, "name: <example.shared>"),
        .expected = shared_refs,
    },
    .{
        .name = "collection/galaxy dependency key: definition opens Workspace galaxy.yml",
        .method = .definition,
        .from = m.cursor(galaxy, "  <example.shared>: \">=1.0.0\""),
        .expected = &.{m.fileStart(shared_galaxy)},
    },
    .{
        .name = "collection/galaxy dependency key: references match declarations and action_groups",
        .method = .references,
        .from = m.cursor(galaxy, "  <example.shared>: \">=1.0.0\""),
        .expected = shared_refs,
    },
    .{
        .name = "collection/role metadata declaration: definition opens Workspace galaxy.yml",
        .method = .definition,
        .from = m.cursor(preflight_meta, "  - <example.shared>\ndependencies:"),
        .expected = &.{m.fileStart(shared_galaxy)},
    },
    .{
        .name = "collection/role metadata declaration: references include the declaration itself",
        .method = .references,
        .from = m.cursor(preflight_meta, "  - <example.shared>\ndependencies:"),
        .expected = shared_refs,
    },
    .{
        .name = "collection/task declaration: definition opens Workspace galaxy.yml",
        .method = .definition,
        .from = m.cursor(rollout, "- name: Run a collection-scoped task\n      collections:\n        - <example.shared>"),
        .expected = &.{m.fileStart(shared_galaxy)},
    },
    .{
        .name = "collection/task declaration: references include the block declaration",
        .method = .references,
        .from = m.cursor(rollout, "- name: Run a collection-scoped task\n      collections:\n        - <example.shared>"),
        .expected = shared_refs,
    },
    .{
        .name = "collection/block declaration: definition opens Workspace galaxy.yml",
        .method = .definition,
        .from = m.cursor(rollout, "- name: Explain the rollout block\n      collections:\n        - <example.shared>"),
        .expected = &.{m.fileStart(shared_galaxy)},
    },
    .{
        .name = "collection/block declaration: references include the task declaration",
        .method = .references,
        .from = m.cursor(rollout, "- name: Explain the rollout block\n      collections:\n        - <example.shared>"),
        .expected = shared_refs,
    },
    .{
        .name = "collection/runtime action_groups FQCN: definition opens Workspace galaxy.yml",
        .method = .definition,
        .from = m.cursor(runtime, "- <example.shared>.notify"),
        .expected = &.{m.fileStart(shared_galaxy)},
    },
    .{
        .name = "collection/runtime action_groups FQCN: references include every shared collection site",
        .method = .references,
        .from = m.cursor(runtime, "- <example.shared>.notify"),
        .expected = shared_refs,
    },
    .{
        .name = "collection/requirements bare entry: definition opens configured Installed MANIFEST",
        .method = .definition,
        .from = m.cursor(req, "  - <fixture.metrics>"),
        .expected = &.{m.fileStart(metrics_manifest)},
    },
    .{
        .name = "collection/requirements bare entry: references include Installed name in Workspace YAML",
        .method = .references,
        .from = m.cursor(req, "  - <fixture.metrics>"),
        .expected = metrics_refs,
    },
    .{
        .name = "collection/execution-environment map name: definition opens Installed MANIFEST",
        .method = .definition,
        .from = m.cursor(ee, "name: <fixture.metrics>"),
        .expected = &.{m.fileStart(metrics_manifest)},
    },
    .{
        .name = "collection/execution-environment map name: references stay in Workspace",
        .method = .references,
        .from = m.cursor(ee, "name: <fixture.metrics>"),
        .expected = metrics_refs,
    },
    .{
        .name = "collection/FQCN role prefix into Installed collection: definition opens MANIFEST",
        .method = .definition,
        .from = m.cursor(dependency, "- <fixture.metrics>.report"),
        .expected = &.{m.fileStart(metrics_manifest)},
    },
    .{
        .name = "collection/FQCN role prefix into Installed collection: references include module keys",
        .method = .references,
        .from = m.cursor(dependency, "- <fixture.metrics>.report"),
        .expected = metrics_refs,
    },
    .{
        .name = "collection/FQCN module key: definition opens Installed MANIFEST",
        .method = .definition,
        .from = m.cursor(rollout, "      <fixture.metrics>.record:"),
        .expected = &.{m.fileStart(metrics_manifest)},
    },
    .{
        .name = "collection/FQCN module key: references include roles and dependency declarations",
        .method = .references,
        .from = m.cursor(rollout, "      <fixture.metrics>.record:"),
        .expected = metrics_refs,
    },
    .{
        .name = "collection/runtime redirect FQCN: definition opens Installed MANIFEST",
        .method = .definition,
        .from = m.cursor(runtime, "redirect: <fixture.metrics>.report"),
        .expected = &.{m.fileStart(metrics_manifest)},
    },
    .{
        .name = "collection/runtime redirect FQCN: references include the redirect itself",
        .method = .references,
        .from = m.cursor(runtime, "redirect: <fixture.metrics>.report"),
        .expected = metrics_refs,
    },
    .{
        .name = "collection/absent dependency: definition has no target",
        .method = .definition,
        .from = m.cursor(galaxy, "  <fixture.missing>: \">=1.0.0\""),
        .expected = &.{},
    },
    .{
        .name = "collection/absent dependency: references still include all name-matched sites",
        .method = .references,
        .from = m.cursor(galaxy, "  <fixture.missing>: \">=1.0.0\""),
        .expected = missing_refs,
    },
    .{
        .name = "collection/absent FQCN module key: definition has no target",
        .method = .definition,
        .from = m.cursor(negative, "<fixture.missing>.fake_module:"),
        .expected = &.{},
    },
    .{
        .name = "collection/absent FQCN module key: references still find all absent names",
        .method = .references,
        .from = m.cursor(negative, "<fixture.missing>.fake_module:"),
        .expected = missing_refs,
    },
    .{
        .name = "collection/README-only configured path: definition uses last fallback",
        .method = .definition,
        .from = m.cursor(negative, "    - <fixture.notes>"),
        .expected = &.{m.fileStart(notes_readme)},
    },
    .{
        .name = "collection/README-only configured path: references include its sole Workspace site",
        .method = .references,
        .from = m.cursor(negative, "    - <fixture.notes>"),
        .expected = &.{m.span(negative, "    - <fixture.notes>")},
    },
    .{
        .name = "collection/non-galaxy URL requirement: definition is not a collection reference",
        .method = .definition,
        .from = m.cursor(req, "name: <https://example.invalid/collection.git>"),
        .expected = &.{},
    },
    .{
        .name = "collection/non-galaxy URL requirement: references are empty",
        .method = .references,
        .from = m.cursor(req, "name: <https://example.invalid/collection.git>"),
        .expected = &.{},
    },
    .{
        .name = "collection/non-reference FQCN value: definition is empty",
        .method = .definition,
        .from = m.cursor(negative_roles, "dynamic_role: <example.rollout>.deploy"),
        .expected = &.{},
    },
    .{
        .name = "collection/non-reference FQCN value: references are empty",
        .method = .references,
        .from = m.cursor(negative_roles, "dynamic_role: <example.rollout>.deploy"),
        .expected = &.{},
    },
};
