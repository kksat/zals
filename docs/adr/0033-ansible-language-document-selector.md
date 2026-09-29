# ADR-0033: Ansible language document selector

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

`zals` does not choose which files it opens. The extension's document selector
is that boundary. `redhat.ansible` already labels a fixed set of files as
language `ansible` (playbooks, role files, vars, Molecule, `site.yml`,
`galaxy.yml`, `requirements.yml`, `execution-environment.yml`, and the
`.ansible.yml` extension) and starts its server only for file-scheme documents
with that language.

## Decision

The extension contributes that same `ansible` language, including those names.
Its language client opens `file` and `untitled` documents whose language id is
`ansible`. A plain YAML file stays YAML unless one of those patterns matches,
or the user sets the language.

## Consequences

- Installed alone, the extension labels the same files Ansible as
  `redhat.ansible`.
- Installed beside it, both servers see the same `ansible` documents
  ([ADR-0032](0032-no-coordination-with-other-language-servers.md)).
- `galaxy.yml`, `requirements.yml`, and `execution-environment.yml` are opened
  by `zals` even though they are not playbooks.
- Unsaved `ansible` buffers get a server. `redhat.ansible`'s own server does
  not attach to `untitled` documents.
