# ADR-0019: Toolchain, build, and platforms

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Zig is pre-1.0 and breaks compatibility between releases, so the version must be
pinned. The project vendors C (tree-sitter) and needs a schema snapshot at build
time. Target platforms are Linux and macOS first, Windows later.

## Decision

- Pin **Zig 0.15.1** via `minimum_zig_version` in `build.zig.zon`.
- Use `build.zig.zon` for dependencies (tree-sitter) and materialize the schema
  snapshot into `vendor/schemas/` at build time
  ([ADR-0006](0006-bundle-schema-snapshot.md)).
- Target **Linux and macOS first**; Windows later.
- Produce **static binaries where feasible**.

### macOS 26 + Xcode 26.5 SDK workaround

Zig 0.15.1's bundled lld does not match a plain `arm64-macos` request against the
SDK's `libSystem.B.tbd`, which lists `arm64e-macos` but not `arm64-macos`. The
link fails with undefined libc symbols (`_abort`, `_getenv`, ...). Setting
`DEVELOPER_DIR=/nonexistent` makes Zig skip SDK discovery and use its bundled
libc stubs, which link correctly. The `Makefile` sets this automatically on
Darwin. This is safe for a pure-Zig project with vendored C sources.

## Consequences

- Builds are reproducible across machines with the same Zig version.
- The macOS workaround is a local build-environment concern, not a code change;
  it should be revisited when a newer Zig fixes the lld matching.
- Vendoring C means the build needs a C toolchain, which `zig cc` provides.
- Windows support will require revisiting process spawning, path handling, and
  the self-pipe wakeup.