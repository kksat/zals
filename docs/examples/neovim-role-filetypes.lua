-- Source from init.lua, or copy into ~/.config/nvim/ftdetect/zals-role.lua.
-- Standalone Role repositories need not live under a roles/<name>/ directory.
local role_dirs = { "defaults", "vars", "tasks", "handlers", "meta", "templates" }

local function role_filetype(path, filetype)
  local dir = vim.fs.dirname(path)
  while dir do
    if vim.tbl_contains(role_dirs, vim.fs.basename(dir)) then
      local role = vim.fs.dirname(dir)
      if role and (vim.fs.basename(vim.fs.dirname(role) or "") == "roles"
          or vim.fn.filereadable(role .. "/meta/main.yml") == 1
          or vim.fn.filereadable(role .. "/meta/main.yaml") == 1) then
        return filetype
      end
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir = parent
  end
end

local patterns = {}
for _, directory in ipairs(role_dirs) do
  patterns[".*/" .. directory .. "/.*%.ya?ml"] = {
    function(path) return role_filetype(path, "yaml.ansible") end,
    { priority = 10 },
  }
end
patterns[".*/templates/.*%.j2"] = {
  function(path) return role_filetype(path, "jinja2") end,
  { priority = 10 },
}
vim.filetype.add({ pattern = patterns })
