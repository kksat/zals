//! Which YAML files bind variables (ADR-0045). Only Variable files do: Role
//! defaults/vars, files below group_vars/, host_vars/, or vars/, and targets
//! of a vars load. Package, collection, execution-environment, tool, docs,
//! changelog, inventory, and template maps in the Workspace spell keys like
//! these variables and fields, but bind nothing. Every case before the
//! Controls section fails if classification reverts to "every map-rooted file
//! is a vars file"; the controls pass either way.
const m = @import("../model.zig");

const play = "playbooks/metadata-names.yml";
const settings = "playbooks/settings/release-metadata.yml";
const runtime_settings = "playbooks/settings/runtime-metadata.yml";
const galaxy = "ansible_collections/example/rollout/galaxy.yml";
const collection_runtime = "ansible_collections/example/rollout/meta/runtime.yml";
const ee = "execution-environment.yml";
const compose = "docker-compose.yml";
const molecule = "molecule/default/molecule.yml";
const inventory = "inventory.yml";
const mkdocs = "mkdocs.yml";
const changelog = "changelogs/changelog.yaml";
const template = "ansible_collections/example/rollout/roles/preflight/templates/compose.yml.j2";
const group_vars = "group_vars/all.yml";
const host_vars = "host_vars/localhost.yml";

const version_read = m.cursor(play, "msg: \"{{ <version> }}");
const routing_read = m.cursor(play, "{{ <plugin_routing> }}");
const groups_read = m.cursor(play, "{{ <action_groups> }}");
const region_read = m.cursor(play, "{{ <deploy_region> }}");
const host_label_read = m.cursor(play, "{{ <deploy_host_label> }}");
const opens_read = m.cursor(play, "{{ release_window.<opens> }}");
const image_read = m.cursor(play, "{{ release_window.<image> }}");

