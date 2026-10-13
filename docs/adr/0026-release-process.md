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
  annotations).
- Merging the release PR creates the `vX.Y.Z` tag and a GitHub release.
- `.github/workflows/release.yml` runs when a release is published. It
  cross-compiles `x86_64`/`aarch64` Linux, `x86_64`/`aarch64` macOS, and
  `x86_64` Windows binaries from a single Linux runner (Zig cross-compiles),
  packages them as `zals-<version>-<target>.tar.gz` (`.zip` on Windows), and
  attaches them to the release.
- The same workflow renders `Formula/zals.rb` with the release version and the
  archive SHA-256s and pushes it to the Homebrew tap
  (`kksat/homebrew-tap` by default, overridable with the
  `HOMEBREW_TAP_REPO` repository variable). The push is skipped when the
  `HOMEBREW_TAP_TOKEN` secret is absent.
- The same workflow also builds and publishes the **`zals` Python package** to
  PyPI. The package is a thin wrapper: each wheel bundles the prebuilt binary
  for one platform and exposes it as the `zals` console script. Wheels are
  tagged `py3-none-<platform>` (`manylinux_2_17_{x86_64,aarch64}`,
  `macosx_13_0_{x86_64,arm64}`, `win_amd64`) and published with PyPI trusted
  publishing (OIDC). The wrapper source lives in `python/`; `python/setup.py`
  copies the binary from `ZALS_BINARY` and overrides the wheel platform tag from
  `ZALS_PLATFORM_TAG`.

The current baseline is **0.1.0**: `version.txt`,
`.release-please-manifest.json`, `src/main.zig`, `build.zig.zon`, and
`python/pyproject.toml` all read `0.1.0`. The initial `v0.1.0` tag is created
once by hand (or by running the release workflow manually); subsequent releases
flow through release-please.

## Consequences

- Versions, tags, and changelogs are derived from commit messages, so the
  release PR is the single review point.
- All five binaries build on one runner, which keeps the matrix small and cheap.
- Windows support required making the transport, writer, logging, and cache
  directory portable (`std.fs.File` instead of raw POSIX fds,
  `std.process.getEnvVarOwned` instead of `std.posix.getenv`).
- Homebrew publishing depends on a `HOMEBREW_TAP_TOKEN` secret; without it the
  formula is rendered but not pushed, and the release still succeeds.
- The formula template lives in this repo; the tap holds the rendered copy.
- PyPI publishing depends on a trusted publisher configured for this repository
  and the `release.yml` workflow. An API token can be used instead by adding
  `password: ${{ secrets.PYPI_API_TOKEN }}` to the publish step.
- The Python wrapper adds no runtime dependencies and does not reimplement the
  server; it only locates and executes the bundled binary.