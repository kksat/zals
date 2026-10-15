# ADR-0026: Release process

- **Status:** Accepted
- **Date:** 2026-09-19
- **Supersedes:** —
- **Superseded by:** —

## Context

The project needs a repeatable way to cut releases, tag them, and publish
installable binaries. The version is currently hard-coded in `src/main.zig` and
`build.zig.zon`, and there is no CI. Target platforms are Linux, macOS, and
Windows ([ADR-0019](0019-toolchain-build-and-platforms.md)); macOS and Linux
users expect a Homebrew path.

Hand-maintaining versions, tags, changelogs, and checksums is error-prone and
easy to forget.

## Decision

Use **Google release-please** to drive releases from
[Conventional Commits](https://www.conventionalcommits.org/):

- `.github/workflows/release-please.yml` runs on every push to `main`. It opens
  (or updates) a release PR that bumps the version, updates `CHANGELOG.md`, and
  rewrites the version in `src/main.zig`, `build.zig.zon`, and
  `python/pyproject.toml` via the generic updater (`x-release-please-version`
  annotations), plus the VS Code manifest and lockfile via JSON updaters.
- Merging the release PR creates the `vX.Y.Z` tag and a GitHub release.
- `.github/workflows/release.yml` runs when a release is published. It
  cross-compiles `x86_64`/`aarch64` Linux, `x86_64`/`aarch64` macOS, and
  `x86_64` Windows binaries from a single Linux runner (Zig cross-compiles),
  packages them as `zals-<version>-<target>.tar.gz` (`.zip` on Windows).
  Linux binaries use static musl so the Python wrapper needs no newer glibc;
  macOS binaries target macOS 13, matching the wheel tags.
- The same workflow builds the **`zals` Python package** as five wheels. Each
  wheel bundles the matching prebuilt binary and exposes the `zals` console
  script. Wheels are tagged `py3-none-<platform>`
  (`manylinux_2_17_{x86_64,aarch64}`, `macosx_13_0_{x86_64,arm64}`, `win_amd64`).
  The wrapper source lives in `python/`; `python/setup.py` copies the binary
  from `ZALS_BINARY` and overrides the platform tag from `ZALS_PLATFORM_TAG`.
- The VS Code client lives in `editors/vscode`. Five platform-specific VSIXs
  (`linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`, `win32-x64`) each
  bundle the matching binary and the compiled language client. Packaging uses
  the locked `@vscode/vsce` dependency and Node 22 for TypeScript unit tests.
- Every job checks out the requested tag. A validation job checks that all
  source versions match it. Publication waits for every binary, wheel, and
  VSIX, verifies the 15-asset contract and matching bundled binary bytes,
  and attaches all assets plus `SHA256SUMS` to GitHub.
- Packaging defaults to **GitHub only**. Manual dispatch inputs
  `publish_pypi`, `publish_homebrew`, `publish_vscode`, and `publish_openvsx`
  explicitly opt into external publishing; credentials alone never enable it.
- `publish_existing` skips rebuilding and reuses the existing GitHub release.
  Publication checks all 15 assets and `SHA256SUMS` before distributing them.
  PyPI uses OIDC trusted publishing configured for `release.yml`, uploading all
  five wheels. Existing files are skipped to make retries safe.
- Marketplace and Open VSX upload all five verified VSIXs without rebuilding or
  modifying them. Both use locked npm clients from the workflow revision and
  skip duplicate versions to support partial-publication retries. Marketplace
  follows Microsoft's secure automated publishing approach: GitHub OIDC
  federates to a user-assigned Azure managed identity via `azure/login`, then
  `vsce publish --azure-credential` uses the Azure CLI session. Its job grants
  `id-token: write` at job scope and uses the protected `vscode-marketplace` environment.
  An explicit `vscode_auth=pat` option instead selects an isolated Marketplace
  job using `VSCE_PAT`, with no Azure setup or OIDC permission. Entra remains the
  default; missing identity configuration never silently falls back to a PAT.
  Both PAT secrets are scoped only to credential check/upload steps; Open VSX
  uses `OVSX_PAT`.
  Registries are independent; a failure does not roll back another registry.
  See [setup instructions](../vscode-publishing.md) for federation and publisher
  authorization.
- Homebrew renders `Formula/zals.rb` from the workflow revision's template
  and the tagged release's verified archive SHA-256s, then commits it to `kksat/homebrew-tap` (Homebrew's
  `kksat/tap`). `HOMEBREW_TAP_TOKEN` is required; `HOMEBREW_TAP_REPO` can override
  the repository. An already-current formula is a no-op.

The current baseline is **0.1.0**: `version.txt`,
`.release-please-manifest.json`, `src/main.zig`, `build.zig.zon`, and
`python/pyproject.toml`, `editors/vscode/package.json`, and the extension
lockfile all read `0.1.0`. The initial `v0.1.0` tag is pushed once by hand,
then the release workflow is dispatched with that tag; subsequent releases
flow through release-please.

## Consequences

- Versions, tags, and changelogs are derived from commit messages, so the
  release PR is the single review point.
- All five binaries build on one runner, which keeps the matrix small and cheap.
- Windows support required making the transport, writer, logging, and cache
  directory portable (`std.fs.File` instead of raw POSIX fds,
  `std.process.getEnvVarOwned` instead of `std.posix.getenv`).
- External publication is opt-in and independent for each registry.
  Existing verified GitHub assets can be published without moving a tag or
  replacing assets. VSIXs can still be installed locally.
- Marketplace's default Entra mode stores no long-lived PAT/client secret. It
  requires one-time Azure federation and Marketplace identity authorization,
  plus GitHub environment branch restrictions. The explicitly selected PAT mode
  is a transitional alternative, since Microsoft is retiring global Azure
  DevOps PATs. Open VSX requires namespace authorization and a repository token
  secret.
- A public tap does not expose private GitHub release binaries; if the source
  repository remains private, installing the formula needs release access.
- The Python wrapper and VS Code client do not reimplement the server; they
  locate and execute the bundled binary.
- Release contract tests run locally in `make check` using Python 3.11+.
- A manually dispatched workflow cannot accidentally package the branch tip
  under an older tag's filename.