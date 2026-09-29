import os
import unittest


class TestNvimPlugin(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.nvim_dir = os.path.join(self.repo_root, "editors", "nvim")

    def test_plugin_files_exist(self):
        ftdetect = os.path.join(self.nvim_dir, "ftdetect", "ansible.lua")
        ftplugin = os.path.join(self.nvim_dir, "ftplugin", "ansible.lua")
        init_lua = os.path.join(self.nvim_dir, "lua", "zals", "init.lua")
        readme = os.path.join(self.nvim_dir, "README.md")

        self.assertTrue(os.path.isfile(ftdetect), f"Missing {ftdetect}")
        self.assertTrue(os.path.isfile(ftplugin), f"Missing {ftplugin}")
        self.assertTrue(os.path.isfile(init_lua), f"Missing {init_lua}")
        self.assertTrue(os.path.isfile(readme), f"Missing {readme}")

    def test_ftdetect_patterns(self):
        ftdetect = os.path.join(self.nvim_dir, "ftdetect", "ansible.lua")
        with open(ftdetect, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("vim.filetype.add", content)
        self.assertIn("playbook", content)
        self.assertIn("roles", content)
        self.assertIn("tasks", content)
        self.assertIn("yaml.ansible", content)

    def test_ftplugin_lsp_start(self):
        ftplugin = os.path.join(self.nvim_dir, "ftplugin", "ansible.lua")
        with open(ftplugin, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("vim.lsp.start", content)
        self.assertIn('"zals"', content)
        self.assertIn("ansible.cfg", content)

    def test_lua_module_setup(self):
        init_lua = os.path.join(self.nvim_dir, "lua", "zals", "init.lua")
        with open(init_lua, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("M.setup", content)
        self.assertIn("validation", content)
        self.assertIn("ansible-lint", content)


if __name__ == "__main__":
    unittest.main()
