# Native Ansible AST and CEL diagnostics requirements

These product requirements documents (PRDs) are for implementers and reviewers
of Zals's native Ansible diagnostics. They record the agreed product scope and
provide acceptance criteria; they do **not** describe shipped functionality or
a completed CEL-C++ integration.

**Document status:** Drafts recording agreed requirements, ready for review.
**Repository baseline:** `fb808719d04b9bf68c33c09f588fec934f3847ba`, after rebasing
`ast1` onto the fetched `origin/main` before authoring.
**Implementation status:** No AST/CEL feature implementation in this change.

## Document map

Each document owns one part of the contract:

| Document | Responsibility |
| --- | --- |
| [PRD-0001: Recovered Ansible AST](0001-ansible-ast.md) | Minimal rule-driven representation, structural admission, maximal bounded recovery, Parse issues, source/metadata snapshots |
| [PRD-0002: Native CEL rules and rule authoring](0002-cel-rules.md) | CEL-C++ embedding, typed one-rule-per-file authoring, conditions/messages, custom-rule loading, limits, and reload behavior |
| [PRD-0003: Workspace-wide native diagnostics](0003-workspace-diagnostics.md) | Provider defaults, Workspace-wide scheduling, LSP locations, settings, suppressions, compatibility, and failure presentation |
| [Native coverage of ansible-lint checks](ansible-lint-coverage.md) | Complete pinned built-in inventory and approved implement/defer/exclude decisions |

The [project glossary](../../GLOSSARY.md) supplies domain terminology. Exact
public AST field names, target-selection schema, numeric resource limits, and
C++ ownership/build details remain implementation-design deliverables. They
must satisfy these requirements rather than silently changing product policy.

## Product outcome

Build a minimal Ansible AST in Zig as Workspace files are read and updated.
Evaluate useful native diagnostics by querying that AST with CEL predicates.
Users can work without ansible-lint, retain it for deeper checks, or run both
providers alongside the existing schema validator.

The selected checks drive the AST: retain only shared structural, source, value,
and metadata information needed by the approved catalog and diagnostic
reporting. Do not implement an Ansible execution engine, a complete Jinja
interpreter, or every upstream lint rule.

## Settled decisions

The following decisions are requirements, not alternatives still awaiting
selection:

- **Engine:** embed CEL-C++ in the native Zig server through a C-compatible
  interface. Do not implement another CEL interpreter or require a separate
  runtime service.
- **Catalog:** implement the support entries in the pinned ansible-lint 26.11.0
  matrix. Omit whole deferred/excluded subrules rather than approximate easy
  cases under the same compatibility claim.
- **Defaults:** native CEL and schema diagnostics are enabled; external
  diagnostics are disabled. Every implemented native built-in is enabled,
  including upstream opt-in rules.
- **Workspace scope:** native findings include unopened eligible files, not
  only open buffers. Unsaved buffer contents win over disk.
- **External compatibility:** preserve the enabled external provider's
  established behavior. The intentional changes are its default and the rule
  that disabling it also forbids syntax-check fallback.
- **Independent results:** no deduplication between diagnostic sources.
- **Collection:** use `ansible-doc --metadata-dump` and preserve its existing
  fallback. Collection can run with external diagnostics disabled; CEL itself
  has no subprocess, filesystem, or network access.
- **Recovery:** retain as many structurally understandable Tasks and children
  as possible, with bounded supplementary recovery beyond tree-sitter's
  surviving structure. Keep only context that can be established.
- **Parse issues:** expose observed YAML/Ansible structural failures as AST
  targets for CEL diagnostics. They are not fabricated Task nodes.
- **Recovered-view semantics:** no `tasks_complete` flags or completeness
  gating. Ordinary rules query the recovered lists and may report absence
  while the omitted Task is still being written.
- **Templates:** preserve explicit templated values. Rules may inspect only
  literal values or deliberately reject templates; `dyn` is not a template
  marker, and templates are not automatically rule errors.
- **Authoring:** one typed rule declaration per `.cel` file. Conditions return
  booleans; true means a violation. Messages are CEL string expressions, not
  YAML-embedded expressions or a second interpolation language.
- **Locations:** source-backed node ranges by default, with optional field
  targeting; structured LSP coordinates are separate from message text.
- **Custom rules:** support explicit global rule files and opt-in Workspace
  rule files. Invalid saved rules deactivate individually and lose their old
  findings; other rules continue.
- **Configuration:** native LSP settings only. No native `.ansible-lint`
  configuration support or planned importer.
- **Suppressions:** source-level `# noqa` comments, not task tags such as
  `skip_ansible_lint`. The external tool keeps its own configuration/tag
  behavior.
