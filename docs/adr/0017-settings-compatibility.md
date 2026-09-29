# ADR-0017: Settings compatibility

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Users configure the Ansible language server through `ansible.*` settings. If
`zals` invented its own names, every existing configuration would need editing
and documentation would diverge from upstream.

## Decision

Use **upstream's exact setting names and defaults** for the Tier 1 subset:

| Setting | Default |
| --- | --- |
| `ansible.ansible.path` | `ansible` |
| `ansible.ansible.useFullyQualifiedCollectionNames` | `true` |
| `ansible.completion.provideRedirectModules` | `true` |
| `ansible.completion.provideModuleOptionAliases` | `true` |
| `ansible.validation.enabled` | `true` |
| `ansible.validation.lint.enabled` | `true` |
| `ansible.validation.lint.path` | `ansible-lint` |
| `ansible.validation.lint.arguments` | `""` |
| `ansible.validation.lint.autoFixOnSave` | `false` |
| `ansible.python.interpreterPath` | `""` |
| `ansible.python.activationScript` | `""` |
| `ansible.python.venvPath` | `.venv` |
| `ansible.workspace.missingGitWarning` | `true` |
| `ansible.workspace.rootMarker` | `.git` |

## Consequences

- Existing configurations work unchanged.
- Upstream documentation applies directly.
- `ansible.workspace.missingGitWarning`, `ansible.workspace.rootMarker`, and
  `ansible.python.venvPath` ([ADR-0032](0032-workspace-wide-navigation.md)) are
  zals settings (see [ADR-0014](0014-multi-root-workspace.md)); upstream has no
  equivalent. `rootMarker` defaults to `.git`; changing it redefines the
  Workspace.
- We inherit upstream's naming, including any inconsistencies; we do not
  "improve" names, because that would break compatibility.
- Settings outside the Tier 1 subset are ignored rather than rejected.