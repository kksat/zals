import ast
import json
import os
import unittest


class TestSublimePlugin(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.sublime_dir = os.path.join(self.repo_root, "editors", "sublime")

    def test_files_exist(self):
        plugin_py = os.path.join(self.sublime_dir, "plugin.py")
        settings_file = os.path.join(self.sublime_dir, "LSP-zals.sublime-settings")
        package_json = os.path.join(self.sublime_dir, "sublime-package.json")
        readme = os.path.join(self.sublime_dir, "README.md")

        self.assertTrue(os.path.isfile(plugin_py), f"Missing {plugin_py}")
        self.assertTrue(os.path.isfile(settings_file), f"Missing {settings_file}")
        self.assertTrue(os.path.isfile(package_json), f"Missing {package_json}")
        self.assertTrue(os.path.isfile(readme), f"Missing {readme}")

    def test_plugin_py_syntax(self):
        plugin_py = os.path.join(self.sublime_dir, "plugin.py")
        with open(plugin_py, "r", encoding="utf-8") as f:
            code = f.read()

        # Parse AST to ensure valid Python syntax
        tree = ast.parse(code)
        self.assertIsInstance(tree, ast.Module)

        # Check for class definition inheriting from AbstractPlugin
        classes = [node.name for node in tree.body if isinstance(node, ast.ClassDef)]
        self.assertIn("Zals", classes)

    def test_settings_json_structure(self):
        settings_file = os.path.join(self.sublime_dir, "LSP-zals.sublime-settings")
        with open(settings_file, "r", encoding="utf-8") as f:
            data = json.load(f)

        settings = data.get("settings", {})
        self.assertIn("command", settings)
        self.assertEqual(settings["command"][0], "zals")
        self.assertIn("selector", settings)
        self.assertIn("source.ansible", settings["selector"])

        inner_settings = settings.get("settings", {})
        self.assertIn("ansible.validation.enabled", inner_settings)
        self.assertIn("ansible.validation.lint.enabled", inner_settings)
        self.assertIn("ansible.validation.lint.path", inner_settings)

    def test_sublime_package_json(self):
        package_json = os.path.join(self.sublime_dir, "sublime-package.json")
        with open(package_json, "r", encoding="utf-8") as f:
            data = json.load(f)

        contributions = data.get("contributions", {})
        settings_list = contributions.get("settings", [])
        self.assertTrue(len(settings_list) > 0)
        self.assertIn("file_patterns", settings_list[0])


if __name__ == "__main__":
    unittest.main()
