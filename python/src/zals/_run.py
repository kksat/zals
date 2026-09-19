"""Locate and execute the bundled zals binary."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def binary_path() -> Path:
    """Return the path to the bundled binary for the current platform."""
    name = "zals.exe" if os.name == "nt" else "zals"
    return Path(__file__).resolve().parent / "bin" / name


def main() -> int:
    """Run the bundled language server, forwarding all arguments and stdio."""
    binary = binary_path()
    if not binary.is_file():
        print(
            f"zals: bundled binary not found at {binary}; "
            "reinstall the zals package for this platform",
            file=sys.stderr,
        )
        return 1

    if os.name != "nt":
        # Replace the wrapper process so stdio and signals go straight to the
        # language server. Wheels do not always preserve the executable bit.
        try:
            binary.chmod(binary.stat().st_mode | 0o111)
        except OSError:
            pass
        os.execv(str(binary), [str(binary), *sys.argv[1:]])

    return subprocess.call([str(binary), *sys.argv[1:]])