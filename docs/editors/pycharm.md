# Configuring PyCharm and IntelliJ IDEA for zals

This guide explains how to install and configure the **zals** (Zig Ansible Language Server) plugin in JetBrains IDEs, including PyCharm, IntelliJ IDEA, and WebStorm.

## 1. Install zals

Ensure `zals` is installed and reachable via your system `$PATH`:

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

## 2. Install the Plugin

### From Pre-built Plugin Archive

1. Download or build the plugin archive `zals-pycharm-<version>.zip`.
2. Open your JetBrains IDE (PyCharm, IntelliJ IDEA).
3. Open **Settings** (`Ctrl+Alt+S` on Linux/Windows, `Cmd+,` on macOS).
4. Navigate to **Plugins**.
5. Click the gear icon ⚙️ at the top and select **Install Plugin from Disk...**.
6. Select the downloaded `.zip` file and restart the IDE.

---

## 3. Configuration

Go to **Settings > Languages & Frameworks > Ansible (zals)**:

* **zals executable path**: Path to the `zals` binary. If left empty, the plugin searches `$PATH`.
* **Validation & Diagnostics**: Toggle real-time validation.
* **ansible-lint path & toggle**: Enable or disable lint diagnostics and configure custom `ansible-lint` location.

---

## 4. Keybindings in JetBrains IDEs

| Action | Shortcut (macOS) | Shortcut (Windows/Linux) |
|---|---|---|
| Quick Documentation (Hover) | `F1` or `Cmd-Y` | `Ctrl+Q` |
| Go to Definition | `Cmd-B` or `Cmd-Click` | `Ctrl+B` or `Ctrl-Click` |
| Go to Implementation | `Cmd-Alt-B` | `Ctrl+Alt+B` |
| Find Usages / References | `Alt-F7` | `Alt+F7` |
| Show Intention Actions / Quick Fixes | `Alt-Enter` | `Alt+Enter` |
| File Structure / Outline | `Cmd-F12` | `Ctrl+F12` |

---

## 5. Troubleshooting

* **Check LSP Console:** Open `Help > Diagnostic Tools > Show Log in Explorer/Finder` to view `idea.log` for LSP errors.
* **PATH on macOS:** GUI applications on macOS sometimes do not inherit terminal environment variables. If `zals` is not found, specify the full path (e.g. `/opt/homebrew/bin/zals`) in **Settings > Languages & Frameworks > Ansible (zals)**.
