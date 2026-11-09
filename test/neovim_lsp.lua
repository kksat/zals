-- Run with: nvim --headless -u NONE -l test/neovim_lsp.lua
-- End-to-end LSP features through Neovim's own client: module documentation
-- hover, module completion and resolve, module go-to-definition, and
-- published diagnostics, against a real ansible-doc/ansible-playbook.
-- Complements neovim_attachment.lua (filetypes, attachment, references).
local function write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  assert(vim.fn.writefile(lines, path) == 0)
end

local function find_position(lines, needle, offset)
  for i, line in ipairs(lines) do
    local start = line:find(needle, 1, true)
    if start then return i - 1, start - 1 + (offset or 0) end
  end
  error("position not found: " .. needle)
end

local playbook = {
  "---",
  "- name: Module documentation",
  "  hosts: all",
  "  tasks:",
  "    - name: Copy task",
  "      ansible.builtin.copy:",
  "        src: /tmp/a",
  "        dest: /tmp/b",
  "    - name: Choose a module",
  "      module_choice:",
}
local copy_description = "Copy files to remote locations"

local broken_playbook = {
  "---",
  "- name: Broken play",
  "  hosts: all",
  "  tasks:",
  "    - name: Unknown module",
  "      ansible.builtin.no_such_module:",
  "        arg: value",
}

-- Genuinely valid under ansible-playbook --syntax-check: no completion
-- placeholder task (the module-docs section reuses `playbook` with
-- validation disabled, where the placeholder is harmless).
local valid_playbook = {
  "---",
  "- name: Module documentation",
  "  hosts: all",
  "  tasks:",
  "    - name: Copy task",
  "      ansible.builtin.copy:",
  "        src: /tmp/a",
  "        dest: /tmp/b",
  "    - name: Debug task",
  "      ansible.builtin.debug:",
  "        msg: hello",
}

-- One server per section: the module-docs section disables validation, the
-- diagnostics section needs it enabled (lint off, so the syntax-check
-- fallback path runs without requiring ansible-lint).
local function start_server(root, init_options, handlers)
  vim.fn.mkdir(root .. "/.git", "p")
  root = assert(vim.uv.fs_realpath(root))
  local config = {
    cmd = { assert(vim.uv.fs_realpath("zig-out/bin/zals")), "--stdio" },
    filetypes = { "yaml.ansible" },
    root_markers = { ".git" },
    init_options = init_options,
  }
  for name, handler in pairs(handlers or {}) do
    config.handlers = config.handlers or {}
    config.handlers[name] = handler
  end
  vim.lsp.config("zals", config)
  vim.lsp.enable("zals")
  return root
end

