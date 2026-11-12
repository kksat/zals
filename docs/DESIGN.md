# zals — Design

This document is the high-level design for `zals`, a Zig reimplementation of the
[Ansible Language Server](https://github.com/ansible/vscode-ansible)
(`packages/ansible-language-server`). It summarizes the decisions recorded
individually under [`docs/adr/`](adr/). When this document and an ADR disagree,
the ADR wins.

## 1. Goal and scope

`zals` is a **standalone LSP server** that speaks JSON-RPC over **stdio**. It is
not a drop-in replacement for the VS Code extension's bundled server, which uses
Node IPC; any LSP client that can launch a stdio server can use `zals`.

The v1 target is **feature parity with upstream's Tier 1 surface**:

| Feature | Notes |
| --- | --- |
| Semantic tokens | full-document token stream |
| Hover | keywords, modules, module options, variables, roles, role parameters, collections |
| Completion (+ resolve) | modules, options, values, keywords |
| Go to definition | module source files, variable definitions, roles, task and vars files, collections |
| Go to implementation | role main task files |
| Find references | variables, roles, task and vars files, and collections, across the Workspace |
| Workspace symbols | collections, roles, playbooks, task files, plays, tasks, handlers |
| Validation | `ansible-lint`, `ansible-playbook --syntax-check` fallback, JSON-schema validation |

Out of scope (Tier 2/3): inventory and metadata notifications, execution
environments, and `--generate-docs`. A standalone VS Code client bundling the
native stdio binary lives under `editors/vscode/`.

Post-parity extensions: variable navigation (find-references and variable
go-to-definition, §5), document symbols ([ADR-0027](adr/0027-document-symbols.md)),
debug code actions ([ADR-0028](adr/0028-debug-code-actions.md)), role
navigation ([ADR-0029](adr/0029-role-navigation.md)), extract-tasks code
actions ([ADR-0030](adr/0030-extract-tasks-code-actions.md)), and workspace-wide
navigation over a persistent Workspace index
([ADR-0031](adr/0031-workspace-index.md),
[ADR-0032](adr/0032-workspace-wide-navigation.md)), and root variable rename
([ADR-0046](adr/0046-root-variable-rename.md)).

Parity is behavioral, not byte-for-byte. Intentional differences are tracked in
[`docs/deviations.md`](deviations.md).

## 2. Architecture

```
                 ┌─────────────────────────────────────────────┐
   stdio ◄──────►│ writer thread        main thread            │
                 │  (framing out)        • owns all state      │
                 │                       • reads/parses input  │
                 │                       • dispatches requests │
                 │                       • drains worker pool  │
                 └──────────────────────────┬──────────────────┘
                                            │ immutable snapshots / tasks
                                    ┌───────▼──────────────────┐
                                    │ bounded worker pool      │
                                    │  • Workspace discovery   │
                                    │    & parallel YAML parse │
                                    │  • validation (lint,     │
                                    │    syntax, schema)       │
                                    │  • docs bootstrap,       │
                                    │    metadata-dump & cache │
                                    └──────────────────────────┘
```

The **main thread is the sole writer** of shared state. Workers receive
immutable inputs and publish results back to synchronized queues; while
background bootstrap, indexing, or validation is pending, the main thread waits
for input in bounded 25 ms intervals to drain completed work and emit readiness
notifications, returning to blocking reads once idle.

## 3. Layers

The codebase is organized layer-first. Each layer depends only on the ones above
it in this list.

| Layer | Responsibility |
| --- | --- |
| `src/lsp/` | JSON-RPC framing, message types, capability negotiation, dispatch, and the navigation protocol adapter (definition, implementation, references, hover, rename) |
| `src/providers/` | One module per remaining LSP feature (semantic tokens, completion, document symbols, Workspace symbols, code actions, validation) |
| `src/queries/` | Typed semantic navigation over the request-scoped navigation context (`context.zig`): Workspace files with open documents winning, text, locations, role resolution |
| `src/variables/` | Jinja scanning, definition-site detection, role/playbook scope, per-document occurrences |
| `src/roles/` | Role reference detection, name-to-directory resolution, navigation targets |
| `src/services/` | Docs library, schema cache/service/validator, validation manager, config |
| `src/yaml/` | YAML parser interface, tree-sitter backend, semantic DOM, path utilities |
| `src/concurrency/` | Bounded worker thread pool |
| `src/exec/` | Command-runner interface and POSIX backend |
| `src/workspace/` | Document store, Workspace index, git Workspaces, settings |
| `vendor/` | Vendored C (`tree-sitter`, `tree-sitter-yaml`) and committed schema snapshots |
| `editors/vscode/` | VS Code extension client bundling the native `zals` binary |
| `python/` | PyPI wrapper package bundling the native `zals` binary |
| `test/` | Unit fixtures, real-stdio E2E suites, headless Neovim tests, smoke tests, and the upstream parity harness (`test/parity/compare.py`) |
| `tools/` | Release automation (`tools/release/`) and CI performance regression gate (`tools/performance/`) |

### Pluggable seams

Every external dependency sits behind an interface so it can be replaced later:

- **`CommandRunner`** — all shellouts (`ansible`, `ansible-config`, `ansible-doc`,
  `ansible-lint`, `ansible-playbook`).
- **`YamlParser`** — tree-sitter today; a pure-Zig parser later.
- **`DocsSource`** — `ansible-doc --json` today; a bundled index later.
- **`SchemaSource`** — bundled snapshot today; a remote fetch later.
- **`SchemaValidator`** — Zig-native subset validator today; a full validator later.

## 4. YAML

Parsing uses **tree-sitter-yaml** (vendored C) to produce a concrete syntax tree,
which is lowered into a Zig semantic DOM (`Scalar`, `Map`, `Seq`, `Pair`) that
retains source ranges. Path utilities mirror upstream's `yamlAst` helpers:
`getPathAt`, `AncestryBuilder`, `isTaskParam`, `isPlayParam`, `isBlockParam`,
`isModuleParam`, and friends.

The DOM is the shared substrate for semantic tokens, hover, completion,
definition, variable references, document symbols, and code actions.

## 5. Variables

Find-references and go-to-definition for variables share one model
([ADR-0024](adr/0024-variable-go-to-definition.md),
[ADR-0025](adr/0025-variable-references.md)). The `src/variables/` layer scans
Jinja expressions and bare-expression keys for root identifiers, detects
definition sites over the DOM. Searches run over the Workspace that owns the
file ([ADR-0032](adr/0032-workspace-wide-navigation.md)), read from the
Workspace index (`src/workspace/index.zig`, [ADR-0031](adr/0031-workspace-index.md))
with open documents layered on top. References is name-based. Go-to-definition
and hover rank the reachable definitions (role scope or playbook, the
playbooks that invoke the role or include the task file, and their vars files)
by precedence and list the others after them. Files outside a session
Workspace search their Role or Playbook scope instead, extracted into the same
Facts and searched by the same `src/workspace/view.zig` functions
([scope guide](variable-navigation.md#without-a-session-workspace)).

## 5a. Roles

Role navigation ([ADR-0029](adr/0029-role-navigation.md)) lives in
`src/roles/`. It detects role references over the DOM (`roles:` entries,
`include_role`/`import_role` names, `meta/main.yml` dependencies, and
`requirements.yml` roles), resolves the name in `ansible-playbook`'s order
(FQCN, declared collections, sibling role, adjacent `roles/` up to the
Workspace root, `roles_path`, Ansible's defaults) with a Workspace-wide fallback,
and selects a target file: argument specs, metadata, or the main task file for
definition; the main task file for implementation. Search paths come per file
from `ANSIBLE_*` variables, the nearest `ansible.cfg`, then a cached
`ansible-config dump` (`src/services/project_config.zig`); the selected
virtual environment (`ansible.python.venvPath` or `--venv`) adds its
collections ([ADR-0032](adr/0032-workspace-wide-navigation.md)).

## 6. Documentation data

Module documentation comes from `ansible-doc`, behind `DocsLibrary` and
`DocsService` (`src/services/docs.zig`, `src/services/docs_service.zig`).

- **Catalog:** `ansible-doc -l --json -t module` on startup (skipped when a warm
  on-disk cache matches the `ansible-doc --version` fingerprint), plus on-disk
  module FQCN scanning for completion.
- **Full-docs bootstrap:** one `ansible-doc --metadata-dump` call ingests every
  installed module's documentation at once; when `--metadata-dump` is
  unavailable (older `ansible-core`), `DocsService` falls back to batched
  `ansible-doc --json <names>` prefetch.
- **Lazy & contextual:** `ansible-doc --json <names>` serves uncached modules on
  demand, and isolated `ContextLibraries` (keyed by effective ordered
  `collections_paths`, [ADR-0037](adr/0037-selected-venv-collections.md)) handle
  per-file collection search paths.

The global disk cache is keyed by the `ansible-doc --version` fingerprint and
persisted asynchronously through coalesced worker-pool writes.

## 7. Validation

Validation runs asynchronously on the worker pool on `didOpen` and `didSave`
(dropping superseded queued jobs for the same URI) and merges three sources into
one diagnostic set per document:

1. **JSON schema** — a Zig-native draft-07 subset validator over the committed
   schema snapshot (`vendor/schemas/`), for Ansible metadata files.
2. **`ansible-lint`** — `--offline --nocolor -f codeclimate`, parsed into LSP
   diagnostics.
3. **Syntax check** — `ansible-playbook --syntax-check` fallback when lint is
   disabled (and schema diagnostics are empty) or when the `ansible-lint`
   executable is unavailable.

## 8. Protocol and runtime

- **Transport:** hand-rolled JSON-RPC over stdio using `std.json`.
- **Sync:** incremental (`TextDocumentSyncKind.Incremental`); position encoding
  negotiated as `utf-8` when the client supports it, else `utf-16`.
- **Concurrency:** main thread owns state (with request-scoped `WorkspaceIndex`
  query leases); dedicated stdout `Writer` thread + bounded `ThreadPool` (2–4
  workers) for indexing, validation, docs bootstrap, and cache writes; 25 ms
  bounded input wait while background tasks are pending.
- **Memory:** arenas for request-scoped work; explicit ownership for long-lived
  state; the debug allocator in tests.
- **Workspace:** one context per root marker (default `.git`, file or directory), with a shared docs cache.

## 9. Configuration

Settings use upstream's exact names and defaults for the Tier 1 subset, so an
existing `ansible.*` configuration works unchanged. See
[ADR-0017](adr/0017-settings-compatibility.md).

## 10. Custom messages

Two custom readiness notifications are retained for tests and benchmarks:
`ansible/workspaceIndexReady` reports the applied Workspace index file count;
`ansible/docsLibraryReady` reports the catalog count after asynchronous docs
bootstrap, not full documentation prefetch completion. Ordinary editor requests
do not wait for either notification.

`ansible/refreshConfiguration` is not supported. Settings use
`initializationOptions` and `workspace/didChangeConfiguration`; no replacement
cache or installed-collection refresh is provided. `ansible/errorMessage` was
never implemented; existing warnings use standard LSP messages. The Tier 2
messages (`resync/ansible-inventory`, `update/ansible-metadata`) remain unsupported.
See [ADR-0043](adr/0043-custom-readiness-without-refresh.md).

## 11. Build and platforms

- Zig **0.15.1** (pinned via `build.zig.zon`).
- Prebuilt binaries, Python wheels, and VS Code VSIXs for Linux, macOS, and Windows.
- Static binaries where feasible.
- Schemas are committed under `vendor/schemas/` (`embed.zig`).

## 12. Testing

- Unit tests and ported upstream fixtures run under `zig build test` (`make test`).
- Real-stdio end-to-end suites (`make e2e`), headless Neovim integration tests
  (`make neovim-test`), and stdio smoke/latency harnesses (`make smoke`,
  `test/benchmark_operations.py`) exercise the built `zals` binary.
- A dev-only **differential parity harness** (`test/parity/compare.py`, `make parity`)
  runs the same inputs through upstream ALS and `zals` and diffs the results.
- Behavioral differences are documented in `docs/deviations.md`.

## 13. License

GPL-3.0-only. See [ADR-0020](adr/0020-license.md).