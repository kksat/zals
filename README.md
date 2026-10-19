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

You can also install the platform-specific `.whl` downloaded from the GitHub
release page locally.

### Direct download

Download `zals-<version>-<target>.tar.gz` (or `.zip` on Windows) from the
release page and put `zals` on your `PATH`.

### VS Code

Download the `.vsix` matching your VS Code host platform from the release page,
then use **Extensions: Install from VSIX...** or:

```sh
code --install-extension ./zals-0.1.0-<platform>.vsix
```

Each VSIX bundles the matching native binary; no separate server install is
needed. The extension source and development commands are in
[`editors/vscode`](editors/vscode/README.md).

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
to `main`; release-please opens a release PR that updates the changelog and all
server, Python, and VS Code versions in lockstep. Merging that PR creates the
`vX.Y.Z` tag and a GitHub release. See
[ADR-0026](docs/adr/0026-release-process.md).

When release-please creates a release after its release PR is merged, it calls
the **release** workflow with the new tag and publishes to Visual Studio
Marketplace and Open VSX using `VSCE_PAT` and `OVSX_PAT`. Ordinary commits,
unrelated GitHub release events, and tag pushes do not start publishing. Manual
dispatch remains available and defaults to **GitHub-only** packaging. The workflow
builds five native archives, five Python wheels, five platform-specific VSIXs,
and `SHA256SUMS`. PyPI and Homebrew remain explicit manual opt-ins.

To bootstrap or rebuild a release, push the version tag, then run:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0
```

Build and asset verification jobs check out the requested tag, not the moving
branch tip; verification and publishing tools come from the workflow revision. The workflow
rejects mismatched source versions and verifies the complete asset set,
platform metadata, and identical bundled binaries before creating or updating
the GitHub release. Packaging must succeed for every platform before any assets
are published. The initial baseline is `0.1.0`.

GitHub asset publication is idempotent: if all 15 assets and `SHA256SUMS` are
already published with identical bytes, the upload step is skipped and the job
succeeds, including for immutable releases. The check uses GitHub's SHA-256
digests, downloading assets for comparison when a digest is unavailable. API or
download errors are not treated as success. Draft releases still need final
publication; mutable releases can upload missing or changed assets.

The workflow also accepts component-prefixed tags such as `zals-v0.2.0`;
package versions and asset filenames still use `0.2.0`. However, that particular
release was published as immutable with no assets and cannot be repaired by a
retry. An immutable release with missing, changed, or unexpected assets fails
with the affected filenames; use a new release instead. New releases must receive
all assets while still drafts, before publication locks them. Future
release-please tags use `vX.Y.Z` explicitly.

To publish the existing verified GitHub release to PyPI and `kksat/tap` without
rebuilding or replacing its assets:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0 \
  -f publish_existing=true -f publish_pypi=true -f publish_homebrew=true
```

Omit `publish_existing` to build a release and then publish it in one run.
PyPI uses trusted publishing (OIDC) configured for this repository's `release.yml`
workflow; no API token is required. Homebrew uses `HOMEBREW_TAP_TOKEN` to update
`kksat/homebrew-tap` (the repository behind `kksat/tap`), overridable with the
`HOMEBREW_TAP_REPO` repository variable. Each publishing run verifies the GitHub
assets and checksums before uploading the wheels or committing the formula.
The initial GitHub `0.1.0` wheels contain an invalid legacy classifier; PyPI
preparation corrects only that metadata and regenerates wheel `RECORD` hashes.
Bundled binaries, package versions, the release tag, and GitHub assets remain
unchanged. New releases use the corrected source metadata directly.

To publish verified VSIXs to Visual Studio Marketplace and/or Open VSX:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0 \
  -f publish_existing=true -f publish_vscode=true -f publish_openvsx=true
```

Manual runs select each registry independently. Marketplace defaults to Microsoft
Entra ID with GitHub OIDC (no PAT); explicitly selecting `-f vscode_auth=pat`
instead uses `VSCE_PAT`. Automatic release-please publication explicitly selects
PAT mode. Open VSX uses `OVSX_PAT`. Both upload
all five existing platform packages and skip already-published versions on
retry. See [VS Code publishing setup](docs/vscode-publishing.md) for the Azure
managed identity, protected GitHub environment, publisher authorization, and
Open VSX namespace requirements. Already-published version/platform pairs succeed
without replacement; missing targets are uploaded, and real publication errors
still fail. Until setup and a publishing run succeed, install VSIXs from GitHub
as above.

The tap is public, but the formula downloads binaries from the GitHub release.
If this repository is private, Homebrew installation needs access to those
private release assets; publishing the formula does not make the assets public.

The local release contract tests run under `make check` (Python 3.11+). You can
also check a downloaded asset directory with:

```sh
python3 tools/release/verify.py assets --tag v0.1.0 --directory ./release-assets
(cd release-assets && shasum -a 256 -c SHA256SUMS)
```

## License

GPL-3.0-only. See [`LICENSE`](LICENSE).