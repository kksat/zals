# ADR-0003: Pluggable external-process execution

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream shells out to `ansible`, `ansible-config`, `ansible-doc`, `ansible-lint`,
`ansible-playbook`, `ansible-inventory`, `ansible-galaxy`, and container engines.
Reimplementing Ansible's semantics in Zig is infeasible in the near term, but we
do not want the shellouts to become load-bearing architecture that blocks a
future pure-Zig implementation.

## Decision

All external processes go through a **`CommandRunner` interface**. The v1
backend spawns real processes via `std.process.Child`. Every consumer
(`ansible-config`, `ansible-doc`, `ansible-lint`, syntax check) depends on the
interface, never on the process backend directly.

The same principle applies to the other external dependencies:

- `YamlParser` — tree-sitter today ([ADR-0004](0004-yaml-parsing-tree-sitter.md))
- `DocsSource` — `ansible-doc` today ([ADR-0007](0007-module-docs-via-ansible-doc.md))
- `SchemaSource` — bundled snapshot today ([ADR-0006](0006-bundle-schema-snapshot.md))
- `SchemaValidator` — Zig-native subset today ([ADR-0005](0005-json-schema-validation-in-zig.md))

## Consequences

- Tests can substitute fakes for every external dependency, so unit tests do not
  require Ansible to be installed.
- A future pure-Zig implementation replaces one backend without touching
  consumers.
- The interface must be designed around what consumers need, not around the
  process API, to avoid leaking process concerns.