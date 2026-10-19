"""Offline release-note contracts, including GitHub approval and immutable retries."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_notes", ROOT / "tools/release/notes.py")
NOTES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTES)


class FakeGitHub:
    repository = "example/zals"

    def __init__(self, fixture):
        self.fixture = fixture
        self.pr = {"number": 7, "merged": True, "merge_commit_sha": fixture.notes_commit,
                   "base": {"ref": "main", "repo": {"full_name": self.repository}},
                   "head": {"sha": fixture.notes_commit}, "user": {"login": "author"},
                   "changed_files": 3}
        self.files = [{"filename": path, "status": "added", "sha": fixture.blob(path)}
                      for path in (NOTES.PUBLIC, NOTES.EDITOR, NOTES.metadata_path("0.2.0"))]
        self.reviews = [{"state": "APPROVED", "user": {"login": "reviewer", "type": "User"},
                         "commit_id": fixture.notes_commit}]
        self.release = {"tag_name": "v0.1.0", "draft": False,
                        "published_at": "2026-10-01T00:00:00Z", "body": "Legacy notes"}
        self.calls = []

    def pages(self, path):
        self.calls.append(path)
        if path.startswith("/commits/") and path.endswith("/pulls"):
            return [{"number": 7}]
        if path == "/pulls/7/files":
            return self.files
        if path == "/pulls/7/reviews":
            return self.reviews
        raise AssertionError(path)

    def get(self, path):
        self.calls.append(path)
        if path == "/pulls/7":
            return self.pr
        if path.startswith("/contents/"):
            filename = path[len("/contents/"):].split("?", 1)[0]
            return {"sha": self.fixture.blob(filename, self.pr["head"]["sha"])}
        if path.startswith("/releases/tags/"):
            return self.release
        raise AssertionError(path)


class ReleaseNotesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = NOTES.Repository(self.root)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release@example.test")
        self.write("version.txt", "0.1.0\n")
        self.write(".release-please-manifest.json", '{".": "0.1.0"}\n')
        self.write("src/main.zig", 'const version = "0.1.0"; // x-release-please-version\nconst behavior = 1;\n')
        self.write("build.zig.zon", '.version = "0.1.0", // x-release-please-version\n')
        self.write("python/pyproject.toml", 'version = "0.1.0" # x-release-please-version\n')
        self.write("editors/vscode/package.json", '{"version": "0.1.0", "name": "zals"}\n')
        self.write("editors/vscode/package-lock.json", json.dumps({"version": "0.1.0", "packages": {
            "": {"version": "0.1.0", "name": "zals"}}}) + "\n")
        self.history = "# Changelog\n\n## [0.1.0](https://example.test/v0.1.0)\n\nInitial capabilities.\n"
        self.write(NOTES.PUBLIC, self.history)
        self.commit("feat: initial release")
        self.git("tag", "v0.1.0")
        self.write("src/feature.zig", "// user-visible capability\n")
        self.candidate = self.commit("feat: navigate role parameters")
        self.body = ("## [0.2.0](https://example.test/v0.2.0)\n\n### Capabilities\n\n"
                     "Find a role parameter's accepted values with Go to Definition.\n\n"
                     "```yaml\n- role: example.web\n  port: 8080\n```\n")
        self.write(NOTES.PUBLIC, "# Changelog\n\n" + self.body + "\n" + self.history.split("\n\n", 1)[1])
        NOTES.prepare(self.repo, "0.2.0", "v0.1.0", self.candidate)
        self.notes_commit = self.commit("docs(release): describe 0.2.0")
        self.github = FakeGitHub(self)

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def write(self, path, content):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)

    def commit(self, subject):
        self.git("add", ".")
        self.git("commit", "-qm", subject)
        return self.git("rev-parse", "HEAD")

    def blob(self, path, ref="HEAD"):
        return self.git("rev-parse", f"{ref}:{path}")

    def metadata(self):
        return json.loads((self.root / NOTES.metadata_path("0.2.0")).read_text())

    def update_metadata(self, **changes):
        metadata = self.metadata()
        metadata.update(changes)
        self.write(NOTES.metadata_path("0.2.0"), json.dumps(metadata) + "\n")
        self.commit("docs(release): update coverage")

    def check(self):
        return NOTES.check(self.repo, "HEAD", "0.2.0")

    def verify(self):
        return NOTES.verify_approval(self.repo, "HEAD", "0.2.0", self.github)

    def test_prepared_notes_cover_exact_candidate(self):
        body, metadata = self.check()
        self.assertEqual(body, self.body)
        self.assertEqual(metadata["candidate"], self.candidate)
        self.assertEqual((self.root / NOTES.EDITOR).read_bytes(), (self.root / NOTES.PUBLIC).read_bytes())
        self.assertEqual(self.verify(), self.body)

    def test_new_code_requires_refresh_and_reapproval(self):
        self.write("src/fix.zig", "// a late fix\n")
        new_candidate = self.commit("fix: handle empty roles")
        with self.assertRaisesRegex(NOTES.NotesError, "stale"):
            self.check()
        NOTES.prepare(self.repo, "0.2.0", "v0.1.0", new_candidate)
        self.commit("docs(release): refresh coverage")
        self.check()
        with self.assertRaisesRegex(NOTES.NotesError, "merged notes-only PR"):
            self.verify()

    def test_mechanical_versions_and_generated_technical_notes_do_not_stale_coverage(self):
        paths = NOTES.ANNOTATED_VERSIONS | NOTES.JSON_VERSIONS | {"version.txt"}
        for path in paths:
            self.write(path, (self.root / path).read_text().replace("0.1.0", "0.2.0"))
        self.write(NOTES.TECHNICAL, "# Changelog\n\nGenerated technical notes, not public prose.\n")
        self.commit("chore(main): release 0.2.0")
        self.assertEqual(NOTES.check(self.repo, "HEAD")[0], self.body)
        self.assertEqual(self.verify(), self.body)
        self.git("tag", "v0.2.0")
        self.assertEqual(NOTES.check(self.repo, "v0.2.0")[0], self.body)

    def test_source_change_in_version_file_is_not_ignored(self):
        path = "src/main.zig"
        self.write(path, (self.root / path).read_text().replace("behavior = 1", "behavior = 2"))
        self.commit("fix: change behavior alongside version")
        with self.assertRaisesRegex(NOTES.NotesError, "stale"):
            self.check()

    def test_extension_manifest_changes_other_than_version_are_covered(self):
        path = "editors/vscode/package.json"
        self.write(path, (self.root / path).read_text().replace('"zals"', '"other"'))
        self.commit("fix: change extension metadata")
        with self.assertRaisesRegex(NOTES.NotesError, "stale"):
            self.check()

    def test_tree_modes_and_deleted_files_are_covered(self):
        (self.root / "src/feature.zig").chmod(0o755)
        self.commit("build: mark feature executable")
        with self.assertRaisesRegex(NOTES.NotesError, "stale"):
            self.check()
        self.git("rm", "src/feature.zig")
        self.commit("refactor: delete feature")
        with self.assertRaisesRegex(NOTES.NotesError, "stale"):
            self.check()

    def test_published_history_cannot_be_rewritten(self):
        document = (self.root / NOTES.PUBLIC).read_text().replace("Initial capabilities.", "Rewritten history.")
        self.write(NOTES.PUBLIC, document)
        with self.assertRaisesRegex(NOTES.NotesError, "immutable"):
            NOTES.prepare(self.repo, "0.2.0", "v0.1.0", self.candidate)

    def test_prior_release_cannot_be_removed_or_changelog_preamble_changed(self):
        for document in ("# Changelog\n\n" + self.body,
                         (self.root / NOTES.PUBLIC).read_text().replace("# Changelog", "# Rewritten", 1)):
            with self.subTest(document=document):
                self.write(NOTES.PUBLIC, document)
                with self.assertRaises(NOTES.NotesError):
                    NOTES.prepare(self.repo, "0.2.0", "v0.1.0", self.candidate)

    def test_wrong_previous_tag_and_version_fail_closed(self):
        with self.assertRaises(NOTES.NotesError):
            NOTES.prepare(self.repo, "0.2.0", "v9.0.0", self.candidate)
        with self.assertRaises(NOTES.NotesError):
            NOTES.check(self.repo, "HEAD", "0.3.0")
        self.update_metadata(version="0.3.0")
        with self.assertRaisesRegex(NOTES.NotesError, "version"):
            self.check()

    def test_coverage_candidate_must_be_a_real_full_ancestor(self):
        for candidate in ("HEAD", "f" * 40):
            with self.subTest(candidate=candidate):
                self.update_metadata(candidate=candidate)
                with self.assertRaises(NOTES.NotesError):
                    self.check()
        self.git("checkout", "--orphan", "unrelated")
        self.git("rm", "-rf", ".")
        self.write("other", "another history\n")
        orphan = self.commit("feat: independent tree")
        self.git("checkout", "main")
        self.update_metadata(candidate=orphan)
        with self.assertRaisesRegex(NOTES.NotesError, "descend"):
            self.check()

    def test_missing_or_forged_metadata_fails_closed(self):
        self.update_metadata(product_digest="0" * 64)
        with self.assertRaisesRegex(NOTES.NotesError, "digest"):
            self.check()
        self.update_metadata(schema=2)
        with self.assertRaisesRegex(NOTES.NotesError, "schema"):
            self.check()
        self.git("rm", NOTES.metadata_path("0.2.0"))
        self.commit("docs: remove metadata")
        with self.assertRaises(NOTES.NotesError):
            self.check()

    def test_changed_prose_needs_metadata_refresh_and_new_review(self):
        for path in (NOTES.PUBLIC, NOTES.EDITOR):
            self.write(path, (self.root / path).read_text().replace("accepted values", "documented options"))
        self.commit("docs: edit public prose")
        with self.assertRaisesRegex(NOTES.NotesError, "prose changed"):
            self.check()
        NOTES.prepare(self.repo, "0.2.0", "v0.1.0", self.candidate)
        self.commit("docs: refresh prose digest")
        self.check()
        with self.assertRaisesRegex(NOTES.NotesError, "merged notes-only PR"):
            self.verify()

    def test_editor_copy_must_match(self):
        self.write(NOTES.EDITOR, "# Different\n")
        self.commit("docs: drift editor notes")
        with self.assertRaisesRegex(NOTES.NotesError, "differ"):
            self.check()

    def test_approval_must_be_from_another_reviewer_on_final_head(self):
        original = copy.deepcopy(self.github.reviews)
        for changes in ({"commit_id": "0" * 40}, {"state": "DISMISSED"},
                        {"state": "COMMENTED"}, {"user": {"login": "author", "type": "User"}},
                        {"user": {"login": "automation[bot]", "type": "Bot"}}):
            with self.subTest(changes=changes):
                self.github.reviews = [dict(original[0], **changes)]
                with self.assertRaisesRegex(NOTES.NotesError, "final head"):
                    self.verify()
        self.github.reviews = original
        self.verify()

    def test_coverage_only_followup_approves_existing_prose_at_exact_head(self):
        self.write("internal.py", "# Internal maintenance with no public prose change\n")
        candidate = self.commit("refactor: internal maintenance")
        NOTES.prepare(self.repo, "0.2.0", "v0.1.0", candidate)
        self.notes_commit = self.commit("docs(release): refresh reviewed coverage")
        self.github = FakeGitHub(self)
        self.github.files = [item for item in self.github.files if item["filename"].endswith(".json")]
        self.github.pr["changed_files"] = 1
        self.assertEqual(self.verify(), self.body)
        content_calls = [call for call in self.github.calls if call.startswith("/contents/")]
        self.assertEqual(len(content_calls), 2)
        self.assertTrue(all(call.endswith(f"?ref={self.notes_commit}") for call in content_calls))
        original_get = self.github.get
        self.github.get = lambda path: ({"sha": "0" * 40} if path.startswith("/contents/")
                                        else original_get(path))
        with self.assertRaisesRegex(NOTES.NotesError, "differ"):
            self.verify()

    def test_change_request_blocks_even_with_another_approval(self):
        self.github.reviews.append({"user": {"login": "concerned"}, "state": "CHANGES_REQUESTED",
                                    "commit_id": self.notes_commit})
        with self.assertRaisesRegex(NOTES.NotesError, "change request"):
            self.verify()
        self.github.reviews.append({"user": {"login": "concerned"}, "state": "APPROVED",
                                    "commit_id": self.notes_commit})
        self.verify()

    def test_latest_review_and_case_insensitive_identity_are_used(self):
        self.github.reviews.append({"user": {"login": "REVIEWER"}, "state": "DISMISSED",
                                    "commit_id": self.notes_commit})
        with self.assertRaisesRegex(NOTES.NotesError, "final head"):
            self.verify()

    def test_notes_must_be_in_a_separate_merged_notes_only_pr(self):
        scenarios = [lambda: self.github.pr.update(merged=False),
                     lambda: self.github.pr["base"].update(ref="other"),
                     lambda: self.github.pr.update(merge_commit_sha=self.candidate),
                     lambda: self.github.files.append({"filename": "src/new.zig", "status": "added", "sha": "0" * 40}),
                     lambda: self.github.pr.update(changed_files=4),
                     lambda: self.github.files[0].update(status="renamed", previous_filename="other"),
                     lambda: self.github.files[0].update(sha="0" * 40)]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                self.github = FakeGitHub(self)
                scenario()
                with self.assertRaises(NOTES.NotesError):
                    self.verify()

    def test_regular_merge_notes_pr_provenance_uses_first_parent(self):
        # Reconstruct a non-squash merge so provenance must select the merge SHA,
        # not its feature-branch head. Reviews approve that branch head.
        self.git("reset", "--hard", self.candidate)
        self.git("branch", "notes", self.notes_commit)
        self.git("merge", "--no-ff", "notes", "-m", "Merge notes PR")
        merge_commit = self.git("rev-parse", "HEAD")
        self.github.pr["merge_commit_sha"] = merge_commit
        self.assertEqual(self.verify(), self.body)

    def test_previous_tag_must_actually_be_a_published_release(self):
        self.github.release["draft"] = True
        with self.assertRaisesRegex(NOTES.NotesError, "published"):
            self.verify()

    def test_retry_reuses_tagged_notes_without_new_approval(self):
        self.git("tag", "v0.2.0")
        self.github.release.update(tag_name="v0.2.0", body=self.body)
        self.github.reviews = []
        NOTES.retry(self.repo, "v0.2.0", self.github)
        self.assertFalse(any("reviews" in call for call in self.github.calls))
        self.github.release["body"] = "Modified after publication"
        with self.assertRaisesRegex(NOTES.NotesError, "immutable"):
            NOTES.retry(self.repo, "v0.2.0", self.github)

    def test_legacy_retry_reuses_existing_release_without_retroactive_notes(self):
        NOTES.retry(self.repo, "v0.1.0", self.github)
        self.assertEqual(self.github.calls, ["/releases/tags/v0.1.0"])
        self.github.release["published_at"] = None
        with self.assertRaisesRegex(NOTES.NotesError, "already-published"):
            NOTES.retry(self.repo, "v0.1.0", self.github)

    def test_packaged_extension_notes_match_tagged_public_history(self):
        self.git("tag", "v0.2.0")
        directory = self.root / "dist"
        directory.mkdir()
        for platform in ("linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64", "win32-x64"):
            with zipfile.ZipFile(directory / f"zals-0.2.0-{platform}.vsix", "w") as archive:
                archive.writestr("extension/CHANGELOG.md", (self.root / NOTES.PUBLIC).read_bytes())
        NOTES.packages(self.repo, "v0.2.0", directory)
        broken = directory / "zals-0.2.0-linux-x64.vsix"
        with zipfile.ZipFile(broken, "w") as archive:
            archive.writestr("extension/CHANGELOG.md", "Unapproved notes")
        with self.assertRaisesRegex(NOTES.NotesError, "differs"):
            NOTES.packages(self.repo, "v0.2.0", directory)
        with zipfile.ZipFile(broken, "w") as archive:
            archive.writestr("extension/README.md", "No changelog")
        with self.assertRaisesRegex(NOTES.NotesError, "Missing"):
            NOTES.packages(self.repo, "v0.2.0", directory)

    def test_packages_cannot_invent_retrospective_notes_for_legacy_release(self):
        with self.assertRaises(NOTES.NotesError):
            NOTES.packages(self.repo, "v0.1.0", self.root)

    def test_examples_do_not_create_false_release_headings(self):
        document = ("# Changelog\n\n## 0.2.0\n\nExample:\n```markdown\n## 7.8.9\n```\n\n"
                    "## 0.1.0\n\nOld notes.\n")
        self.assertEqual([item[0] for item in NOTES.sections(document)], ["0.2.0", "0.1.0"])
        self.assertIn("## 7.8.9", NOTES.release_body(document, "0.2.0"))
        for invalid in ("# Changelog\n\n## Unreleased\n", "## 0.2.0\n\n```yaml\n",
                        "## 0.2.0\n\n## 0.2.0\n"):
            with self.subTest(document=invalid), self.assertRaises(NOTES.NotesError):
                NOTES.sections(invalid)
        for empty in ("## 0.2.0\n", "## 0.2.0\n\n### Fixes\n", "## 0.2.0\n\nTODO: write this\n"):
            with self.subTest(document=empty), self.assertRaises(NOTES.NotesError):
                NOTES.release_body(empty, "0.2.0")

    def test_cli_fails_without_metadata_or_credentials_and_extracts_only_one_section(self):
        command = ["python3", str(ROOT / "tools/release/notes.py"), "--repo", str(self.root)]
        result = subprocess.run(command + ["body", "--version", "0.2.0"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, self.body)
        result = subprocess.run(command + ["check", "--version", "0.3.0"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        result = subprocess.run(command + ["verify", "--version", "0.2.0", "--github-repository", "example/zals"],
                                env={"PATH": os.environ["PATH"]}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GH_TOKEN", result.stderr)


class ChangelogOwnershipTest(unittest.TestCase):
    def test_release_please_owns_only_the_technical_log(self):
        config = json.loads((ROOT / "release-please-config.json").read_text())
        self.assertEqual(config["release-type"], "simple")
        self.assertEqual(config["packages"]["."]["changelog-path"], NOTES.TECHNICAL)
        self.assertTrue((ROOT / NOTES.TECHNICAL).is_file())
        self.assertEqual((ROOT / NOTES.PUBLIC).read_bytes(), (ROOT / NOTES.EDITOR).read_bytes())


class GitHubReadOnlyTest(unittest.TestCase):
    def test_paginated_evidence_is_not_silently_truncated(self):
        with patch.dict(os.environ, {"GH_TOKEN": "test-token"}):
            github = NOTES.GitHub("example/zals")
        with patch.object(github, "get", side_effect=[[{"number": index} for index in range(100)],
                                                      [{"number": 100}]]) as get:
            self.assertEqual(len(github.pages("/pulls/7/reviews")), 101)
            self.assertEqual(get.call_args_list[1].args[0], "/pulls/7/reviews?per_page=100&page=2")
        with patch.object(github, "get", return_value=[{}] * 100):
            with self.assertRaisesRegex(NOTES.NotesError, "pagination"):
                github.pages("/pulls/7/reviews")

    def test_api_is_read_only_and_network_failure_is_not_approval(self):
        with patch.dict(os.environ, {"GH_TOKEN": "test-token"}):
            github = NOTES.GitHub("example/zals")
        with patch.object(NOTES, "urlopen", side_effect=NOTES.URLError("offline")) as request:
            with self.assertRaisesRegex(NOTES.NotesError, "lookup failed"):
                github.get("/pulls/7")
            self.assertEqual(request.call_args.args[0].get_method(), "GET")
        with patch.dict(os.environ, {"GH_TOKEN": "", "GITHUB_TOKEN": ""}):
            with self.assertRaisesRegex(NOTES.NotesError, "GH_TOKEN"):
                NOTES.GitHub("example/zals")


if __name__ == "__main__":
    unittest.main()
