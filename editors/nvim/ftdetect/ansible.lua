-- Filetype detection for Ansible documents in Neovim
-- Sets filetype to yaml.ansible so standard YAML syntax/treesitter works
-- alongside Ansible-specific tools and language servers.

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
