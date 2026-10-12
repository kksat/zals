# Neovim: attach zals to Ansible files

The navigation E2E client opens each fixture source as an LSP document. Neovim
only starts a server for buffers whose **filetype** matches its LSP configuration.
By default, `requirements.yml`, `galaxy.yml`, playbooks, and role YAML are often
just `yaml`, and a `.j2` template may have no filetype. Configuring the `zals`
command alone therefore leaves navigation unavailable in those buffers. The
Workspace index can still contain unopened files; it is the *source buffer*
that must have zals attached to send definition, implementation, or references
requests.

## Neovim 0.11+ (`init.lua`)

Install `zals` on `PATH` (or replace `"zals"` with its absolute binary path).
Add this before opening the files:

```lua
vim.filetype.add({
  filename = {
    ["requirements.yml"] = "yaml.ansible",
    ["requirements.yaml"] = "yaml.ansible",
    ["execution-environment.yml"] = "yaml.ansible",
    ["execution-environment.yaml"] = "yaml.ansible",
    ["galaxy.yml"] = "yaml.ansible",
    ["galaxy.yaml"] = "yaml.ansible",
    ["site.yml"] = "yaml.ansible", -- common top-level playbook
    ["site.yaml"] = "yaml.ansible",
  },
  pattern = {
    [".*/playbooks/.*%.ya?ml"] = "yaml.ansible", -- includes task and vars files
    [".*/roles/[^/]+/.*%.ya?ml"] = "yaml.ansible", -- tasks, meta, vars, etc.
    [".*/ansible_collections/[^/]+/[^/]+/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/templates/.*%.j2"] = "jinja2",
  },
})

vim.lsp.config("zals", {
  cmd = { "zals", "--stdio" },
  filetypes = { "yaml.ansible", "jinja2" },
  root_markers = { ".git" },
})
vim.lsp.enable("zals")
```

These are **Lua patterns**, not globs: `%.ya?ml` matches `.yml` and `.yaml`,
and `vim.filetype.add` anchors patterns automatically. `yaml.ansible` retains
YAML's filetype settings. Add your own filenames/patterns for top-level
playbooks or nonstandard Ansible directories; do **not** label every YAML
file as Ansible if the repository also has CI, Kubernetes, or other YAML.
The `jinja2` entry lets zals navigate variables in role templates without
pretending that templates are YAML. zals does not require `languageId` to be
literally `ansible`.

### Standalone role repositories

A repository can itself be a Role: `tasks/`, `defaults/`, `vars/`, `handlers/`,
`meta/`, and `templates/` are at its root, with no `roles/<name>/` path segment.
The path-only rules above do not cover this layout. Install the additional
[role filetype detector](examples/neovim-role-filetypes.lua) in your Neovim
`ftdetect/` directory, or source it from `init.lua` before opening buffers:

```lua
dofile("/path/to/zals/docs/examples/neovim-role-filetypes.lua")
```

The detector recognizes conventional Role directories when their parent has
`meta/main.yml` or `meta/main.yaml` (or is under `roles/`). It covers both YAML
extensions, nested task/handler files, directory-style `defaults/main/` and
`vars/main/`, and nested `templates/*.j2`. Directory names alone do not classify
unrelated YAML as Ansible; CI and other YAML outside Role directories are left
alone. Roles without metadata and outside `roles/` need an explicit project
filetype rule. Keep `jinja2` in zals's `filetypes` if you want template navigation.
The detector only changes filetypes; it does not configure any other LSP/plugin.

Use **one** Ansible server configuration: if `ansiblels` is already enabled in
`nvim-lspconfig`, disable it or adapt its `cmd`, `filetypes`, and `root_markers`
instead of running both. Ansible search paths come from `ANSIBLE_*`, the
nearest `ansible.cfg`, and the selected virtual environment—not from Neovim
filetype rules.

## zals and yamlls

Neovim has no general LSP priority setting: navigation can query all attached
clients that support the method. Prefer non-overlapping filetypes instead of
relying on attachment order. zals should own `yaml.ansible`, while yamlls keeps
ordinary YAML and its other specialized filetypes:

```lua
vim.lsp.config("yamlls", {
  filetypes = { "yaml", "yaml.docker-compose", "yaml.gitlab", "yaml.helm-values" },
})
```

