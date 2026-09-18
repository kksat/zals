# zals — Zig Ansible Language Server

A reimplementation of the [Ansible Language Server](https://github.com/ansible/vscode-ansible)
(`packages/ansible-language-server`) in [Zig](https://ziglang.org/).

The goal is feature parity with the upstream language server for its core LSP
surface, with a codebase that is easier to embed, faster to start, and free of
the Node.js runtime. New features will be considered after parity is reached.

## Status

M1–M8 skeleton is in place: stdio LSP, YAML subset parser, providers (semantic
tokens, hover, completion, definition, validation), `ansible-doc` catalog, and
bundled JSON-schema snapshots. See [`docs/deviations.md`](docs/deviations.md)
for intentional gaps versus upstream. Design lives in [`docs/DESIGN.md`](docs/DESIGN.md)
and the decision records under [`docs/adr/`](docs/adr/).

## Scope (v1)

Tier 1 — the client-agnostic language server surface:

- Semantic tokens (syntax highlighting)
- Hover (keyword / module / option documentation)
- Completion (+ resolve)
- Go to definition (module source, and variable definitions)
- Find references (variables, within the enclosing role or playbook)
- Validation: `ansible-lint`, `ansible-playbook --syntax-check` fallback, and
  JSON-schema validation of Ansible metadata files

Variable navigation (find-references and variable go-to-definition) is a
post-parity extension; upstream has no counterpart. See
[ADR-0024](docs/adr/0024-variable-go-to-definition.md) and
[ADR-0025](docs/adr/0025-variable-references.md).

Out of scope for v1: the VS Code extension, inventory/metadata notifications,
and execution environments.

## Requirements

- [Zig](https://ziglang.org/download/) **0.15.1** (pinned)
- Ansible (`ansible`, `ansible-config`, `ansible-doc`)
- `ansible-lint` (optional; validation falls back to `ansible-playbook --syntax-check`)

## Build

```sh
make build           # build the server into zig-out/bin/zals
make test            # run unit tests
make run ARGS=--version
```

Or invoke Zig directly:

```sh
zig build
zig build test
```

> **macOS 26 + Xcode 26.5 SDK:** Zig 0.15.1's bundled lld fails to link against
> the SDK's `libSystem.B.tbd` (it lists `arm64e-macos` but not `arm64-macos`),
> producing undefined libc symbols. The `Makefile` works around this by setting
> `DEVELOPER_DIR=/nonexistent`, which makes Zig use its bundled libc stubs. If
> you call `zig build` directly, export that variable first. See
> [ADR-0019](docs/adr/0019-toolchain-build-and-platforms.md).

## Usage

`zals` speaks LSP over stdio:

```sh
zals --stdio
```

Point any LSP client at the binary with `ansible` as the document language.

## License

GPL-3.0-only. See [`LICENSE`](LICENSE).