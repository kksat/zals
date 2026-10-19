"""Exercise the release contract without network access or package uploads."""

import base64
import csv
import hashlib
import importlib.util
import io
import itertools
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
import unittest
import xml.etree.ElementTree as ET
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
        for tag in (f"v{version}", f"zals-v{version}"):
            with self.subTest(tag=tag):
                release.verify_versions(ROOT, tag)

    def test_release_please_uses_unprefixed_tags(self):
        config = json.loads((ROOT / "release-please-config.json").read_text())
        self.assertIs(config["packages"]["."].get("include-component-in-tag"), False)

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

    def test_pypi_cli_accepts_both_tag_formats(self):
        self.make_assets()
        # Fixture wheels have no classifiers; provide an offline vocabulary.
        (self.directory / "trove_classifiers.py").write_text("classifiers = set()\n")
        for tag in (self.tag, f"zals-{self.tag}"):
            with self.subTest(tag=tag):
                output = self.directory / tag
                result = subprocess.run(
                    [sys.executable, str(ROOT / "tools/release/prepare_pypi.py"),
                     "--tag", tag, "--source", str(self.directory), "--output", str(output)],
                    env={**os.environ, "PYTHONPATH": str(self.directory)},
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(list(output.glob("*.whl"))), 5)
                for wheel in self.directory.glob("*.whl"):
                    self.assertEqual((output / wheel.name).read_bytes(), wheel.read_bytes())

    def test_rejects_invalid_tag(self):
        for tag in ("main", "0.2.0", "other-v0.2.0", "zals-0.2.0", "v0.2.0-rc.1",
                    "zals-v0.2.0-extra", "zals-v0.2.0\n"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "Invalid release tag"):
                release.tag_version(tag)

    def test_complete_asset_set(self):
        self.make_assets()
        for tag in (self.tag, f"zals-{self.tag}"):
            with self.subTest(tag=tag):
                release.verify_assets(self.directory, tag)
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
        script = textwrap.dedent(match[1])
        (self.directory / "dist").mkdir()
        for asset in self.directory.glob("*.tar.gz"):
            shutil.copy2(asset, self.directory / "dist" / asset.name)
        for tag in (self.tag, f"zals-{self.tag}"):
            with self.subTest(tag=tag):
                result = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                        env={**os.environ, "TAG": tag},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                formula = (self.directory / "tap/Formula/zals.rb").read_text()
                self.assertIn('# tokens with the released version', formula)
                self.assertIn(f'version "{self.version}"', formula)
                self.assertIn('--version 2>&1', formula)
                for target, _, _ in release.PLATFORMS:
                    if not target.endswith("windows"):
                        self.assertIn(f'/download/{tag}/zals-{self.version}-{target}.tar.gz', formula)
                for asset in (self.directory / "dist").glob("*.tar.gz"):
                    self.assertIn(hashlib.sha256(asset.read_bytes()).hexdigest(), formula)

    def workflow_job(self, name, path=".github/workflows/release.yml"):
        workflow = (ROOT / path).read_text()
        match = re.search(rf"^  {name}:\n(.*?)(?=^  \w+:\n|\Z)",
                          workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, f"Missing workflow job: {name}")
        return match[1]

    def test_release_runs_only_for_release_please_release_creation_or_manual_dispatch(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        triggers = re.search(r"^on:\n(.*?)(?=^\w)", workflow, re.MULTILINE | re.DOTALL)[1]
        self.assertEqual(set(re.findall(r"^  ([\w_]+):", triggers, re.MULTILINE)),
                         {"workflow_call", "workflow_dispatch"})
        self.assertIn("TAG: ${{ inputs.tag }}", workflow)
        self.assertIn("group: release-${{ inputs.tag }}", workflow)
        release_please_path = ".github/workflows/release-please.yml"
        release_please = (ROOT / release_please_path).read_text()
        self.assertIn("  push:\n    branches: [main]", release_please)
        self.assertIn("id: release", release_please)
        self.assertIn("release_created: ${{ steps.release.outputs.release_created }}", release_please)
        self.assertIn("tag_name: ${{ steps.release.outputs.tag_name }}", release_please)
        publish = self.workflow_job("publish", release_please_path)
        self.assertIn("needs: release-please", publish)
        self.assertIn("if: ${{ needs.release-please.outputs.release_created == 'true' }}", publish)
        self.assertIn("uses: ./.github/workflows/release.yml", publish)
        self.assertIn("tag: ${{ needs.release-please.outputs.tag_name }}", publish)
        self.assertIn("publish_vscode: true", publish)
        self.assertIn("vscode_auth: pat", publish)
        self.assertIn("publish_openvsx: true", publish)
        self.assertNotIn("publish_pypi: true", publish)
        self.assertNotIn("publish_homebrew: true", publish)
        callers = [p.name for p in (ROOT / ".github/workflows").glob("*.yml")
                   if "uses: ./.github/workflows/release.yml" in p.read_text()]
        self.assertEqual(callers, ["release-please.yml"])

    def test_release_notes_gate_uses_trusted_tooling_and_preserves_initial_body(self):
        automatic = (ROOT / ".github/workflows/release-please.yml").read_text()
        self.assertIn("group: release-please-main", automatic)
        self.assertIn("cancel-in-progress: false", automatic)
        self.assertIn("fetch-depth: 0", automatic)
        self.assertIn("npm ci --prefix tools/release", automatic)
        self.assertIn("npm test --prefix tools/release", automatic)
        self.assertIn("run: node tools/release/runner.mjs", automatic)
        self.assertIn("statuses: write", self.workflow_job("release-please", ".github/workflows/release-please.yml"))
        self.assertNotIn("statuses: write", self.workflow_job("publish", ".github/workflows/release-please.yml"))
        self.assertNotIn("googleapis/release-please-action", automatic)
        package = json.loads((ROOT / "tools/release/package.json").read_text())
        lock = json.loads((ROOT / "tools/release/package-lock.json").read_text())
        self.assertEqual(package["dependencies"]["release-please"], "17.3.0")
        self.assertEqual(lock["packages"]["node_modules/release-please"]["version"], "17.3.0")
        status = (ROOT / ".github/workflows/release-notes.yml").read_text()
        self.assertIn("pull_request_target:", status)
        self.assertIn("name: validate curated release notes", status)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha || steps.candidate.outputs.base_sha }}", status)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha || steps.candidate.outputs.head_sha }}", status)
        self.assertIn("workflow_dispatch:", status)
        self.assertIn("PR_NUMBER: ${{ inputs.pull_request }}", status)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER"', status)
        self.assertIn("python3 tooling/tools/release/notes.py --repo candidate verify", status)
        self.assertIn("pull-requests: read", status)
        self.assertIn("statuses: write", status)
        self.assertNotIn("contents: write", status)
        self.assertNotIn("pull-requests: write", status)
        self.assertIn("id: notes", status)
        self.assertIn("always() && steps.pending.outcome == 'success'", status)
        self.assertIn("context='approved curated release notes'", status)
        ci = self.workflow_job("release-runner", ".github/workflows/test.yml")
        self.assertIn('node-version: "22"', ci)
        self.assertIn("cache-dependency-path: tools/release/package-lock.json", ci)
        self.assertIn("npm ci --prefix tools/release", ci)
        self.assertIn("npm --prefix tools/release test", ci)
        validate = self.workflow_job("validate")
        self.assertIn("ref: ${{ github.sha }}", validate)
        self.assertIn("path: release-source", validate)
        self.assertIn("fetch-depth: 0", validate)
        self.assertIn("notes.py --repo release-source retry", validate)
        self.assertIn("notes.py --repo release-source verify", validate)
        publish = self.workflow_job("release")
        self.assertIn("ref: ${{ github.sha }}", publish)
        self.assertIn("release-tools/tools/release/notes.py", publish)
        self.assertIn("id: notes", publish)
        self.assertIn('--github-output "$GITHUB_OUTPUT"', publish)
        self.assertIn('gh release upload "$TAG" dist/* --clobber --repo "$GITHUB_REPOSITORY"', publish)
        self.assertIn('gh release create "$TAG" --verify-tag --title "$TAG"', publish)
        self.assertIn('--notes-file "$RUNNER_TEMP/release-notes.md"', publish)
        self.assertIn("steps.notes.outputs.release_exists == 'true'", publish)
        self.assertIn("steps.notes.outputs.release_exists == 'false'", publish)
        self.assertNotIn("softprops/action-gh-release", publish)
        self.assertNotIn("generate_release_notes:", publish)
        self.assertIn('notes.py --repo "$GITHUB_WORKSPACE" packages', publish)
        self.assertLess(publish.index('verify.py assets'), publish.index('"$GITHUB_WORKSPACE" packages'))
        publication_assets = self.workflow_job("publication_assets")
        self.assertIn('if git cat-file -e "$TAG:docs/releases/${TAG}.json"', publication_assets)
        self.assertIn('notes.py --repo "$GITHUB_WORKSPACE" packages', publication_assets)

    def test_manual_notes_validation_chooses_retry_without_new_approval(self):
        workflow = self.workflow_job("validate")
        match = re.search(r"      - name: Verify approved notes or validate an existing-release retry\n"
                          r".*?        run: \|\n((?:          .*\n)+)", workflow, re.DOTALL)
        self.assertIsNotNone(match)
        script = textwrap.dedent(match[1])
        helper = self.directory / "release-tools/tools/release/notes.py"
        helper.parent.mkdir(parents=True)
        captured = self.directory / "arguments.json"
        helper.write_text("import json, os, sys\nfrom pathlib import Path\n"
                          "Path(os.environ['CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n"
                          "print('Approved body')\n"
                          "sys.exit(int(os.environ.get('HELPER_EXIT', '0')))\n")
        for existing, command, flag, tag in (("true", "retry", "--tag", self.tag),
                                              ("true", "retry", "--tag", f"zals-{self.tag}"),
                                              ("false", "verify", "--ref", self.tag)):
            with self.subTest(publish_existing=existing, tag=tag):
                env = {**os.environ, "TAG": tag, "PUBLISH_EXISTING": existing,
                       "GITHUB_REPOSITORY": "kksat/zals", "CAPTURE": str(captured)}
                result = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = json.loads(captured.read_text())
                self.assertEqual(args[:5], ["--repo", "release-source", command, flag, tag])
                self.assertIn("--github-repository", args)
                failed = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                        env={**env, "HELPER_EXIT": "42"}, capture_output=True, text=True)
                self.assertEqual(failed.returncode, 42)

    def test_github_asset_commands_never_rewrite_existing_release_prose(self):
        workflow = self.workflow_job("release")
        bin_dir = self.directory / "bin"
        bin_dir.mkdir()
        captured = self.directory / "github.json"
        gh = bin_dir / "gh"
        gh.write_text(f"#!{shutil.which('python3')}\nimport json, os, sys\nfrom pathlib import Path\n"
                      "Path(os.environ['CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n"
                      "sys.exit(int(os.environ.get('GH_EXIT', '0')))\n")
        gh.chmod(0o755)
        dist = self.directory / "dist"
        dist.mkdir()
        for filename in ("binary.tar.gz", "extension.vsix", "SHA256SUMS"):
            (dist / filename).write_bytes(b"already verified fixture")
        notes = self.directory / "release-notes.md"
        notes.write_text("Approved selected release body")
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "CAPTURE": str(captured),
               "TAG": self.tag, "GITHUB_REPOSITORY": "kksat/zals", "RUNNER_TEMP": str(self.directory)}
        for name, exists, command in (("Upload verified assets to an existing GitHub release", "true", "upload"),
                                      ("Create a GitHub release with the approved initial body and assets", "false", "create")):
            with self.subTest(command=command):
                match = re.search(rf"      - name: {name}\n(.*?)        run: \|\n((?:          [^\n]*\n)+)",
                                  workflow, re.DOTALL)
                self.assertIsNotNone(match)
                self.assertIn("steps.github_assets.outputs.already_published != 'true'", match[1])
                self.assertIn(f"steps.notes.outputs.release_exists == '{exists}'", match[1])
                script = textwrap.dedent(match[2])
                result = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = json.loads(captured.read_text())
                self.assertEqual(args[:3], ["release", command, self.tag])
                self.assertEqual(sorted(arg for arg in args if arg.startswith("dist/")),
                                 ["dist/SHA256SUMS", "dist/binary.tar.gz", "dist/extension.vsix"])
                if command == "upload":
                    self.assertIn("--clobber", args)
                    self.assertNotIn("--notes-file", args)
                    self.assertNotIn("create", args)
                else:
                    self.assertIn("--verify-tag", args)
                    self.assertEqual(args[args.index("--notes-file") + 1], str(notes))
                    self.assertNotIn("--clobber", args)
                # An existing-release race or failed upload cannot fall back to
                # creating/updating a different body or hiding the API error.
                failed = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                        env={**env, "GH_EXIT": "42"}, capture_output=True, text=True)
                self.assertEqual(failed.returncode, 42)
        decision = 'test "$RELEASE_EXISTS" = true || test "$RELEASE_EXISTS" = false'
        self.assertIn(decision, workflow)
        for value in ("true", "false", "", "unknown"):
            result = subprocess.run(["bash", "-c", decision], env={**os.environ, "RELEASE_EXISTS": value})
            self.assertEqual(result.returncode == 0, value in ("true", "false"))

    def test_manual_readiness_status_uses_exact_head_and_fails_closed(self):
        workflow = self.workflow_job("release-notes", ".github/workflows/release-notes.yml")
        match = re.search(r"      - name: Publish the exact candidate head readiness status\n"
                          r".*?        run: \|\n((?:          .*\n)+)", workflow, re.DOTALL)
        self.assertIsNotNone(match)
        script = textwrap.dedent(match[1])
        bin_dir = self.directory / "bin"
        bin_dir.mkdir()
        captured = self.directory / "status.json"
        gh = bin_dir / "gh"
        gh.write_text(f"#!{shutil.which('python3')}\nimport json, os, sys\nfrom pathlib import Path\n"
                      "Path(os.environ['CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n"
                      "sys.exit(int(os.environ.get('STATUS_EXIT', '0')))\n")
        gh.chmod(0o755)
        head = "a" * 40
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
               "CAPTURE": str(captured), "CANDIDATE_SHA": head,
               "GITHUB_REPOSITORY": "kksat/zals", "GITHUB_SERVER_URL": "https://example.test",
               "GITHUB_RUN_ID": "123"}
        for outcome in ("success", "failure", "skipped", "cancelled", ""):
            with self.subTest(outcome=outcome):
                result = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                        env={**env, "NOTES_OUTCOME": outcome}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = json.loads(captured.read_text())
                self.assertEqual(args[:4], ["api", "--method", "POST", f"repos/kksat/zals/statuses/{head}"])
                self.assertIn("state=success" if outcome == "success" else "state=failure", args)
                self.assertIn("context=approved curated release notes", args)
        failed = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                env={**env, "NOTES_OUTCOME": "success", "STATUS_EXIT": "42"},
                                capture_output=True, text=True)
        self.assertEqual(failed.returncode, 42)
        invalid = subprocess.run(["bash", "-c", script], cwd=self.directory,
                                 env={**env, "CANDIDATE_SHA": "main", "NOTES_OUTCOME": "success"},
                                 capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)

    def test_verification_uses_workflow_tools_against_tagged_sources_and_assets(self):
        for job in ("validate", "release", "publication_assets"):
            with self.subTest(job=job):
                body = self.workflow_job(job)
                self.assertIn("ref: ${{ env.TAG }}", body)
                self.assertIn("ref: ${{ github.sha }}", body)
                self.assertIn("path: release-tools", body)
                self.assertIn("sparse-checkout: tools/release", body)
                self.assertIn("python release-tools/tools/release/verify.py", body)

    def test_workflow_version_extraction_supports_both_tag_formats(self):
        for job in ("build", "python", "vscode", "vscode_marketplace",
                    "vscode_marketplace_pat", "openvsx", "homebrew"):
            body = self.workflow_job(job)
            assignments = re.findall(r'^ *version=".*"$', body, re.MULTILINE)
            self.assertTrue(assignments, f"Missing version extraction: {job}")
            for tag in (self.tag, f"zals-{self.tag}"):
                with self.subTest(job=job, tag=tag):
                    script = "\n".join(assignments) + '\nprintf "%s" "$version"'
                    result = subprocess.run(["bash", "-c", script],
                                            env={**os.environ, "TAG": tag},
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, self.version)

    def test_registry_publication_is_opt_in_and_requires_verified_assets(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        publication_assets = self.workflow_job("publication_assets")
        for job, flag in (("vscode_marketplace", "publish_vscode"),
                          ("vscode_marketplace_pat", "publish_vscode"),
                          ("openvsx", "publish_openvsx")):
            with self.subTest(job=job):
                self.assertRegex(workflow, rf"      {flag}:\n"
                                 r"        description: .*\n"
                                 r"        type: boolean\n        default: false\n")
                self.assertIn(f"inputs.{flag}", publication_assets)
                body = self.workflow_job(job)
                self.assertIn("needs: publication_assets", body)
                self.assertIn(f"!cancelled() && inputs.{flag} && ", body)
                self.assertIn("needs.publication_assets.result == 'success'", body)
                self.assertIn("name: verified-publication-assets", body)
                self.assertIn("ref: ${{ github.sha }}", body)
                self.assertIn("run: npm ci --prefix editors/vscode", body)

    def test_marketplace_authentication_modes_are_explicit_and_isolated(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertRegex(workflow, r"      vscode_auth:\n"
                         r"        description: .*\n        type: choice\n"
                         r"        default: entra\n        options:\n"
                         r"          - entra\n          - pat\n")
        marketplace = self.workflow_job("vscode_marketplace")
        self.assertIn("inputs.vscode_auth != 'pat'", marketplace)
        self.assertIn("environment: vscode-marketplace", marketplace)
        self.assertIn("id-token: write", marketplace)
        self.assertIn("uses: azure/login@v2", marketplace)
        self.assertIn("--azure-credential", marketplace)
        self.assertNotIn("VSCE_PAT", marketplace)
        self.assertNotIn("secrets.", marketplace)
        for name in ("AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_SUBSCRIPTION_ID"):
            self.assertIn(f"vars.{name}", marketplace)
        pat = self.workflow_job("vscode_marketplace_pat")
        self.assertIn("inputs.vscode_auth == 'pat'", pat)
        self.assertIn("secrets.VSCE_PAT", pat)
        self.assertNotIn("id-token: write", pat)
        self.assertNotIn("azure/login", pat)
        self.assertNotIn("--azure-credential", pat)
        self.assertNotIn("environment: vscode-marketplace", pat)
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
        for (job, step, client, auth), tag in itertools.product((
                ("vscode_marketplace", "Visual Studio Marketplace", "vsce", ["--azure-credential"]),
                ("vscode_marketplace_pat", "Visual Studio Marketplace", "vsce", []),
                ("openvsx", "Open VSX", "ovsx", [])), (self.tag, f"zals-{self.tag}")):
            with self.subTest(job=job, tag=tag):
                match = re.search(rf"      - name: Publish verified VSIXs to {step}\n"
                                  r".*?        run: \|\n((?:          .*\n)+)",
                                  self.workflow_job(job), re.DOTALL)
                self.assertIsNotNone(match)
                script = textwrap.dedent(match[1])
                result = subprocess.run(["bash", "-c", script], cwd=cwd,
                                        env={**os.environ, "TAG": tag,
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
                                        env={**os.environ, "TAG": tag,
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


class GithubPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.local = self.directory / "local"
        self.remote = self.directory / "remote"
        self.bin = self.directory / "bin"
        for directory in (self.local, self.remote, self.bin):
            directory.mkdir()
        for name in release.asset_names("0.2.0") | {"SHA256SUMS"}:
            content = f"published content for {name}".encode()
            (self.local / name).write_bytes(content)
            (self.remote / name).write_bytes(content)
        self.output = self.directory / "output"
        self.immutable = True
        self.draft = False
        self.status = 200
        self.no_digest = False
        self.download_error = False
        # Exercise the actual CLI at its gh process seam, never a live release.
        gh = self.bin / "gh"
        gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
            import json, os, shutil, sys
            from pathlib import Path
            root = Path(os.environ["PUBLISH_FIXTURE"])
            fixture = json.loads((root / "fixture.json").read_text())
            args = sys.argv[1:]
            with (root / "calls").open("a") as calls:
                calls.write(json.dumps(args) + "\\n")
            if args == ["api", "repos/test/repo/releases/tags/v0.2.0"]:
                if fixture["status"] != 200:
                    print(json.dumps({"status": str(fixture["status"]), "message": "API rejected request"}))
                    print("API rejected request", file=sys.stderr)
                    sys.exit(1)
                print(json.dumps(fixture["release"]))
            elif args[:3] == ["release", "download", "v0.2.0"]:
                if fixture["download_error"]:
                    sys.exit("Download denied")
                destination = Path(args[args.index("--dir") + 1])
                name = args[args.index("--pattern") + 1]
                shutil.copy2(root / "remote" / name, destination / name)
            else:
                sys.exit("Unexpected gh command: " + repr(args))
            '''))
        gh.chmod(0o755)

    def run_check(self):
        metadata = {
            "id": 123, "immutable": self.immutable, "draft": self.draft,
            "assets": [{"name": path.name, "size": path.stat().st_size,
                        "digest": None if self.no_digest else
                        "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
                       for path in self.remote.iterdir()],
        }
        (self.directory / "fixture.json").write_text(json.dumps({
            "release": metadata, "status": self.status, "download_error": self.download_error,
        }))
        self.output.unlink(missing_ok=True)
        return subprocess.run(
            [sys.executable, str(ROOT / "tools/release/check_github.py"),
             "--tag", "v0.2.0", "--repository", "test/repo", "--directory", str(self.local)],
            env={"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.directory),
                 "PUBLISH_FIXTURE": str(self.directory), "GITHUB_OUTPUT": str(self.output)},
            capture_output=True, text=True, timeout=10,
        )

    def assert_decision(self, already_published):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.read_text(),
                         f"already_published={str(already_published).lower()}\n")

    def test_identical_published_release_is_a_noop_on_every_retry(self):
        for immutable in (True, False):
            with self.subTest(immutable=immutable):
                self.immutable = immutable
                self.assert_decision(True)
                self.assert_decision(True)
        calls = [json.loads(line) for line in (self.directory / "calls").read_text().splitlines()]
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(call[0] == "api" for call in calls))

    def test_new_release_needs_publication(self):
        self.status = 404
        self.assert_decision(False)

    def test_draft_release_still_needs_to_be_published(self):
        self.draft = True
        self.immutable = False
        self.assert_decision(False)

    def test_mutable_release_can_upload_missing_or_changed_assets(self):
        self.immutable = False
        asset = next(self.remote.glob("*.tar.gz"))
        asset.write_bytes(b"different content")
        self.assert_decision(False)
        asset.unlink()
        self.assert_decision(False)

    def test_immutable_release_rejects_missing_changed_or_extra_assets(self):
        asset = next(self.remote.glob("*.tar.gz"))
        original = asset.read_bytes()
        for change in ("missing", "changed", "extra"):
            with self.subTest(change=change):
                asset.write_bytes(original)
                extra = self.remote / "unexpected.zip"
                extra.unlink(missing_ok=True)
                if change == "missing":
                    asset.unlink()
                elif change == "changed":
                    asset.write_bytes(b"X" * len(original))
                else:
                    extra.write_bytes(b"extra")
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("immutable", result.stderr.lower())
                self.assertIn(extra.name if change == "extra" else asset.name, result.stderr)
                self.assertFalse(self.output.exists())

    def test_empty_immutable_release_cannot_claim_success(self):
        for asset in self.remote.iterdir():
            asset.unlink()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable", result.stderr.lower())
        self.assertIn("SHA256SUMS", result.stderr)
        self.assertFalse(self.output.exists())

    def test_checksums_are_compared_not_just_package_files(self):
        (self.remote / "SHA256SUMS").write_bytes(b"different checksums")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256SUMS", result.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_digests_fall_back_to_comparing_downloaded_bytes(self):
        self.no_digest = True
        self.assert_decision(True)
        asset = next(self.remote.glob("*.vsix"))
        asset.write_bytes(b"X" * asset.stat().st_size)
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(asset.name, result.stderr)
        self.assertFalse(self.output.exists())

    def test_api_and_download_failures_never_claim_success(self):
        for status in (401, 403, 429, 500):
            with self.subTest(status=status):
                self.status = status
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("API rejected request", result.stderr)
                self.assertFalse(self.output.exists())
        self.status = 200
        self.no_digest = True
        self.download_error = True
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Download denied", result.stderr)
        self.assertFalse(self.output.exists())

    def test_workflow_skips_upload_only_after_successful_content_comparison(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('python release-tools/tools/release/check_github.py --tag "$TAG"', workflow)
        self.assertIn("id: github_assets", workflow)
        self.assertIn("if: steps.github_assets.outputs.already_published != 'true'", workflow)


class RegistryServer(ThreadingHTTPServer):
    """Local registry boundary for exercising the real locked publishing CLIs."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), RegistryHandler)
        self.published = set()
        self.uploads = []
        self.failure_status = None


class RegistryHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, body):
        content = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_OPTIONS(self):
        # Azure DevOps discovers its Gallery API route before publishing.
        self.reply(200, {"value": [{
            "id": "e11ea35a-16fe-4b80-ab11-c4cab88a0966",
            "area": "gallery", "resourceName": "extensions",
            "routeTemplate": "_apis/gallery/publishers/{publisherName}/extensions/{extensionName}",
            "minVersion": "1.0", "maxVersion": "7.2", "releasedVersion": "7.2",
            "resourceVersion": 2,
        }]})

    def do_GET(self):
        if self.path == "/api/version":
            self.reply(200, {"version": "1.0.0"})
        elif self.path.startswith("/_apis/gallery/publishers/kksat/extensions/zals"):
            self.reply(200, {"versions": [
                {"version": "0.1.0", "targetPlatform": target}
                for target in sorted(self.server.published)
            ]})
        else:
            self.reply(404, {"error": "Unexpected test registry path"})

    def upload_body(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if not size:
                    self.rfile.readline()
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def do_POST(self):
        self.publish()

    def do_PUT(self):
        self.publish()

    def publish(self):
        with zipfile.ZipFile(io.BytesIO(self.upload_body())) as archive:
            identity = ET.fromstring(archive.read("extension.vsixmanifest")).find("{*}Metadata/{*}Identity")
            target = identity.get("TargetPlatform")
        if self.server.failure_status is not None:
            self.reply(self.server.failure_status, {"error": "Registry rejected the upload",
                                                    "message": "Registry rejected the upload"})
        elif target in self.server.published:
            self.reply(409, {"error": f"Extension kksat.zals 0.1.0 {target} is already published."})
        else:
            self.server.published.add(target)
            self.server.uploads.append(target)
            self.reply(200, {"namespace": "kksat", "name": "zals", "version": "0.1.0",
                             "targetPlatform": target})


@unittest.skipUnless(shutil.which("node") and
                     (ROOT / "editors/vscode/node_modules/ovsx/bin/ovsx").exists(),
                     "registry CLI tests require npm ci --prefix editors/vscode")
class RegistryCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.targets = {platform for _, _, platform in release.PLATFORMS}
        self.packages = []
        for target in sorted(self.targets):
            package = self.directory / f"zals-0.1.0-{target}.vsix"
            with zipfile.ZipFile(package, "w") as archive:
                archive.writestr("extension/package.json", json.dumps({
                    "name": "zals", "publisher": "kksat", "version": "0.1.0",
                    "engines": {"vscode": "^1.82.0"},
                }))
                archive.writestr("extension.vsixmanifest",
                                 '<PackageManifest><Metadata><Identity Version="0.1.0" '
                                 f'TargetPlatform="{target}" /></Metadata></PackageManifest>')
            self.packages.append(str(package))
        self.server = RegistryServer()
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def publish(self, client):
        executable = "@vscode/vsce/vsce" if client == "vsce" else "ovsx/bin/ovsx"
        url = f"http://127.0.0.1:{self.server.server_port}"
        # Never inherit real credentials, registry settings, proxies, or OIDC tokens.
        env = {"PATH": os.environ["PATH"], "HOME": str(self.directory), "CI": "true",
               "VSCE_PAT": "test-only", "OVSX_PAT": "test-only",
               "VSCE_MARKETPLACE_URL": url, "OVSX_REGISTRY_URL": url,
               "NO_PROXY": "127.0.0.1"}
        return subprocess.run([shutil.which("node"),
                               str(ROOT / "editors/vscode/node_modules" / executable),
                               "publish", "--skip-duplicate", "--packagePath", *self.packages],
                              env=env, capture_output=True, text=True, timeout=30)

    def check_idempotence(self, client):
        for initially_published in (set(), {"darwin-arm64"}, self.targets):
            with self.subTest(initially_published=initially_published):
                self.server.published = set(initially_published)
                self.server.uploads = []
                result = self.publish(client)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.server.published, self.targets)
                self.assertCountEqual(self.server.uploads, self.targets - initially_published)
                self.server.uploads = []
                retry = self.publish(client)
                self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                self.assertEqual(self.server.uploads, [])
        for status in (401, 403, 500):
            with self.subTest(status=status):
                # A mixed batch of duplicates and one missing target must still fail.
                self.server.published = self.targets - {"win32-x64"}
                self.server.failure_status = status
                failed = self.publish(client)
                self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
                self.assertIn("Registry rejected the upload", failed.stdout + failed.stderr)
                self.assertNotIn("win32-x64", self.server.published)
                self.server.failure_status = None
                retry = self.publish(client)
                self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                self.assertEqual(self.server.published, self.targets)

    def test_marketplace_duplicates_succeed_and_real_failures_fail(self):
        self.check_idempotence("vsce")

    def test_openvsx_duplicates_succeed_and_real_failures_fail(self):
        self.check_idempotence("ovsx")


if __name__ == "__main__":
    unittest.main()
