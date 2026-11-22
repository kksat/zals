# Native coverage of ansible-lint checks

**Status:** Approved target selection; no native CEL implementation is claimed.
**Purpose:** Define the checks that determine the minimal Ansible AST and the
native rule catalog in [PRD-0001](0001-ansible-ast.md) and
[PRD-0002](0002-cel-rules.md).

## Reference and interpretation

The reference catalog is **ansible-lint 26.11.0**, commit
[`b74fb6f73d234bf92672372cb1c10768e4018d16`](https://github.com/ansible/ansible-lint/tree/b74fb6f73d234bf92672372cb1c10768e4018d16).
The inventory covers **54 top-level built-in IDs**: 50 ordinary rule families
and four internal/error families. Arbitrary Python plugins are not a closed
catalog and are not included. Native custom CEL rules are a separate extension
mechanism, not ports of Python plugins.

The source references in the tables are files under that commit's
[`src/ansiblelint/rules`](https://github.com/ansible/ansible-lint/tree/b74fb6f73d234bf92672372cb1c10768e4018d16/src/ansiblelint/rules)
unless a different path is stated. Emitted tags were inspected, not only each
class's `_ids` declaration; those declarations omit some emitted subrules and
include at least one unimplemented tag.

The status meanings are:

- **Implement:** part of the first native target. Every implemented built-in
  is enabled by default, including upstream opt-in rules.
- **Defer:** statically feasible in principle, but outside the first target
  because required normalization, metadata, configuration, or cross-file work
  is substantial. Do not claim partial support under the same subrule ID.
- **Exclude:** outside this native scope. The separately enabled external
  provider can still report it. Exclusion is not always an impossibility claim.

Port selected **detectors**, not their automatic fixes. Match a whole selected
rule/subrule under its documented native option contract rather than only its
easiest invocation syntax. Test equivalent module/action forms, scalar types,
templates, exceptions, and source sites. Detection logic remains CEL; common
normalization and source handling belong to the host.

End-to-end output intentionally differs from the CLI: all native built-ins are
enabled, configuration is LSP-only, recovery does not gate ordinary checks,
only comment suppressions apply, and locations can be more precise. Exact
message prose need not be identical. These differences are not permission to
change the detector's meaning while retaining its compatibility claim.

## Implement: 34 complete ordinary families

Every emitted check in these families is in the native target:

| Family | Checks and minimum facts | Detector source |
| --- | --- | --- |
| `avoid-implicit` | Normalized copy invocation and typed content; non-string content check | `avoid_implicit.py` |
| `command-instead-of-module` | Command words/basename, fixed replacement table, and argument exceptions | `command_instead_of_module.py` |
| `command-instead-of-shell` | Shell invocation, executable presence, and lexical command inspection | `command_instead_of_shell.py` |
| `complexity` | `[play]`, `[tasks]`, `[nesting]`; source counts/ancestry and configured thresholds | `complexity.py` |
| `deprecated-bare-vars` | Loop keys, typed values, and fixed lexical/glob exceptions | `deprecated_bare_vars.py` |
| `deprecated-local-action` | Raw `local_action` presence | `deprecated_local_action.py` |
| `deprecated-module` | Normalized name and the pinned hard-coded deprecation list | `deprecated_module.py` |
| `empty-string-compare` | Conditional strings/lists and the fixed comparison detector | `empty_string_compare.py` |
| `galaxy-version-incorrect` | Collection version field and pinned comparison behavior | `galaxy_version_incorrect.py` |
| `ignore-errors` | `ignore_errors`, `register`, and exact literal exceptions | `ignore_errors.py` |
| `inline-env-var` | Normalized command options and command words | `inline_env_var.py` |
| `jinja-template-extension` | Template action and literal source path, including upstream skip cases | `jinja_template_extension.py` |
| `key-order` | `[play]`, `[task]`; ordered raw keys and fixed ordering groups | `key_order.py` |
| `latest` | `[git]`, `[hg]`; revision/version values and absent-value defaults | `latest.py` |
| `literal-compare` | Conditional strings/lists and true/false comparison text | `literal_compare.py` |
| `meta-incorrect` | Role metadata fields and generated-placeholder strings | `meta_incorrect.py` |
| `meta-no-tags` | Role metadata tags/categories, field types, and lexical checks | `meta_no_tags.py` |
| `meta-video-links` | Typed video-link entries and fixed URL patterns; no network requests | `meta_video_links.py` |
| `no-changed-when` | Command/shell/raw invocation, condition/argument presence, and async exceptions | `no_changed_when.py` |
| `no-free-form` | Base, `[raw]`, `[raw-non-string]`; original invocation, typed arguments, and include exceptions | `no_free_form.py` |
| `no-handler` | Known Handler context and fixed conditional-text heuristics | `no_handler.py` |
| `no-jinja-when` | Task and role-entry `when` values and lexical delimiters | `no_jinja_when.py` |
| `no-log-password` | Password-related option names, loop information, boolean conversion, and template exceptions | `no_log_password.py` |
| `no-prompting` | Play prompts and pause options | `no_prompting.py` |
| `no-relative-paths` | Fixed action/folder table and source-path text | `no_relative_paths.py` |
| `no-same-owner` | Synchronize/unarchive arguments and missing-versus-explicit delegation | `no_same_owner.py` |
| `no-tabs` | Nested Task key/value strings, template detection, and pinned exceptions | `no_tabs.py` |
| `only-builtins` | Original action spelling, pinned builtin table, and native allow-list options | `only_builtins.py` |
| `package-latest` | Package-action table and state/version/update options | `package_latest.py` |
| `partial-become` | `[play]`, `[task]`; `become_user` and `become` presence at the same mapping level | `partial_become.py` |
| `playbook-extension` | Existing Playbook classification and source filename | `playbook_extension.py` |
| `risky-file-permissions` | Typed options and fixed module/default-create/mode exceptions | `risky_file_permissions.py` |
| `risky-shell-pipe` | Shell text, executable/ignore-errors facts, and equivalent pipe/pipefail detection | `risky_shell_pipe.py` |
| `run-once` | `[play]`, `[task]`; file kind, strategy, and task flag | `run_once.py` |

## Mixed coverage: six ordinary families

The subrule, not the family name, is the implementation unit:

| Family | Implement | Defer | Exclude |
| --- | --- | --- | --- |
| `fqcn` | `[keyword]` | `[action]`, `[action-core]`, `[canonical]` | `[deep]` |
| `galaxy` | `[tags]`, `[tags-format]`, `[tags-length]`, `[tags-count]`, `[version-missing]`, `[invalid-dependency-version]`, `[no-repository]`, `[no-license]` | `[no-changelog]`, `[no-runtime]` | None |
| `name` | `[play]`, `[missing]`, `[unique]`, `[template]` | `[casing]`, `[prefix]` | None |
| `role-name` | `[path]` | Base rule | None |
| `schema` | `[moves]` | Ansible schema tags listed in the schema scope section | Non-Ansible/tool schema tags listed in that section |
| `var-naming` | `[non-string]`, `[non-ascii]`, `[no-keyword]` | `[no-reserved]`, `[read-only]`, `[pattern]`, `[no-role-prefix]` | `[no-jinja]` declaration without an emitted match |

The reasons for splitting these families are:

- **`fqcn`:** the keyword check is structural. Action/canonical checks need
  faithful plugin identity, collection search order, and redirect resolution;
  counting dots is not equivalent. `[deep]` checks plugin-source path layout,
  excluded by scope rather than by runtime requirements. Source: `fqcn.py`.
- **`galaxy`:** field checks use typed metadata and fixed policy tables.
  Changelog/runtime checks need cross-file existence facts and invalidation.
  Preserve early returns and ordering that affect which checks are reached.
  Source: `galaxy.py`.
- **`name`:** presence, immediate-list uniqueness, and template-text checks
  are selected. Prefix/casing checks need additional path/configuration and
  Unicode semantics. Prefix-related preconditions can affect other name checks;
  preserve the declared native option profile rather than guessing. Source:
  `name.py`.
- **`role-name`:** path references are local facts. The base check depends on
  Role-directory identity, metadata overrides, and naming rules. Source:
  `role_name.py`.
- **`schema`:** `[moves]` is a fixed Task-key migration check, not general
  schema validation. The existing native schema provider remains independent.
  Source: `schema.py` and `src/ansiblelint/schemas/`.
- **`var-naming`:** the first lexical/type checks need correct Variable
  definition sites and a pinned Python-keyword set as data. The deferred checks
  depend on reserved-name metadata, prefix context, configurable regex behavior,
  and first-error precedence. `[no-jinja]` is declared but the inspected matcher
  skips templated names instead of emitting it; do not invent a native finding
  from the declaration alone. Source: `var_naming.py`.

### Schema scope

Defer upstream parity for these Ansible schema tags:

```text
execution-environment, galaxy, inventory, meta, meta-runtime,
play-argspec, playbook, requirements, role-arg-spec, tasks, vars
```

Also defer the dynamic `schema[handlers]` field-check path. Some play/task/
handler checks include installed become-plugin membership in addition to JSON
Schema behavior. The baseline's narrow validator is not proof of full upstream
schema compatibility.

Exclude these tool/release-note/EDA schema tags from this native CEL scope:

```text
ansible-lint-config, ansible-navigator-config, changelog, molecule, rulebook
```

These exclusions do not remove any existing native schema coverage or modify
the external provider.

## Defer: four complete ordinary families

| Family | Checks and reason | Detector source |
| --- | --- | --- |
| `loop-var-prefix` | `[missing]`, `[wrong]`; Role context, prefix configuration, and compatible regex semantics | `loop_var_prefix.py` |
| `meta-runtime` | `[unsupported-version]`, `[invalid-version]`; effective version policy and compatible specifier parsing | `meta_runtime.py` |
| `risky-octal` | Full scalar/numeric interpretation and the permission-bit heuristic, not a leading-zero text check | `risky_octal.py` |
| `role-argument-spec` | Role-directory discovery, sibling/embedded metadata, and cross-file refresh/target handling | `role_argument_spec.py` |

## Exclude: six complete ordinary families

| Family | Checks and reason | Detector source |
| --- | --- | --- |
| `args` | `[module]`; full behavior imports/executes Module argument-validation machinery. Documentation fields are not equivalent. | `args.py` |
| `event-query` | All audit-query format checks; outside the initial Ansible AST domain, although the inspected checks are static | `event_query.py` |
| `jinja` | `[invalid]`, `[spacing]`; full Ansible/Jinja interpretation and Jinja/Black formatting behavior | `jinja.py` |
| `sanity` | `[cannot-ignore]`, `[bad-ignore]`; sanity-ignore text files outside the selected domain | `sanity.py` |
| `syntax-check` | `[missing-file]`, `[no-file]`, `[empty-playbook]`, `[malformed]`, `[unknown-module]`, `[specific]`; external Ansible loading/syntax-check behavior | `syntax_check.py` |
| `yaml` | Full yamllint raw-source/configuration behavior, including the tags listed in the YAML scope section | `yaml_rule.py` |

The excluded `event-query` tags are:

```text
module-key-format, invalid-entry, invalid-query-type, missing-query,
query-missing-field, device-type, device-type-missing, canonical-facts-empty
```

Diagnostics-only scope does not make `jinja[spacing]` a simple AST predicate:
upstream computes a formatted candidate to decide whether a diagnostic exists,
not only to apply an optional fix.

### YAML scope

Exclude all 23 named yamllint subrules declared by the pinned wrapper:

```text
anchors, braces, brackets, colons, commas, comments-indentation,
comments, document-end, document-start, empty-lines, empty-values,
float-values, hyphens, indentation, key-duplicates, key-ordering,
line-length, new-line-at-end-of-file, new-lines, octal-values,
quoted-strings, trailing-spaces, truthy
```

Syntax/error paths and any dependency-generated dynamic tags are also excluded.
The documentation's `yaml[syntax]` spelling and the wrapper's possible
`yaml[None]` path must not be conflated without execution evidence. The runtime
yamllint dependency can evolve independently; this is not a promise to enumerate
all tags an arbitrary future dependency may emit.

Native parse issues are still in scope under a native identity. Excluding the
`yaml` rule family does not prevent reporting native parser observations.

## Exclude as ports: four internal/error families

These complete the inventory of 54 top-level IDs:

| Family | Upstream behavior and native distinction |
| --- | --- |
| `internal-error` | Linter/runtime exceptions and unmatched subprocess failures; native engine errors have their own identity |
| `parser-error` | Ansible task-normalization failures; native Parse issues do not claim to reproduce every Python parser condition |
| `load-failure` | Base, `[not-found]`, `[yaml]`, and dynamic exception-class tags; native read/parse failures use their own contract |
| `warning` | Base/arbitrary warning tags, including `[outdated-tag]`; native rule/configuration problems are not ports of this channel |

Sources: pinned
[`src/ansiblelint/_internal/rules.py`](https://github.com/ansible/ansible-lint/blob/b74fb6f73d234bf92672372cb1c10768e4018d16/src/ansiblelint/_internal/rules.py),
[`runner.py`](https://github.com/ansible/ansible-lint/blob/b74fb6f73d234bf92672372cb1c10768e4018d16/src/ansiblelint/runner.py),
and [`utils.py`](https://github.com/ansible/ansible-lint/blob/b74fb6f73d234bf92672372cb1c10768e4018d16/src/ansiblelint/utils.py).

## Compatibility traps and verification

Several rule names imply stronger analysis than their detector performs:

- `deprecated-module` uses a fixed list, not arbitrary installed deprecation
  metadata.
- `galaxy[invalid-dependency-version]` rejects empty/whitespace text rather than
  fully validating version ranges.
- `galaxy-version-incorrect` uses the pinned implementation's string-component
  comparison; do not substitute a different version algebra silently.
- `partial-become` inspects the same mapping level, not runtime inheritance.
- `name[unique]` inspects the immediate task sections of a named Play; it does
  not recursively expand includes or every nested Block.
- `no-handler` uses lexical heuristics, not a proof of equivalent execution.
- `no-jinja-when` detection and its transformer do not inspect exactly the same
  fields. Port the detector, not extra behavior inferred from the fix.
- `run-once[task]` is not a complete execution-strategy analysis.

CEL uses RE2-style matching, not arbitrary Python regex syntax. Equivalent
predicates may require different expressions or bounded common lexical helpers.
Do not drop lookarounds into CEL and assume they work.

For each implemented rule/subrule, check in positive, negative, and edge-case
fixtures with expected rule IDs and source locations. Differential tests must
pin upstream and explicitly configure opt-in rules/options so comparisons are
meaningful. Isolate intentional lifecycle differences: native recovery, native
settings, comment-only suppression, and all-enabled defaults.

Do not use native output to generate its own expected results. Record syntax,
option, and upstream version coverage with the fixtures. A scope change moves
an entire rule/subrule with an explicit review; it does not silently downgrade
an approved detector to an approximate imitation.
