import os
import unittest

try:
    import tomllib
except ImportError:
    import tomli as tomllib


class TestZedExtension(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.zed_dir = os.path.join(self.repo_root, "editors", "zed")

    def test_files_exist(self):
        ext_toml = os.path.join(self.zed_dir, "extension.toml")
        cargo_toml = os.path.join(self.zed_dir, "Cargo.toml")
        lib_rs = os.path.join(self.zed_dir, "src", "lib.rs")
        lang_config = os.path.join(self.zed_dir, "languages", "ansible", "config.toml")
        readme = os.path.join(self.zed_dir, "README.md")

        self.assertTrue(os.path.isfile(ext_toml), f"Missing {ext_toml}")
        self.assertTrue(os.path.isfile(cargo_toml), f"Missing {cargo_toml}")
        self.assertTrue(os.path.isfile(lib_rs), f"Missing {lib_rs}")
        self.assertTrue(os.path.isfile(lang_config), f"Missing {lang_config}")
        self.assertTrue(os.path.isfile(readme), f"Missing {readme}")

    def test_extension_toml(self):
        ext_toml = os.path.join(self.zed_dir, "extension.toml")
        with open(ext_toml, "rb") as f:
            data = tomllib.load(f)

        self.assertEqual(data.get("id"), "zals")
        self.assertIn("lsp", data)
        self.assertIn("zals", data["lsp"])
        self.assertEqual(data["lsp"]["zals"].get("name"), "zals")

    def test_language_config_toml(self):
        lang_config = os.path.join(self.zed_dir, "languages", "ansible", "config.toml")
        with open(lang_config, "rb") as f:
            data = tomllib.load(f)

        self.assertEqual(data.get("name"), "Ansible")
        self.assertEqual(data.get("grammar"), "yaml")
        path_suffixes = data.get("path_suffixes", [])
        self.assertIn("ansible.yml", path_suffixes)

    def test_lib_rs_content(self):
        lib_rs = os.path.join(self.zed_dir, "src", "lib.rs")
        with open(lib_rs, "r", encoding="utf-8") as f:
            code = f.read()

        self.assertIn("Extension for ZalsExtension", code)
        self.assertIn("language_server_command", code)
        self.assertIn('"zals"', code)


if __name__ == "__main__":
    unittest.main()
