# ADR-0047: Personal-owner release-note approval

- **Status:** Accepted
- **Date:** 2026-11-04
- **Supersedes:** [ADR-0044](0044-user-facing-release-notes.md) (personal-owner approval alternative only)
- **Superseded by:** —

## Context

A sole maintainer cannot obtain independent editorial review, and GitHub rejects
authors' attempts to approve their own PRs. Requiring another person therefore
blocks releases even when the personal repository owner explicitly approves the
notes. Silently ignoring approval or representing an assistant as an independent
human reviewer would misstate the release's authorization.

## Decision

Keep independent final-head human review as the normal approval path. Add an
explicit owner-authorization alternative only when GitHub identifies the
repository owner as a personal `User` account and that owner authored the notes
PR. The owner posts a first-line `/approve-release-notes X.Y.Z FULL_HEAD_SHA`
command in a PR comment. The verifier binds it to the exact version/head and
checks its authenticated account, `OWNER` association, creation timestamp, and
last-edit timestamp before merge. An assistant can record it on the owner's
behalf only with explicit delegation and disclosure, not by deciding that its own
notes are approved.

A later `/revoke-release-notes X.Y.Z FULL_HEAD_SHA` command withdraws the owner
path's authorization; creation order determines the latest matching decision.
Outstanding change requests still block either approval path. Organization-owned
repositories and other PR authors retain the independent-review requirement.
The [maintainer procedure](../release-notes.md#approve-notes-as-a-sole-maintainer)
defines the command and refresh steps.

## Consequences

- A personal owner can make an accountable release decision without fabricating
  independent review. This gives up a second human's editorial check for that
  path; machine validation still cannot establish prose accuracy.
- Both approval paths keep the notes-only scope, exact-head root/editor blobs,
  complete candidate coverage, immutable published history, and pre-tag gate.
  Metadata-only refreshes still need approval of their own final head.
- Owner authorization is opt-in for each exact head, never inferred from authorship,
  merge permission, successful CI, or chat alone. Missing/deleted comments,
  invalid timestamps, API failures, and approval edited after merge fail closed.
- Updating the policy is ordinary tracked work, not part of a notes-only PR; it
  invalidates coverage and requires a separately refreshed approved notes PR.
