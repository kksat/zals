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
| Hover | keywords, modules, module options |
| Completion (+ resolve) | modules, options, values, keywords |
| Go to definition | module source files, variable definitions, and roles |
| Go to implementation | role main task files |
| Find references | variables, within the enclosing role or playbook |
| Validation | `ansible-lint`, `ansible-playbook --syntax-check` fallback, JSON-schema validation |

Out of scope for v1 (Tier 2/3): the VS Code extension, inventory and metadata
notifications, execution environments, and `--generate-docs`.

Post-parity extensions: variable navigation (find-references and variable
go-to-definition, §5), document symbols ([ADR-0027](adr/0027-document-symbols.md)),
debug code actions ([ADR-0028](adr/0028-debug-code-actions.md)), role
navigation ([ADR-0029](adr/0029-role-navigation.md)), and extract-tasks code
actions ([ADR-0030](adr/0030-extract-tasks-code-actions.md)).

Parity is behavioral, not byte-for-byte. Intentional differences are tracked in
[`docs/deviations.md`](deviations.md).

## 2. Architecture

```
                 ┌─────────────────────────────────────────────┐
   stdio ◄──────►│ writer thread        main thread            │
                 │  (framing out)        • owns all state      │
                 │                       • reads/parses input  │
                 │                       • dispatches requests │
                 │                       • poll() loop         │
                 └───────┬───────────────────────┬─────────────┘
                         │ immutable snapshots   │ jobs
                 ┌───────▼───────┐       ┌───────▼─────────────┐
                 │ worker pool   │       │ docs thread         │
                 │ (parse, lint, │       │ (ansible-doc batch) │
                 │  schema)      │       └───────┬─────────────┘
                 └───────────────┘               │
                                         ┌───────▼─────────────┐
                                         │ cache-writer thread │
                                         │ (docs/schema cache) │
                                         └─────────────────────┘
```

The **main thread is the sole writer** of shared state. Workers receive
immutable snapshots and return results over channels; the main thread applies
them. A self-pipe wakes the `poll()` loop when a worker finishes.

## 3. Layers

The codebase is organized layer-first. Each layer depends only on the ones above
it in this list.

| Layer | Responsibility |
| --- | --- |
| `src/lsp/` | JSON-RPC framing, message types, capability negotiation, dispatch |
| `src/providers/` | One module per LSP feature (semantic tokens, hover, completion, definition, references, document symbols, code actions, validation) |
| `src/variables/` | Jinja scanning, definition-site detection, role/playbook scope, the variable index |
| `src/roles/` | Role reference detection, name-to-directory resolution, navigation targets |
| `src/services/` | Docs library, schema cache/service/validator, validation manager, config |
| `src/yaml/` | YAML parser interface, tree-sitter backend, semantic DOM, path utilities |
| `src/exec/` | Command-runner interface and POSIX backend |
| `src/workspace/` | Document store, git Workspaces, settings |
| `vendor/` | Vendored C (tree-sitter) and the schema snapshot |
| `test/` | Ported upstream fixtures and unit tests |
| `tools/differential/` | Dev-only parity harness against upstream |

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
definition sites over the DOM, and resolves the enclosing role or playbook
scope. The scope is the role's conventional directories or the playbook file,
plus one level of `vars_files`/`include_vars` targets. References is name-based;
go-to-definition is scope-aware and ranks visible definitions by precedence.
Files are read through a `FileSource` seam (open documents first, then disk) so
the model is testable in isolation.

## 5a. Roles

Role navigation ([ADR-0029](adr/0029-role-navigation.md)) lives in
`src/roles/`. It detects role references over the DOM (`roles:` entries,
`include_role`/`import_role` names, and `meta/main.yml` dependencies), resolves
the name against playbook-adjacent `roles/`, `DEFAULT_ROLES_PATH`, workspace
roots, and declared collections, and selects a target file: argument specs,
metadata, or the main task file for definition; the main task file for
implementation. `DEFAULT_ROLES_PATH` and `COLLECTIONS_PATHS` come from a cached
`ansible-config dump` shared with the module index.

## 6. Documentation data

Module documentation comes from `ansible-doc --json`, behind `DocsSource`.

- **Catalog:** `ansible-doc -l --json` on startup (~0.6 s for ~860 modules).
- **Lazy:** `ansible-doc --json <names>` in batches on demand.
- **Prefetch:** a background pass loads all modules (~6 s, ~8 MB) and persists
  them through the cache-writer thread.

The cache is keyed by `ansible_version + config_fingerprint` and shared across
Workspaces.

## 7. Validation

Validation has three sources, merged into one diagnostic set per document:

1. **`ansible-lint`** — `--offline --nocolor -f codeclimate`, run on open and
   save. Parsed into LSP diagnostics.
2. **Syntax check** — `ansible-playbook --syntax-check` when lint is unavailable.
3. **JSON schema** — a Zig-native draft-07 subset validator over the bundled
   schema snapshot, for Ansible metadata files.

On change, a quick validation runs and cached diagnostics are reconciled against
the edited lines using a **sorted array** (upstream uses an interval tree).
Multi-file diagnostics are ref-counted. `autoFixOnSave` is supported. Progress
is reported best-effort via `$/progress`.

## 8. Protocol and runtime

- **Transport:** hand-rolled JSON-RPC over stdio using `std.json`.
- **Sync:** incremental (`TextDocumentSyncKind.Incremental`); position encoding
  negotiated as `utf-8` when the client supports it, else `utf-16`.
- **Concurrency:** main thread owns state; worker pool + docs thread +
  cache-writer thread + writer thread; self-pipe wakeup.
- **Memory:** arenas for request-scoped work; explicit ownership for long-lived
  state; the debug allocator in tests.
- **Workspace:** one context per root marker (default `.git`, file or directory), with a shared docs cache.

## 9. Configuration

Settings use upstream's exact names and defaults for the Tier 1 subset, so an
existing `ansible.*` configuration works unchanged. See
[ADR-0017](adr/0017-settings-compatibility.md).

## 10. Custom messages

Three upstream custom messages are retained: `ansible/errorMessage`,
`ansible/docsLibraryReady`, and `ansible/refreshConfiguration`. The Tier 2
messages (`resync/ansible-inventory`, `update/ansible-metadata`) are dropped.

## 11. Build and platforms

- Zig **0.15.1** (pinned via `build.zig.zon`).
- Linux and macOS first; Windows later.
- Static binaries where feasible.
- Schemas are materialized into `vendor/schemas/` at build time.

## 12. Testing

- Upstream unit fixtures are ported and run under `zig build test`.
- A dev-only **differential harness** (`tools/differential/`) runs the same
  inputs through upstream ALS and `zals` and diffs the results.
- Behavioral differences are documented in `docs/deviations.md`.

## 13. License

GPL-3.0-only. See [ADR-0020](adr/0020-license.md).