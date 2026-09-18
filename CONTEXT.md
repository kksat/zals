# zals

A Zig reimplementation of the Ansible Language Server. This glossary covers the
vocabulary of variable navigation: finding the definition of a variable and
finding every reference to it.

## Language

**Role**:
An Ansible reusable unit rooted at a directory containing conventional
subdirectories (`defaults/`, `vars/`, `tasks/`, `handlers/`, `templates/`,
`meta/`).
_Avoid_: package, module

**Playbook**:
A single YAML file containing one or more plays.
_Avoid_: play (a play is one entry within a playbook)

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

**Role scope**:
The search space for a variable defined or used in a role: the conventional
subdirectories of the role root, plus one level of `vars_files`/`include_vars`
targets.
_Avoid_: role directory, role folder

**Playbook scope**:
The search space for a variable defined or used in a playbook: the playbook file
plus one level of `vars_files`/`include_vars` targets.
_Avoid_: play scope, file scope