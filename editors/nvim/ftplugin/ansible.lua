-- ftplugin/ansible.lua
-- Runs automatically when opening an Ansible buffer (filetype 'ansible' or 'yaml.ansible')

local ok, zals = pcall(require, "zals")
if ok then
  zals.start()
else
  -- Fallback if zals module not loaded via plugin manager
  if vim.lsp and vim.lsp.start then
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
  end
end