In LazyVim, put that `filetypes` list under
`opts.servers.yamlls` in your `neovim/nvim-lspconfig` plugin spec; put zals's
configuration under `opts.servers.zals`. Keep `ansiblels` disabled when zals
replaces it. Register the Ansible filetype rules before opening source buffers.

For already-open buffers, changing filetype can leave the previous client
attached. Restart Neovim after changing the configuration, or detach yamlls from
just the Ansible buffer with `vim.lsp.buf_detach_client(bufnr, client.id)`.
Do not stop the entire yamlls client if it still serves ordinary YAML buffers.

## Existing Vimscript filetype detectors

If tasks work but references from a role's `vars/main.yml` do not, check the
variable buffer's filetype and attached clients first. Neovim's built-in
Ansible detection can recognize tasks while leaving variable files as `yaml`;
`yamlls` alone does not provide zals's variable references.

A `BufRead`/`BufNewFile` autocmd pattern containing a slash matches the **full
absolute path**, not a path relative to the project. A rule such as
`ansible_collections/**/*.yml` therefore misses
`/path/to/project/ansible_collections/internal/leapp/roles/upgrade_perform/vars/main.yml`.
Use a leading `*/`:

```vim
augroup zals_collection_filetypes
  autocmd!
  autocmd BufRead,BufNewFile */ansible_collections/**/*.yml,*/ansible_collections/**/*.yaml set filetype=yaml.ansible
augroup END
```

The ready-to-source [Vimscript example](examples/neovim-filetypes.vim) contains
these rules. They cover collection YAML only; the Lua configuration above covers
`roles/<name>/`, playbooks, and templates. Add the role detector for repositories
whose root is the Role itself. After fixing an existing
detector, reopen the buffer or run `:set filetype=yaml.ansible` to trigger LSP
attachment for an already-open variable file.

`make neovim-test` (Neovim 0.11+ required) tests the example with real filetype
detection and a real zals process: references from folded-value vars keys in
both YAML extensions, with and without declarations; standalone Role repositories
with nested defaults, vars, tasks, handlers, and Jinja templates; and unrelated
YAML buffers that must not attach. A direct stdio provider test cannot detect missing
editor attachment.

## Trying the checked-in E2E fixture

The fixture at `test/fixtures/e2e-workspace/` deliberately has
`fixture-workspace-root` instead of a nested `.git`. In a **fixture-only**
Neovim configuration, replace `root_markers` and add `init_options` **inside**
the `vim.lsp.config("zals", { ... })` call above:

```lua
root_markers = { "fixture-workspace-root" },
init_options = {
  ansible = { workspace = { rootMarker = "fixture-workspace-root" } },
},
```

These two markers must agree: the first selects Neovim's LSP root; the
second selects zals's Workspace boundary **during initialization**. Do not
apply the fixture marker globally to ordinary Git projects. The fixture's
`ansible.cfg` points to its checked-in role and collection dependencies; make
sure an unrelated `ANSIBLE_CONFIG` or `ANSIBLE_COLLECTIONS_PATH` environment
variable is not overriding it. The external `MANIFEST.json` targets do not
need to be treated as Ansible source buffers to navigate *to* them.

To attach in the fixture's deliberately invalid `negative/` examples as
well, add this entry to the `pattern` table in the first snippet:

```lua
[".*/test/fixtures/e2e%-workspace/negative/.*%.ya?ml"] = "yaml.ansible",
```

## Verify attachment

Open `requirements.yml` or `ansible_collections/<namespace>/<collection>/galaxy.yml`
and check `:set filetype?` (expect `yaml.ansible`) and
`:checkhealth vim.lsp` (expect `zals` attached to the buffer). Then put the
cursor on a collection or role **name** and run
`:lua vim.lsp.buf.definition()` or `:lua vim.lsp.buf.references()`.
If zals is absent, inspect the log at `:lua print(vim.lsp.get_log_path())`.
If Workspace-wide results stay empty after indexing, check that Neovim's LSP
root and zals's root marker agree and that collection/role search paths are
available. For a real project, leave both roots at `.git` (zals's default);
do not set Neovim's root to `ansible.cfg` while zals still uses `.git`.
