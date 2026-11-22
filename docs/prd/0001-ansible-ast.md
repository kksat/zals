# PRD-0001: Recovered Ansible AST

**Status:** Draft recording agreed product requirements; not implemented.
**Audience:** Implementers and reviewers of native Ansible diagnostics.
**Baseline:** `fb808719d04b9bf68c33c09f588fec934f3847ba`.
**Related:** [PRD index](README.md), [CEL rules](0002-cel-rules.md),
[diagnostic delivery](0003-workspace-diagnostics.md),
[approved rule coverage](ansible-lint-coverage.md).

## Problem and outcome

Zals needs a native representation of Ansible source that CEL rules can query
without invoking Ansible or Python to interpret a task. The representation must
remain useful during incomplete edits and expose parsing failures as data that
rules can report.

Build the smallest Ansible abstract syntax tree (AST) that supports the approved
checks. Derive its information requirements from those checks, not from a goal
of reproducing Ansible's complete execution model. Reuse the existing YAML and
Ansible structural machinery rather than creating a competing interpretation
for each rule.

The AST is deliberately a **recovered view**, not a claim to contain every task
the author intended. A rule querying that view may report a missing task while
the omitted task is being written. That behavior is intentional.

## Baseline and integration constraints

The baseline already contains several useful pieces:

- [YAML nodes](../../src/yaml/dom.zig) with source ranges and parent links.
- [Play/task/block recognition](../../src/yaml/plays.zig).
- [Workspace facts](../../src/workspace/facts.zig) used by navigation.
- [Module documentation collection](../../src/services/docs.zig), including
  `ansible-doc --metadata-dump`.

These pieces do not constitute the required retained, normalized Ansible AST.
The [tree-sitter adapter](../../src/yaml/treesitter.zig) rejects a tree whose root
contains an error, and [YAML dispatch](../../src/yaml/root.zig) falls back to the
subset parser. The [Workspace index](../../src/workspace/index.zig) retains
facts rather than source trees. Module lookup can perform I/O on a cache miss.
None of those behaviors should be mistaken for the new AST contract.

Implementation must review the storage and recovery decisions in
[ADR-0004](../adr/0004-yaml-parsing-tree-sitter.md),
[ADR-0013](../adr/0013-memory-management.md), and
[ADR-0031](../adr/0031-workspace-index.md). These PRDs do not silently supersede
those ADRs or claim the required changes have shipped.

## Scope

The AST covers source-backed representations needed by the selected rules:

| Concept | Required information |
| --- | --- |
| Document | URI/path, existing file-kind context, source revision, roots, source ranges, and ordered source structure |
| Play | Relevant keywords, task sections, role invocations, and their source order |
| Task | Original invocation, normalized action and arguments, task keywords, and known containing context |
| Block and Handler | Recoverable child lists and known section/handler relationships |
| Role invocation/reference | Source spelling, passed values, and known Role/Collection context |
| Variable definition | Definition site and typed name, according to the existing domain vocabulary |
| Role/Collection metadata | Fields required by the selected metadata rules, not a new complete schema engine |
| Value | Literal type/value or explicit templated/expression representation, with source spelling and location |
| Parse issue | An observed YAML or Ansible structural failure, its location, and an explanation |
| Collected environment facts | Only the static metadata required by supported checks, with availability and provenance |

These are information requirements, not a mandate for one public struct per row.
Every exposed field must serve an approved rule, source reporting, or shared
structural interpretation. Do not retain an entire concrete syntax tree or a
copy of all installed documentation merely because it is available.

## Requirements

### AST-01: Construct reusable source snapshots

Create the native representation when eligible Workspace source is read or
updated. Reuse it across rule evaluations instead of reparsing separately for
each rule. Open-buffer contents take precedence over the indexed disk copy.

Workers evaluate immutable snapshots. Source text, source ranges, related
facts, and metadata bindings must remain valid for the complete evaluation.
Keep document, ruleset, and metadata revisions distinguishable so the publisher
can discard obsolete results. The concrete storage strategy must fit the
existing bounded worker pool and single-writer index ownership.

