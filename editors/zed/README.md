# Zed Extension for zals (Ansible)

This directory provides the official **Zed extension** for **zals** (Zig Ansible Language Server).

Provides autocompletion, hover documentation, go-to-definition, find-references, and diagnostics for Ansible files directly in Zed.

## Prerequisites

Ensure `zals` is installed and available on your system `$PATH`:

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

## Installing the Extension in Zed

### Install as a Dev Extension

1. Open Zed.
2. Open the Command Palette (`cmd-shift-p` on macOS or `ctrl-shift-p` on Linux/Windows).
3. Search for `zed: install dev extension`.
4. Select the `editors/zed` directory from this repository.

Zed will build and load the extension into your running editor.

## Configuration

In your Zed `settings.json` (`cmd-,` on macOS or `ctrl-,` on Linux):

```json
{
  "languages": {
    "Ansible": {
      "language_servers": ["zals"]
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

See [`docs/editors/zed.md`](../../docs/editors/zed.md) for detailed documentation and settings.
