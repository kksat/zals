"""Exercise the release contract without network access or package uploads."""

import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_verify", ROOT / "tools/release/verify.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.version = "0.1.0"
        self.tag = f"v{self.version}"

    def make_assets(self):
        for target, wheel_platform, vscode_platform in release.PLATFORMS:
            binary_name = "zals.exe" if target.endswith("windows") else "zals"
            binary = f"binary for {target}".encode()
            if target.endswith("windows"):
                with zipfile.ZipFile(self.directory / f"zals-{self.version}-{target}.zip", "w") as archive:
                    archive.writestr(binary_name, binary)
            else:
                with tarfile.open(self.directory / f"zals-{self.version}-{target}.tar.gz", "w:gz") as archive:
                    member = tarfile.TarInfo(binary_name)
                    member.size = len(binary)
                    member.mode = 0o755
                    archive.addfile(member, io.BytesIO(binary))
            with zipfile.ZipFile(self.directory / f"zals-{self.version}-py3-none-{wheel_platform}.whl", "w") as wheel:
                wheel.writestr(f"zals/bin/{binary_name}", binary)
                wheel.writestr("zals/_run.py", "# wrapper")
                wheel.writestr(f"zals-{self.version}.dist-info/METADATA", f"Name: zals\nVersion: {self.version}\n")
                wheel.writestr(f"zals-{self.version}.dist-info/WHEEL", f"Tag: py3-none-{wheel_platform}\n")
            with zipfile.ZipFile(self.directory / f"zals-{self.version}-{vscode_platform}.vsix", "w") as vsix:
                vsix.writestr(f"extension/bin/{binary_name}", binary)
                vsix.writestr("extension/dist/extension.js", "// compiled client")
                vsix.writestr("extension/package.json", json.dumps({
                    "name": "zals", "version": self.version, "publisher": "kksat",
                }))
                vsix.writestr("extension.vsixmanifest", f'<PackageManifest><Metadata><Identity Version="{self.version}" TargetPlatform="{vscode_platform}" /></Metadata></PackageManifest>')

    def test_repository_versions_match_baseline(self):
        version = (ROOT / "version.txt").read_text().strip()
        release.verify_versions(ROOT, f"v{version}")

    def test_rejects_mismatched_source_version(self):
        for filename in ("version.txt", ".release-please-manifest.json", "src/main.zig",
                         "build.zig.zon", "python/pyproject.toml", "editors/vscode/package.json",
                         "editors/vscode/package-lock.json"):
            destination = self.directory / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / filename).read_bytes())
        (self.directory / "version.txt").write_text("99.0.0")
        with self.assertRaisesRegex(ValueError, "version.txt"):
            release.verify_versions(self.directory, self.tag)

    def test_rejects_invalid_tag(self):
        with self.assertRaisesRegex(ValueError, "Invalid release tag"):
            release.tag_version("main")

    def test_complete_asset_set(self):
        self.make_assets()
        release.verify_assets(self.directory, self.tag)
        self.assertEqual(len(release.asset_names(self.version)), 15)

    def test_missing_asset(self):
        self.make_assets()
        (self.directory / "zals-0.1.0-win32-x64.vsix").unlink()
        with self.assertRaisesRegex(ValueError, "Asset set mismatch"):
            release.verify_assets(self.directory, self.tag)

    def test_mismatched_bundled_binary(self):
        self.make_assets()
        wheel = self.directory / "zals-0.1.0-py3-none-win_amd64.whl"
        with zipfile.ZipFile(wheel, "w") as archive:
            archive.writestr("zals/bin/zals.exe", b"wrong binary")
        with self.assertRaisesRegex(ValueError, "Wheel binary differs"):
            release.verify_assets(self.directory, self.tag)

    def test_wrong_vsix_platform(self):
        self.make_assets()
        path = self.directory / "zals-0.1.0-win32-x64.vsix"
        with zipfile.ZipFile(path) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files["extension.vsixmanifest"] = files["extension.vsixmanifest"].replace(b"win32-x64", b"linux-x64")
        with zipfile.ZipFile(path, "w") as archive:
            for name, content in files.items():
                archive.writestr(name, content)
        with self.assertRaisesRegex(ValueError, "Wrong VSIX platform"):
            release.verify_assets(self.directory, self.tag)


if __name__ == "__main__":
    unittest.main()