- **Detection:** preserve existing server/editor detection mechanisms. No
  shared detector, new classification overrides, or filetype switching during
  edits. [Issue #59](https://github.com/kksat/zals/issues/59) records the separate
  follow-up with examples and alternatives.
- **Editing source:** native diagnostics only; no native automatic fixes.

## Existing decisions that implementation must reconcile

The baseline provides useful foundations but not the new feature. The following
ADRs identify decisions that implementation must preserve, extend, or explicitly
supersede rather than contradict through code alone:

| Existing decision | Required review |
| --- | --- |
| [ADR-0004: YAML parsing](../adr/0004-yaml-parsing-tree-sitter.md) | Local recovery and Parse issues must replace the blanket-error fallback where needed without inventing valid structure |
| [ADR-0011: Threading](../adr/0011-threading-topology.md) and [ADR-0013: Memory](../adr/0013-memory-management.md) | Own immutable input/program lifetimes and keep worker/publication responsibilities clear |
| [ADR-0015: Validation](../adr/0015-validation-behavior.md) | Add an independent native source while preserving enabled external compatibility and documenting the two intentional behavior changes |
| [ADR-0019: Toolchain](../adr/0019-toolchain-build-and-platforms.md) | Validate the C++ dependency/linking strategy; the release workflow already has five targets, including Windows |
| [ADR-0031: Workspace index](../adr/0031-workspace-index.md) | The index retains facts, not AST/source trees; define the smallest reusable storage needed for native evaluation |
| [ADR-0037: Selected environments](../adr/0037-selected-venv-collections.md) | Preserve per-context metadata isolation and reject version-only cache reuse across different environments |
| [ADR-0043: Readiness](../adr/0043-custom-readiness-without-refresh.md) | Do not reinterpret catalog readiness as metadata or diagnostic completion, or silently restore a removed refresh command |
| [ADR-0048: Code comments](../adr/0048-no-inline-code-comments.md) | Record implementation decisions in durable documents; source suppression fixtures are data, not permission to add explanatory code comments |

These PRDs do not mark existing ADRs superseded in advance of an implementation.
They also do not treat every behavior promised by an older ADR as proven to
exist in the baseline code.

## Delivery sequence and gates

The feature can be built in focused changes, but the approved target is the
complete support column, not an unannounced reduction to a handful of checks.

1. **Prove the integration constraints.** Link a pinned CEL-C++ slice, check the
   typed declaration, extract/compile condition and message subexpressions,
   exercise typed inputs and source positions, and validate the five-target
   distribution strategy. Capture resource/cancellation behavior and costs.
2. **Establish the AST/recovery contract.** Implement explicit structural
   admission, Parse issues, typed/source-backed values, and reusable snapshots.
   Add recovery and metadata-isolation fixtures before expanding the catalog.
3. **Deliver a vertical diagnostic slice.** Run a parse-issue rule and
   representative Task/Play checks through real LSP publication, including an
   unopened file, an unsaved edit, suppression, and provider switching.
4. **Complete the approved rules and authoring surface.** Port the full selected
   catalog, distribute the typed rule environment, support global/Workspace
   rule loading, and implement reload/failure isolation.
5. **Verify scale and compatibility.** Exercise Workspace-wide invalidation,
   limits, stale-result rejection, external-provider characterization, editor
   regressions, and packaging. Record migration behavior before release.

If an engineering gate exposes a blocker that requires dropping a release
target, changing the engine, weakening a rule's semantics, or changing agreed
recovery behavior, obtain an explicit scope decision. Do not hide that change
inside a fallback or an undocumented compatibility exception.

## Verification strategy

Tests must cross the same interfaces used by the server and use independent
expected results. The minimum verification layers are:

- **AST fixtures:** intact and malformed source, wrong Ansible shapes, alternate
  invocation forms, literal/template values, source ranges, and recovered child
  relationships.
- **Rule conformance:** positive/negative/edge fixtures against the pinned
  upstream subrules with options and opt-in enablement explicitly controlled.
- **Rule-host tests:** typed declarations, metadata extraction, condition and
  message failures, source mapping, IDs, trust, reloads, and resource limits.
- **Real stdio tests:** all provider combinations, forbidden subprocess
  assertions, unopened-file publication, edits/deletions/reloads, URI/position
  encoding, and obsolete work.
- **Editor regression tests:** preserve existing VS Code/Neovim attachment;
  CEL editing tests verify the new rule environment separately, without
  redesigning Ansible file detection.
- **Build/distribution tests:** link/package all release targets and exercise
  native runtime behavior where target runners are available. Compile-only
  success is not runtime proof.
- **Performance tests:** record startup, memory, Workspace evaluation, edit
  latency, and cancellation under representative and adversarial inputs.
  Set explicit budgets based on this evidence; no benchmark is claimed here.

Use the repository's existing `make check` gate for each implementation change,
plus relevant `make e2e`, `make parity`, and `make neovim-test` suites. Add
feature-specific fixtures and test roots through the normal build/test system;
these PRDs do not claim those tests already exist.

## Non-goals

The feature does not include these projects:

- Full ansible-lint replacement or all of its CLI/configuration behavior.
- Native execution of Ansible Modules, playbooks, or Jinja to resolve a check.
- Native YAML formatting, Jinja formatting, automatic fixes, or lossless source
  rewriting.
- A detector-sharing service or automatic editor language reassignment.
- A complete symbolic uncertainty model or completeness-gated AST queries.
- Arbitrary Python/custom native rule plugins, remote rule downloads, or an
  unrestricted helper interface.
- Repair of unrelated existing schema, navigation, metadata, or external-lint
  issues unless a specific approved requirement depends on that repair.
