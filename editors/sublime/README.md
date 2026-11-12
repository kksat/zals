# LSP-zals (Sublime Text)

Sublime Text LSP helper package for **zals** (Zig Ansible Language Server).

Provides autocompletion, hover documentation, go-to-definition, find-references, document symbols, and diagnostics for Ansible playbooks, roles, tasks, and variables in Sublime Text.

## Prerequisites

1. Install **Sublime Text 4**.
2. Install the **[LSP](https://packagecontrol.io/packages/LSP)** package via Package Control.
3. Install **`zals`** and ensure it is on your `$PATH`:
   ```sh
   # Homebrew (macOS / Linux)
   brew tap kksat/tap && brew install zals

   # Or pip (Linux / macOS / Windows)
   pip install zals
   ```

## Installation

### Manual Installation (Development / Direct)

Clone or link this directory into your Sublime Text `Packages` directory:

* **macOS:** `~/Library/Application Support/Sublime Text/Packages/LSP-zals`
* **Linux:** `~/.config/sublime-text/Packages/LSP-zals`
* **Windows:** `%APPDATA%\Sublime Text\Packages\LSP-zals`

```sh
cd ~/Library/Application\ Support/Sublime\ Text/Packages/
git clone https://github.com/kksat/zals.git
# Or create a symbolic link to editors/sublime
ln -s /path/to/zals/editors/sublime LSP-zals
```

Restart Sublime Text.

## Configuration

Access settings via `Preferences > Package Settings > LSP > Servers > LSP-zals` or edit `LSP-zals.sublime-settings`:

```json
{
  "settings": {
    "command": ["zals", "--stdio"],
    "settings": {
      "ansible.validation.enabled": true,
      "ansible.validation.lint.enabled": true,
      "ansible.validation.lint.path": "ansible-lint"
    }
  }
}
```

See [`docs/editors/sublime.md`](../../docs/editors/sublime.md) for full settings reference and troubleshooting.
