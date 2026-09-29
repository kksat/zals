# Configuring Sublime Text for zals

Sublime Text supports Language Server Protocol (LSP) through the community-standard **`LSP`** package. The **`LSP-zals`** helper package provides seamless integration with the `zals` server.

## 1. Install Prerequisites

### 1. Install zals

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

### 2. Install Sublime LSP Package

1. Open Sublime Text.
2. Open the Command Palette (`Ctrl+Shift+P` on Linux/Windows, `Cmd+Shift+P` on macOS).
3. Type `Package Control: Install Package` and press Enter.
4. Search for `LSP` and press Enter to install it.

---

## 2. Install LSP-zals

### From Git / Local Directory

Clone or symlink `editors/sublime` to your Sublime Text `Packages` directory:

* **macOS:**
  ```sh
  cd ~/Library/Application\ Support/Sublime\ Text/Packages
  git clone https://github.com/kksat/zals.git
  ln -s zals/editors/sublime LSP-zals
  ```

* **Linux:**
  ```sh
  cd ~/.config/sublime-text/Packages
  git clone https://github.com/kksat/zals.git
  ln -s zals/editors/sublime LSP-zals
  ```

* **Windows:**
  ```cmd
  cd %APPDATA%\Sublime Text\Packages
  git clone https://github.com/kksat/zals.git
  mklink /D LSP-zals zals\editors\sublime
  ```

Restart Sublime Text after installation.

---

## 3. Configuration

You can customize `LSP-zals` settings through `Preferences > Package Settings > LSP > Servers > LSP-zals` or by creating `Packages/User/LSP-zals.sublime-settings`:

```json
{
  "settings": {
    "command": ["zals", "--stdio"],
    "settings": {
      "ansible.validation.enabled": true,
      "ansible.validation.lint.enabled": true,
      "ansible.validation.lint.path": "ansible-lint",
      "ansible.ansible.path": "ansible",
      "ansible.ansible.useFullyQualifiedCollectionNames": true,
      "ansible.completion.provideRedirectModules": true,
      "ansible.completion.provideDisabledModules": true
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

## 4. Keybindings in Sublime Text LSP

| Action | Default Shortcut |
|---|---|
| Hover Documentation | Move mouse over symbol or run `show_at_point` |
| Go to Definition | `F12` |
| Go to Implementation | `Shift+F12` |
| Find References | `Alt+Shift+F12` |
| Code Actions | `Alt+Enter` |
| Document Symbols | `Ctrl+R` / `Cmd+R` |
| Workspace Diagnostics | `LSP: Show Diagnostics Panel` in Command Palette |

---

## 5. Troubleshooting

* **Check LSP Status:** Run `LSP: Toggle Log Panel` in the Command Palette to inspect LSP requests and server responses.
* **Server Not Starting:** Verify that `zals` is found in the shell `$PATH`. If using a non-standard path, set `"command": ["/path/to/zals", "--stdio"]` in `LSP-zals.sublime-settings`.
