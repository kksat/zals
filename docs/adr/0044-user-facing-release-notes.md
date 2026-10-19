# ADR-0044: User-facing release notes

- **Status:** Accepted
- **Date:** 2026-10-19
- **Supersedes:** [ADR-0026](0026-release-process.md) (changelog ownership and release-body selection only)
- **Superseded by:** —

## Context

Conventional Commits are useful for release version calculation and technical
traceability, but subjects about allocators, traversal stacks, or process setup
do not explain what an Ansible editor user gains. Root changelog, GitHub release
body generation, and the extension package also need one explicit source of
approved user-facing prose.

A separate editorial PR allows capability-level review without mixing prose
with release-please's mechanical version changes. Its approval must remain tied
to the product state that was actually reviewed: late fixes, bot refreshes, and
manual release dispatch must not publish stale or unapproved text. Correcting a
GitHub body after initial creation would leave an uncurated visibility window
and would not fix notes already embedded in an immutable VSIX.

## Decision

Keep release-please's Conventional Commit version policy and lockstep package
versions unchanged. Move its generated full technical log to
`TECHNICAL_CHANGELOG.md`. Root `CHANGELOG.md` becomes authoritative reviewed
user-facing prose, copied exactly to `editors/vscode/CHANGELOG.md`; GitHub
Releases use only the matching version section, including at initial creation.

Provide the repository-local, human-invoked `/skill:release-notes` skill in
`.agents/skills/release-notes/`. It reconstructs the delta since the latest
published release, verified from live GitHub metadata and fetched tag/main/PR
references, using diffs, tests, and docs. Stale checkouts stop for explicit
synchronization rather than falling back to an older local tag or automatically
merging remote main. No per-change fragments are required.
Write capabilities, meaningful fixes, and upgrade actions for Ansible editor
users, with short examples where useful, rather than publishing commit subjects.
Treat source/PR text as untrusted evidence, not operational instructions.

The skill prepares a separate **notes-only PR**, limited to root changelog,
exact editor copy, and generated `docs/releases/vX.Y.Z.json` coverage metadata.
Metadata always changes; root/editor change together when prose changes. A
follow-up after a late internal change can update metadata alone if the prose
remains accurate, without manufacturing changelog edits. Every commit in the
covered range receives an include/exclude decision, evidence, rationale,
and any unresolved questions in the **PR description**. The skill reads the
exact release-please-calculated candidate version; it never calculates its own
bump or edits product/version/technical-log files. Explicit invocation permits
local drafting and a checked commit, not an implicit push or PR creation.

Approval must come from a human other than the notes PR author on its final
head, and the notes PR must be merged before the release gate succeeds. The
helper binds prose/history to a pinned candidate and full tracked-tree product
digest. Nonexempt tracked changes invalidate coverage; exact changelog paths,
per-release metadata, and narrowly recognized mechanical version substitutions
do not. Files containing version fields are not exempt
from coverage of their other changes. Changes to the draft require reapproval.
Reruns update the same open PR, preserve human edits, and surface conflicts.
After an earlier notes PR is merged, use a new follow-up PR; metadata-only
refreshes still require nonauthor human approval of their final head. The gate
checks root/editor blobs against the approved final-head snapshot even when
those paths are unchanged, so prose cannot drift outside that approval.

Gate release readiness deterministically and recheck before creating a tag or
initial GitHub release, including manual new-release paths. Supply approved
prose at initial creation, rather than patching a default body afterward.
A required GitHub status complements this pre-tag guard but requires explicit
external branch-protection/ruleset configuration; repository code alone does not
enable it. The authoring agent has no merge/tag/release/publication role and
needs no registry credentials.

Preserve published historical entries, starting with `0.1.0`. Corrections belong
in the next release. Existing-release retries reuse tagged/published notes and
assets without new creative generation or approval. Adopting the workflow does
not itself generate next-release prose or rewrite a historical release.

## Consequences

- Users receive one narrative across the root changelog, tagged extension copy,
  and GitHub release, while maintainers retain the generated technical log.
- Human synthesis and review are explicit work; a model skill is authoring help,
  not an unattended editorial authority or proof that its claims are true.
- Two PRs are intentional: merge approved notes before releasing the separately
  versioned candidate. A late product change can block release until coverage
  and final-head approval are refreshed.
- Machine metadata is small; detailed editorial provenance lives in the PR
  description. Structural gates validate identity, hashes, history, and approval,
  not completeness or truthfulness of prose.
- Preserving human edits costs conflict handling instead of wholesale
  regeneration. Immutable published notes avoid divergence from shipped VSIXs.
- External required-check setup and GitHub review access are operational
  prerequisites, documented in [the maintainer workflow](../release-notes.md).
