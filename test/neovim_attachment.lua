-- Run with: nvim --headless -u NONE -l test/neovim_attachment.lua
-- Exercise real filetype detection, LSP attachment, and references from a
-- collection role's vars key. A direct stdio request cannot catch this bug.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
root = assert(vim.uv.fs_realpath(root))
local role = root .. "/ansible_collections/internal/leapp/roles/upgrade_perform"
local tasks = role .. "/tasks/upgrade.yml"
local variables = {
  role .. "/vars/main.yml",
  role .. "/vars/main.yaml",
}

local function write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  assert(vim.fn.writefile(lines, path) == 0)
end

local ok, err = xpcall(function()
  write_file(tasks, {
    "- name: Execute upgrade",
    "  ansible.builtin.command:",
    '    argv: "{{ upgrade_perform_cmd }}"',
  })
  for _, path in ipairs(variables) do
    write_file(path, {
      "---",
      "upgrade_perform_cmd: >-",
      "  {{",
      "    ['leapp', 'upgrade']",
      "    + (upgrade_extra_leapp_args.split()",
      "       if upgrade_extra_leapp_args | default('') else [])",
      "  }}",
    })
  end
  local ordinary_yaml = root .. "/ordinary.yml"
  write_file(ordinary_yaml, { "some_setting: value" })

  vim.cmd("filetype on")
  vim.cmd("source docs/examples/neovim-filetypes.vim")
  dofile("docs/examples/neovim-role-filetypes.lua")
  local ready = {}
  vim.lsp.config("zals", {
    cmd = { assert(vim.uv.fs_realpath("zig-out/bin/zals")), "--stdio" },
    filetypes = { "yaml.ansible", "jinja2" },
    root_markers = { ".git" },
    init_options = {
      ansible = { validation = { enabled = false, lint = { enabled = false } } },
    },
    handlers = {
      ["ansible/workspaceIndexReady"] = function(_, _, ctx)
        ready[ctx.client_id] = true
      end,
    },
  })
  vim.lsp.enable("zals")

  for _, path in ipairs(variables) do
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    assert(vim.bo.filetype == "yaml.ansible", path .. ": got filetype " .. vim.bo.filetype)
    assert(vim.wait(10000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = "zals" }) == 1
    end), "zals did not attach to " .. path)
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "zals" })[1]
    assert(vim.wait(10000, function()
      -- Requests drive the server's index handoff queue.
      client:request_sync("workspace/symbol", { query = "__neovim_test_wait__" }, 1000, bufnr)
      return ready[client.id]
    end), "Workspace index did not become ready")
    for _, include_declaration in ipairs({ false, true }) do
      local response, request_err = client:request_sync("textDocument/references", {
        textDocument = { uri = vim.uri_from_fname(path) },
        position = { line = 1, character = 3 },
        context = { includeDeclaration = include_declaration },
      }, 10000, bufnr)
      assert(response and not response.err, vim.inspect(request_err or response))
      local locations = response.result
      assert(#locations == (include_declaration and 3 or 1), vim.inspect(locations))
      local expected = { [vim.uri_from_fname(tasks)] = { line = 2, start = 14, finish = 33 } }
      if include_declaration then
        for _, variable in ipairs(variables) do
          expected[vim.uri_from_fname(variable)] = { line = 1, start = 0, finish = 19 }
        end
      end
      for _, location in ipairs(locations) do
        local span = assert(expected[location.uri], "unexpected or duplicate location: " .. vim.inspect(location))
        assert(location.range.start.line == span.line and location.range.start.character == span.start)
        assert(location.range["end"].line == span.line and location.range["end"].character == span.finish)
        expected[location.uri] = nil
      end
      assert(next(expected) == nil, "missing locations: " .. vim.inspect(expected))
    end
  end

  -- A standalone role repository has no /roles/<name>/ component. Cover
  -- both YAML extensions, nested defaults/vars, and nested Jinja templates.
  for _, ext in ipairs({ "yml", "yaml" }) do
    local standalone = root .. "/standalone-" .. ext
    vim.fn.mkdir(standalone .. "/.git", "p")
    write_file(standalone .. "/meta/main." .. ext, { "galaxy_info: {}" })
    local default_file = standalone .. "/defaults/main/settings." .. ext
    local var_file = standalone .. "/vars/main/settings." .. ext
    local task_file = standalone .. "/tasks/nested/run." .. ext
    local handler_file = standalone .. "/handlers/main." .. ext
    local template = standalone .. "/templates/etc/config.j2"
    write_file(default_file, { "role_setting: default" })
    write_file(var_file, { "role_setting: override" })
    write_file(task_file, { "- debug:", '    msg: "{{ role_setting }}"' })
    write_file(handler_file, { "- name: Reload", "  debug:", '    msg: "{{ role_setting }}"' })
    write_file(template, { "setting={{ role_setting }}" })
    for _, path in ipairs({ default_file, var_file, task_file, handler_file, standalone .. "/meta/main." .. ext, template }) do
      vim.cmd.edit(vim.fn.fnameescape(path))
      local bufnr = vim.api.nvim_get_current_buf()
      local expected_ft = path == template and "jinja2" or "yaml.ansible"
      assert(vim.bo.filetype == expected_ft, path .. ": got filetype " .. vim.bo.filetype)
      assert(vim.wait(10000, function()
        return #vim.lsp.get_clients({ bufnr = bufnr, name = "zals" }) == 1
      end), "zals did not attach to " .. path)
      local client = vim.lsp.get_clients({ bufnr = bufnr, name = "zals" })[1]
      assert(client.config.root_dir == standalone, "incorrect standalone Role Workspace")
      assert(vim.wait(10000, function()
        client:request_sync("workspace/symbol", { query = "__neovim_test_wait__" }, 1000, bufnr)
        return ready[client.id]
      end), "standalone Role index did not become ready")
      if path == default_file then
        local response = client:request_sync("textDocument/references", {
          textDocument = { uri = vim.uri_from_fname(path) },
          position = { line = 0, character = 2 },
          context = { includeDeclaration = false },
        }, 10000, bufnr)
        assert(response and not response.err, vim.inspect(response))
        local expected = {
          [vim.uri_from_fname(task_file)] = true,
          [vim.uri_from_fname(handler_file)] = true,
          [vim.uri_from_fname(template)] = true,
        }
        assert(#response.result == 3, vim.inspect(response.result))
        for _, location in ipairs(response.result) do
          assert(expected[location.uri], "unexpected reference: " .. vim.inspect(location))
          expected[location.uri] = nil
        end
        assert(next(expected) == nil, "missing standalone references")
      end
    end
  end

  -- Directory names alone must not turn non-Ansible YAML into Ansible.
  for _, directory in ipairs({ "defaults", "vars", "meta", "handlers" }) do
    local path = root .. "/ordinary-project/" .. directory .. "/settings.yml"
    write_file(path, { "some_setting: value" })
    vim.cmd.edit(vim.fn.fnameescape(path))
    assert(vim.bo.filetype == "yaml", path .. ": got filetype " .. vim.bo.filetype)
    assert(#vim.lsp.get_clients({ bufnr = 0, name = "zals" }) == 0)
  end

  vim.cmd.edit(vim.fn.fnameescape(ordinary_yaml))
  assert(vim.bo.filetype == "yaml", "ordinary YAML should not be classified as Ansible")
  assert(#vim.lsp.get_clients({ bufnr = 0, name = "zals" }) == 0)
end, debug.traceback)

for _, client in ipairs(vim.lsp.get_clients({ name = "zals" })) do
  client:stop(true)
end
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("Neovim attachment: collection and standalone Role YAML/Jinja references pass")
