"""Skip GitHub uploads only when the complete published asset set is identical.

Run after local asset verification and checksum generation. New/draft or mutable
releases still use the normal uploader; immutable releases with missing or changed
assets cannot be repaired. With --require-complete, compare even draft assets and
reject any difference before publication. This check never mutates a GitHub release.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from verify import asset_names, require, tag_version


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return "sha256:" + hashlib.file_digest(source, "sha256").hexdigest()


def github_json(path: str, *, missing_ok: bool = False):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=60)
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Cannot inspect GitHub release: {result.stderr or result.stdout}")
    if result.returncode:
        if missing_ok and isinstance(metadata, dict) and str(metadata.get("status")) == "404":
            return None
        raise RuntimeError(f"Cannot inspect GitHub release: {result.stderr or result.stdout}")
    return metadata


def find_release(repository: str, tag: str):
    metadata = github_json(f"repos/{repository}/releases/tags/{tag}", missing_ok=True)
    if metadata is not None:
        return metadata
    # REST's tag endpoint hides drafts. List authenticated releases so a draft
    # is never confused with an absent release, including on interrupted retries.
    matches = []
    for page in range(1, 32):
        releases = github_json(f"repos/{repository}/releases?per_page=100&page={page}")
        require(isinstance(releases, list), "Expected a GitHub release list")
        matches.extend(item for item in releases if item.get("tag_name") == tag)
        if len(releases) < 100:
            require(len(matches) <= 1, "Multiple releases have the target tag")
            return matches[0] if matches else None
    raise RuntimeError("GitHub releases exceed safe pagination limit")


def already_published(repository: str, tag: str, directory: Path, *, require_complete: bool = False) -> bool:
    expected = asset_names(tag_version(tag)) | {"SHA256SUMS"}
    local = {path.name: path for path in directory.iterdir() if path.is_file()}
    require(set(local) == expected, "Expected all 15 verified assets and SHA256SUMS")
    metadata = find_release(repository, tag)
    if metadata is None:
        require(not require_complete, "Target release is missing; cannot publish")
        return False
    require(metadata.get("tag_name") == tag, "Target release identity is inconsistent")
    if metadata["draft"] and not require_complete:
        return False  # Identical draft assets still need final publication.

    remote = {asset["name"]: asset for asset in metadata["assets"]}
    require(len(remote) == len(metadata["assets"]), "Duplicate GitHub release asset names")
    missing = set(local) - set(remote)
    extra = set(remote) - set(local)
    changed = set()
    with tempfile.TemporaryDirectory() as temporary:
        for name in sorted(set(local) & set(remote)):
            asset = remote[name]
            if asset["size"] != local[name].stat().st_size or asset.get("state", "uploaded") != "uploaded":
                changed.add(name)
                continue
            published_digest = asset.get("digest")
            if not published_digest or not published_digest.startswith("sha256:"):
                # Older releases may lack server-side digests. Compare real bytes
                # through gh, which handles authenticated asset redirects safely.
                download = subprocess.run(
                    ["gh", "release", "download", tag, "--repo", repository,
                     "--pattern", name, "--dir", temporary],
                    capture_output=True, text=True, timeout=120,
                )
                if download.returncode:
                    raise RuntimeError(f"Cannot compare {name}: {download.stderr or download.stdout}")
                published_digest = digest(Path(temporary) / name)
            if published_digest != digest(local[name]):
                changed.add(name)
    if not (missing or extra or changed):
        return not metadata["draft"]
    if require_complete or metadata.get("immutable", False):
        immutable = metadata.get("immutable", False)
        reason = "release is immutable" if immutable else "uploaded assets differ"
        recovery = "Publish a new release instead" if immutable else "Complete the draft uploads before publishing"
        raise ValueError(
            f"Cannot publish {tag}: {reason}; missing={sorted(missing)}, "
            f"changed={sorted(changed)}, extra={sorted(extra)}. "
            f"{recovery}; no assets were modified."
        )
    return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    parser.add_argument("--require-complete", action="store_true",
                        help="Fail unless uploaded assets, including draft assets, exactly match local verified files")
    args = parser.parse_args()
    identical = already_published(args.repository, args.tag, args.directory, require_complete=args.require_complete)
    if identical:
        print(f"{args.tag}: all published assets are identical; skipping upload")
    else:
        print(f"{args.tag}: publication required")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with Path(output).open("a") as stream:
            stream.write(f"already_published={str(identical).lower()}\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
