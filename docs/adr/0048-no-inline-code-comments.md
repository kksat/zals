# ADR-0048: No inline code comments

- **Status:** Accepted
- **Date:** 2026-11-21
- **Supersedes:** —
- **Superseded by:** —

## Context

A full audit of the repository found 1,913 comment lines across 141 files.
Nearly all of them fell into four categories:

- **Tautology** — restates what the code already says (`// Tests.`, `// consume
  '['`). The comment adds a second, divergent copy of the code that must be
  maintained by hand.
- **Excuse** — justifies a hacky or limited implementation ("workaround", "for
  now", "upstream does X"). The comment is what lets the hack survive review;
  deleting it without an issue would hide the debt, so each excuse becomes a
  tracked issue to fix the implementation.
- **Stale** — describes code, names, or behavior that no longer exists. Comments
  rot because nothing checks them.
- **Decision record** — a non-obvious *why*: an invariant, ordering constraint,
  protocol requirement, or security property. These have value, but the value
  belongs in a durable, reviewable artifact, not in a medium that cannot be
  tested, linked, or superseded.

Doc comments (`///`, `//!`) showed the same pattern: the useful ones restate
ADR content, the rest restate field names.

## Decision

**Inline comments are banned in code.** This covers Zig (`//`, `///`, `//!`),
Python (`#`), shell, Make, and TypeScript under `src/`, `test/` (excluding
`test/fixtures/`), `tools/`, `python/`, `editors/vscode/src`, `editors/vscode/test`,
`build.zig`, `Makefile`, and `.githooks/`.

- Code must speak for itself: rename, restructure, or split rather than
  narrate.
- Non-obvious decisions are recorded as [ADRs](README.md), which carry status,
  dates, and supersession.
- Implementation debt tracked for repair is recorded as GitHub issues, not as
  comments at the hack site.
- Functional, machine-read markers are allowlisted: shebangs and the
  `x-release-please-version` marker.

Enforcement is a ratchet: `tools/lint/comments.py` (run by `make lint` and
`make check`) counts comment lines per file and compares them against the
committed budget in `tools/lint/comment_ratchet.json`. Counts may only
shrink. Any new comment, or any edit that leaves the budget above reality,
fails the build. The ratchet acknowledges that the existing stock is deleted
incrementally: the [`/delete-comment`
skill](../../.agents/skills/delete-comment/SKILL.md) repeats the audit
categorization (tautology / excuse / stale / decision record) on the remaining
stock and tightens the budget after each deletion pass.

## Consequences

- A comment can no longer be the place where a design decision lives. Every
  surviving decision from the audit has been moved into an ADR; new ones must
  go there directly.
- Excuse comments cannot silently accumulate: the lint rejects them outright,
  and the audit converted the existing ones into issues.
- The remaining stock (~1.9k lines at introduction, decreasing) is deleted
  over successive passes rather than in one unreviewable change. Zig doc
  comments are part of the stock and are removed by the same process.
- Readers lose inline orientation in dense algorithms; the answer is better
  decomposition and names, and ADRs for the reasoning that names cannot carry.
- Test fixtures, vendored code, and generated files are out of scope and keep
  whatever comments they carry.