Preserve document boundaries in multi-document YAML. Do not accidentally treat
a recovery fragment as an independent YAML document. Existing workspace roots,
discovery exclusions, and editor file detection remain unchanged; see
[issue #59](https://github.com/kksat/zals/issues/59).

### AST-02: Admit structurally understandable Ansible nodes

Task admission depends on source structure, not on installed module metadata or
the ability to evaluate an argument. Apply the following contract:

| Source situation | Required treatment |
| --- | --- |
| Valid Task using an uninstalled or unknown Module | Retain the Task and known source facts |
| Task with a templated argument | Retain the Task and identify the templated value |
| Module key with null/omitted arguments, such as `ansible.builtin.debug:` | Admit when that is a structurally valid invocation |
| A Task containing only `name`, without an action or Block section | Record an incomplete/invalid Ansible structure; do not invent an executable Task |
| Conflicting action/module keys | Record a structural issue; do not silently select one action |
| Scalar or nested sequence where a Task mapping is required | Record a structural issue; do not admit it as a Task |
| `block: not-a-list` | Record a structural issue; independently recover valid other sections/children |
| Broken YAML syntax | Record the observed syntax issue and recover other usable structure |

Normalize legal action forms required by the selected checks, including module
keys, `action`, `local_action`, free-form arguments, and `args`. Preserve the
original spelling/form as well: a check about free-form syntax cannot use only
its normalized result. Argument normalization must not execute Python,
`ModuleArgsParser`, a Module, a playbook, or Jinja.

### AST-03: Recover as much structure as possible

Retain valid siblings and independently parseable children even when an
ancestor has damaged fields. Preserve the parent/section relationships that can
be established; unavailable ancestor information remains unavailable. Do not
promote recovered children to an invented root or fabricate an intact parent.

Use tree-sitter's surviving structure and supplement it with **bounded
source-region recovery** when needed. A successful tree-sitter parse of an
individual candidate is evidence to inspect, not proof of Ansible ownership.

Recovery must observe the following constraints:

- Inspect local error/missing-node information rather than discarding every
  descendant of a node with `has_error`.
- Inspect useful descendants of error wrappers instead of dropping every
  `ERROR` subtree wholesale.
- Protect recognized scalar, quoted-text, and comment regions.
- Use indentation and lexical/container context when identifying candidate
  task or section boundaries. Blank lines and `- name:` alone are not fences.
- Preserve original source offsets when reparsing a candidate region.
- Bound attempts, input sizes, nesting, and work so malformed input cannot
  monopolize the server.

An unfinished quote or flow collection can hide apparent later tasks. Recovery
is best effort, not a guarantee to infer every intended boundary. Record the
observed unparsed/error region when more specific attribution is unavailable.

### AST-04: Represent parse issues without gating ordinary rules

Expose parse-issue nodes as CEL targets alongside recovered Ansible nodes.
Each issue needs a source reference, an explanation, and enough categorization
to distinguish YAML syntax from invalid Ansible structure. Task/Block ownership
is optional and must not be guessed.

A parse issue can coexist with retained siblings, children, or a partially
known enclosing context. It need not correspond one-to-one with an omitted
Task. A missing delimiter may be detected at a following token or at EOF.

Do **not** add `tasks_complete`, document-completeness flags, or an automatic
eligibility gate that suppresses ordinary rules because recovery omitted nodes.
Rules see the recovered lists as their input. Absence, count, and universal
predicates operate over those lists, even when the result differs from what
fully repaired source would produce. Reporting parse issues is itself a CEL
rule, not an obligatory parser-side diagnostic publication path.

### AST-05: Preserve value meaning and source evidence

Distinguish absent attributes, explicit null, strings, booleans, numbers,
mappings, and sequences. Preserve key order, original text where checks need
it, and source references for individual keys/values. Quoted `"true"` must not
become a boolean merely because its contents resemble one.

Represent templated values explicitly, retaining their source expression. For
expression-valued keys, preserve their expression context without pretending
the expression has been evaluated. CEL's `dyn` type is not the template marker.
Nested values can contain literal and templated children independently.

A rule may deliberately reject templates or inspect only literal values. An
expected templated value is not automatically a CEL execution error or an
Ansible violation. Built-in rules follow the selected upstream subrule's actual
literal/template behavior.

Alias, merge-key, tag, scalar-decoding, and alternative invocation behavior must
be tested wherever it affects a claimed supported subrule. Do not advertise
whole-subrule support based only on its easiest syntax. Unsupported structural
interpretation must remain observable, not silently become an empty value or a
clean result. If faithful support proves infeasible, propose an explicit scope
change rather than weakening the coverage claim invisibly.

### AST-06: Separate collection from evaluation

The collection stage may read source/configuration files and use the existing
metadata-discovery helpers. Prefer `ansible-doc --metadata-dump` and preserve its
existing fallback to batched documentation requests. This remains permitted
when external diagnostics are disabled.

CEL receives collected, immutable data. No property accessor, helper, target
selection, or message expression may cause lazy file access, a subprocess, or
network access. In particular, an I/O-capable documentation lookup cannot be
passed through as a supposedly read-only CEL lookup.

A global metadata dump is not automatically authoritative for every per-file
collection-path context. Preserve the isolation described in
[ADR-0037](../adr/0037-selected-venv-collections.md). Do not substitute the global
version-only cache for a context with different effective paths.

### AST-07: Make unavailable metadata distinguishable from negative facts

Keep valid Tasks when metadata is absent, loading, failed, partial, or stale.
A documentation miss does not prove that a Module or option does not exist.
Likewise, an omitted projection field is not proof that a Module declares an
empty choices/aliases list or that every argument is optional.

Use cached metadata only when its environment identity and validity checks
match. Invalidate affected bindings after a known environment/configuration
change; do not mix old-context metadata with a new-context AST. Define and test
installation-change/freshness behavior rather than assuming unchanged paths
prove unchanged contents. This PRD does not introduce a new refresh command.

Unavailable facts and collector failures must be inspectable without forcing
CEL unknown propagation or a full symbolic evaluator. Metadata-independent
checks continue. Persistent reduced coverage is reported through the
consolidated status required by PRD-0003, not through invented task violations.
Existing readiness notifications must retain their meaning: catalog readiness
is not proof that complete module metadata is available.

## Acceptance scenarios

The implementation must include explicit fixtures and expected source ranges
for the following scenarios:

| Scenario | Observable acceptance result |
| --- | --- |
| Valid playbook/task/handler/metadata documents | Selected rules can query required facts without reparsing per rule |
| Unsaved edit differs from disk | Native queries use the buffer revision |
| Broken Task between valid siblings | Recoverable siblings remain; an issue represents the damaged region |
| Damaged parent field with intact Block/rescue/always children | Retain independently recognizable children and only known context |
| Missing section colon or bad indentation | No invented parentage or silently accepted malformed Task |
| Empty unrelated value such as `when:` | Not mislabeled a YAML syntax error merely because editing is in progress |
| Blank lines and task-looking text inside block scalars | No fabricated Task nodes |
| Unfinished quote/flow collection | Bounded recovery; issue location does not assert an unknowable task count |
| Wrong Ansible shape in valid YAML | Ansible structural issue, distinct from YAML syntax failure |
| Unknown Module or templated argument | Task retained; independent checks still run |
| Omitted Task was the only cleanup Task | An absence rule can fire over the recovered list, by design |
| Empty recovered list plus parse issues | Ordinary universal predicates retain normal CEL semantics; issue rules are independent |
| Missing, partial, malformed, or wrong-context metadata | No negative fact fabricated from missing information |
| Unicode, CRLF, aliases, and multiple YAML documents | Correct value/source relationships for supported syntax |
| Repeated edits and cancellation | No stale-pointer access, unbounded recovery, or obsolete snapshot publication |

## Evidence and technical validation

The source comparisons support tolerant recovery but do not supply a complete
recovery algorithm:

- [Tree-sitter's error/missing-node interface](https://github.com/tree-sitter/tree-sitter/blob/208c6cac1453315e979f05ab34b6d4f7cd0340be/lib/include/tree_sitter/api.h#L591-L616)
  exposes local observations, not guaranteed recovery of every later Task.
- [Red Hat YAML language-server parsing](https://github.com/redhat-developer/yaml-language-server/blob/4bf9c818850bf9751696d24848fdeaececb4203c/src/languageservice/parser/yamlParser07.ts)
  and its [document representation](https://github.com/redhat-developer/yaml-language-server/blob/4bf9c818850bf9751696d24848fdeaececb4203c/src/languageservice/parser/yaml-documents.ts)
  demonstrate retained documents plus separate parse errors. Best-effort
  composition can still merge keys or lose intended ancestry.
- [YAML block sequences](https://yaml.org/spec/1.2.2/#821-block-sequences) and
  [literal scalars](https://yaml.org/spec/1.2.2/#812-literal-style) explain why
  blank lines are not task delimiters.
- [Pinned ansible-lint loading/traversal](https://github.com/ansible/ansible-lint/blob/b74fb6f73d234bf92672372cb1c10768e4018d16/src/ansiblelint/runner.py)
  is not a model to copy for maximal editor recovery: its loading and
  syntax-check failure gates can stop ordinary file processing.

Exploratory malformed-input probes informed these requirements. They are not a
substitute for checked-in regression fixtures against the implemented Zig path.
The principal validation risks are source-backed child attachment, candidate
recovery after unmatched quotes, scalar fidelity, metadata provenance, and the
memory cost of retaining the minimal AST for Workspace-wide evaluation.
