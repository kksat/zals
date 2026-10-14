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

## Install and develop

Releases publish VSIXs to GitHub by default. Maintainers can opt into publishing
those verified packages to Visual Studio Marketplace and Open VSX; see the
[registry publishing setup](../../docs/vscode-publishing.md).
For local installation, download the package matching the VS Code host platform
and use
**Extensions: Install from VSIX...**. For remote development, choose the remote
host's platform, not the local desktop's.

Development requires Node 22+:

```sh
npm ci
npm run typecheck
npm test
npm run package
```

Before packaging a VSIX, put the matching release binary in `bin/zals`
(`bin/zals.exe` on Windows). Then run, for example:

```sh
npx --no-install vsce package --target darwin-arm64 --no-dependencies
```

The root release workflow performs this for all five supported platforms.

## License

GPL-3.0-only. See [LICENSE](../../LICENSE) for details.
