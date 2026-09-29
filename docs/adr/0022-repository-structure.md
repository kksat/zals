# ADR-0022: Repository structure

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

The server spans several concerns: protocol handling, feature providers, shared
services, YAML parsing, process execution, and workspace state. The structure
should make dependencies obvious and keep the pluggable seams
([ADR-0003](0003-pluggable-external-process-execution.md)) visible.

## Decision

Use a **layer-first** layout:

```
src/
  lsp/          JSON-RPC framing, message types, capabilities, dispatch
  providers/    one module per LSP feature
  services/     docs library, schema cache/service/validator, validation manager, config
  yaml/         parser interface, tree-sitter backend, DOM, path utilities
  exec/         command-runner interface and POSIX backend
  workspace/    document store, multi-root contexts, settings
  cli.zig       argument parsing
  root.zig      library root
  main.zig      CLI entry point
vendor/         vendored C (tree-sitter) and the schema snapshot
test/           ported fixtures and unit tests
tools/differential/  dev-only parity harness
docs/           DESIGN.md, deviations.md, adr/
```

Dependencies point downward: `providers` may use `services`, `yaml`, `exec`, and
`workspace`; `services` may use `yaml`, `exec`, and `workspace`; lower layers do
not depend on higher ones.

## Consequences

- The pluggable seams are visible as directories and interfaces.
- Adding a provider is a local change in `providers/`.
- Layer-first means a feature's code is spread across directories; this is
  acceptable because the layers are small and the dependency direction is clear.
- `tools/differential/` is isolated so it never becomes a runtime dependency.
- The VS Code extension lives at `editors/vscode`, outside this tree
  ([ADR-0038](0038-vscode-extension-in-this-repository.md)).