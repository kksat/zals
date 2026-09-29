# zals Neovim Integration

This directory provides native Neovim integration for `zals` (Zig Ansible Language Server).

It includes:
- **Filetype detection** (`ftdetect/ansible.lua`) for standard Ansible directory layouts and filenames.
- **Buffer auto-attach** (`ftplugin/ansible.lua`) using Neovim's native `vim.lsp.start`.
- **Plugin module** (`lua/zals/init.lua`) supporting custom settings and integration with `nvim-lspconfig`.

## Prerequisites

Ensure `zals` is installed and available in your `PATH`:

```sh
brew tap kksat/tap && brew install zals
# or
pip install zals
```

## Installation

### With lazy.nvim

```lua
{
  "kksat/zals",
  ft = { "ansible", "yaml.ansible" },
  opts = {
    -- optional settings override
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
```

### With vim-plug

```vim
Plug 'kksat/zals'
```

And in your `init.lua`:
```lua
require('zals').setup()
```

## Manual Configuration (Without Plugin)

If you prefer configuring Neovim directly without installing this repository as a plugin, see [`docs/editors/neovim.md`](../../docs/editors/neovim.md) for full instructions on configuring built-in `vim.lsp` or `nvim-lspconfig`.
