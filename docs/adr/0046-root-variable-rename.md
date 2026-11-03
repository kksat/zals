# ADR-0046: Root variable rename

- **Status:** Accepted
- **Date:** 2026-10-15
- **Extends:** [ADR-0024](0024-variable-go-to-definition.md),
  [ADR-0025](0025-variable-references.md),
  [ADR-0032](0032-workspace-wide-navigation.md),
  [ADR-0036](0036-variable-navigation-from-bindings.md),
  [ADR-0039](0039-role-parameter-navigation.md), and
  [ADR-0045](0045-variable-files.md)

## Context

Users can find every reference and definition of a root Variable across the
owning Workspace (ADRs 0025, 0032, 0036), including passed Role parameters
(ADR-0039) and loaded Variable files (ADR-0045), but must rename occurrences by
hand. Unlike read-only navigation, a rename mutates files: partial results
during indexing, unbound or runtime-supplied names, third-party Installed
collections, or fallback scopes that omit callers silently break playbooks.

## Decision

Expose `textDocument/prepareRename` and `textDocument/rename` for **root
Variables** only.

- **Trigger and edit set.** Any root Variable read or definition in the owning
  session Workspace (all ADR-0024/0036/0039/0045 sites) is an entry point, and
  rename rewrites the complete Workspace-wide root-name group (reads and
  definitions), excluding Installed collections. Variable fields
  ([ADR-0041](0041-field-name-navigation.md)), Role references, Task file
  references, Collection references, and Module keys are not renamable and
  return `null`.
- **Quote preservation.** Quoted and escaped YAML definition keys and scalar
  binding values (`register`, `loop_var`, `vars_prompt`) report their inner
  identifier span (`scalarRange`), so edits preserve surrounding single or
  double quotes.
- **User variables only.** The target name must be a valid identifier, must
  not be an `ansible_*` or runtime-supplied Ansible/Jinja name (`item`,
  `hostvars`, `inventory_hostname`, `lookup`, `range`, etc.), and must not be
  bound exclusively in an Installed collection. Call keyword arguments (such as
  `map(attribute='name')`) are not variable references and return `null`.
  Unbound user variable reads (for example variables supplied via
  `import_playbook`, `validate_argument_spec`, inventory, or extra-vars) rename
  across all of their Workspace occurrences, matching `textDocument/references`.
- **Workspace completeness guards.**
  - Requests while the Workspace index is scanning fail with `-32803
    RequestFailed` rather than returning a partial `WorkspaceEdit`.
  - Files without an owning session Workspace fail with `-32803 RequestFailed`
    rather than falling back to a Role-only or Playbook-only edit that misses
    callers or callees.
  - Cursors in open documents excluded from the Workspace file set (such as
    `.venv/` or hidden directories) or inside an Installed collection
    (`MANIFEST.json`) return `null`.
  - Occurrences inside an Installed collection are skipped so rename only
    rewrites the Workspace under work.
- **Target name (`newName`) validation.** `newName` must be a valid ASCII
  identifier and must not be a Jinja keyword, a Python keyword, or a
  runtime-supplied name (`-32602 InvalidParams`). Renaming onto a variable name
  that already has a definition in the Workspace (including the current name)
  fails with `-32803 RequestFailed`.
