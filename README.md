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
- Go to implementation (role main task files and concrete variable bindings)
- Find references (variables, roles, task and vars files, collections)
- Validation: `ansible-lint`, `ansible-playbook --syntax-check` fallback, and
  JSON-schema validation of Ansible metadata files

Workspace-wide navigation (post-parity): find-references, definition, and
hover for variables, roles, role parameters, task and vars files, and
collections across the Workspace, plus `workspace/symbol`. Workspace collection
symbols include roles, modules, and plugins, with metadata-defined collection
names across standard, dotted, and nested source layouts. Installed dependencies
remain outside the Workspace symbol set. See
[ADR-0031](docs/adr/0031-workspace-index.md),
[ADR-0032](docs/adr/0032-workspace-wide-navigation.md), and the
[collection member scope guide](docs/workspace-collection-members.md)
([ADR-0038](docs/adr/0038-workspace-collection-members.md)).

Variable navigation (find-references, definition, and implementation) is a
post-parity extension; upstream has no counterpart. Reads and binding keys are
both entry points. Structured-value fields have a separate Workspace-wide
leaf-name group, parsed key targets, and nested argument-spec descriptions
([ADR-0041](docs/adr/0041-field-name-navigation.md)). See the [variable navigation scope guide](docs/variable-navigation.md),
[ADR-0024](docs/adr/0024-variable-go-to-definition.md),
[ADR-0025](docs/adr/0025-variable-references.md), and
[ADR-0036](docs/adr/0036-variable-navigation-from-bindings.md).

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
See [ADR-0029](docs/adr/0029-role-navigation.md). Passed parameter keys navigate
to the called role's selected argument-spec option and concrete bindings, using
the same role context as hover
([ADR-0039](docs/adr/0039-role-parameter-navigation.md)). Nested passed fields
use the full parameter path while keeping references Workspace-wide
([ADR-0042](docs/adr/0042-passed-role-field-navigation.md)).

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
make check           # lint (zig fmt --check) + build + unit tests
make hooks           # install the tracked pre-commit and commit-msg hooks
make build           # build the server into zig-out/bin/zals
make test            # run unit tests
make e2e             # run all stdio E2E suites (requires ansible-core on PATH)
make e2e SUITE=navigation-e2e                 # run one E2E suite
make e2e SUITE=standalone-role-e2e            # repository root is one Role
make zig-test FILE=test/navigation_uris_e2e.zig FILTER='stdio navigation'
make smoke           # run stdio smoke tests, including the latency matrix
make benchmark-operations # generate checked editor-operation latency tables
make run ARGS=--version
```

`make help` lists every target; `make zig ARGS="..."` runs any other Zig
command.

The [navigation E2E suite](test/e2e/README.md) uses a static Ansible Workspace
and an explicitly written location oracle; `make e2e SUITE=navigation-e2e` needs no
Galaxy installation, virtual environment, or Ansible execution. `make e2e`
also runs standalone Role repositories (both YAML extensions, directory-style
defaults/vars, and Role-relative task includes), plus the collection-symbol,
file-URI, unsaved-argument-spec, and
[selected-venv/module-docs](test/selected_venv_e2e.md) suites. The module-docs
suite requires `ansible` and `ansible-doc` from `ansible-core` on PATH; CI uses
Python 3.12 and `ansible-core==2.19.2`. No suite installs collections or executes
playbooks. Unit, E2E, and smoke targets run in separate CI jobs.

[Editor operation benchmarks](docs/performance/README.md) cover navigation,
completion, symbols, tokens and code actions, with Debug/ReleaseSafe example
tables and optional raw JSON samples. `make test` also runs the benchmark's
Python statistics/validation checks using `python3`; `zig build test` runs
only the Zig unit tests.

> **macOS 26 + Xcode 26.5 SDK:** Zig 0.15.1's bundled lld fails to link against
> the SDK's `libSystem.B.tbd` (it lists `arm64e-macos` but not `arm64-macos`),
> producing undefined libc symbols. The `Makefile` works around this by setting
> `DEVELOPER_DIR=/nonexistent`, which makes Zig use its bundled libc stubs. Run
> Zig through `make` (`make help`; `make zig ARGS=...` for anything else). See
> [ADR-0019](docs/adr/0019-toolchain-build-and-platforms.md).

## Usage

`zals` speaks LSP over stdio:

```sh
zals --stdio
```

Point your LSP client at the binary and attach it to Ansible source buffers.
Collections installed directly under the selected venv root or in its
site-packages are supported by navigation, module docs, and discovery; see the
[selected environment guide](docs/selected-venv-collections.md)
([ADR-0037](docs/adr/0037-selected-venv-collections.md)). Navigation uses absolute,
escaped file URIs, anchored to the server process's working directory for
relative filesystem targets
([ADR-0040](docs/adr/0040-navigation-file-uris.md)).
For Neovim, see the [filetype and LSP setup](docs/neovim.md), including
`requirements.yml`, collection metadata, and Jinja templates.

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