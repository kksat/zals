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

- Pin **Zig 0.17.1** via `minimum_zig_version` in `build.zig.zon`.
- Use `build.zig.zon` for dependencies (tree-sitter) and materialize the schema
  snapshot into `vendor/schemas/` at build time
  ([ADR-0006](0006-bundle-schema-snapshot.md)).
- Target **Linux and macOS first**; Windows later.
- Produce **static binaries where feasible**.

### macOS 26 + Xcode 26.5 SDK workaround (removed)

Zig 0.15.1's bundled lld did not match a plain `arm64-macos` request against
the SDK's `libSystem.B.tbd`, which lists `arm64e-macos` but not `arm64-macos`.
The link fails with undefined libc symbols (`_abort`, `_getenv`, ...). Until
the 0.17.1 upgrade the `Makefile` set `DEVELOPER_DIR=/nonexistent` on Darwin so
Zig skipped SDK discovery and linked against its bundled libc stubs. Zig
0.17.1 links against the real SDK (`aarch64-macos.13.0`, verified on macOS 26
with Xcode 26.5: plain build, `make check`, `make e2e`, `make smoke`), so the
workaround was removed.

## Consequences

- Builds are reproducible across machines with the same Zig version.
- The macOS `DEVELOPER_DIR` workaround was removed with the 0.17.1 upgrade
  after the SDK link path was verified on hardware; revive it from this ADR if
  a future Zig regresses the lld `arm64e-macos` TBD matching.
- Vendoring C means the build needs a C toolchain, which `zig cc` provides.
- Windows support will require revisiting process spawning, path handling, and
  the self-pipe wakeup.