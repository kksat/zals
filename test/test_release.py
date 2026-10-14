"""Exercise the release contract without network access or package uploads."""

import base64
import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_verify", ROOT / "tools/release/verify.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
pypi_spec = importlib.util.spec_from_file_location("prepare_pypi", ROOT / "tools/release/prepare_pypi.py")
pypi = importlib.util.module_from_spec(pypi_spec)
pypi_spec.loader.exec_module(pypi)


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

    def test_source_uses_valid_replacement_for_legacy_classifier(self):
        self.assertNotIn('"Topic :: Software Development :: Language Servers"',
                         (ROOT / "python/pyproject.toml").read_text())

    def make_legacy_wheel(self):
        path = self.directory / "legacy.whl"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as wheel:
            wheel.writestr("zals/bin/zals", b"unchanged executable")
            wheel.writestr("zals/_run.py", b"unchanged Python wrapper")
            wheel.writestr("zals-0.1.0.dist-info/METADATA",
                           b"Name: zals\nVersion: 0.1.0\n" + pypi.INVALID_CLASSIFIER + b"\n")
            wheel.writestr("zals-0.1.0.dist-info/RECORD", "old record")
        return path

    def test_pypi_classifier_repair_preserves_payloads_and_record_hashes(self):
        source = self.make_legacy_wheel()
        original_bytes = source.read_bytes()
        output = self.directory / "publication/repaired.whl"
        self.assertTrue(pypi.prepare_wheel(source, output, self.version))
        self.assertEqual(source.read_bytes(), original_bytes)
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as repaired:
            self.assertEqual(original.namelist(), repaired.namelist())
            for name in ("zals/bin/zals", "zals/_run.py"):
                self.assertEqual(original.read(name), repaired.read(name))
            metadata = repaired.read("zals-0.1.0.dist-info/METADATA")
            self.assertNotIn(pypi.INVALID_CLASSIFIER, metadata)
            self.assertIn(pypi.VALID_CLASSIFIER, metadata)
            for name, digest, size in csv.reader(io.StringIO(
                    repaired.read("zals-0.1.0.dist-info/RECORD").decode())):
                if name.endswith("/RECORD"):
                    self.assertEqual((digest, size), ("", ""))
                else:
                    data = repaired.read(name)
                    expected_hash = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
                    self.assertEqual(digest, "sha256=" + expected_hash)
                    self.assertEqual(int(size), len(data))
        copied = self.directory / "publication/copied.whl"
        self.assertFalse(pypi.prepare_wheel(output, copied, self.version))
        self.assertEqual(copied.read_bytes(), output.read_bytes())

    def test_pypi_preparation_rejects_version_mismatch(self):
        with self.assertRaisesRegex(ValueError, "Wrong wheel version"):
            pypi.prepare_wheel(self.make_legacy_wheel(), self.directory / "bad.whl", "0.2.0")

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

    @unittest.skipUnless(shutil.which("sha256sum") and shutil.which("ruby"),
                         "formula rendering requires sha256sum and Ruby")
    def test_homebrew_workflow_renders_template_comments_and_checksums(self):
        self.make_assets()
        formula_dir = self.directory / "Formula"
        formula_dir.mkdir()
        shutil.copy2(ROOT / "Formula/zals.rb", formula_dir / "zals.rb")
        # Exercise the actual workflow script, not a second implementation.
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        match = re.search(
            r"      - name: Render the formula from verified archives\n"
            r"        shell: bash\n        run: \|\n((?:          .*\n)+)", workflow,
        )
        self.assertIsNotNone(match)
        script = textwrap.dedent(match[1]).replace('version="${TAG#v}"',
                                                  f'version="{self.version}"')
        (self.directory / "dist").mkdir()
        for asset in self.directory.glob("*.tar.gz"):
            shutil.copy2(asset, self.directory / "dist" / asset.name)
        result = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        formula = (self.directory / "tap/Formula/zals.rb").read_text()
        self.assertIn('# tokens with the released version', formula)
        self.assertIn(f'version "{self.version}"', formula)
        self.assertIn('--version 2>&1', formula)
        for asset in (self.directory / "dist").glob("*.tar.gz"):
            self.assertIn(hashlib.sha256(asset.read_bytes()).hexdigest(), formula)

    def workflow_job(self, name):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        match = re.search(rf"^  {name}:\n(.*?)(?=^  \w+:\n|\Z)",
                          workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, f"Missing workflow job: {name}")
        return match[1]

    def test_registry_publication_is_opt_in_and_requires_verified_assets(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        publication_assets = self.workflow_job("publication_assets")
        for job, flag in (("vscode_marketplace", "publish_vscode"),
                          ("openvsx", "publish_openvsx")):
            with self.subTest(job=job):
                self.assertRegex(workflow, rf"      {flag}:\n"
                                 r"        description: .*\n"
                                 r"        type: boolean\n        default: false\n")
                self.assertIn(f"inputs.{flag}", publication_assets)
                body = self.workflow_job(job)
                self.assertIn("needs: publication_assets", body)
                self.assertIn(f"!cancelled() && inputs.{flag} && "
                              "needs.publication_assets.result == 'success'", body)
                self.assertIn("name: verified-publication-assets", body)
                self.assertIn("ref: ${{ github.sha }}", body)
                self.assertIn("run: npm ci --prefix editors/vscode", body)

    def test_marketplace_uses_federated_identity_not_pat(self):
        marketplace = self.workflow_job("vscode_marketplace")
        self.assertIn("environment: vscode-marketplace", marketplace)
        self.assertIn("id-token: write", marketplace)
        self.assertIn("uses: azure/login@v2", marketplace)
        self.assertIn("--azure-credential", marketplace)
        self.assertNotIn("VSCE_PAT", marketplace)
        self.assertNotIn("secrets.", marketplace)
        for name in ("AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_SUBSCRIPTION_ID"):
            self.assertIn(f"vars.{name}", marketplace)
        openvsx = self.workflow_job("openvsx")
        self.assertIn("secrets.OVSX_PAT", openvsx)
        self.assertNotIn("id-token: write", openvsx)

    def test_registry_commands_publish_all_five_prebuilt_packages_without_rebuilding(self):
        self.make_assets()
        dist = self.directory / "dist"
        dist.mkdir()
        for source in self.directory.glob("*.vsix"):
            shutil.copy2(source, dist / source.name)
        # An unrelated version must not be selected by either command.
        (dist / "zals-99.0.0-linux-x64.vsix").write_bytes(b"unrelated")
        cwd = self.directory / "editors/vscode"
        cwd.mkdir(parents=True)
        bin_dir = self.directory / "fake-bin"
        bin_dir.mkdir()
        captured = self.directory / "command.json"
        npx = bin_dir / "npx"
        # Never invoke a real registry client in these tests.
        npx.write_text(f"#!{shutil.which('python3')}\n"
                       "import json, os, sys\n"
                       "from pathlib import Path\n"
                       "Path(os.environ['CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n"
                       "sys.exit(int(os.environ.get('PUBLISH_EXIT', '0')))\n")
        npx.chmod(0o755)
        for job, step, client, auth in (
                ("vscode_marketplace", "Visual Studio Marketplace", "vsce", ["--azure-credential"]),
                ("openvsx", "Open VSX", "ovsx", [])):
            with self.subTest(job=job):
                match = re.search(rf"      - name: Publish verified VSIXs to {step}\n"
                                  r".*?        run: \|\n((?:          .*\n)+)",
                                  self.workflow_job(job), re.DOTALL)
                self.assertIsNotNone(match)
                script = textwrap.dedent(match[1])
                result = subprocess.run(["bash", "-c", script], cwd=cwd,
                                        env={**os.environ, "TAG": self.tag,
                                             "PATH": f"{bin_dir}:{os.environ['PATH']}",
                                             "CAPTURE": str(captured)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = json.loads(captured.read_text())
                expected_args = ["--no-install", client, "publish", *auth,
                                 "--skip-duplicate", "--packagePath"]
                self.assertEqual(args[:len(expected_args)], expected_args)
                packages = [str((cwd / value).resolve()) for value in args[len(expected_args):]]
                self.assertEqual(sorted(packages), sorted(str(p.resolve()) for p in dist.glob("zals-0.1.0-*.vsix")))
                self.assertEqual(len(packages), 5)
                # Authentication/upload failures must not be silently ignored.
                failed = subprocess.run(["bash", "-c", script], cwd=cwd,
                                        env={**os.environ, "TAG": self.tag,
                                             "PATH": f"{bin_dir}:{os.environ['PATH']}",
                                             "CAPTURE": str(captured), "PUBLISH_EXIT": "42"},
                                        capture_output=True, text=True)
                self.assertEqual(failed.returncode, 42)

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
