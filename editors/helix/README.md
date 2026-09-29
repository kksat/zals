# Helix Configuration for zals (Ansible Language Server)

Helix supports Language Server Protocol (LSP) natively through declarative configuration in `languages.toml`. No external plugin is required.

## Prerequisites

Ensure `zals` is installed and available in your `PATH`:

```sh
# Via Homebrew
brew tap kksat/tap
brew install zals

# Or via pip
pip install zals
```

Verify the installation:
```sh
zals --version
```

## Quick Start

### 1. Global Setup

Copy or append the contents of [`languages.toml`](languages.toml) to your global Helix configuration:

* **Linux/macOS:** `~/.config/helix/languages.toml`
* **Windows:** `%APPDATA%\helix\languages.toml`

### 2. Workspace Setup

Alternatively, configure `zals` for a specific project by placing [`languages.toml`](languages.toml) in `.helix/languages.toml` at your repository root.

## Features Supported in Helix

| Feature | Keybinding in Helix |
|---|---|
| Hover Documentation | `space` + `k` |
| Go to Definition | `g` + `d` |
| Go to Implementation | `g` + `i` |
| Find References | `g` + `r` |
| Code Actions | `space` + `a` |
| Document Outline / Symbols | `space` + `s` |
| Diagnostics Picker | `space` + `d` |

## Detailed Documentation

See [`docs/editors/helix.md`](../../docs/editors/helix.md) for full configuration options, settings reference, and troubleshooting.
