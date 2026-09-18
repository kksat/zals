# ADR-0018: CLI and logging

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream's CLI supports `--version` and `--generate-docs <file>`, and logs
through the LSP connection. Because `zals` speaks stdio, stdout is reserved for
the protocol, so logs cannot go there. LSP clients often hide a server's stderr,
which makes debugging a launched server hard.

## Decision

Support these flags:

| Flag | Meaning |
| --- | --- |
| `--stdio` | Communicate over stdio (default) |
| `--log-file <path>` | Write server logs to a file |
| `--log-level <level>` | `error` \| `warn` \| `info` \| `debug` |
| `--version` | Print version and exit |
| `-h`, `--help` | Print help and exit |

Logging behavior:

- Logs go to **stderr** by default, and to `--log-file` when given.
- Important messages are mirrored to the client via `window/logMessage` and
  `window/showMessage`.

`--generate-docs` is dropped (Tier 2).

## Consequences

- `--log-file` makes a client-launched server debuggable even when stderr is
  swallowed.
- stdout stays clean for the protocol.
- No config file is needed for v1; flags and LSP settings cover the cases.
- Dropping `--generate-docs` is consistent with the scope decision
  ([ADR-0002](0002-tier-1-feature-scope.md)).