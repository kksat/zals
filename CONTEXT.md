# zals

A Zig reimplementation of the Ansible Language Server. This glossary covers the
vocabulary of variable navigation (finding the definition of a variable and
finding every reference to it), of the document outline (the symbols a client
shows for a single file), of code actions (adding and removing a debug task
for a variable, and extracting tasks into a task file), and of the project
tree.

## Language

**Workspace**:
The nearest directory containing `.git` at or above a folder or file, whether
`.git` is a directory or a file. A nested `.git` is its own Workspace and stays
out of the session until an opened folder walks up to it, one per distinct
`.git`, and a folder with no `.git` at or above it has none.
_Avoid_: workspace folder, root URI, multi-root workspace

**Role**:
An Ansible reusable unit rooted at a directory containing conventional
subdirectories (`defaults/`, `vars/`, `tasks/`, `handlers/`, `templates/`,
`meta/`).
_Avoid_: package, module

**Playbook**:
A single YAML file containing one or more plays.
_Avoid_: play (a play is one entry within a playbook)

**Play**:
One entry within a playbook, targeting hosts and containing tasks, roles, and
handlers.
_Avoid_: playbook entry, play block

**Task**:
A single unit of work in a play, block, or task file, invoking one module.
_Avoid_: step, action, job

**Task file**:
A YAML file whose root is a task list, included into a play or another task
file with `include_tasks` or `import_tasks`.
_Avoid_: tasks file, subtask file

**Block**:
A task that groups nested tasks under `block`, `rescue`, and `always`.
_Avoid_: task group, section

**Handler**:
A task that runs only when notified by another task.
_Avoid_: callback, hook

**Role invocation**:
An entry in a play's `roles:` list that applies a role.
_Avoid_: role reference, role call

**Role reference**:
A site that names a role to apply: an entry in a play's `roles:` list, the
`name` of an `include_role`/`import_role` task, or an entry in a role's
`meta/main.yml` `dependencies:`. Go-to-definition opens the role's argument
specs, metadata, or main task file; go-to-implementation opens its main task
file.
_Avoid_: role usage, role mention

**Module key**:
The key of a task map that names the module the task invokes.
_Avoid_: action key, module name

**Document symbol**:
An entity shown in a client's outline for a single document.
_Avoid_: outline entry, breadcrumb

**Variable**:
A name that Ansible resolves at runtime from a definition.
_Avoid_: parameter, argument, setting, fact

**Variable definition**:
A site that binds a name to a value for later reference. In scope: top-level
keys in role `defaults/main.yml` and `vars/main.yml`; `vars:` maps at play,
block, and task level; `set_fact:` keys; `register:` values; `vars_files:`;
`include_vars` (without a `name` prefix); `loop_control.loop_var`; `vars_prompt:`
names; role `meta/main.yml` `argument_specs` options; and role invocation params
in a playbook's `roles:` entry.
_Avoid_: definition site, declaration, binding, assignment

**Variable reference**:
An occurrence of a variable name that reads its value — inside a Jinja
expression (`{{ … }}`, `{% … %}`) or as a bare name in an expression-valued key.
_Avoid_: reference occurrence, variable usage, variable use, variable mention

**Jinja expression**:
Text delimited by `{{ … }}` or `{% … %}`. Only root identifiers are references;
attribute, filter, and test names are not.
_Avoid_: template, interpolation

**Bare-expression key**:
A task or play key whose value is a Jinja expression without delimiters:
`when`, `changed_when`, `failed_when`, `until`, `loop`, `with_*`, and
`assert.that`.
_Avoid_: implicit template, raw expression

**Debug statement**:
A task that invokes the `debug` module (`debug` or `*.debug`) to print a
variable or message.
_Avoid_: debug task, print statement

**Code action**:
An LSP `textDocument/codeAction` entry that edits the document. zals offers two
families: debug actions of kind `refactor` (add a debug statement for the
variable under the cursor, and remove the debug statement the cursor is
inside), and extract actions of kind `refactor.extract` (move the task(s) under
the cursor or selection into a new task file and replace them with
`include_tasks` or `import_tasks`).
_Avoid_: quick fix, refactoring

**Extract**:
Move one or more task items into a new sibling task file and replace them with
an `include_tasks` or `import_tasks` reference. The new file is named
`taskN.<ext>` and is never overwritten.
_Avoid_: split, factor out

**Role scope**:
The search space for a variable defined or used in a role: the conventional
subdirectories of the role root, plus one level of `vars_files`/`include_vars`
targets.
_Avoid_: role directory, role folder

**Playbook scope**:
The search space for a variable defined or used in a playbook: the playbook file
plus one level of `vars_files`/`include_vars` targets.
_Avoid_: play scope, file scope