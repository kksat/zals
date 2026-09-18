# ADR-0007: Module documentation via `ansible-doc`

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Hover, completion, and definition all need module documentation: names, options,
types, defaults, choices, and the source file of each module. Upstream gets this
from `ansible-doc`. Reimplementing Ansible's documentation resolution — including
doc fragments, redirects, and collection search paths — is a large effort and
would drift from the installed Ansible version.

Measured on the development machine (ansible-core 2.17.1, 861 modules):

| Command | Time | Size |
| --- | --- | --- |
| `ansible-doc -l --json` | ~0.6 s | catalog |
| `ansible-doc --json <100 modules>` | ~0.74 s | — |
| `ansible-doc --json <all 861>` | ~6.3 s | ~7.7 MB |

`ansible-doc` resolves doc fragments and redirects and reports `doc.filename`,
which is exactly what go-to-definition needs.

## Decision

Use **`ansible-doc --json`** behind a `DocsSource` interface. Batch module names
into single invocations. The catalog comes from `-l --json`; full docs come from
`--json <names>`.

## Consequences

- Documentation always matches the user's installed Ansible, including
  collections.
- We inherit `ansible-doc`'s cost and its failure modes; the loading strategy in
  [ADR-0008](0008-hybrid-docs-loading.md) is designed around the measured
  timings.
- `doc.filename` gives go-to-definition for free
  ([ADR-0009](0009-go-to-definition-target.md)).
- A future `DocsSource` backend can read a prebuilt index without changing
  consumers.