# Configuring Zed for zals

Zed supports Language Servers via its WebAssembly-based Extension system. The `zals` extension integrates the Zig Ansible Language Server into Zed.

## 1. Install zals

Ensure `zals` is available on your system `$PATH`:

```sh
# macOS / Linux (Homebrew)
brew tap kksat/tap
brew install zals

# Linux / macOS / Windows (pip)
pip install zals
```

Verify:
```sh
zals --version
```

---

## 2. Install the Zed Extension

### Install as a Dev Extension

1. Open Zed.
2. Press `cmd-shift-p` (macOS) or `ctrl-shift-p` (Linux/Windows) to open the Command Palette.
3. Type `zed: install dev extension` and press Enter.
4. Browse to and select the `editors/zed` directory in your clone of this repository.

Zed will compile the WebAssembly extension and activate `zals`.

---

## 3. Configuration (`settings.json`)

Open your Zed settings (`cmd-,` on macOS or `ctrl-,` on Linux) to configure `zals`:

```json
{
  "languages": {
    "Ansible": {
      "language_servers": ["zals"]
    },
    "YAML": {
      "language_servers": ["zals", "!yaml-language-server"]
    }
  },
  "lsp": {
    "zals": {
      "settings": {
        "ansible": {
          "validation": {
            "enabled": true,
            "lint": {
              "enabled": true,
              "path": "ansible-lint"
            }
          },
          "ansible": {
            "path": "ansible",
            "useFullyQualifiedCollectionNames": true
          },
          "completion": {
            "provideRedirectModules": true,
            "provideDisabledModules": true
          }
        }
      }
    }
  }
}
```

### Supported Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `ansible.validation.enabled` | boolean | `true` | Enable validation and diagnostics. |
| `ansible.validation.lint.enabled` | boolean | `true` | Enable `ansible-lint` diagnostics. |
| `ansible.validation.lint.path` | string | `"ansible-lint"` | Executable path for `ansible-lint`. |
| `ansible.ansible.path` | string | `"ansible"` | Executable path for `ansible`. |
| `ansible.ansible.useFullyQualifiedCollectionNames` | boolean | `true` | Suggest FQCN module names in completions. |
| `ansible.completion.provideRedirectModules` | boolean | `true` | Include redirected modules in completions. |
| `ansible.completion.provideDisabledModules` | boolean | `true` | Include deprecated/disabled modules in completions. |

---

## 4. Keybindings in Zed

| Feature | Shortcut (macOS) | Shortcut (Linux/Windows) |
|---|---|---|
| Hover Documentation | `cmd-k cmd-i` (or hover mouse) | `ctrl-k ctrl-i` |
| Go to Definition | `f12` or `cmd-click` | `f12` or `ctrl-click` |
| Go to Implementation | `cmd-f12` | `ctrl-f12` |
| Find All References | `shift-f12` | `shift-f12` |
| Code Actions | `cmd-.` | `ctrl-.` |
| Document Outline | `cmd-shift-o` | `ctrl-shift-o` |

---

## 5. Troubleshooting

* **Check LSP Logs:** Open Command Palette and run `zed: open log` to inspect extension and language server output.
* **Server Not Found:** Ensure `zals` is in the `PATH` of the shell that launched Zed (e.g. `which zals`).