local function edit_and_attach(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  assert(vim.bo.filetype == "yaml.ansible", path .. ": got filetype " .. vim.bo.filetype)
  assert(vim.wait(10000, function()
    return #vim.lsp.get_clients({ bufnr = bufnr, name = "zals" }) == 1
  end), "zals did not attach to " .. path)
  return bufnr, vim.lsp.get_clients({ bufnr = bufnr, name = "zals" })[1]
end

local function sync(client, method, params, bufnr)
  local response, err = client:request_sync(method, params, 20000, bufnr)
  assert(response and not response.err, method .. ": " .. vim.inspect(err or response))
  return response.result
end

local ok, err = xpcall(function()
  vim.cmd("filetype on")
  -- The filetype rules documented in docs/neovim.md, applied verbatim so
  -- this test also proves the documented configuration works as written.
  vim.filetype.add({
    filename = {
      ["requirements.yml"] = "yaml.ansible",
      ["requirements.yaml"] = "yaml.ansible",
      ["execution-environment.yml"] = "yaml.ansible",
      ["execution-environment.yaml"] = "yaml.ansible",
      ["galaxy.yml"] = "yaml.ansible",
      ["galaxy.yaml"] = "yaml.ansible",
      ["site.yml"] = "yaml.ansible",
      ["site.yaml"] = "yaml.ansible",
    },
    pattern = {
      [".*/playbooks/.*%.ya?ml"] = "yaml.ansible",
      [".*/roles/[^/]+/.*%.ya?ml"] = "yaml.ansible",
      [".*/ansible_collections/[^/]+/[^/]+/.*%.ya?ml"] = "yaml.ansible",
      [".*/roles/[^/]+/templates/.*%.j2"] = "jinja2",
    },
  })

  if vim.fn.executable("ansible-doc") == 1 then
    local root = start_server(vim.fn.tempname(), {
      ansible = { validation = { enabled = false, lint = { enabled = false } } },
    }, {})
    local playbook_path = root .. "/site.yml"
    write_file(playbook_path, playbook)

    local bufnr, client = edit_and_attach(playbook_path)
    local uri = vim.uri_from_fname(playbook_path)
    -- Inside the module segment, past the ansible.builtin collection prefix.
    local hover_line, hover_char = find_position(playbook, "ansible.builtin.copy:", #"ansible.builtin." + 1)

    -- Hover over the module name: real documentation from ansible-doc.
    local hover = sync(client, "textDocument/hover", {
      textDocument = { uri = uri },
      position = { line = hover_line, character = hover_char },
    }, bufnr)
    assert(hover and hover.contents and hover.contents.value, "no hover documentation")
    assert(hover.contents.value:find(copy_description, 1, true),
      "hover lacked the real module description: " .. hover.contents.value)

    -- Go to definition lands on the module's source file.
    local definition = sync(client, "textDocument/definition", {
      textDocument = { uri = uri },
      position = { line = hover_line, character = hover_char },
    }, bufnr)
    local target = type(definition) == "table" and definition[1] or definition
    assert(target and target.uri, "no module definition: " .. vim.inspect(definition))
    assert(vim.uri_to_fname(target.uri):find("copy%.py$"),
      "module definition is not copy.py: " .. target.uri)
    assert(vim.uv.fs_stat(vim.uri_to_fname(target.uri)), "module definition file missing")

    -- Completion at a module-name position lists the builtin module; the
    -- list is eventually consistent with the background catalog bootstrap,
    -- so poll for it rather than asserting one interleaving. Resolving the
    -- item returns the module's documentation.
    local completion_line, completion_char = find_position(playbook, "module_choice:", 2)
    local params = {
      textDocument = { uri = uri },
      position = { line = completion_line, character = completion_char },
    }
    local resolved
    assert(vim.wait(30000, function()
      local result = sync(client, "textDocument/completion", params, bufnr)
      for _, item in ipairs(result.items or result or {}) do
        if item.label == "ansible.builtin.copy" then
          resolved = sync(client, "completionItem/resolve", item, bufnr)
          return true
        end
      end
      return false
    end), "ansible.builtin.copy never appeared in module completions")
    assert(resolved.documentation and resolved.documentation.value
      and resolved.documentation.value:find(copy_description, 1, true),
      "resolved completion lacked documentation: " .. vim.inspect(resolved))
    print("Neovim LSP: module hover, definition, completion, and resolve pass")
  else
    print("Neovim LSP: SKIP module docs (ansible-doc not found)")
  end

  if vim.fn.executable("ansible-playbook") == 1 then
    -- Diagnostics: lint disabled so validation uses the syntax-check
    -- fallback; a playbook referencing an unknown module must surface an
    -- error diagnostic in the buffer, a valid one must stay clean.
    local published = {}
    local root = start_server(vim.fn.tempname(), {
      ansible = { validation = { enabled = true, lint = { enabled = false } } },
    }, {
      ["textDocument/publishDiagnostics"] = function(_, result)
        if result and result.uri then published[result.uri] = result.diagnostics or {} end
      end,
    })
    local broken_path = root .. "/playbooks/broken.yml"
    local valid_path = root .. "/playbooks/site.yml"
    write_file(broken_path, broken_playbook)
    write_file(valid_path, valid_playbook)

    local broken_bufnr, _ = edit_and_attach(broken_path)
    local broken_uri = vim.uri_from_fname(broken_path)
    assert(vim.wait(30000, function()
      return published[broken_uri] ~= nil
    end), "no diagnostics published for the broken playbook")
    local errors = vim.tbl_filter(function(d)
      return d.severity == vim.diagnostic.severity.ERROR
    end, published[broken_uri])
    assert(#errors > 0, "no error diagnostic for the broken playbook: "
      .. vim.inspect(published[broken_uri]))

    local valid_bufnr, _ = edit_and_attach(valid_path)
    local valid_uri = vim.uri_from_fname(valid_path)
    assert(vim.wait(30000, function()
      return published[valid_uri] ~= nil
    end), "no diagnostics published for the valid playbook")
    assert(#published[valid_uri] == 0,
      "unexpected diagnostics for the valid playbook: " .. vim.inspect(published[valid_uri]))
    print("Neovim LSP: syntax-check diagnostics pass")
  else
    print("Neovim LSP: SKIP diagnostics (ansible-playbook not found)")
  end
end, debug.traceback)

for _, client in ipairs(vim.lsp.get_clients({ name = "zals" })) do
  client:stop(true)
end
if not ok then
  error(err)
end
