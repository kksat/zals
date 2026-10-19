"""Skip GitHub uploads only when the complete published asset set is identical.

Run after local asset verification and checksum generation. New/draft or mutable
releases still use the normal uploader; immutable releases with missing or changed
assets cannot be repaired. This check never mutates a GitHub release.
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


def already_published(repository: str, tag: str, directory: Path) -> bool:
    expected = asset_names(tag_version(tag)) | {"SHA256SUMS"}
    local = {path.name: path for path in directory.iterdir() if path.is_file()}
    require(set(local) == expected, "Expected all 15 verified assets and SHA256SUMS")
    result = subprocess.run(
        ["gh", "api", f"repos/{repository}/releases/tags/{tag}"],
        capture_output=True, text=True, timeout=60,
    )
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Cannot inspect GitHub release: {result.stderr or result.stdout}")
    if result.returncode:
        if metadata.get("status") == "404":
            return False
        raise RuntimeError(f"Cannot inspect GitHub release: {result.stderr or result.stdout}")
    if metadata["draft"]:
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
        return True
    if metadata.get("immutable", False):
        raise ValueError(
            f"Cannot publish {tag}: release is immutable; missing={sorted(missing)}, "
            f"changed={sorted(changed)}, extra={sorted(extra)}. "
            "Publish a new release instead; no assets were modified."
        )
    return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    args = parser.parse_args()
    identical = already_published(args.repository, args.tag, args.directory)
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
