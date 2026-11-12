import os
import unittest

try:
    import tomllib
except ImportError:
    import tomli as tomllib


class TestHelixConfig(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.helix_config_path = os.path.join(
            self.repo_root, "editors", "helix", "languages.toml"
        )

    def test_languages_toml_exists(self):
        self.assertTrue(
            os.path.isfile(self.helix_config_path),
            f"languages.toml not found at {self.helix_config_path}",
        )

    def test_languages_toml_parses(self):
        with open(self.helix_config_path, "rb") as f:
            data = tomllib.load(f)
        self.assertIsInstance(data, dict)

    def test_zals_language_server_definition(self):
        with open(self.helix_config_path, "rb") as f:
            data = tomllib.load(f)

        ls_section = data.get("language-server", {})
        self.assertIn(
            "zals", ls_section, "language-server.zals section missing from languages.toml"
        )
        zals_cfg = ls_section["zals"]
        self.assertEqual(zals_cfg.get("command"), "zals")

        # Config section should contain ansible settings
        config = zals_cfg.get("config", {})
        ansible_cfg = config.get("ansible", {})
        self.assertIn("validation", ansible_cfg)
        self.assertTrue(ansible_cfg["validation"].get("enabled", False))

    def test_ansible_language_definition(self):
        with open(self.helix_config_path, "rb") as f:
            data = tomllib.load(f)

        languages = data.get("language", [])
        self.assertIsInstance(languages, list)

        ansible_lang = None
        for lang in languages:
            if lang.get("name") == "ansible":
                ansible_lang = lang
                break

        self.assertIsNotNone(ansible_lang, "language 'ansible' missing from languages.toml")
        self.assertIn("zals", ansible_lang.get("language-servers", []))
        self.assertIn("ansible.cfg", ansible_lang.get("roots", []))
        self.assertIn(".git", ansible_lang.get("roots", []))

        # Check standard file types
        file_types = ansible_lang.get("file-types", [])
        self.assertTrue(len(file_types) > 0, "file-types must not be empty")


if __name__ == "__main__":
    unittest.main()