pub const all = [_]m.Case{
    // A play var named like galaxy/EE/Compose/template `version` keys.
    .{
        .name = "variable file/metadata-spelled play var: definition excludes metadata maps",
        .method = .definition,
        .from = version_read,
        .expected = &.{m.span(play, "    <version>: 2")},
    },
    .{
        .name = "variable file/metadata-spelled play var: implementation excludes metadata maps",
        .method = .implementation,
        .from = version_read,
        .expected = &.{m.span(play, "    <version>: 2")},
    },
    .{
        .name = "variable file/metadata-spelled play var: references with declarations exclude metadata maps",
        .method = .references,
        .from = version_read,
        .include_declaration = true,
        .expected = &.{
            m.span(play, "msg: \"{{ <version> }}"),
            m.span(play, "    <version>: 2"),
        },
    },
    .{
        .name = "variable file/metadata-spelled play var: same references from its binding",
        .method = .references,
        .from = m.cursor(play, "    <version>: 2"),
        .include_declaration = true,
        .expected = &.{
            m.span(play, "msg: \"{{ <version> }}"),
            m.span(play, "    <version>: 2"),
        },
    },
    .{
        .name = "variable file/metadata-spelled play var: hover shows only the play binding",
        .method = .hover,
        .from = version_read,
        .expected = &.{m.span(play, "msg: \"{{ <version> }}")},
        .markdown_contains = &.{ "**Variable** `version`", "metadata-names.yml" },
        .markdown_excludes = &.{ "galaxy.yml", "execution-environment.yml", "docker-compose.yml", "compose.yml.j2", "1.0.0", "3.8" },
    },

    // vars_files target outside a vars/ directory binds because it is loaded.
    .{
        .name = "variable file/vars_files target outside a vars directory: definition",
        .method = .definition,
        .from = routing_read,
        .expected = &.{m.span(settings, "<plugin_routing>: disabled")},
    },
    .{
        .name = "variable file/vars_files target outside a vars directory: implementation",
        .method = .implementation,
        .from = routing_read,
        .expected = &.{m.span(settings, "<plugin_routing>: disabled")},
    },
    .{
        .name = "variable file/vars_files target outside a vars directory: key definition",
        .method = .definition,
        .from = m.cursor(settings, "<plugin_routing>: disabled"),
        .expected = &.{m.span(settings, "<plugin_routing>: disabled")},
    },
    .{
        .name = "variable file/vars_files target outside a vars directory: references exclude runtime metadata",
        .method = .references,
        .from = m.cursor(settings, "<plugin_routing>: disabled"),
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ <plugin_routing> }}"),
            m.span(settings, "<plugin_routing>: disabled"),
        },
    },
    .{
        .name = "variable file/vars_files target outside a vars directory: hover excludes runtime metadata",
        .method = .hover,
        .from = routing_read,
        .expected = &.{m.span(play, "{{ <plugin_routing> }}")},
        .markdown_contains = &.{ "**Variable** `plugin_routing`", "disabled" },
        .markdown_excludes = &.{ "runtime.yml", "redirect" },
    },

    // include_vars target outside a vars/ directory binds because it is loaded.
    .{
        .name = "variable file/include_vars target outside a vars directory: definition",
        .method = .definition,
        .from = groups_read,
        .expected = &.{m.span(runtime_settings, "<action_groups>: rollout-only")},
    },
    .{
        .name = "variable file/include_vars target outside a vars directory: references exclude collection runtime",
        .method = .references,
        .from = groups_read,
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ <action_groups> }}"),
            m.span(runtime_settings, "<action_groups>: rollout-only"),
        },
    },
    .{
        .name = "variable file/include_vars target outside a vars directory: references from its key",
        .method = .references,
        .from = m.cursor(runtime_settings, "<action_groups>: rollout-only"),
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ <action_groups> }}"),
            m.span(runtime_settings, "<action_groups>: rollout-only"),
        },
    },

    // Names that only non-Variable files spell as keys are unbound.
    .{
        .name = "variable file/unloaded Molecule platforms: no definition",
        .method = .definition,
        .from = m.cursor(play, "{{ <platforms> }}"),
        .expected = &.{},
    },
    .{
        .name = "variable file/unloaded Molecule platforms: references with declarations",
        .method = .references,
        .from = m.cursor(play, "{{ <platforms> }}"),
        .include_declaration = true,
        .expected = &.{m.span(play, "{{ <platforms> }}")},
    },
    .{
        .name = "variable file/inventory group as a field: no definition",
        .method = .definition,
        .from = m.cursor(play, "{{ groups.<webservers> }}"),
        .expected = &.{},
    },
    .{
        .name = "variable file/inventory group as a field: references with declarations",
        .method = .references,
        .from = m.cursor(play, "{{ groups.<webservers> }}"),
        .include_declaration = true,
        .expected = &.{m.span(play, "{{ groups.<webservers> }}")},
    },
    .{
        .name = "variable file/mkdocs site_name: no definition",
        .method = .definition,
        .from = m.cursor(play, "{{ <site_name> }}"),
        .expected = &.{},
    },
    .{
        .name = "variable file/mkdocs site_name: hover finds no definition",
        .method = .hover,
        .from = m.cursor(play, "{{ <site_name> }}"),
        .expected = &.{m.span(play, "{{ <site_name> }}")},
        .markdown_contains = &.{ "**Variable** `site_name`", "No definition found" },
        .markdown_excludes = &.{ "mkdocs.yml", "Rollout fixture" },
    },
    .{
        .name = "variable file/changelog and template releases: references with declarations",
        .method = .references,
        .from = m.cursor(play, "{{ <releases> }}"),
        .include_declaration = true,
        .expected = &.{m.span(play, "{{ <releases> }}")},
    },
    .{
        .name = "variable file/changelog and template releases: no implementation",
        .method = .implementation,
        .from = m.cursor(play, "{{ <releases> }}"),
        .expected = &.{},
    },

    // Fields exist only below admitted root bindings.
    .{
        .name = "variable file/loaded settings field: definition excludes Compose image",
        .method = .definition,
        .from = image_read,
        .expected = &.{m.span(settings, "  <image>: example/app:candidate")},
    },
    .{
        .name = "variable file/loaded settings field: references exclude Compose image",
        .method = .references,
        .from = image_read,
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ release_window.<image> }}"),
            m.span(settings, "  <image>: example/app:candidate"),
        },
    },
    .{
        .name = "variable file/loaded settings field: same references from its key",
        .method = .references,
        .from = m.cursor(settings, "  <image>: example/app:candidate"),
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ release_window.<image> }}"),
            m.span(settings, "  <image>: example/app:candidate"),
        },
    },

    // Keys of non-Variable files are not navigation subjects themselves.
    .{
        .name = "variable file/non-match: galaxy.yml key is not a definition",
        .method = .definition,
        .from = m.cursor(galaxy, "<version>: 1.0.0"),
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: galaxy.yml key is not a reference",
        .method = .references,
        .from = m.cursor(galaxy, "<version>: 1.0.0"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: galaxy.yml key has no implementation",
        .method = .implementation,
        .from = m.cursor(galaxy, "<version>: 1.0.0"),
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: requirements collections key is not a reference",
        .method = .references,
        .from = m.cursor("requirements.yml", "<collections>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: requirements roles key is not a reference",
        .method = .references,
        .from = m.cursor("requirements.yml", "<roles>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: collection runtime key is not a reference",
        .method = .references,
        .from = m.cursor(collection_runtime, "<plugin_routing>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: collection runtime key is not a definition",
        .method = .definition,
        .from = m.cursor(collection_runtime, "<action_groups>:"),
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: execution-environment key is not a reference",
        .method = .references,
        .from = m.cursor(ee, "<version>: 3"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: changelog nested key is not a field",
        .method = .references,
        .from = m.cursor(changelog, "      <release_summary>: Initial release."),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: Compose key is not a reference",
        .method = .references,
        .from = m.cursor(compose, "<version>: \"3.8\""),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: Compose nested key is not a field definition",
        .method = .definition,
        .from = m.cursor(compose, "<image>: example/app:stable"),
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: Molecule key is not a reference",
        .method = .references,
        .from = m.cursor(molecule, "<platforms>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: inventory root is not a reference",
        .method = .references,
        .from = m.cursor(inventory, "<all>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: inventory group is not a field",
        .method = .references,
        .from = m.cursor(inventory, "<webservers>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: mkdocs key is not a reference",
        .method = .references,
        .from = m.cursor(mkdocs, "<site_name>:"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: changelog key is not a definition",
        .method = .definition,
        .from = m.cursor(changelog, "<releases>:"),
        .expected = &.{},
    },
    .{
        .name = "variable file/non-match: Role template map key is not a reference",
        .method = .references,
        .from = m.cursor(template, "<version>: \"3.8\""),
        .include_declaration = true,
        .expected = &.{},
    },

    // Controls. These answers were already right before ADR-0045: reads-only
    // results do not depend on bindings, and group_vars/, host_vars/, and
    // uncontested loaded keys were bindings. They fail if the Variable-file
    // allowlist or load resolution becomes too strict.
    .{
        .name = "variable file/metadata-spelled play var: references without declarations",
        .method = .references,
        .from = version_read,
        .include_declaration = false,
        .expected = &.{m.span(play, "msg: \"{{ <version> }}")},
    },
    .{
        .name = "variable file/vars_files target outside a vars directory: references without declarations",
        .method = .references,
        .from = m.cursor(settings, "<plugin_routing>: disabled"),
        .include_declaration = false,
        .expected = &.{m.span(play, "{{ <plugin_routing> }}")},
    },
    .{
        .name = "variable file/group_vars: definition without a load",
        .method = .definition,
        .from = region_read,
        .expected = &.{m.span(group_vars, "<deploy_region>: eu-west")},
    },
    .{
        .name = "variable file/group_vars: references with declarations from its key",
        .method = .references,
        .from = m.cursor(group_vars, "<deploy_region>: eu-west"),
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ <deploy_region> }}"),
            m.span(group_vars, "<deploy_region>: eu-west"),
        },
    },
    .{
        .name = "variable file/group_vars: hover shows the value",
        .method = .hover,
        .from = region_read,
        .expected = &.{m.span(play, "{{ <deploy_region> }}")},
        .markdown_contains = &.{ "**Variable** `deploy_region`", "eu-west" },
        .markdown_excludes = &.{"No definition found"},
    },
    .{
        .name = "variable file/host_vars: definition without a load",
        .method = .definition,
        .from = host_label_read,
        .expected = &.{m.span(host_vars, "<deploy_host_label>: primary")},
    },
    .{
        .name = "variable file/host_vars: references with declarations",
        .method = .references,
        .from = host_label_read,
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ <deploy_host_label> }}"),
            m.span(host_vars, "<deploy_host_label>: primary"),
        },
    },
    .{
        .name = "variable file/loaded settings field: definition",
        .method = .definition,
        .from = opens_read,
        .expected = &.{m.span(settings, "  <opens>: monday")},
    },
    .{
        .name = "variable file/loaded settings field: references with declarations",
        .method = .references,
        .from = opens_read,
        .include_declaration = true,
        .expected = &.{
            m.span(play, "{{ release_window.<opens> }}"),
            m.span(settings, "  <opens>: monday"),
        },
    },
};
