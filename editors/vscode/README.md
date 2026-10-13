# Ansible Language Server (zals) for VS Code

A lightweight VS Code extension providing language support for Ansible playbooks,
roles, and metadata files, backed by the high-performance Zig Ansible Language
Server ([zals](https://github.com/kksat/zals)).

## Features

- **Document selector:** Automatically activates on Ansible playbooks, role files
  (`tasks`, `handlers`, `defaults`, `vars`, `meta`), `galaxy.yml`,
  `requirements.yml`, and `execution-environment.yml`.
- **Diagnostics:** Inline validation and syntax checking via `ansible-lint` and
  `ansible-playbook --syntax-check`.
- **Navigation:** Go-to-definition and references for variables and roles.
- **Completion & Outline:** Fast symbol outline and module/argument completion.
- **Code Actions:** Debug tasks for variables and extract-to-task refactorings.
- **Fast & Self-Contained:** Every platform package bundles a native `zals`
  executable with instant startup and zero Node runtime overhead.

## Settings

This extension exposes the native `ansible.*` settings accepted by `zals`:

| Setting | Default | Description |
| --- | --- | --- |
| `ansible.ansible.path` | `"ansible"` | Path to the ansible executable. |
| `ansible.ansible.useFullyQualifiedCollectionNames` | `true` | Use FQCN when completing module names. |
| `ansible.completion.provideRedirectModules` | `true` | Toggle redirected module completion. |
| `ansible.completion.provideModuleOptionAliases` | `true` | Toggle alias completion for module options. |
| `ansible.validation.enabled` | `true` | Enable or disable document validation. |
| `ansible.validation.lint.enabled` | `true` | Run `ansible-lint` diagnostics. |
| `ansible.validation.lint.path` | `"ansible-lint"` | Path to the `ansible-lint` executable. |
| `ansible.validation.lint.arguments` | `""` | Arguments to pass to `ansible-lint`. |
| `ansible.validation.lint.autoFixOnSave` | `false` | Run `ansible-lint --fix` on save. |

## License

GPL-3.0-only. See [LICENSE](../../LICENSE) for details.
