import os
import unittest
import xml.etree.ElementTree as ET


class TestPyCharmPlugin(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.pycharm_dir = os.path.join(self.repo_root, "editors", "pycharm")

    def test_files_exist(self):
        build_gradle = os.path.join(self.pycharm_dir, "build.gradle.kts")
        settings_gradle = os.path.join(self.pycharm_dir, "settings.gradle.kts")
        plugin_xml = os.path.join(
            self.pycharm_dir, "src", "main", "resources", "META-INF", "plugin.xml"
        )
        provider_kt = os.path.join(
            self.pycharm_dir,
            "src",
            "main",
            "kotlin",
            "com",
            "kksat",
            "zals",
            "ZalsLspServerSupportProvider.kt",
        )
        descriptor_kt = os.path.join(
            self.pycharm_dir,
            "src",
            "main",
            "kotlin",
            "com",
            "kksat",
            "zals",
            "ZalsLspServerDescriptor.kt",
        )
        settings_kt = os.path.join(
            self.pycharm_dir,
            "src",
            "main",
            "kotlin",
            "com",
            "kksat",
            "zals",
            "settings",
            "ZalsSettings.kt",
        )
        readme = os.path.join(self.pycharm_dir, "README.md")

        for path in [
            build_gradle,
            settings_gradle,
            plugin_xml,
            provider_kt,
            descriptor_kt,
            settings_kt,
            readme,
        ]:
            self.assertTrue(os.path.isfile(path), f"Missing {path}")

    def test_plugin_xml_structure(self):
        plugin_xml = os.path.join(
            self.pycharm_dir, "src", "main", "resources", "META-INF", "plugin.xml"
        )
        tree = ET.parse(plugin_xml)
        root = tree.getroot()

        self.assertEqual(root.tag, "idea-plugin")

        id_elem = root.find("id")
        self.assertIsNotNone(id_elem)
        self.assertEqual(id_elem.text, "com.kksat.zals")

        name_elem = root.find("name")
        self.assertIsNotNone(name_elem)
        self.assertEqual(name_elem.text, "Ansible Language Server (zals)")

        vendor_elem = root.find("vendor")
        self.assertIsNotNone(vendor_elem)
        self.assertEqual(vendor_elem.text, "kksat")

        # Check dependencies
        depends = [d.text for d in root.findall("depends")]
        self.assertIn("com.intellij.modules.platform", depends)

    def test_descriptor_kotlin_logic(self):
        descriptor_kt = os.path.join(
            self.pycharm_dir,
            "src",
            "main",
            "kotlin",
            "com",
            "kksat",
            "zals",
            "ZalsLspServerDescriptor.kt",
        )
        with open(descriptor_kt, "r", encoding="utf-8") as f:
            code = f.read()

        self.assertIn("class ZalsLspServerDescriptor", code)
        self.assertIn("isSupportedFile", code)
        self.assertIn('"zals"', code)
        self.assertIn("ansible.cfg", code)


if __name__ == "__main__":
    unittest.main()
