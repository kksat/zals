#!/usr/bin/env python3
"""Curated release notes: content snapshots, approval evidence, and publication gates.

No model or write-capable GitHub client is used here. The authoring skill writes
prose; this tool binds a reviewed document to the exact product that will ship.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import zipfile


PUBLIC = "CHANGELOG.md"
EDITOR = "editors/vscode/CHANGELOG.md"
TECHNICAL = "TECHNICAL_CHANGELOG.md"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
TAG = re.compile(r"v([0-9]+\.[0-9]+\.[0-9]+)\Z")
SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
METADATA = re.compile(r"docs/releases/v[0-9]+\.[0-9]+\.[0-9]+\.json\Z")
ANNOTATED_VERSIONS = {"src/main.zig", "build.zig.zon", "python/pyproject.toml"}
JSON_VERSIONS = {".release-please-manifest.json", "editors/vscode/package.json",
                 "editors/vscode/package-lock.json"}


class NotesError(ValueError):
    """A missing or inconsistent release contract; fail closed before publication."""


def require(condition, message):
    if not condition:
        raise NotesError(message)


def version_tuple(value):
    require(isinstance(value, str) and VERSION.fullmatch(value), "Expected version X.Y.Z")
    return tuple(map(int, value.split(".")))


def metadata_path(version):
    version_tuple(version)
    return f"docs/releases/v{version}.json"


class Repository:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()

    def git(self, *args, check=True):
        result = subprocess.run(["git", "-C", str(self.directory), *args],
                                capture_output=True)
        if check and result.returncode:
            raise NotesError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
        return result

    def commit(self, ref):
        return self.git("rev-parse", "--verify", "--end-of-options",
                        f"{ref}^{{commit}}").stdout.decode().strip()

    def read(self, ref, path):
        sha = self.commit(ref)
        return self.git("show", f"{sha}:{path}").stdout

    def exists(self, ref, path):
        sha = self.commit(ref)
        return self.git("cat-file", "-e", f"{sha}:{path}", check=False).returncode == 0

    def ancestor(self, older, newer):
        return self.git("merge-base", "--is-ancestor", self.commit(older),
                        self.commit(newer), check=False).returncode == 0

    def previous_tag(self, ref, version):
        limit = version_tuple(version)
        tags = self.git("tag", "--merged", self.commit(ref)).stdout.decode().splitlines()
        candidates = [tag for tag in tags if TAG.fullmatch(tag)
                      and version_tuple(tag[1:]) < limit]
        require(candidates, "No previous release tag found; fetch the full release history")
        return max(candidates, key=lambda tag: version_tuple(tag[1:]))

    def product_digest(self, ref):
        """Hash the full tracked tree except notes and *only* mechanical versions.

        Ordinary objects use their Git content IDs, so large vendored sources do
        not need to be loaded. File modes and names remain part of the snapshot.
        Version-bearing source files are still covered, with just the annotated
        version literal normalized; ignoring entire files would hide real fixes.
        """
        sha = self.commit(ref)
        tree = self.git("ls-tree", "-rz", "--full-tree", sha).stdout
        digest = hashlib.sha256()
        for entry in tree.split(b"\0"):
            if not entry:
                continue
            properties, path_bytes = entry.split(b"\t", 1)
            mode, kind, object_id = properties.split()
            path = path_bytes.decode("utf-8", errors="surrogateescape")
            if path in {PUBLIC, EDITOR, TECHNICAL} or METADATA.fullmatch(path):
                continue
            content_id = object_id
            if path in ANNOTATED_VERSIONS | JSON_VERSIONS | {"version.txt"}:
                require(kind == b"blob", f"Expected ordinary version file: {path}")
                content = self.git("cat-file", "blob", object_id.decode()).stdout
                content_id = hashlib.sha256(normalize_version(path, content)).hexdigest().encode()
            for part in (mode, kind, path_bytes, content_id):
                digest.update(part + b"\0")
        return digest.hexdigest()


def normalize_version(path, content):
    text = content.decode("utf-8")
    if path == "version.txt":
        version_tuple(text.strip())
        return b"<release-version>\n"
    if path in ANNOTATED_VERSIONS:
        pattern = r'(?m)^(.*?\")([0-9]+\.[0-9]+\.[0-9]+)(\"[^\n]*x-release-please-version[^\n]*)$'
        normalized, count = re.subn(pattern, r'\1<release-version>\3', text)
        require(count == 1, f"Expected one annotated version in {path}")
        return normalized.encode()
    document = json.loads(text)
    require(isinstance(document, dict), f"Expected JSON object in {path}")
    if path == ".release-please-manifest.json":
        version_tuple(document.get("."))
        document["."] = "<release-version>"
    else:
        version_tuple(document.get("version"))
        document["version"] = "<release-version>"
        if path.endswith("package-lock.json"):
            root = document.get("packages", {}).get("")
            require(isinstance(root, dict), "Missing root package in extension lockfile")
            version_tuple(root.get("version"))
            root["version"] = "<release-version>"
    return json.dumps(document, sort_keys=True, separators=(",", ":")).encode()


def sections(document):
    """Find release headings outside fenced examples, retaining exact history."""
    result = []
    offset = 0
    fence = None
    for line in document.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker:
            run = marker[1]
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = None
        elif fence is None and line.startswith("## "):
            match = re.match(r"## \[?([0-9]+\.[0-9]+\.[0-9]+)(?:\]|\s|$)", line)
            require(match, "Every level-two changelog heading must identify a release version")
            require(match[1] not in [item[0] for item in result], "Duplicate release heading")
            result.append((match[1], offset))
        offset += len(line)
    require(fence is None, "Unclosed fenced example in changelog")
    require(result, "Changelog has no release sections")
    return result


def release_body(document, version):
    version_tuple(version)
    entries = sections(document)
    for index, (entry_version, start) in enumerate(entries):
        if entry_version == version:
            end = entries[index + 1][1] if index + 1 < len(entries) else len(document)
            body = document[start:end].strip() + "\n"
            visible = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
            visible = re.sub(r"(?m)^#+[^\n]*", "", visible).strip()
            require(visible, f"Empty release notes for {version}")
            require(not re.search(r"\b(?:TODO|TBD|FIXME)\b", visible), "Unresolved release-note placeholder")
            return body
    raise NotesError(f"No public release notes for {version}")


def validate_history(repo, document, version, previous_tag):
    previous = repo.read(previous_tag, PUBLIC).decode()
    old_entries = sections(previous)
    entries = sections(document)
    require(entries[0][0] == version, "The candidate release must be the first changelog section")
    require(old_entries[0][0] == previous_tag[1:], "Previous tag and historical changelog disagree")
    require([item[0] for item in entries[1:]] == [item[0] for item in old_entries],
            "Published release sections must be retained unchanged")
    require(document[:entries[0][1]] == previous[:old_entries[0][1]],
            "Retain the existing changelog preamble")
    require(document[entries[1][1]:] == previous[old_entries[0][1]:],
            "Published notes are immutable; put corrections in the next release")
    return release_body(document, version)


def prepare(repo, version, previous_tag, candidate):
    version_tuple(version)
    require(TAG.fullmatch(previous_tag), "Expected previous release tag vX.Y.Z")
    candidate = repo.commit(candidate)
    require(repo.previous_tag(candidate, version) == previous_tag,
            "Previous tag is not the latest reachable release before the candidate version")
    document = (repo.directory / PUBLIC).read_text()
    body = validate_history(repo, document, version, previous_tag)
    metadata = {"schema": 1, "version": version, "previous_tag": previous_tag,
                "candidate": candidate, "product_digest": repo.product_digest(candidate),
                "notes_sha256": hashlib.sha256(body.encode()).hexdigest()}
    editor = repo.directory / EDITOR
    editor.parent.mkdir(parents=True, exist_ok=True)
    editor.write_text(document)
    destination = repo.directory / metadata_path(version)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def check(repo, ref, version=None):
    ref = repo.commit(ref)
    version = version or repo.read(ref, "version.txt").decode().strip()
    path = metadata_path(version)
    metadata = json.loads(repo.read(ref, path))
    expected = {"schema", "version", "previous_tag", "candidate", "product_digest", "notes_sha256"}
    require(isinstance(metadata, dict) and set(metadata) == expected, "Invalid coverage metadata fields")
    require(type(metadata["schema"]) is int and metadata["schema"] == 1, "Unsupported coverage schema")
    require(metadata["version"] == version, "Coverage version does not match release")
    require(isinstance(metadata["candidate"], str) and SHA.fullmatch(metadata["candidate"]),
            "Coverage candidate must be a full commit SHA")
    for field in ("product_digest", "notes_sha256"):
        require(isinstance(metadata[field], str) and DIGEST.fullmatch(metadata[field]), f"Invalid {field}")
    previous_tag = metadata["previous_tag"]
    require(isinstance(previous_tag, str) and TAG.fullmatch(previous_tag), "Invalid previous release tag")
    require(repo.previous_tag(ref, version) == previous_tag, "Coverage uses an outdated previous release")
    require(repo.ancestor(previous_tag, metadata["candidate"]), "Candidate does not descend from previous release")
    require(repo.ancestor(metadata["candidate"], ref), "Coverage candidate is not an ancestor of release")
    digest = repo.product_digest(metadata["candidate"])
    require(digest == metadata["product_digest"], "Recorded candidate digest is incorrect")
    require(digest == repo.product_digest(ref), "Release notes are stale: product changed after the candidate")
    public = repo.read(ref, PUBLIC)
    require(repo.read(ref, EDITOR) == public, "Root and extension changelogs differ")
    body = validate_history(repo, public.decode(), version, previous_tag)
    require(hashlib.sha256(body.encode()).hexdigest() == metadata["notes_sha256"],
            "Release prose changed without refreshed coverage metadata")
    return body, metadata


class GitHub:
    """Read-only REST access; API failures never turn into a passing gate."""

    def __init__(self, repository):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid GitHub repository")
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        require(token, "GH_TOKEN is required to verify release-note approval")
        base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        require(base.startswith("https://"), "GitHub API must use HTTPS")
        self.base = f"{base}/repos/{repository}"
        self.repository = repository
        self.token = token

    def get(self, path):
        request = Request(self.base + path, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "zals-release-notes"})
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            raise NotesError(f"GitHub approval lookup failed: HTTP {error.code} ({path})") from error
        except URLError as error:
            raise NotesError(f"GitHub approval lookup failed: {error.reason}") from error

    def pages(self, path):
        result = []
        for page in range(1, 32):
            items = self.get(f"{path}?per_page=100&page={page}")
            require(isinstance(items, list), "Expected paginated GitHub response")
            result.extend(items)
            if len(items) < 100:
                return result
        raise NotesError("GitHub response exceeds safe pagination limit")


def verify_approval(repo, ref, version, github):
    body, metadata = check(repo, ref, version)
    path = metadata_path(metadata["version"])
    # First-parent history finds the merge on main, not an unmerged side-branch
    # commit. Later unauthorized prose edits become a new provenance candidate.
    provenance = repo.git("log", "--first-parent", "-1", "--format=%H", repo.commit(ref),
                          "--", PUBLIC, EDITOR, path).stdout.decode().strip()
    require(provenance, "Cannot locate the notes merge")
    candidates = github.pages(f"/commits/{provenance}/pulls")
    matching = []
    for candidate in candidates:
        pr = github.get(f"/pulls/{int(candidate['number'])}")
        if (pr.get("merged") is True and pr.get("merge_commit_sha") == provenance
                and pr.get("base", {}).get("ref") == "main"
                and pr.get("base", {}).get("repo", {}).get("full_name", "").lower()
                == github.repository.lower()):
            matching.append(pr)
    require(len(matching) == 1, "Notes must come from one merged notes-only PR targeting main")
    pr = matching[0]
    number = int(pr["number"])
    files = github.pages(f"/pulls/{number}/files")
    allowed = {PUBLIC, EDITOR, path}
    filenames = {item["filename"] for item in files}
    require(len(files) == pr.get("changed_files") and len(filenames) == len(files)
            and filenames in (allowed, {path}),
            "Notes PR may change only this release's metadata and, together, both public changelogs")
    head = pr.get("head", {}).get("sha")
    require(isinstance(head, str) and SHA.fullmatch(head), "Notes PR has no valid final head")
    reviewed_blobs = {}
    for item in files:
        require(item.get("status") in {"added", "modified"} and not item.get("previous_filename"),
                "Notes PR must not rename or remove files")
        reviewed_blobs[item["filename"]] = item.get("sha")
    for filename in allowed:
        # Coverage-only refreshes still approve the exact existing prose. Query
        # its blob at the approved head, not at a moving main branch revision.
        if filename not in reviewed_blobs:
            reviewed_blobs[filename] = github.get(f"/contents/{filename}?ref={head}").get("sha")
        blob = repo.git("rev-parse", f"{repo.commit(ref)}:{filename}").stdout.decode().strip()
        require(blob == reviewed_blobs[filename], "Released notes differ from the reviewed PR head")
    reviews = github.pages(f"/pulls/{number}/reviews")
    latest = {}
    for review in reviews:
        login = review.get("user", {}).get("login")
        state = review.get("state")
        if login and state in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            latest[login.lower()] = review
    require(not any(review["state"] == "CHANGES_REQUESTED" for review in latest.values()),
            "Notes PR still has an outstanding change request")
    author = pr.get("user", {}).get("login", "").lower()
    require(any(login != author and review["state"] == "APPROVED"
                and review.get("user", {}).get("type") == "User"
                and review.get("commit_id") == head
                for login, review in latest.items()),
            "Notes PR requires another reviewer's approval of its final head")
    previous = github.get(f"/releases/tags/{metadata['previous_tag']}")
    require(previous.get("tag_name") == metadata["previous_tag"] and not previous.get("draft")
            and previous.get("published_at"), "Previous tag is not a published GitHub release")
    return body


def retry(repo, tag, github):
    require(TAG.fullmatch(tag), "Expected release tag vX.Y.Z")
    release = github.get(f"/releases/tags/{tag}")
    require(release.get("tag_name") == tag and not release.get("draft") and release.get("published_at"),
            "Publication retries require an already-published GitHub release")
    if repo.exists(tag, metadata_path(tag[1:])):
        body, _ = check(repo, tag, tag[1:])
        require((release.get("body") or "").strip() == body.strip(),
                "Published release prose differs from the immutable tagged notes")
    # Legacy releases have no coverage metadata. Their existing assets and prose
    # are reused unchanged, rather than inventing retrospective approval.


def packages(repo, tag, directory):
    """Check embedded notes; verify.py separately validates the exact asset set."""
    require(TAG.fullmatch(tag), "Expected release tag vX.Y.Z")
    check(repo, tag, tag[1:])
    expected = repo.read(tag, PUBLIC)
    extensions = sorted(Path(directory).glob("*.vsix"))
    require(extensions, "No VSIX packages to verify")
    for extension in extensions:
        with zipfile.ZipFile(extension) as archive:
            require(archive.namelist().count("extension/CHANGELOG.md") == 1,
                    f"Missing or duplicate extension changelog: {extension.name}")
            require(archive.read("extension/CHANGELOG.md") == expected,
                    f"Packaged changelog differs from approved notes: {extension.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Git repository (default: current directory)")
    commands = parser.add_subparsers(dest="command", required=True)
    author = commands.add_parser("prepare", help="Stamp working prose and synchronize editor copy")
    author.add_argument("--version", required=True)
    author.add_argument("--previous-tag", required=True)
    author.add_argument("--candidate", required=True)
    for name in ("check", "verify", "body"):
        command = commands.add_parser(name)
        command.add_argument("--ref", default="HEAD")
        command.add_argument("--version")
        if name == "verify":
            command.add_argument("--github-repository", required=True)
    command = commands.add_parser("retry", help="Validate an immutable existing-release retry")
    command.add_argument("--tag", required=True)
    command.add_argument("--github-repository", required=True)
    command = commands.add_parser("packages", help="Verify approved notes embedded in VSIX packages")
    command.add_argument("--tag", required=True)
    command.add_argument("--directory", required=True)
    args = parser.parse_args()
    repo = Repository(args.repo)
    try:
        if args.command == "prepare":
            print(json.dumps(prepare(repo, args.version, args.previous_tag, args.candidate), indent=2))
        elif args.command == "check":
            check(repo, args.ref, args.version)
            print("Release notes match the candidate", file=sys.stderr)
        elif args.command == "verify":
            print(verify_approval(repo, args.ref, args.version, GitHub(args.github_repository)), end="")
        elif args.command == "body":
            version = args.version or repo.read(args.ref, "version.txt").decode().strip()
            print(release_body(repo.read(args.ref, PUBLIC).decode(), version), end="")
        elif args.command == "retry":
            retry(repo, args.tag, GitHub(args.github_repository))
        elif args.command == "packages":
            packages(repo, args.tag, args.directory)
    except (NotesError, OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError,
            zipfile.BadZipFile) as error:
        print(f"Release notes: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
