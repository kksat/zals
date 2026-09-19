# ADR-0027: Document symbols

- **Status:** Accepted
- **Date:** 2026-09-19
- **Supersedes:** —
- **Superseded by:** —

## Context

Clients show an outline and breadcrumb tree from `textDocument/documentSymbol`.
Upstream's language server never implemented it — issue #601 was closed "not
planned" — so this is a post-parity extension with no counterpart to match. It
is also the first feature whose subject is a **single document**: a **Role**
spans many files, but the request is scoped to one.

## Decision

**Document-scoped.** The provider returns the outline of the requested document
only. It never synthesises a cross-file "Role" symbol or reaches into sibling
files; cross-file role navigation is left to a future workspace-level feature.

**Result shape.** Always hierarchical `DocumentSymbol[]`. The spec says servers
should prefer `DocumentSymbol` whenever possible, and the hierarchy is the point
of an Ansible outline. There is no flat `SymbolInformation` fallback and no
gating on the client's `hierarchicalDocumentSymbolSupport` capability.
`workspace/symbol` is out of scope.

**Vocabulary.**

| File | Symbols |
| --- | --- |
| Playbook | Play, Role invocation, Task, Block, Handler |
| Task file | Task, Block |
| Handlers file | Handler, Block |
| Vars / defaults file | Variable (top-level keys), Field (nested map keys, recursive) |
| Meta / other map-rooted file | Variable, Field (generic map model) |

Section keys (`tasks:`, `pre_tasks:`, `post_tasks:`, `handlers:`) are **not**
symbols — they are structural YAML, not Ansible entities. Sequence items are not
expanded into symbols. `meta/main.yml` and `galaxy.yml` get the generic map
model; `argument_specs` options are not promoted to `Variable`.

**Classification is content-first**, with the path used only to label handlers:

1. Map root → generic map model.
2. Seq root containing a play (a play-exclusive keyword, or `import_playbook`)
   → playbook model.
3. Seq root whose items are maps → task list (`Handler` under `<role>/handlers/`,
   otherwise `Task`).
4. Seq root of scalars → empty.

**Kinds.**

| Entity | `SymbolKind` |
| --- | --- |
| Play | `Module` (2) |
| Role invocation | `Class` (5) |
| Block | `Array` (18) |
| Task | `Object` (19) |
| Handler | `Event` (24) |
| Variable | `Variable` (13) |
| Field | `Field` (8) |

**Naming.** First non-empty source wins; `N` is 1-based per parent scope.

| Entity | Name source |
| --- | --- |
| Play | `name:` → `hosts:` → `import_playbook:` → `Play N` |
| Role invocation | `role:` → scalar entry → `Role N` |
| Task / Handler | `name:` → module key → `Task N` / `Handler N` |
| Block | `name:` → `Block N` |
| Variable / Field | key text |

The **module key** is the first key of a task map that is not a task keyword
(`keywords.isTaskKeyword`, which covers `with_*`). Detection is purely
structural — the provider does not consult the docs catalog, so it stays fast
and independent of `ansible-doc`. A task using `action:` therefore falls back to
`Task N`, which is accepted.

**Ranges.** `range` is the entity's full extent (whole map, or whole pair for a
variable); `selectionRange` is the identifier (`name:` value, module key, role
name, or key). `selectionRange` is always contained by `range`.

**Detail.** Play → `hosts` value; Task / Handler → module key, but only when it
differs from the name; other entities omit it.

**Capability.** Advertise `documentSymbolProvider: { label: "zals" }`.

**Request handling.** Open documents only (matching semantic tokens and hover),
parsed per request with no caching. A parse failure or an unclassifiable
document yields `[]`, never `null`.

**Implementation.** The core is a pure function over the YAML DOM in
`src/providers/document_symbols.zig`; the LSP entry point is a thin wrapper. The
file classifier stays private to the provider. Tests are unit tests over inline
YAML plus fixture-based tests over `test/fixtures/`. There is no differential
test, because upstream has nothing to diff against.

## Consequences

- The outline is semantic, not a generic YAML tree; a client that wants the raw
  YAML outline still needs its YAML extension.
- The `SymbolKind` mapping is a client-visible contract. Changing it later is a
  breaking change for users' muscle memory, which is why it is recorded here.
- Because classification is content-first, a playbook is recognised wherever it
  lives, and a task file is recognised even outside a role.
- `action:`-style tasks and `argument_specs` options are named generically; both
  are documented gaps, not bugs.
- A future `workspace/symbol` or folding-range feature can reuse the classifier
  by promoting it to `src/yaml/`.