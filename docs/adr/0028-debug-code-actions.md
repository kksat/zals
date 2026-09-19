# ADR-0028: Debug code actions

- **Status:** Accepted
- **Date:** 2026-09-19
- **Supersedes:** —
- **Superseded by:** —

## Context

Debugging an Ansible variable usually means hand-writing a `debug` task next to
the task that uses it, then deleting it afterwards. Upstream's language server
has no code-action handler at all, so this is a post-parity extension with no
counterpart to match. It builds on the variable model
([ADR-0024](0024-variable-go-to-definition.md),
[ADR-0025](0025-variable-references.md)) and the YAML DOM.

## Decision

**Two `refactor` actions.** `textDocument/codeAction` returns at most two
actions, both with kind `refactor`:

- **Add debug** — when the cursor is on a variable occurrence, insert a debug
  task for that variable.
- **Remove debug** — when the cursor is inside a task whose module key is
  `debug` or `*.debug`, delete that task.

Both may be returned at once (a variable inside a debug task). The capability is
`codeActionProvider: { codeActionKinds: ["refactor"] }`; there is no
`resolveProvider` and no `executeCommandProvider`. `context.only` is respected
(an action matches when its kind is the requested kind or a sub-kind of it).
The client's `codeActionLiteralSupport` is not consulted, matching how document
symbols ignores `hierarchicalDocumentSymbolSupport` (ADR-0027). The cursor
offset is `range.start`.

**Inserted text.** For a task at indent `N`:

```yaml
<N>- name: Debug variable foo
<N>  ansible.builtin.debug:
<N>    var: foo
```

The module is fully qualified and the task is named. The variable is the **root
identifier** under the cursor (`foo.bar` → `foo`), matching what the variable
model resolves. The line ending is detected from the document (CRLF when
present) and the block ends with a newline.

**Placement.** The enclosing task is the deepest map whose parent is a sequence
and whose line range contains the cursor. When it is a task item, the debug goes
at the start of the next sibling's line (after blank lines), or immediately
after the task's last line when it is last in its sequence — always bounded by
the sequence, so a block's debug stays inside the block. When there is no
enclosing task but there is an enclosing play (play-level `vars:`, `hosts:`,
role invocation params, `vars_prompt`), the debug goes at the start of the
play's `tasks:` list; if the play has no `tasks:`, one is created at the end of
the play. `import_playbook` entries and role `defaults/`/`vars/`/`meta/` files
offer nothing.

**Removal range.** From the start of the debug's first line through the start of
the next sibling's line (swallowing the blank line after it); when it is last in
its sequence, the debug's own lines only, bounded by the sequence.

**Idempotency.** Add is always offered, even when an identical debug already
follows; duplicate detection would be fragile and a false suppression is worse
than a duplicate the user can undo.

**Edit delivery.** `CodeAction.edit` is a `WorkspaceEdit` with
`documentChanges` carrying the document version, so a stale edit can be
rejected. `isPreferred`, `diagnostics`, and `command` are omitted.

**Implementation.** A pure core in `src/providers/code_actions.zig` over the
parsed document and the variable model
(`variables.Index.occurrenceInForest`); the LSP entry point is a thin wrapper.
The provider parses the document once. Tests are unit tests over inline YAML
plus a stdio smoke test (`test/smoke_code_actions.py`). There is no differential
test, because upstream has nothing to diff against.

## Consequences

- The action is a `refactor`, not a `quickfix`: it is not tied to a diagnostic,
  and clients surface it in the lightbulb menu.
- `action: debug` / `local_action: debug` tasks are not removable — the module
  key is `action`, which is a task keyword. Documented gap, matching document
  symbols' generic naming for `action:` tasks.
- The debug is placed after the whole enclosing task, so a variable in a block's
  `when:` produces a debug that runs outside the block's condition. This is the
  literal reading of "right after the current action".
- The inserted task is a sibling, so it inherits the task list's indentation and
  nesting; no reformatting of the surrounding document is needed.