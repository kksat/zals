# ADR-0030: Extract tasks code actions

- **Status:** Accepted
- **Date:** 2026-09-20
- **Supersedes:** —
- **Superseded by:** —

## Context

A task list grows until a single file is hard to navigate. The usual fix is to
move a group of tasks into a sibling task file and replace them with an
`include_tasks` or `import_tasks` reference. Doing that by hand means creating
the file, re-indenting the tasks, choosing a name, and writing the reference.

Upstream's language server has no code-action handler at all, so this is a
post-parity extension with no counterpart to match. It builds on the debug code
actions ([ADR-0028](0028-debug-code-actions.md)) and the YAML DOM.

## Decision

**Two `refactor.extract` actions.** `textDocument/codeAction` returns, in
addition to the debug actions, two extract actions when the cursor or selection
is on one or more task items:

- **Extract to include_tasks** — move the task(s) into a new sibling file and
  replace them with `ansible.builtin.include_tasks`.
- **Extract to import_tasks** — the same, with `ansible.builtin.import_tasks`.

The capability is `codeActionProvider: { codeActionKinds: ["refactor",
"refactor.extract"] }`. `context.only` is respected per action: `refactor`
matches both the debug actions and the extract actions (a sub-kind), while
`refactor.extract` matches only the extract actions.

**Trigger.** With an empty selection, the unit is the deepest task item
containing the cursor: a nested task inside a block is extracted on its own,
and a block is extracted whole only when the cursor is on the block's own level
(`block:`/`rescue:`/`always:` or its task keywords). With a non-empty
selection, the unit is the deepest task-list sequence whose line range fully
contains the selection, and every direct item of that sequence the selection
intersects (even partially) is extracted. A selection that crosses a block
boundary therefore extracts the block whole. A selection not fully contained in
any task-list sequence offers nothing.

**Eligibility.** Any task file and any playbook, whether or not it is part of a
role. `defaults/`, `vars/`, `meta/`, and files with no task item offer nothing.

**Target file.** A sibling of the current file, so the reference is always the
basename. The name is the first free `taskN.<ext>` (`task1.yml`, `task2.yml`,
…), where `<ext>` is the current file's extension (`.yml` when it has none).
Existing files are never overwritten. The new file is `---` followed by the
extracted task text dedented to column 0, preserving internal blank lines,
comments, and line endings, with a trailing newline. A comment block directly
attached (no blank line) above the first extracted task moves with it.

**Inserted reference.** At the original indentation, with exactly one blank
line on each side that has a sibling (the existing blank run is replaced):

```yaml
- name: Include file 'task1.yml'
  ansible.builtin.include_tasks: task1.yml
```

The module is fully qualified and the task is named. The `import_tasks` action
uses `Import file 'task1.yml'` and `ansible.builtin.import_tasks`.

**Edit delivery.** `CodeAction.edit` is a `WorkspaceEdit` whose
`documentChanges` are, in order: `CreateFile` (with `options.overwrite: false`),
a `TextDocumentEdit` for the new file (version `null`) carrying its contents,
and a `TextDocumentEdit` for the source document carrying its version. The
extract actions are offered only when the client advertises
`workspace.workspaceEdit.resourceOperations` containing `create`; the debug
actions are unaffected. This is a deliberate exception to ADR-0028's "do not
consult client capabilities" stance, because an unsupported resource operation
corrupts the edit rather than just changing presentation.

**Implementation.** The pure core in `src/providers/code_actions.zig` takes a
`Selection` and an optional `ExtractEnv { dir, ext, exists }`; the LSP wrapper
supplies the real filesystem predicate and the client capability. `Action`
gains an optional `create` field. Tests are unit tests over inline YAML with a
stub `exists` predicate plus a stdio smoke test (`test/smoke_code_actions.py`).
There is no differential test, because upstream has nothing to diff against.

## Consequences

- The action is a `refactor.extract`, not a `quickfix`: it is not tied to a
  diagnostic, and clients surface it in the lightbulb menu.
- Extraction is always to a sibling file, so playbook tasks land next to the
  playbook rather than in a `tasks/` subdirectory. This is the only rule that
  is always correct for Ansible's file-relative resolution.
- The new file is named `taskN`, not after the task's `name:`. A code action
  cannot prompt, and a deterministic name avoids collisions and surprises.
- A cursor on a comment line (not inside a task) offers nothing, because the
  DOM does not represent comments.
- A comment directly above a task that is really the previous task's trailing
  comment moves with the extracted task.
- The extracted tasks keep their own `when:`/`tags:`/`register:`; only the
  enclosing block's keywords stay behind with the include.