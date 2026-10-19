# Agent notes

## Build

Run Zig through `make` (`make help`); it carries the macOS SDK link workaround ([ADR-0019](docs/adr/0019-toolchain-build-and-platforms.md)). Use `make zig ARGS="..."` for any Zig command without a target.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/). Releases are derived from these messages ([ADR-0026](docs/adr/0026-release-process.md)).

After making changes, run `make check` and commit each completed logical change separately. Each commit must have one reason to change and be reviewable on its own.

## Release notes

For release-note authoring, see [the workflow](docs/release-notes.md). The human may invoke `/skill:release-notes`; it is human-only, not an automatic step for coding tasks.
