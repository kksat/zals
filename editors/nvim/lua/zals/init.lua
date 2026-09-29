-- lua/zals/init.lua
-- Neovim plugin integration for zals (Zig Ansible Language Server)

local M = {}

M.defaults = {
  cmd = { "zals", "--stdio" },
  root_markers = { "ansible.cfg", ".git", "requirements.yml", "galaxy.yml" },
  settings = {
    ansible = {
      validation = {
        enabled = true,
        lint = {
          enabled = true,
          path = "ansible-lint",
          arguments = {},
          autoFixOnSave = false,
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

M.options = vim.deepcopy(M.defaults)

--- Find root directory for an Ansible project
---@param bufnr number
---@return string|nil
function M.find_root(bufnr)
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  if bufpath == "" then
    return vim.fn.getcwd()
  end
  local dir = vim.fs.dirname(bufpath)
  local found = vim.fs.find(M.options.root_markers, {
    upward = true,
    path = dir,
  })
  if #found > 0 then
    return vim.fs.dirname(found[1])
  end
  return vim.fs.find({ ".git" }, { upward = true, path = dir })[1] and vim.fs.dirname(vim.fs.find({ ".git" }, { upward = true, path = dir })[1]) or dir
end

--- Start zals on the given buffer
---@param bufnr number|nil
function M.start(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local root_dir = M.find_root(bufnr)

  if vim.lsp.start then
    vim.lsp.start({
      name = "zals",
      cmd = M.options.cmd,
      root_dir = root_dir,
      settings = M.options.settings,
    }, { bufnr = bufnr })
  end
end

--- Setup zals plugin with user options
---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})

  -- If nvim-lspconfig is present, register zals in its configs table
  local ok, lspconfig_configs = pcall(require, "lspconfig.configs")
  if ok and not lspconfig_configs.zals then
    lspconfig_configs.zals = {
      default_config = {
        cmd = M.options.cmd,
        filetypes = { "ansible", "yaml.ansible" },
        root_dir = function(fname)
          local found = vim.fs.find(M.options.root_markers, { upward = true, path = fname })
          if #found > 0 then
            return vim.fs.dirname(found[1])
          end
          return vim.fs.dirname(fname)
        end,
        settings = M.options.settings,
      },
    }
  end

  -- In Neovim 0.11+, configure native vim.lsp.config
  if vim.lsp and vim.lsp.config then
    vim.lsp.config["zals"] = {
      cmd = M.options.cmd,
      filetypes = { "ansible", "yaml.ansible" },
      root_markers = M.options.root_markers,
      settings = M.options.settings,
    }
  end
end

return M
