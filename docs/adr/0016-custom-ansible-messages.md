# ADR-0016: Custom `ansible/*` messages

- **Status:** Superseded by ADR-0037
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** ADR-0037

## Context

Upstream defines five custom messages beyond standard LSP:

| Message | Direction | Tier |
| --- | --- | --- |
| `ansible/errorMessage` | server → client | 1 |
| `ansible/docsLibraryReady` | server → client | 1 |
| `ansible/refreshConfiguration` | client → server | 1 |
| `resync/ansible-inventory` | client → server | 2 |
| `update/ansible-metadata` | client → server | 2 |

## Decision

Keep the three Tier 1 messages and drop the two Tier 2 messages:

- **`ansible/errorMessage`** — reports an unsupported environment at startup.
- **`ansible/docsLibraryReady`** — signals the docs index is ready.
- **`ansible/refreshConfiguration`** — clears caches and re-reads configuration.

## Consequences

- A client written for upstream ALS behaves identically against `zals` for the
  Tier 1 surface.
- Clients that ignore these messages are unaffected; they are additive.
- `refreshConfiguration` gives users a way to pick up newly installed
  collections without restarting the server.
- Dropping the Tier 2 messages is consistent with the scope decision
  ([ADR-0002](0002-tier-1-feature-scope.md)).