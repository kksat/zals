# ADR-0036: Extension settings contribution

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

The extension should expose the configuration `zals` accepts. Python settings are
out ([ADR-0035](0035-extension-ignores-python-configuration.md)). Of the other
nine, the server only consults the validation and lint settings. It parses
`ansible.ansible.path`, `ansible.ansible.useFullyQualifiedCollectionNames`, the
two completion toggles, and `ansible.validation.lint.autoFixOnSave`, and does
not read them.

## Decision

Contribute those nine settings, with the names and defaults in
[ADR-0017](0017-settings-compatibility.md). Property scopes match the
`redhat.ansible` contribution for the same keys. The extension forwards the
values as set in VS Code.

## Consequences

- Five of the nine settings are visible before the server honors them. They
  take effect in the `zals` release that starts reading them, which is the same
  version as the extension.
- `ansible.validation.lint.autoFixOnSave` does not fix on save today.
- Python settings stay out of the contribution.
