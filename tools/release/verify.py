"""Validate tagged versions and the GitHub-only release asset contract."""

from __future__ import annotations

import argparse
from email.parser import Parser
import json
from pathlib import Path
import re
import tarfile
import tomllib
import xml.etree.ElementTree as ET
import zipfile

# Archive target, Python wheel platform, VS Code platform.
PLATFORMS = (
    ("x86_64-linux", "manylinux_2_17_x86_64", "linux-x64"),
    ("aarch64-linux", "manylinux_2_17_aarch64", "linux-arm64"),
    ("x86_64-macos", "macosx_13_0_x86_64", "darwin-x64"),
    ("aarch64-macos", "macosx_13_0_arm64", "darwin-arm64"),
    ("x86_64-windows", "win_amd64", "win32-x64"),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def tag_version(tag: str) -> str:
    require(re.fullmatch(r"v\d+\.\d+\.\d+", tag) is not None, f"Invalid release tag: {tag}")
    return tag[1:]


def verify_versions(root: Path, tag: str) -> None:
    version = tag_version(tag)
    lock = json.loads((root / "editors/vscode/package-lock.json").read_text())
    versions = {
        "version.txt": (root / "version.txt").read_text().strip(),
        ".release-please-manifest.json": json.loads(
            (root / ".release-please-manifest.json").read_text()
        )["."],
        "python/pyproject.toml": tomllib.loads(
            (root / "python/pyproject.toml").read_text()
        )["project"]["version"],
        "editors/vscode/package.json": json.loads(
            (root / "editors/vscode/package.json").read_text()
        )["version"],
        "editors/vscode/package-lock.json": lock["version"],
        "editors/vscode/package-lock.json root package": lock["packages"][""]["version"],
    }
    for filename, pattern in (
        ("src/main.zig", r'const version = "([^"]+)";'),
        ("build.zig.zon", r'\.version = "([^"]+)"'),
    ):
        match = re.search(pattern, (root / filename).read_text())
        require(match is not None, f"Missing version in {filename}")
        versions[filename] = match[1]
    for filename, actual in versions.items():
        require(actual == version, f"{filename}: expected {version}, got {actual}")


def asset_names(version: str) -> set[str]:
    names = set()
    for target, wheel_platform, vscode_platform in PLATFORMS:
        suffix = "zip" if target.endswith("windows") else "tar.gz"
        names.update((
            f"zals-{version}-{target}.{suffix}",
            f"zals-{version}-py3-none-{wheel_platform}.whl",
            f"zals-{version}-{vscode_platform}.vsix",
        ))
    return names


def verify_assets(directory: Path, tag: str) -> None:
    version = tag_version(tag)
    expected = asset_names(version)
    actual = {p.name for p in directory.iterdir() if p.is_file()} - {"SHA256SUMS"}
    require(actual == expected,
            f"Asset set mismatch: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
    for target, wheel_platform, vscode_platform in PLATFORMS:
        binary_name = "zals.exe" if target.endswith("windows") else "zals"
        if target.endswith("windows"):
            with zipfile.ZipFile(directory / f"zals-{version}-{target}.zip") as archive:
                require(archive.namelist() == [binary_name], f"Unexpected archive files: {target}")
                binary = archive.read(binary_name)
        else:
            with tarfile.open(directory / f"zals-{version}-{target}.tar.gz") as archive:
                members = archive.getmembers()
                require(len(members) == 1 and members[0].name == binary_name
                        and members[0].isfile() and bool(members[0].mode & 0o111),
                        f"Missing executable or unexpected archive files: {target}")
                binary = archive.extractfile(members[0]).read()
        require(bool(binary), f"Empty binary: {target}")

        with zipfile.ZipFile(directory / f"zals-{version}-py3-none-{wheel_platform}.whl") as wheel:
            require(wheel.read(f"zals/bin/{binary_name}") == binary,
                    f"Wheel binary differs from archive: {target}")
            metadata = Parser().parsestr(wheel.read(f"zals-{version}.dist-info/METADATA").decode())
            require(metadata["Name"] == "zals" and metadata["Version"] == version,
                    f"Wrong wheel package metadata: {target}")
            wheel_metadata = Parser().parsestr(wheel.read(f"zals-{version}.dist-info/WHEEL").decode())
            require(wheel_metadata["Tag"] == f"py3-none-{wheel_platform}",
                    f"Wrong wheel platform: {target}")
            require("zals/_run.py" in wheel.namelist(), f"Missing Python wrapper: {target}")

        with zipfile.ZipFile(directory / f"zals-{version}-{vscode_platform}.vsix") as vsix:
            require(vsix.read(f"extension/bin/{binary_name}") == binary,
                    f"VSIX binary differs from archive: {target}")
            package = json.loads(vsix.read("extension/package.json"))
            require(package["version"] == version and package["name"] == "zals"
                    and package["publisher"] == "kksat", f"Wrong VSIX package metadata: {target}")
            manifest = ET.fromstring(vsix.read("extension.vsixmanifest"))
            identity = manifest.find("{*}Metadata/{*}Identity")
            require(identity is not None and identity.get("TargetPlatform") == vscode_platform
                    and identity.get("Version") == version, f"Wrong VSIX platform: {target}")
            require(bool(vsix.read("extension/dist/extension.js")), f"Missing VS Code client: {target}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("versions", "assets"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, default=Path("."))
    args = parser.parse_args()
    if args.check == "versions":
        verify_versions(args.directory, args.tag)
    else:
        verify_assets(args.directory, args.tag)
    print(f"Verified {args.check} for {args.tag}")


if __name__ == "__main__":
    main()
