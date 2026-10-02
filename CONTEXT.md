# zals

A Zig reimplementation of the Ansible Language Server. This glossary covers the
vocabulary of variable navigation (finding the definition of a variable and
finding every reference to it), of the document outline (the symbols a client
shows for a single file), of code actions (adding and removing a debug task
for a variable, and extracting tasks into a task file), and of the project
tree.

## Language

**Workspace**:
The nearest directory containing the configured root marker (`.git` by default,
as a file or directory) at or above a folder or file. Nested markers define
separate Workspaces; a Workspace joins the session only when an opened folder
reaches it, and a variable name is sought across the Workspace that owns its
file.
_Avoid_: workspace folder, root URI, multi-root workspace

**Role**:
An Ansible reusable unit rooted at a directory containing conventional
subdirectories (`defaults/`, `vars/`, `tasks/`, `handlers/`, `templates/`,
`meta/`).
_Avoid_: package, module

**Collection**:
An Ansible distribution unit named `namespace.collection`, holding roles,
modules, plugins, and playbooks, and described by its `galaxy.yml`.
_Avoid_: package, bundle

**Workspace collection**:
A Collection that is part of the project: one under any `ansible_collections/`
directory in the Workspace, or the Workspace itself when it contains
`galaxy.yml`.
_Avoid_: local collection, project collection

**Installed collection**:
A Collection the project depends on: one in the selected Python virtual
environment or on the configured collections paths.
_Avoid_: external collection, vendored collection

**Collection reference**:
A site that names a Collection: a `collections:` keyword entry (play, block,
task, or role metadata), a `requirements.yml` or inline execution-environment
collection entry, a `galaxy.yml` `dependencies:` key, or the collection part of
an FQCN (module key, role name, role dependency, runtime redirect, action
group). A requirements entry that names a git, url, file, or dir source is not
one. Go-to-definition opens the Collection's `galaxy.yml`; hover shows its
`README.md`, falling back to its unrendered `galaxy.yml`; find-references
returns every site in the Workspace that names it.
_Avoid_: collection usage, collection mention

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
file with `include_tasks` or `import_tasks`. Go-to-definition opens the target
file; find-references returns every inclusion across the Workspace.
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

**Galaxy role**:
A role named `namespace.role` (one dot), installed into a roles path under that
full name. A name with two or more dots is an FQCN role inside a Collection.
_Avoid_: legacy role, standalone role

**Role parameter**:
A parameter passed to a role at its invocation site: a key in a play's `roles:`
entry, or a key under `vars:` of an `include_role`/`import_role` task. Hover
shows the unrendered YAML option from the role's argument specs.
_Avoid_: role argument, role input, role call param

**Role reference**:
A site that names a role to apply: an entry in a play's `roles:` list, the
`name` of an `include_role`/`import_role` task, an entry in a role's
`meta/main.yml` `dependencies:`, or a `roles:` entry in `requirements.yml`.
Go-to-definition opens the role's argument specs, metadata, or main task file;
go-to-implementation opens its main task file; find-references returns Workspace
sites whose possible resolved Roles overlap, including short and fully
qualified names for the same Role, while an
unresolved reference finds only itself; hover shows the role's `README.md`,
falling back to its argument specs, metadata, or resolved path.
_Avoid_: role usage, role mention

**Module key**:
The key of a task map that names the module the task invokes.
_Avoid_: action key, module name

**Document symbol**:
An entity shown in a client's outline for a single document.
_Avoid_: outline entry, breadcrumb

**Workspace symbol**:
An entity found by project-wide symbol search: a Workspace collection, role,
playbook, task file, named play, or named task or handler. Each carries its
nearest parent by file location. Installed collections and variables are not
workspace symbols.
_Avoid_: global symbol, project symbol

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

**Variable implementation**:
A binding that can supply a Variable's runtime value, rather than an
argument-spec declaration describing that value.
_Avoid_: variable body, variable implementation file

**Reachable definition**:
A Variable definition that can apply at a given Variable reference: one in the
reference's own role scope or playbook scope, in a playbook that invokes that
role, or in the vars files those load. Only reachable definitions have
precedence; the highest-ranked one is the active definition. Other definitions
of the same name elsewhere in the Workspace are listed, unranked.
_Avoid_: visible definition, in-scope definition

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
The conventional subdirectories of one role, where that role's variable
definitions live.
_Avoid_: search space, role directory, role folder

**Playbook scope**:
The playbook file, where that playbook's variable definitions live.
_Avoid_: play scope, file scope, search space