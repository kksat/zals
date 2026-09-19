"""Build hooks for the zals Python wrapper.

The wrapper is pure Python but ships a prebuilt, platform-specific binary, so
the wheel must be tagged for the target platform. The binary is taken from the
``ZALS_BINARY`` environment variable and the platform tag from
``ZALS_PLATFORM_TAG``; both are set by the release workflow.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from setuptools import Distribution, setup
from setuptools.command.bdist_wheel import bdist_wheel
from setuptools.command.build_py import build_py


class BinaryDistribution(Distribution):
    """Mark the distribution as platform-specific despite having no C extensions."""

    def has_ext_modules(self) -> bool:
        return True


class BuildPy(build_py):
    """Copy the compiled binary into the package before the wheel is built."""

    def run(self) -> None:
        super().run()
        binary = os.environ.get("ZALS_BINARY")
        if not binary:
            raise SystemExit(
                "ZALS_BINARY must point at the compiled zals binary "
                "(set by the release workflow)"
            )
        source = Path(binary)
        if not source.is_file():
            raise SystemExit(f"ZALS_BINARY does not exist: {source}")
        dest_dir = Path(self.build_lib) / "zals" / "bin"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / source.name
        shutil.copy2(source, dest)
        dest.chmod(0o755)


class BdistWheel(bdist_wheel):
    """Force a platform-specific wheel and allow overriding the platform tag."""

    def finalize_options(self) -> None:
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self) -> tuple[str, str, str]:
        _, _, plat = super().get_tag()
        plat = os.environ.get("ZALS_PLATFORM_TAG", plat)
        return "py3", "none", plat


setup(distclass=BinaryDistribution, cmdclass={"build_py": BuildPy, "bdist_wheel": BdistWheel})