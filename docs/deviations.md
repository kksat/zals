# Known deviations from upstream

`zals` aims for behavioral parity with the upstream Ansible Language Server, not
byte-for-byte parity. This file records intentional differences. Each entry says
what differs, why, and whether it is expected to be permanent.

## Transport and packaging

| # | Deviation | Rationale | Permanent? |
| --- | --- | --- | --- |
| 1 | Speaks LSP over **stdio**, not Node IPC. | `zals` is a standalone binary; Node IPC is unavailable. See [ADR-0001](adr/0001-standalone-stdio-lsp-server.md). | Yes |
| 2 | No VS Code extension integration. | Out of scope for v1. See [ADR-0002](adr/0002-tier-1-feature-scope.md). | Until Tier 2 |
| 3 | `--generate-docs` is not implemented. | Tier 2. See [ADR-0018](adr/0018-cli-and-logging.md). | Until Tier 2 |

## Features

| # | Deviation | Rationale | Permanent? |
| --- | --- | --- | --- |
| 4 | `resync/ansible-inventory` and `update/ansible-metadata` are not implemented. | Tier 2. See [ADR-0016](adr/0016-custom-ansible-messages.md). | Until Tier 2 |
| 5 | Go-to-definition targets the start of the module file. | Simpler and always correct. See [ADR-0009](adr/0009-go-to-definition-target.md). | Maybe |

## Implementation

| # | Deviation | Rationale | Permanent? |
| --- | --- | --- | --- |
| 6 | Validation reconciles cached diagnostics with a **sorted array**, not an interval tree. | Simpler; sufficient for the document sizes involved. See [ADR-0015](adr/0015-validation-behavior.md). | Maybe |
| 7 | Schemas are a **pinned build-time snapshot**, not a 24-hour remote cache. | Reproducibility and offline use. See [ADR-0006](adr/0006-bundle-schema-snapshot.md). | Yes |
| 8 | JSON-schema validation supports a **draft-07 subset**. | The bundled schemas use a bounded keyword set. See [ADR-0005](adr/0005-json-schema-validation-in-zig.md). | Maybe |
| 9 | Schema diagnostics always use the **document root range**. | Matches upstream's observable behavior; avoids mapping schema paths to YAML ranges. See [ADR-0005](adr/0005-json-schema-validation-in-zig.md). | Yes |
| 11 | YAML is parsed by **tree-sitter-yaml** (vendored C) by default, with an indent-based subset parser as fallback. | tree-sitter is the intended backend; the subset parser ships as a safety net. See [ADR-0004](adr/0004-yaml-parsing-tree-sitter.md). | No |
| 12 | Schema snapshot is **committed** under `vendor/schemas/`, not fetched at build. | Offline clones; pin is ansible-lint v25.8.2. See [ADR-0006](adr/0006-bundle-schema-snapshot.md). | Maybe |
| 13 | JSON Schema `pattern` uses a **built-in ECMA-262 subset regex engine**, not a full regex library. | Covers the patterns in the bundled schemas; unsupported constructs are treated as non-matching. See [ADR-0005](adr/0005-json-schema-validation-in-zig.md). | Maybe |
| 14 | Parsing, linting, and schema validation still run on the **main thread**; the pool is used for docs prefetch and cache writes. | Keeps validation synchronous and deterministic; the docs path is the blocking one. See [ADR-0011](adr/0011-threading-topology.md). | Maybe |
| 15 | Docs catalog is loaded on `initialized` (from an on-disk cache when warm); full docs are prefetched in the background and cached. | Implements the hybrid strategy. See [ADR-0008](adr/0008-hybrid-docs-loading.md). | No |

## Adding an entry

When you make a deliberate behavioral choice that differs from upstream, add a
row here and link the ADR that explains it. If the difference is not deliberate,
it is a bug, not a deviation.