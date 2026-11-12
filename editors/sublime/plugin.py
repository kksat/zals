from __future__ import annotations

import shutil
from typing import Any, Tuple

try:
    import sublime
    from LSP.plugin import AbstractPlugin, register_plugin, unregister_plugin
except ImportError:
    # Allow running AST/syntax tests outside Sublime Text environment
    sublime = None
    AbstractPlugin = object  # type: ignore

    def register_plugin(cls: Any) -> None:
        pass

    def unregister_plugin(cls: Any) -> None:
        pass


class Zals(AbstractPlugin):
    """LSP plugin for zals (Zig Ansible Language Server) in Sublime Text."""

    @classmethod
    def name(cls) -> str:
        return "zals"

    @classmethod
    def can_start(
        cls,
        window: Any,
        initiating_view: Any,
        point: int | None,
        server_score: int,
    ) -> bool:
        # If zals is configured or present in PATH, proceed
        configuration = cls.configuration()
        if not configuration:
            return False

        command = configuration.settings.get("command")
        if isinstance(command, list) and len(command) > 0:
            binary = command[0]
            if shutil.which(binary):
                return True

        if sublime:
            sublime.status_message(
                "LSP-zals: 'zals' executable not found on PATH. "
                "Install it with 'brew install zals' or 'pip install zals'."
            )
        return False


def plugin_loaded() -> None:
    register_plugin(Zals)


def plugin_unloaded() -> None:
    unregister_plugin(Zals)
