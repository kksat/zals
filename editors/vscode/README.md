# Ansible Language Server (zals) for VS Code

**Spend less time searching YAML. Spend more time writing Ansible.**

Find where a variable is defined and used, jump from a role call to its contract
or implementation, and add debug tasks without breaking your flow. zals brings
Ansible-aware navigation, documentation, completion, and refactoring into your
editor, backed by a native language server.

[Install from Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=kksat.zals)
· [Get it on Open VSX](https://open-vsx.org/extension/kksat/zals)
· [Source code](https://github.com/kksat/zals)

## Why zals?

- **Understand unfamiliar playbooks faster.** Inspect variable definitions and
  values on hover, then follow references across your workspace.
- **See what a role expects—and what it does.** Read role documentation and
  parameter descriptions on hover. Jump straight to argument specs, task files,
  or parameter values.
- **Keep repetitive edits out of your way.** Insert and remove variable debug
  tasks, or extract selected tasks into a separate file with an include or import.
- **Keep the essentials.** Ansible syntax highlighting, module and argument
  completion, module documentation, jump-to-module-source, an Outline view, and
  diagnostics from your Ansible tools.
- **No separate server install.** The matching native zals executable is bundled
  with the extension for Linux, macOS, and Windows.

## Get started

1. Install **Ansible Language Server (zals)** by **kksat** from the
   [Marketplace](https://marketplace.visualstudio.com/items?itemName=kksat.zals)
   or [Open VSX](https://open-vsx.org/extension/kksat/zals). In VS Code, you can
   also run:

   ```sh
   code --install-extension kksat.zals
   ```

2. Have **ansible-core** available in the environment running the extension
   (`ansible`, `ansible-doc`, `ansible-config`, and `ansible-playbook` on `PATH`).
   Install **ansible-lint** for lint diagnostics and fixes; without it,
   validation falls back to `ansible-playbook --syntax-check`.
3. Open your Ansible project folder. Workspace-wide navigation uses the Git
   repository boundary (`.git`) by default. The extension requires a trusted
   workspace: trust only projects whose contents you trust.
4. Open a playbook or role file. If the status bar says **YAML**, click the
   language mode and select **Ansible**.

**Try it now:** right-click a variable and choose **Find All References**, hover
over a role parameter, or use **Go to Symbol in Workspace** from the Command
Palette.

Using Remote SSH, WSL, or a dev container? Install zals on
remote host.

```sh
 pip install --user zals
```

or

```sh
 brew install kksat/tap/zals
```

The bundled server must match the host running the extension,
not your local desktop.

For offline or manual installation, download the matching platform's `.vsix`
from [GitHub Releases](https://github.com/kksat/zals/releases) and run
**Extensions: Install from VSIX...**. Packages support Linux x64/arm64, macOS
Intel/Apple Silicon, and Windows x64.

## See it in action

All eight recordings below show zals running in VS Code, from the
[Ansible community introduction](https://forum.ansible.com/t/ansible-deserves-proper-language-server/46483).

### Follow a variable across your workspace

Use **Find All References** from a variable read or definition to see where that
name appears. Use **Go to Definition** to inspect its bindings, and hover to see
candidate values without leaving your file.

![Find all references to an Ansible variable across the workspace](https://us1.discourse-cdn.com/ansible/original/2X/4/449651e44d47de482ee3d7ca2f3c21d80607ab20.gif)

### Find references to variable fields, too

Follow fields such as `ansible_facts['distribution']` and
`ansible_facts.distribution`; both access styles are recognized.

![Find references to a variable field in Ansible expressions](https://us1.discourse-cdn.com/ansible/original/2X/5/588f701186d1f7bb1dc9f3f9da24cc10f7c04ada.gif)

References are static, workspace-wide name matches, not a simulation of Ansible
execution. Variables with the same name can appear across roles; field references
match the leaf field name, even on different objects.

### Add a debug task without typing the boilerplate

Place the cursor on a variable and open **Refactor...** to insert a debug task
for it.

![Insert an Ansible debug task for the variable under the cursor](https://us1.discourse-cdn.com/ansible/original/2X/5/551375014abcf7f8e7557255730ad7572ecaf247.gif)

When you are done, use the code action inside the debug task to remove it.

![Remove an Ansible debug task with a code action](https://us1.discourse-cdn.com/ansible/original/2X/0/0af4df77112af46346714c32959fb8ee59ff9b81.gif)

### Jump from a role call to its contract

Use **Go to Definition** on a role name to open its argument specs, with role
metadata or the main task file as fallbacks. See the role's interface without
hunting through directories.

![Go to a role definition in its argument specs](https://us1.discourse-cdn.com/ansible/original/2X/4/43f6f5597b6205495317f6c8e304a4c47375e97c.gif)

### Go straight to the role's tasks

Use **Go to Implementations** on a role name to open its main task file.

![Go from a role invocation to its main task file](https://us1.discourse-cdn.com/ansible/original/2X/1/1c8dad4dcea6a6da303bf7362dca3125de5f0cbe.gif)

### Understand role parameters where you use them

Hover over a passed parameter for its argument-spec documentation. Use **Go to
Definition** to open the matching option, or **Go to Implementations** to find
concrete values in the called role, such as defaults or vars.

![Go from a passed role parameter to its argument-spec definition](https://us1.discourse-cdn.com/ansible/original/2X/c/c6904d641e1b29268b56a1692fba5935843de9b0.gif)

### Find tasks and roles by name, not by file path

Run **Go to Symbol in Workspace** to search playbooks, roles, and named tasks.
Use the **Outline** view to navigate the current file.

![Search Ansible symbols across the workspace](https://us1.discourse-cdn.com/ansible/original/2X/8/8bed9d9c68c414c575394d0ff541eae286c6949e.gif)

## Fits your Ansible project

zals recognizes common playbook and role paths, including tasks, handlers,
defaults, vars, and metadata. It also supports Ansible metadata files such as
`galaxy.yml`, `requirements.yml`, and `execution-environment.yml` with bundled
schema validation. For other filenames, select **Ansible** as the language mode
or add a targeted `files.associations` entry in VS Code settings.

Open **Settings** and search for `@ext:kksat.zals` to adjust completion and
validation. Common options:

| Setting                                            | Default          | When to change it                                            |
| -------------------------------------------------- | ---------------- | ------------------------------------------------------------ |
| `ansible.ansible.path`                             | `"ansible"`      | Point to your Ansible executable if it is not on `PATH`.     |
| `ansible.ansible.useFullyQualifiedCollectionNames` | `true`           | Turn off if you prefer short module names where unambiguous. |
| `ansible.validation.enabled`                       | `true`           | Turn off document validation.                                |
| `ansible.validation.lint.path`                     | `"ansible-lint"` | Point to the linter in your Ansible environment.             |
| `ansible.validation.lint.arguments`                | `""`             | Pass additional arguments to `ansible-lint`.                 |
| `ansible.validation.lint.autoFixOnSave`            | `false`          | Opt in to `ansible-lint --fix` on save; this modifies files. |

## Focused, local, and open source

- **Runs on your extension host.** The bundled native server communicates
  directly with VS Code and uses your Ansible tools for documentation and linting.
- **Edits stay under your control.** Debug and extract-task actions are explicit
  editor actions. Lint auto-fix on save is off by default.
- **Developed in the open.** Browse the [source](https://github.com/kksat/zals),
  [release history](https://github.com/kksat/zals/releases), and
  [community discussion](https://forum.ansible.com/t/ansible-deserves-proper-language-server/46483).

zals is an independent project, not an official Red Hat or Ansible extension.
It focuses on editing Ansible YAML—not Lightspeed, MCP, execution-environment
management, or the full ansible-dev-tools experience. It can serve as your
Ansible YAML language extension without requiring the Red Hat extension.

## Feedback and support

Something not working? [Report an issue](https://github.com/kksat/zals/issues)
with your extension version, operating system or remote environment, and a small
example. Feature ideas are welcome in the
[Ansible forum discussion](https://forum.ansible.com/t/ansible-deserves-proper-language-server/46483).

If zals makes your Ansible work easier, a review on the
[Marketplace](https://marketplace.visualstudio.com/items?itemName=kksat.zals&ssr=false#review-details)
or [Open VSX](https://open-vsx.org/extension/kksat/zals/reviews) helps others find it.

## License

[GPL-3.0-only](https://github.com/kksat/zals/blob/main/LICENSE).
