# Deep-module review

## Scope and conclusion

Reviewed `c0c7ae384a12a747ca2596f53bbbb121b1c16ba0` on
`deepmodules-review`, using the Ousterhout skill from
[markduan/a-philosophy-of-software-design-skills](https://github.com/markduan/a-philosophy-of-software-design-skills)
at `39ddc4b655faeb82c5feccc65780a95c7e9d5d74`.
The review covers first-party runtime module interfaces and their callers,
with the design document, glossary, relevant ADRs, and tests as constraints.
It is an architecture review, not an exhaustive correctness audit of every
function, dependency, fixture, or distribution artifact.

**The project has deep implementations, but its query interfaces expose too
much coordination.** Providers repeatedly assemble parsing, indexed and
filesystem searches, reachability, role resolution, open-buffer overlays,
source descriptions, and location mapping. The greatest improvement is to
move that knowledge behind a request-scoped semantic query interface, not to
merge all files or introduce more forwarding wrappers.

Depth means capability hidden behind a simple **interface**. That interface
includes ownership, ordering, errors, and performance obligations, not only
method signatures. Implementation size is not a depth score.

Making *every file* deep is not a useful target. Types, vocabulary tables,
namespace exports, private helpers, and real adapters can appropriately be
small. Aim for every externally consumed behavioral module to earn its
interface cost, with shallow composition inside its implementation.

## Priority summary

These are design priorities, not assertions that all findings are reproduced
runtime failures.

| Priority | Opportunity | Principal benefit |
| --- | --- | --- |
| High | One owner for all outgoing LSP messages | Enforce framing and FIFO rather than relying on callers |
| High | Request-long Workspace snapshot/lease | Hide index lifetime and mutation rules |
| High | One semantic query interface | Hide search selection, ranking, and navigation dispatch policy |
| Medium-high | Docs-owned storage and persistence snapshots | Hide maps/locking and remove disk I/O from read locks |
| Medium | Shared callee binding lookup | Reuse indexed sources consistently for root and field parameters |
| Medium | Forest-level YAML path lookup | Hide YAML-document selection and incomplete-cursor semantics |
| Medium | Document-level validation with explicit tool status | Hide orchestration without losing fallback information |
| Medium | Binding descriptions owned by source interpretation | Avoid rediscovering values and parsing once per candidate |

## Findings

### 1. High: enforce one outgoing-message owner

**Evidence:** `src/lsp/server.zig:145–148` sends handler failures through
`out.sendError(&self.transport, ...)`, whereas normal responses, errors, and
notifications use `self.writer` at `:168–178`. `src/lsp/outgoing.zig:8–11`
accepts either via `anytype`. Both `src/lsp/transport.zig:126–134` and
`src/lsp/writer.zig:77–82` frame/write the same output file independently.
The transport's write mutex does not coordinate with the writer thread.

**Interface leak:** callers must remember that two compatible
`writeMessage` methods have different ordering and ownership semantics.
The direct error path bypasses queued messages and introduces a possible
reordering/interleaving path. Source inspection establishes the two owners;
this review did not reproduce corrupted output.

**Deepen:** bind production outgoing helpers to the queued writer, route
handler failures through `Server.sendError`, and make raw output framing
internal to that owner. The input transport need not offer a production
sending capability. Keep `result`, `error`, `notification`, and client-request
operations; do not replace them with a generic configurable message pipeline.
A recording output adapter is useful if tests genuinely need substitution.

**Tradeoff:** changing bidirectional transport tests is worthwhile; adding a
second shared fd lock is not enough because it still permits bypassing FIFO.

**Verification:** mix normal responses, deterministic handler errors, and
notifications; assert complete JSON frames in enqueue order, exactly one
response per request, request-arena independence, and flush-on-shutdown.
Use a controlled partial-writing sink for an interleaving regression test.

### 2. High: guarantee a request-long Workspace view

**Evidence:** `src/providers/workspace_view.zig:39–43` copies `e.facts` and
`e.path` into a view without owning their backing entry arena.
`src/workspace/index.zig:281–289` returns entry pointers, not owned facts.
`View.reachableFiles` at `src/providers/workspace_view.zig:69–77` calls
`util.roleResolver`; that obtains `Server.projectContext` and another view
(`src/providers/util.zig:102–113`). Server collection/role-directory getters
drain the index (`src/lsp/server.zig:309–322`), and `indexEntries` can also
refresh it (`:283–286`).

A drain applies replacements at `src/workspace/index.zig:215`;
`putEntry` at `:295–297` destroys the old entry, whose `destroy` at `:49–51`
frees its arena. Root-info replacement also destroys old storage.

**Interface leak:** a supposedly read-only query must know which transitive
helpers invalidate borrowed facts. Main-thread-only mutation is not the same
as request-long stability. A replacement during rescan, or a nested no-watch
refresh after a disk change, can invalidate an outer view. This is a verified
borrow/invalidation path, not a runtime-reproduced use-after-free.

**Deepen:** acquire a `QueryContext` once before answering. Drain/refresh
before acquisition, capture Workspace discovery inputs and open-buffer facts,
and guarantee their lifetime until request completion. Pass that context to
role and collection resolution instead of allowing nested mutable Server
getters to drain or refresh.

**Design alternatives:**

- Under the current sole-main-writer model, apply index mutations between
  requests and prohibit them during a query lease. This is the simplest first
  design and avoids copying the whole index.
- Pin immutable entries, or copy facts into request storage, if independent
  snapshot lifetimes become necessary. This costs bookkeeping or memory.

Returning const pointers alone does not solve invalidation. Do not retain
parse trees or duplicate every file body merely to make a snapshot.

**Verification:** deterministically queue replacements while a query holds
old facts, then perform role-dependent variable definition/hover. The current
query must see one coherent revision and the next must see the new revision.
Cover rescan, no-watch refresh, partial startup, nested Workspaces, and
unsaved-buffer precedence with allocator checks.

### 3. High: give providers one semantic query interface

**Evidence:** the Workspace/fallback branch, reachability, schema filtering,
and location mapping recur in `src/providers/variable_navigation.zig:28–44`,
`src/providers/variable_hover.zig:35–55`, and
`src/providers/references.zig:35–53`. Field providers repeat the workflow and
directly traverse stored facts (`src/providers/field_navigation.zig:90–105`).
Definition dispatch owns skip/stop/fallback rules
(`src/providers/definition.zig:24–43`), while hover owns another chain,
including the requirement to avoid cold module-doc subprocesses until
navigation hovers have been attempted (`src/lsp/handlers.zig:140–158`).
Most navigation entry points accept the entire `Server` and JSON params,
whereas formatting modules already demonstrate narrower typed inputs.

**Interface leak:** adding a feature requires knowing storage selection,
nullable-versus-empty semantics, declaration filtering, ranking, special
callee contracts, dispatch precedence, and which lookup can run a subprocess.
A small function taking `*Server` is not a small conceptual interface.

**Deepen:** use the request context from finding 2 to expose typed operations
such as `subjectAt(uri, offset)`, `definition(subject)`,
`implementation(subject)`, `references(subject, include_declaration)`, and
`hover(subject)`. These are conceptual interfaces, not proposed compilable
signatures. Keep result types explicit and document inapplicable versus
applicable-but-empty answers. Parsing/classification can be reused lazily
within the request; avoid eagerly loading module docs for every subject.

The implementation owns indexed-versus-filesystem selection, domain ranking,
and which subject/fallback applies. Providers decode protocol params and
encode results. Existing pure Workspace algorithms and real `FileSource`
adapters remain internal building blocks.

**Design alternatives:** extracting more shared helper functions removes a
few repeated lines but still leaves providers coordinating the workflow. A
query owner provides greater leverage. Prefer explicit typed operations over
one stringly typed `query(kind, flags, data)` or a speculative plugin framework.
The context is not a renamed Server bag: it should offer semantic capabilities
and prevent bypassing its lifetime guarantee.

**Verification:** retain complete navigation oracles from every read/binding,
both reference declaration modes, ordered reachable/elsewhere definitions,
schema-only implementation negatives, exact hover ranges, root/field name
separation, no-marker fallback, and unsaved edits. Preserve handler dispatch
precedence and verify that navigation-only hover does not load module docs.

### 4. Medium-high: let docs own their storage and synchronization

**Evidence:** `src/services/docs.zig:40–58` exposes maps, arena, readiness,
version, and mutex. `src/cursor.zig:331–337` locks the library and iterates
`module_fqcns`. `src/services/docs_service.zig:77–84` and `:108–120` know
arena allocation and missing-module selection. `src/services/docs_cache.zig:44–94`
locks at `:54–55` and holds that lock through serialization and disk writes.
Cache restoration at `:109–157` knows the internal allocation/map layout.

**Interface leak:** callers know storage and lock policy, and persistence can
block library reads for filesystem work. Borrowed `Module.options` also needs
an explicit immutable-view lifetime contract.

**Deepen:** add library-owned enumeration and missing-catalog-name operations;
keep loader-only capabilities internal to the docs cluster. Produce a coherent
owned cache snapshot or encoded bytes under synchronization, then perform disk
I/O after releasing the lock. Restore through library-owned ingestion rather
than reconstructing its maps externally. State whether lookup results borrow
for library lifetime or own request snapshots.

Do not solve this by running arbitrary consumer callbacks under the mutex.
Encoding under lock and writing owned bytes afterward is a smaller first step
than copying an entire object graph. Preserve the shared pool's ownership;
docs can expose `requestStop` without secretly joining a pool used by indexing.

**Preserve:** filesystem-discovered FQCNs/redirects are not interchangeable
with catalog names. Contextual libraries are keyed by ordered paths **and cwd**
and intentionally do not share the startup version-only disk cache (ADR-0037).
Runner injection and the fake cursor docs adapter remain valuable.

**Verification:** discovered-but-not-catalogued names, nested-option cache
round trips, invalid-cache fallback, blocked persistence with unblocked lookup,
bootstrap readiness, concurrent prefetch/lookup, and selected-venv/per-file
configuration isolation. Measure snapshot memory and lock hold time rather
than assuming every copy is cheap.

### 5. Medium: unify indexed callee bindings for root and field parameters

**Evidence:** root parameter implementation always synthesizes a role task
URI and invokes filesystem `Index.definitions`
(`src/providers/role_navigation.zig:238–252`). Field parameter implementation
uses persistent callee facts, hydrates explicit dependencies, overrides empty
source-candidate facts, or falls back to filesystem discovery
(`src/providers/field_parameter_navigation.zig:85–120`). The pure callee
algorithms already exist at `src/workspace/view.zig:136–185`.

**Interface leak:** a provider knows index exceptions, conventional role
sources, one-level load provenance, extension-independent dependencies, and
when it must replace facts. Two providers answer related questions through
different storage routes, reducing index leverage.

**Deepen:** let the query implementation own
`calleeBindings(role_dir, selector)`, with a root-name or complete-field-path
selector. It owns concrete-only filtering, precedence, indexed source reuse,
and bounded dependency hydration via `FileSource`. Keep parameter detection,
selected entry-point contract preference, and protocol formatting separate.

**Preserve:** do not include invokers in callee implementation scope; do not
apply full-path/callee selectors to references. Explicit JSON vars dependencies
must remain supported without broadening ordinary Workspace discovery.
Non-Workspace callees still need filesystem discovery.

**Verification:** root and nested targets in precedence order, schema-only
and unrelated-role negatives, changed unsaved callee loads/values, JSON loads,
load-looking-data controls, and no enumeration/reparse of unchanged indexed
role sources. Bounded dependency reads remain allowed.

### 6. Medium: make YAML document selection part of the parsed-source interface

**Evidence:** `src/yaml/path.zig:10–15` always starts with the supplied root
and returns a path after successful allocation; a missing descendant produces
an empty scalar at `:59–65`, not null. However,
`src/cursor.zig:128–138` and `src/providers/util.zig:32–43` iterate roots and
stop at the first non-null result. Consequently these callers choose the first
root even for a later YAML document, rather than receiving meaningful root
selection from the path module.

**Interface leak:** callers must select the right document and interpret
optional-versus-placeholder semantics, inclusive positions, and forest-arena
allocation themselves. The forest's source ownership comment is also stronger
than the current implementation: parsers assign the caller's text slice
(`src/yaml/parser.zig:54–59`, `src/yaml/treesitter.zig:44`).

**Deepen:** offer `Forest.pathAt(offset, cursor_policy)` that selects the
applicable YAML document and hides path allocation. Keep placeholder behavior
inside the selected document, and define separators, trailing whitespace,
incomplete values, and EOF explicitly. Document the borrowed source lifetime;
add owned parsing only when an actual caller requires it.

**Verification:** second-document cursors, empty documents, `---`/`...`,
inter-document comments/whitespace, EOF, incomplete `key:`, and supported
backend parity. Simply adding a root-range check without editor gap semantics
could regress completion. No runtime failing case was added in this review.

### 7. Medium: make validation document-level without erasing tool outcomes

**Evidence:** `src/services/lint.zig:11–35` returns the same empty diagnostics
for an execution failure, malformed output, and a valid empty lint result.
`src/providers/validation.zig:13–35` owns target preparation, schema/lint
merging, fallback, and publication through the whole Server. Its fallback at
`:31–33` depends on disabled lint and the merged diagnostic count, not lint
availability. Validation also uses a partial URI decoder at
`src/services/lint.zig:106–127` instead of the shared `src/paths.zig` contract.

**Interface leak:** the low-level module discards a distinction required for
ADR-0015's unavailable-lint fallback, while the provider learns process,
filesystem, schema, and protocol policy.

**Deepen:** a validation module accepts a document snapshot, options, injected
Runner, and schema dependencies, and returns diagnostics. It owns temporary
resource cleanup, common URI conversion, schema preparation, and merge policy.
Internally keep tool status distinct from diagnostics: available/clean,
available/findings, unavailable, and invalid output as policy requires.
Nonzero lint status with valid findings is not equivalent to unavailability.
The protocol provider only publishes results.

**Behavior-change caution:** structure-preserving extraction and correcting
unavailable-lint fallback are separate changes. Confirm disabled-lint and
malformed-output semantics rather than silently interpreting them. Moving code
must not accidentally change disk-versus-buffer validation, first-root schema
selection, diagnostic ranges, or introduce worker execution/autofix features.

**Verification:** fake-runner status matrix, schema diagnostics alongside tool
results, enablement settings, temporary-target cleanup on all exits, escaped
URIs, and publication independent of a full Server fixture.

### 8. Medium: keep binding/value interpretation out of hover presentation

**Evidence:** `src/variables/definitions.zig:47–52` retains identifier ranges
but no value span. `src/providers/variable_hover.zig:152–178` reparses an entire
source and rediscovers the corresponding pair for each candidate.
Field hover repeats candidate-description assembly
(`src/providers/field_navigation.zig:53–71`). Rendering limits lists only after
all candidates are described (`src/providers/variable_hover.zig:104–115`).

**Interface leak:** presentation must understand YAML key quoting and
binding/value association. Repeated definitions in one file cause repeated
parses, including candidates never displayed. This is source-demonstrated
work amplification, not a measured latency claim.

**Deepen:** record optional value spans during existing fact extraction, or
initially use one request-local parse per source. Let a binding-description
operation associate candidates with source values; keep Markdown layout,
dedenting/truncation policy, and display selection in hover. Describe only
shown candidates while retaining total counts.

**Tradeoff:** value spans cost entry memory and must refer to the same source
revision as facts. Do not slice newer disk bytes with stale ranges or retain
all source text/trees permanently to avoid that problem.

**Verification:** quoted/escaped keys, nested/block/list values, no-value
register/loop sites, unsaved moves, UTF-16/CRLF, list overflow counts, and
multiple same-named bindings without a full parse per candidate.

## Module-family assessment

This is a map of architectural direction, not a declaration that every private
function must become a separately deep module.

| Module family | Assessment and direction |
| --- | --- |
| `workspace/document.zig` | Deep: owns text edits, line index, CRLF and encoding conversions; preserve the cohesive behavior |
| Workspace roots/discovery/settings/store | Useful policy/storage modules; bring query-time consumption under the stable request context, not arbitrary getter wrappers |
| Workspace index/facts/view | Deep implementation for scanning, ownership, extraction and ranking; strengthen lifetime/query interface (2, 3, 5, 8) |
| Variables scanning/normalization/definitions | Strong leverage from lexical exclusions and original-source spans; preserve root/field distinction and deepen descriptions |
| Variables Index/scope/source | Useful fallback implementation and real file seam; hide its selection from feature callers |
| Role detection/resolution/targets | Resolution order and target preference hide useful domain rules; keep detection and selection inside semantic queries rather than assembling them per provider |
| Cursor and YAML | Shared classification and backend-neutral DOM are good foundations; add forest-level selection and extend request reuse without forcing docs loading |
| Hover/completion/tokens formatting | Typed formatting already avoids repeating classification; retain small, honest presentation modules |
| Definition/references/implementation and navigation providers | Currently orchestrate too much; become protocol adapters over semantic queries |
| Document symbols/code actions | Already offer powerful operations behind typed pure cores; large files/private helpers are not evidence of shallowness |
| Workspace symbols/collections | Useful output behavior, but direct fact traversal and collection discovery belong behind the shared query context |
| Docs/config/schema/regex/markup services | Config, evaluator, regex and markup have strong leverage; close docs synchronization/persistence leaks and validation orchestration gaps |
| Execution/concurrency | Runner is a real substitution seam; bounded pool hides synchronization and shutdown. Preserve explicit task/context lifetime contracts |
| LSP transport/writer/handlers/encoding | Keep protocol adaptation separate from semantics; enforce one output owner |
| CLI/main/paths and root exports | Small adapters/data/facades can be appropriate. Reuse the canonical path implementation; avoid growing these solely for depth |

Examples worth preserving:

- `src/services/project_config.zig:110–171` hides environment/config/dump
  precedence, venv layouts, expansion and ordered deduplication.
- `src/workspace/document.zig:84–149` hides position conversion and edits.
- `src/variables/scalar_expression.zig:12–63` and Jinja scanning hide source
  normalization, lexical exclusions, and original byte spans.
- `src/workspace/facts.zig:68–128` owns copying facts out of temporary parse
  storage; `WorkspaceIndex.syncRoots` hides bounded asynchronous scanning and
  generation rejection.
- `src/providers/code_actions.zig:126–164` hides substantial edit-planning
  behavior behind `actions`; `src/providers/document_symbols.zig:40–47`
  exposes an outline without requiring callers to walk the DOM.
- Runner, `FileSource`, fake docs adapters, backend selection, namespace
  exports, and keyword tables are justified small seams/facades. Removing
  them indiscriminately would scatter knowledge, not remove complexity.

The root library exports many implementation-oriented names
(`src/root.zig:5–29`). After choosing the query interface, distinguish the
supported embedding surface from internal tooling imports. Do not remove
existing exports without checking consumers and compatibility requirements;
a smaller public surface is useful only when it hides real caller knowledge.

## Suggested target shape and sequence

A conceptual target is:

```text
LSP handlers / protocol adapters
  -> request-scoped semantic queries
       -> stable Workspace facts + open-buffer overlay
       -> role/collection/config resolution
       -> filesystem fallback and bounded dependency hydration
       -> lazy docs lookup and binding descriptions

Document validation -> diagnostics -> protocol publication
All outgoing protocol messages -> one queued output owner
```

This does not require a monolith. Internal pure functions, adapters, parser
implementations, and loader/cache files can remain separate.

1. **Enforce output ownership.** A small, independent correctness-oriented
   change with mixed-response/flush tests.
2. **Establish request lifetime.** Remove nested index mutation; add a
   deterministic replacement/lease test before broad query refactoring.
3. **Migrate one vertical query slice.** Start with root definition and
   implementation, then root hover/references and fields. Reuse ranking and
   location policy; delete obsolete duplicated orchestration when replaced.
4. **Deepen callee and description queries.** Bring both parameter forms onto
   the indexed implementation and avoid per-candidate source parsing.
5. **Close service leaks independently.** Docs snapshot/enumeration, YAML
   forest path semantics, and validation status each have separate reasons
   to change and should be separate commits.

Use existing behavior-level oracles as preservation tests. Retain useful
parser/scanner/algorithm tests; remove obsolete plumbing tests only after
replacement coverage exists, not simply because they are lower-level.

Success criteria are fewer caller obligations and localized change: a new
binding form, precedence rule, or storage strategy should not require edits
across multiple feature providers. Do not measure success by larger files,
fewer files, or a lines-of-code ratio.

## Verification performed for this review

- Local skill clone is clean; name, description, and bundled main-skill
  references validated. No installation scripts or third-party code executed.
- `make check`: passed (format check, build, Zig unit tests, and five Python
  benchmark-statistics/validation tests).
- `make e2e SUITE=navigation-e2e`: passed, **560 cases, 0 failures**.
- Two read-only reviewers verified the same integration base and reported
  clean worktrees; key findings were inspected during consolidation.
- No runtime implementation was changed. Full E2E aggregate, performance
  measurements, output interleaving reproduction, and index-lifetime
  reproduction were not performed. Proposed tests above are future work,
  not claimed test results.

## Implementation follow-through

The findings above describe the reviewed baseline. All eight numbered findings
have since received focused implementation changes on `deepmodules-review`,
through runtime commit `c843c43`; their original line references are historical.

| Finding | Integrated changes |
| --- | --- |
| 1. Output ownership | `77b9cda`: outgoing helpers require the queued writer; handler errors use it |
| 2. Query lifetime | `e387a82`: handler-owned, lazily prepared request lease freezes indexed facts |
| 3. Semantic queries | `67efe1e`: initial root slice; `76d40fe` and `c843c43`: shared root/field operations and typed navigation dispatch, including docs-last fallback |
| 4. Docs ownership | `3e54f6b`: library-owned enumeration, ingestion and encoded snapshots; disk I/O after unlocking |
| 5. Callee bindings | `64a8385`: shared indexed root/full-path selection, concrete-only filtering and one-level dependency hydration |
| 6. YAML paths | `036ef1c`: forest-owned document selection, editor-gap policy and truthful source borrowing |
| 7. Validation | `fe12f11`: document operation and explicit outcomes; `d0e96e7`: separate unavailable-lint fallback correction |
| 8. Binding descriptions | `d33572e`: request-local source interpretation, revision guards and displayed-only descriptions |

`src/queries/navigation.zig` now supplies typed subjects and explicit
`definition`, `implementation`, `references`, and `hover` operations. Protocol
adapters decode and encode; queries own search and action-specific precedence.
The initial `root_navigation.zig` slice has been replaced, not layered beneath
another forwarding interface. The handler remains the sole query-lease owner.

The implementation preserves name-based root and separate leaf-name field
references, applicable-empty stops, selected-entrypoint contracts, unsaved
precedence, bounded callee loads, and navigation-before-docs hover. It does not
introduce a full Ansible execution model or redesign completion and symbols.
Docs replacement storage is retained for library-long immutable borrowing;
encoding still holds the lock, but disk writes do not. Stale indexed hover
values are withheld when captured bytes fail their source-fingerprint check.

Each logical runtime change passed `make check`, full `make e2e`, and
`make smoke` before its commit. Completed branches were reviewed, rebased onto
verified integration tips, checked independently, and fast-forwarded. Final
runtime checks also passed `make neovim-test`; navigation reported **560 cases,
0 failures**, and existing standalone-role and lexical suites passed.

No tests or fixtures were created, removed, or changed, at the user's request.
The complete `test/` tree and all 53 existing Zig inline-test-containing suffixes
were verified byte-for-byte unchanged. These existing suites establish
preservation, not exhaustive new coverage of the proposed regressions above.
No new blocked-write, tool-status-matrix, stale-source, parse-count, or
multi-document oracle was introduced; snapshot memory and lock duration were
not measured. Nothing was pushed.
