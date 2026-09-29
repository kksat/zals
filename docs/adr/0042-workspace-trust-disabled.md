# ADR-0042: Workspace trust disabled

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** —
- **Superseded by:** —

## Context

`zals` invokes `ansible-config dump` during initialization, and `ansible-lint`
or `ansible-playbook --syntax-check` during validation. In Ansible projects,
custom plugins (action, filter, lookup) and collection code present in the
workspace are executed by these CLI tools. Running them against untrusted code
is an arbitrary code execution risk.

## Decision

Declare `capabilities.untrustedWorkspaces: { supported: false }` in
`package.json`. The extension remains disabled in Restricted Mode until the
user explicitly trusts the workspace.

## Consequences

- Opening an untrusted folder or repository will not start `zals` or spawn
  Ansible CLI tools.
- Once the user clicks "Trust", the extension activates and starts the language
  server.