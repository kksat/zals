# Ansible Language Server (zals) for PyCharm & IntelliJ IDEA

This directory contains the IntelliJ Platform plugin for **zals** (Zig Ansible Language Server), providing first-class Ansible language support in PyCharm, IntelliJ IDEA, and other JetBrains IDEs.

## Features

* **Autocompletion**: Ansible modules, keyword directives, and variables.
* **Hover Documentation**: Detailed documentation for built-in and collection modules.
* **Go to Definition**: Jump to variable definitions, module source, and Ansible roles.
* **Go to Implementation**: Jump directly to role main task files (`tasks/main.yml`).
* **Find References**: Locate variable usage across playbooks and roles.
* **Diagnostics**: Real-time syntax check and `ansible-lint` diagnostics.

## Prerequisites

1. Install **`zals`** and ensure it is in your system `$PATH`:
   ```sh
   # Homebrew (macOS / Linux)
   brew tap kksat/tap && brew install zals

   # Or pip (Linux / macOS / Windows)
   pip install zals
   ```

## Building the Plugin

To build the plugin `.zip` distribution:

```sh
cd editors/pycharm
./gradlew buildPlugin
```

The resulting package will be in `build/distributions/zals-pycharm-0.1.0.zip`.

## Installation into PyCharm / IntelliJ IDEA

1. Open PyCharm or IntelliJ IDEA.
2. Go to **Settings / Preferences** (`Ctrl+Alt+S` or `Cmd+,`) > **Plugins**.
3. Click the gear icon ⚙️ and select **Install Plugin from Disk...**.
4. Select `build/distributions/zals-pycharm-0.1.0.zip`.
5. Restart the IDE.

## Configuration

Configure `zals` in **Settings > Languages & Frameworks > Ansible (zals)**:
* **zals executable path**: Leave blank to use the `zals` found on `$PATH`, or specify an absolute path.
* **Validation / Linting**: Enable or disable `ansible-lint` diagnostics.

See [`docs/editors/pycharm.md`](../../docs/editors/pycharm.md) for full documentation.
