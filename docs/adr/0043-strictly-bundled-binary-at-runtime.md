# ADR-0043: Strictly bundled binary at runtime

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** —
- **Superseded by:** —

## Context

LSP extensions often provide an escape hatch — an environment variable
(`ZALS_PATH`), a custom setting (`ansible.server.path`), or a `PATH` lookup —
to override the bundled executable. Allowing overrides can lead to version skew
where the running server does not match the extension's bundled version or its
contributed settings.

## Decision

The extension strictly launches `<extensionPath>/bin/zals` (or `bin/zals.exe` on
Windows). It provides no environment variable, setting, or `PATH` fallback.

## Consequences

- The running server is always the exact binary packaged with that extension
  version ([ADR-0031](0031-vscode-extension-bundles-zals.md)).
- For local development, the extension build task copies `zig-out/bin/zals` into
  `editors/vscode/bin/zals`.
- If the binary is missing or cannot be executed (e.g. wrong permissions), the
  extension fails to activate with an error notification.