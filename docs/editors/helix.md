# Configuring Helix for zals

Helix has native LSP support and does not use plugins. All language servers and file associations are defined declaratively in `languages.toml`.

## 1. Install zals

First, install `zals` and ensure it is on your `$PATH`:

```sh
# macOS / Linux (Homebrew)
brew tap kksat/tap
brew install zals

# Linux / macOS / Windows (pip)
pip install zals
```

Verify that `zals` starts:
```sh
zals --version
```

## 2. Configuration (`languages.toml`)

Add the following to your `~/.config/helix/languages.toml` (or project-level `.helix/languages.toml`):

```toml
[language-server.zals]
command = "zals"
args = ["--stdio"]

[language-server.zals.config.ansible]
validation.enabled = true
validation.lint.enabled = true
validation.lint.path = "ansible-lint"
completion.provideRedirectModules = true
completion.provideDisabledModules = true

[[language]]
name = "ansible"
scope = "source.ansible"
injection-regex = "ansible"
file-types = [
  "playbook.yml",
  "playbook.yaml",
  "site.yml",
  "site.yaml",
  { glob = "**/playbooks/*.yml" },
  { glob = "**/playbooks/*.yaml" },
  { glob = "**/roles/*/tasks/*.yml" },
  { glob = "**/roles/*/tasks/*.yaml" },
  { glob = "**/roles/*/handlers/*.yml" },
  { glob = "**/roles/*/handlers/*.yaml" },
  { glob = "**/roles/*/defaults/*.yml" },
  { glob = "**/roles/*/defaults/*.yaml" },
  { glob = "**/roles/*/vars/*.yml" },
  { glob = "**/roles/*/vars/*.yaml" },
  { glob = "**/roles/*/meta/*.yml" },
  { glob = "**/roles/*/meta/*.yaml" },
  { glob = "**/tasks/*.yml" },
  { glob = "**/tasks/*.yaml" },
  { glob = "**/handlers/*.yml" },
  { glob = "**/handlers/*.yaml" },
  { glob = "**/defaults/*.yml" },
  { glob = "**/defaults/*.yaml" },
  { glob = "**/vars/*.yml" },
  { glob = "**/vars/*.yaml" },
  { glob = "**/meta/*.yml" },
  { glob = "**/meta/*.yaml" },
  { glob = "**/molecule/*/*.yml" },
  { glob = "**/molecule/*/*.yaml" },
  { glob = "*.ansible.yml" },
  { glob = "*.ansible.yaml" },
]
roots = ["ansible.cfg", ".git", "requirements.yml", "galaxy.yml"]
language-servers = [ "zals" ]
indent = { tab-width = 2, unit = "  " }
comment-token = "#"
```

### Coexisting with `yaml-language-server`

If you also write generic YAML and use `yaml-language-server`, you can configure Helix to use both servers or attach `zals` to generic YAML:

```toml
[[language]]
name = "yaml"
language-servers = [ "zals", "yaml-language-server" ]
```

## 3. Settings Reference

The following `ansible.*` settings are supported by `zals`:

| Setting | Type | Default | Description |
|---|---|---|---|
| `ansible.validation.enabled` | boolean | `true` | Enable validation and diagnostics. |
| `ansible.validation.lint.enabled` | boolean | `true` | Enable `ansible-lint` diagnostics. |
| `ansible.validation.lint.path` | string | `"ansible-lint"` | Path to the `ansible-lint` executable. |
| `ansible.ansible.path` | string | `"ansible"` | Path to the `ansible` executable. |
| `ansible.ansible.useFullyQualifiedCollectionNames` | boolean | `true` | Suggest FQCN module names in completions. |
| `ansible.completion.provideRedirectModules` | boolean | `true` | Include redirected modules in completions. |
| `ansible.completion.provideDisabledModules` | boolean | `true` | Include deprecated/disabled modules in completions. |

## 4. Keybindings in Helix

| LSP Action | Helix Shortcut |
|---|---|
| Show documentation on hover | `space` + `k` |
| Jump to definition | `g` + `d` |
| Jump to implementation (role main task) | `g` + `i` |
| Find references | `g` + `r` |
| Apply code action (e.g. debug task) | `space` + `a` |
| Document outline / symbols | `space` + `s` |
| Diagnostics list | `space` + `d` |
| Rename symbol | `space` + `r` |

## 5. Troubleshooting

* **Check LSP status in Helix:** Open an Ansible file and run `:lsp-workspace-command` or `:check` in Helix.
* **View language server logs:** Run `:log-open` inside Helix to view Helix's LSP communication logs.
* **Verify `zals` command:** Run `which zals` in your terminal to ensure the binary is in the `PATH` that Helix inherits.
