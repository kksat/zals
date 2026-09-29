# ADR-0035: Extension ignores Python configuration

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

`zals` accepts `ansible.python.interpreterPath` and
`ansible.python.activationScript` ([ADR-0017](0017-settings-compatibility.md))
and never reads them. `redhat.ansible` fills an empty interpreter path from the
Python extension before starting its server.

## Decision

The extension ignores Python configuration. It does not contribute those two
settings, does not send them on its own, and does not call the Python
extension.

## Consequences

- An empty or absent interpreter path stays empty. The extension will not
  discover a workspace virtualenv.
- [ADR-0017](0017-settings-compatibility.md) is unchanged: the server still
  accepts the keys. This decision is about the extension's settings UI.
- If those keys are already present in a workspace `ansible` block, the server
  stores them and continues to ignore them.
