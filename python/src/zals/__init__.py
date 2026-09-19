"""Thin Python wrapper around the zals language server binary.

The package ships a prebuilt ``zals`` binary for the current platform and
exposes it as the ``zals`` console script. It is not a reimplementation: the
wrapper only locates and executes the bundled binary.
"""

from __future__ import annotations

__all__ = ["main"]

from ._run import main