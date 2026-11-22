# PRD-0003: Workspace-wide native diagnostics

**Status:** Draft recording agreed product requirements; not implemented.
**Audience:** Implementers and reviewers of validation, settings, and LSP delivery.
**Baseline:** `fb808719d04b9bf68c33c09f588fec934f3847ba`.
**Related:** [PRD index](README.md), [Ansible AST](0001-ansible-ast.md),
[CEL rules](0002-cel-rules.md), [approved coverage](ansible-lint-coverage.md).

## Problem and outcome

Provide useful Workspace-wide Ansible diagnostics without requiring
`ansible-lint`. Users can also retain the external tool's deeper checks and the
existing schema validator. Native rule evaluation must be independent of
external-tool execution, while metadata collection remains available for the
AST and other language features.

The product has three diagnostic sources:

| Source | Default | Required scope/behavior |
| --- | --- | --- |
| Native CEL | Enabled | Evaluate the approved built-ins and loaded custom rules across eligible Workspace files, including unopened files |
| Native schema validator | Enabled | Retain the existing validator and its coverage; do not replace it with CEL |
| External Ansible diagnostics | Disabled | When enabled, preserve the established ansible-lint/Ansible language-server compatibility contract |

The sources can be enabled independently under the overall validation control.
When more than one reports the same problem, **keep both findings**. There is no
cross-source deduplication, ownership preference, or automatic handoff of a rule
from the external provider to CEL.

## Baseline and compatibility

The [validation service](../../src/services/validation.zig) combines schema
results with external lint/syntax-check results. The baseline lint setting
defaults to enabled, and disabling lint can still start syntax-check.
[Document synchronization](../../src/lsp/sync.zig) schedules validation on open
and save; the baseline change handler updates text without scheduling native
CEL work. A native rule registry and Workspace-wide CEL scheduler do not exist.

[ADR-0015](../adr/0015-validation-behavior.md) records the external compatibility
intent. Its complete parity list must not be presented as proof that every item
is implemented. Characterize the actual enabled-provider behavior and protect
it while adding the native path. This work is not a general external-validator
rewrite or a project to repair all historical parity gaps.

Two external behavior changes are intentional:

1. External diagnostics default to disabled.
2. Disabling that provider forbids both `ansible-lint` and
   `ansible-playbook --syntax-check`; there is no disabled-provider fallback.

Otherwise preserve its command/argument handling, open/save behavior, existing
quick-validation/cached-result policy where implemented, and enabled-provider
fallback semantics. Do not make the native Workspace scheduler invoke external
lint once per indexed file or change enabled external behavior merely to share
an internal scheduler. External fixes, if separately supported/configured, are
outside the native diagnostics-only feature and must not be redesigned here.

## Requirements

### DIAG-01: Keep collection and providers independent

The following execution contract is mandatory:

| External provider | CEL provider | Diagnostic execution permitted |
| --- | --- | --- |
| Off | On | Native CEL only, plus the schema source if enabled |
| On | Off | Existing external diagnostics, plus the schema source if enabled |
| On | On | Both, without deduplication, plus the schema source if enabled |
| Off | Off | Neither external nor CEL; schema can still run if enabled |

Disabling all validation sources does not disable indexing, navigation, or
permitted metadata collection needed by other language features.

`ansible-doc --metadata-dump` and its existing collection fallback remain
permitted independently of the external diagnostic switch. Metadata collection
is outside CEL evaluation. The evaluator and its helpers cannot launch a
subprocess, read a file, or access the network. Do not turn missing metadata into
an implicit lint/syntax-check fallback when external diagnostics are disabled.

### DIAG-02: Evaluate the whole eligible Workspace

Evaluate CEL rules for unopened eligible files during background indexing, not
only when a document is opened. Reevaluate affected native inputs after:

- Open-buffer edits, using debounced background work.
- Saves and filesystem changes within existing discovery boundaries.
- Relevant metadata snapshot changes.
- Rule-file reloads, rule options, enablement, and permission changes.
- Workspace additions/removals and source creation/deletion observed by the
  existing discovery/update mechanisms.

