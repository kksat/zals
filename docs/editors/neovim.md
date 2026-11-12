# Configuring Neovim for zals

Neovim has native support for the Language Server Protocol (LSP). You can configure `zals` either using Neovim's built-in LSP client or with `nvim-lspconfig`.

## 1. Install zals

Ensure `zals` is in your `$PATH`:

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

## 2. Filetype Detection

Ansible playbooks and role files are YAML documents, but tools like `zals` work best when Neovim recognizes them under the `yaml.ansible` or `ansible` filetype.

Add the following to `~/.config/nvim/lua/config/filetype.lua` (or `init.lua`):

```lua
vim.filetype.add({
  extension = {
    ["ansible.yml"] = "yaml.ansible",
    ["ansible.yaml"] = "yaml.ansible",
  },
  filename = {
    ["site.yml"] = "yaml.ansible",
    ["site.yaml"] = "yaml.ansible",
    ["playbook.yml"] = "yaml.ansible",
    ["playbook.yaml"] = "yaml.ansible",
    ["requirements.yml"] = "yaml.ansible",
    ["galaxy.yml"] = "yaml.ansible",
    ["execution-environment.yml"] = "yaml.ansible",
  },
  pattern = {
    [".*/playbooks/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/tasks/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/handlers/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/defaults/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/meta/.*%.ya?ml"] = "yaml.ansible",
    [".*/tasks/.*%.ya?ml"] = "yaml.ansible",
    [".*/handlers/.*%.ya?ml"] = "yaml.ansible",
    [".*/defaults/.*%.ya?ml"] = "yaml.ansible",
    [".*/vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/meta/.*%.ya?ml"] = "yaml.ansible",
    [".*/host_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/group_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/molecule/.*%.ya?ml"] = "yaml.ansible",
  },
})
```

---

## 3. Configuration Methods

Choose one of the methods below:

### Option A: Built-in `vim.lsp.config` (Neovim 0.11+)

In Neovim 0.11+, you can define and enable servers declaratively in `init.lua`:

```lua
vim.lsp.config["zals"] = {
  cmd = { "zals", "--stdio" },
  filetypes = { "ansible", "yaml.ansible" },
  root_markers = { "ansible.cfg", ".git", "requirements.yml", "galaxy.yml" },
  settings = {
    ansible = {
      validation = {
        enabled = true,
        lint = {
          enabled = true,
          path = "ansible-lint",
        },
      },
      ansible = {
        path = "ansible",
        useFullyQualifiedCollectionNames = true,
      },
      completion = {
        provideRedirectModules = true,
        provideDisabledModules = true,
      },
    },
  },
}

vim.lsp.enable("zals")
```

---

### Option B: Built-in `vim.lsp.start` (Neovim 0.8–0.10)

Create `~/.config/nvim/ftplugin/ansible.lua`:

```lua
local root_markers = { "ansible.cfg", ".git", "requirements.yml", "galaxy.yml" }
local bufname = vim.api.nvim_buf_get_name(0)
local dir = bufname ~= "" and vim.fs.dirname(bufname) or vim.fn.getcwd()
local found = vim.fs.find(root_markers, { upward = true, path = dir })
local root_dir = #found > 0 and vim.fs.dirname(found[1]) or dir

vim.lsp.start({
  name = "zals",
  cmd = { "zals", "--stdio" },
  root_dir = root_dir,
  settings = {
    ansible = {
      validation = {
        enabled = true,
        lint = {
          enabled = true,
          path = "ansible-lint",
        },
      },
    },
  },
})
```

---

### Option C: Using `nvim-lspconfig`

If you use `neovim/nvim-lspconfig`, add this custom configuration to your LSP setup:

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.zals then
  configs.zals = {
    default_config = {
      cmd = { "zals", "--stdio" },
      filetypes = { "ansible", "yaml.ansible" },
      root_dir = lspconfig.util.root_pattern("ansible.cfg", ".git", "requirements.yml", "galaxy.yml"),
      settings = {
        ansible = {
          validation = {
            enabled = true,
            lint = {
              enabled = true,
              path = "ansible-lint",
            },
          },
        },
      },
    },
  }
end

lspconfig.zals.setup({
  on_attach = function(client, bufnr)
    -- Your keymaps here
    local bufopts = { noremap = true, silent = true, buffer = bufnr }
    vim.keymap.set("n", "K", vim.lsp.buf.hover, bufopts)
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, bufopts)
    vim.keymap.set("n", "gI", vim.lsp.buf.implementation, bufopts)
    vim.keymap.set("n", "gr", vim.lsp.buf.references, bufopts)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, bufopts)
  end,
})
```

---

## 4. Keybindings Reference

Recommended standard Neovim keymaps for LSP features supported by `zals`:

```lua
vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "Ansible Hover Documentation" })
vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to Definition (Variable/Module/Role)" })
vim.keymap.set("n", "gI", vim.lsp.buf.implementation, { desc = "Go to Implementation (Role Main Task)" })
vim.keymap.set("n", "gr", vim.lsp.buf.references, { desc = "Find Variable References" })
vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Ansible Code Action (Debug Task/Extract)" })
vim.keymap.set("n", "<leader>ds", vim.lsp.buf.document_symbol, { desc = "Document Symbols / Outline" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous Diagnostic" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next Diagnostic" })
```

## 5. Verifying the Setup

1. Open an Ansible playbook (e.g. `playbook.yml`).
2. Run `:checkhealth vim.lsp` or `:LspInfo`.
3. Check that `zals` is attached to the buffer.
4. Hover over a task module (e.g. `ansible.builtin.ping`) and press `K` to view documentation.
