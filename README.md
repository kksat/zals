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
- Go to definition (module source, variable definitions, and roles)
- Go to implementation (role main task files)
- Find references (variables, within the enclosing role or playbook)
- Validation: `ansible-lint`, `ansible-playbook --syntax-check` fallback, and
  JSON-schema validation of Ansible metadata files

Variable navigation (find-references and variable go-to-definition) is a
post-parity extension; upstream has no counterpart. See
[ADR-0024](docs/adr/0024-variable-go-to-definition.md) and
[ADR-0025](docs/adr/0025-variable-references.md).

Document symbols (`textDocument/documentSymbol`) are a second post-parity
extension: a semantic outline for playbooks, task and handler files, variable
files, and role metadata. See [ADR-0027](docs/adr/0027-document-symbols.md).

Debug code actions (`textDocument/codeAction`) are a third post-parity
extension: add a `debug` task for the variable under the cursor, or remove the
debug task the cursor is inside. See
[ADR-0028](docs/adr/0028-debug-code-actions.md).

Role navigation is a fourth post-parity extension: go-to-definition on a role
reference opens its argument specs, metadata, or main task file, and
go-to-implementation (`textDocument/implementation`) opens its main task file.
See [ADR-0029](docs/adr/0029-role-navigation.md).

Extract-tasks code actions are a fifth post-parity extension: move the task(s)
under the cursor or selection into a new sibling `taskN.yml` and replace them
with `include_tasks` or `import_tasks`. See
[ADR-0030](docs/adr/0030-extract-tasks-code-actions.md).

Out of scope for v1: the VS Code extension, inventory/metadata notifications,
and execution environments.

## Requirements

- [Zig](https://ziglang.org/download/) **0.15.1** (pinned)
- Ansible (`ansible`, `ansible-config`, `ansible-doc`)
- `ansible-lint` (optional; validation falls back to `ansible-playbook --syntax-check`)

## Install

Prebuilt binaries for Linux, macOS, and Windows are attached to every
[release](https://github.com/kksat/zals/releases).

### Homebrew (macOS and Linux)

```sh
brew tap kksat/tap
brew install zals
```

### pip (Linux, macOS, and Windows)

The [`zals`](https://pypi.org/project/zals/) package is a thin wrapper that
bundles the binary for your platform:

```sh
pip install zals
zals --version
```

### Direct download

Download `zals-<version>-<target>.tar.gz` (or `.zip` on Windows) from the
release page and put `zals` on your `PATH`.

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

### Editor Integrations

* **Helix**: See [`docs/editors/helix.md`](docs/editors/helix.md) or [`editors/helix`](editors/helix/) for `languages.toml` configuration.


## Releasing

Releases are driven by [release-please](https://github.com/googleapis/release-please)
from [Conventional Commits](https://www.conventionalcommits.org/). Push commits
to `main`; release-please opens a release PR that bumps the version, updates
`CHANGELOG.md`, and rewrites the version in `src/main.zig` and `build.zig.zon`.
Merging that PR creates the `vX.Y.Z` tag and a GitHub release, which triggers the
release workflow to build and attach the Linux, macOS, and Windows binaries, to
publish the `zals` Python package to PyPI, and to update the Homebrew tap. See
[ADR-0026](docs/adr/0026-release-process.md).

To (re)build assets for an existing tag, run the **release** workflow manually
and pass the tag (for example `v1.0.0`). The current baseline is `1.0.0`, so the
initial `v1.0.0` release is bootstrapped this way; later releases flow through
release-please.

Publishing the Homebrew formula requires a `HOMEBREW_TAP_TOKEN` secret with
write access to the tap repository (default `kksat/homebrew-tap`, overridable
with the `HOMEBREW_TAP_REPO` repository variable). Without it, the release still
succeeds and the formula is only rendered in the workflow log.

Publishing to PyPI uses [trusted
publishing](https://docs.pypi.org/trusted-publishers/): configure a trusted
publisher for this repository and the `release.yml` workflow. To use an API
token instead, add `password: ${{ secrets.PYPI_API_TOKEN }}` to the publish step
in `.github/workflows/release.yml`.

## License

GPL-3.0-only. See [`LICENSE`](LICENSE).