Open buffers override disk snapshots. When a buffer closes, return to its disk
view for Workspace diagnostics rather than clearing native findings solely
because the buffer is no longer open. Remove findings for deleted sources or
removed Workspaces. Context dependencies must be invalidated when a change
alters a supported check's inputs, without reevaluating every rule on every
file for each keystroke.

Keep scheduling bounded and cancellable. Do not block editor requests on a
complete Workspace scan or on module documentation bootstrap. Publish useful
results progressively. Reuse the existing fallback behavior for clients without
filesystem watching; document its discovery limitations rather than inventing
an unrelated detection/refresh feature.

### DIAG-03: Keep file detection unchanged

Reuse existing workspace discovery, Ansible classification, editor associations,
and attachment mechanisms. Discovery by extension is not itself a new semantic
classification rule. Preserve existing document-kind evidence and do not turn
all discovered YAML or Jinja text into task input indiscriminately.

This delivery does not introduce a shared detector manifest, classifier CLI,
custom classification request, new classification overrides, or automatic
filetype switching while a buffer changes. VS Code and Neovim definitions
remain separate. Existing detection inconsistencies are deliberately deferred
to [issue #59](https://github.com/kksat/zals/issues/59), not silently repaired as
part of AST construction.

Attachment and task diagnostics remain distinct. For example, a `.j2` template
can retain variable-navigation support without becoming a YAML Task document.
The native feature must not broaden nested-Workspace or exclusion boundaries
or lint external dependency files merely because their metadata was consulted.

### DIAG-04: Publish source-backed diagnostics

Each native finding carries a source identifier, stable rule ID, severity,
message, document URI, and source range. The host resolves these from the rule
and AST target; it does not parse a filename or coordinate out of message text.

Use the selected node's range by default. Support an optional source-backed
field selector so a Module-name check can underline the Module key. Define a
safe fallback to the target's range when a selected optional field is absent;
invalid selectors are rule-definition errors, not arbitrary offsets. A
parse-issue rule uses the issue's own recorded range unless explicitly selecting
another supported source-backed location.

Provide 1-based human-facing line/column values to message expressions. Convert
source offsets to zero-based LSP positions with the negotiated encoding. Test
Unicode, CRLF, missing/zero-width locations, and URI escaping. Document the
source-column convention rather than confusing it with screen width after tab
expansion. Display paths can be Workspace-relative, but the URI remains
unambiguous.

Keep results separate by provider and input generation before composing the
LSP publication for a URI. Updating or disabling one source must not erase the
others. Discard obsolete native document/ruleset/metadata results; cancellation,
rule deletion, or provider disablement must not allow a late worker to restore
old findings. Preserve the external provider's own compatibility policy rather
than imposing a new native revision policy on its cached results.

### DIAG-05: Configure native checks only through LSP settings

Use the CEL settings in PRD-0002, including explicit global/Workspace rule files,
Workspace permission, rule enablement, severity overrides, and supported rule
options. Retain the overall validation control and expose independent provider
controls. The external setting remains `ansible.validation.lint.enabled`, with
the new default and disabling semantics specified here.

Do not load, import, or plan compatibility with `.ansible-lint` configuration for
the native provider. In particular, native rule selection must not inherit its
profiles, `skip_list`, `warn_list`, `enable_list`, or discovery configuration.
Use the pinned built-in defaults and explicitly documented native options.
The independently invoked external tool can still read its own configuration
normally; this restriction is not a change to that tool's behavior.

All implemented native built-ins are enabled by default, including upstream
opt-in rules. Native configuration, recovery, rule defaults, and source ranges
are deliberate differences from the external linter's end-to-end output. Rule
compatibility means the selected detectors and supported options, not identical
CLI lifecycle or byte-for-byte diagnostic prose.

### DIAG-06: Honor comment suppressions, not task tags

Support source-level `# noqa` comments, including suppression by corresponding
built-in rule/subrule identity and by custom rule ID. A broad `# noqa` can
suppress applicable native findings according to the documented attachment
scope. Do not implement `skip_ansible_lint` tags or other task-tag suppression
for CEL. The external tool retains its own tag semantics.

Collect actual comments using source/parser evidence. Text resembling `# noqa`
inside a string, block scalar, or template literal is not a suppression comment.
Specify and test comment attachment for Task, Play, metadata, parse-issue, and
field-targeted diagnostics. A field selector must not unexpectedly change the
meaning of an established task-level suppression. Do not promise a suppression
whose source cannot be recognized in a damaged region.

This is comment compatibility for selected native rules, not `.ansible-lint`
configuration compatibility. Do not add a second comment language merely to
support custom rules. Keep suppression processing separate from whether a CEL
condition evaluates true.

### DIAG-07: Make failures visible without flooding source diagnostics

Use consolidated, inspectable status to explain unavailable checks or metadata.
Do not emit the same metadata-tool failure on every Task. Transient loading
should not repeatedly interrupt the editor with warnings. Persistent failures
must be discoverable without requiring debug logs.

Distinguish these outcomes:

| Outcome | User-visible treatment |
| --- | --- |
| Condition true with a valid message | Native finding at the selected source location |
| Condition false | No finding from that evaluation |
| Intentional disablement or comment suppression | No finding; distinct from failure |
| Metadata pending, unavailable, or invalidated | Independent checks continue; consolidated availability explanation |
| Parse issue | Available to CEL as a target; it does not gate other rules |
| Invalid saved custom rule | Deactivate that rule, remove its previous findings, and report the rule-file error |
| Runtime/type/message error or resource limit | Bounded rule/provider error, not an invented Ansible violation |
| Obsolete/cancelled work | No late publication for that generation |

The absence of diagnostics is not a certification that every possible check
ran or that every intended Task was recovered. Do not introduce completeness
flags or suppression of ordinary AST queries to change the agreed recovery
semantics.

Keep existing `ansible/workspaceIndexReady` and `ansible/docsLibraryReady`
contracts intact. As [ADR-0043](../adr/0043-custom-readiness-without-refresh.md)
states, the latter describes catalog/discovery readiness, not full metadata
prefetch. Native diagnostic readiness/status must not silently repurpose either
notification. Select a status presentation compatible with ordinary LSP clients;
any additional protocol surface needs its own explicit contract.

## Acceptance scenarios

| Scenario | Observable acceptance result |
| --- | --- |
| Default startup without ansible-lint | Native and schema providers are enabled; no external lint/syntax-check attempt |
| Every provider combination and the master validation switch | Correct findings and subprocess permissions; metadata collection remains independent |
| External provider enabled | Characterization/parity tests preserve its established invocation and publication behavior except the documented switch/default changes |
| Two providers report the same problem | Both findings remain, with distinct sources |
| An unopened eligible file has a violation | Native diagnostics appear after background indexing without opening the file |
| Unsaved edit changes a finding | Updated native ranges/results use that buffer, not disk |
| Close, delete, rename, or remove a Workspace | Native findings follow the corresponding source lifecycle; other providers are not accidentally cleared |
| Edit/rule reload during slow evaluation | Old results cannot overwrite newer findings |
| `# noqa`, targeted IDs, and comment-like scalar text | Only real, correctly attached comments suppress native findings |
| `tags: [skip_ansible_lint]` | Does not suppress a native finding |
| `.ansible-lint` contains a skip list | Native checks remain unaffected; external behavior remains its own |
| Invalid custom rule saved after producing findings | Only that rule's findings disappear; corrected source reactivates it |
| Missing/partial metadata | Metadata-free findings remain; one inspectable availability explanation replaces per-task tool errors |
| Unrelated YAML, Role templates, and incomplete edits | Existing detection/attachment behavior remains unchanged |
| Large Workspace or expensive custom rule | Bounded worker/resource use and responsive requests; measured limits recorded before release |

## Release and migration requirements

Document the following user-visible changes before release:

- External diagnostics are opt-in, and disabling them also disables syntax-check.
- Native findings include unopened eligible files and all implemented built-ins
  by default; upstream opt-in policies can therefore produce additional findings.
- Native rules ignore `.ansible-lint` configuration and task suppression tags.
- Source comments and native LSP settings control native findings.
- Keeping multiple providers enabled can produce duplicate-looking findings.
- Custom Workspace rules require explicit permission and invalid saved rules
  stop running rather than silently retaining their last valid version.

Update settings descriptions and provider tests when implementation lands.
Preserve existing editor detection and external-tool options. Release-note
preparation remains the repository's separate, human-invoked workflow; this PRD
is not a release note or a statement of shipped functionality.
