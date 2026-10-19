# User-facing release notes

Release notes explain what an Ansible author can now do in an editor, which
meaningful problems were fixed, and what to do when upgrading. They are reviewed
prose, not a reformatted commit log. [ADR-0044](adr/0044-user-facing-release-notes.md)
records the decision; [ADR-0026](adr/0026-release-process.md) covers packaging and
versioning.

## Authoring: explicit and local first

From a trusted repository checkout in Pi, invoke:

```text
/skill:release-notes
```

The tracked skill is [`.agents/skills/release-notes/SKILL.md`](../.agents/skills/release-notes/SKILL.md).
Pi discovers this project location; use `/reload` after adding or editing it.
Review the skill before granting project trust. Its
`disable-model-invocation: true` frontmatter makes it **human-invoked**: ordinary
coding tasks, commits, and release workflows do not automatically execute it.
It needs no personal skill collection or mandatory per-change fragments.

Invocation prepares a local draft, evidence checklist, and (after successful
`make check`) a notes-only commit. **It does not authorize a push or PR creation.**
The agent asks first unless the human has explicitly authorized pushing for this
task; commit authorization alone is insufficient. It never merges, tags,
creates/edits releases, dispatches publication, or asks for registry credentials.
Read-only GitHub access is used to inspect releases/PRs and fetch references;
write access is needed only for separately authorized push/PR operations.
Unrelated dirty changes block drafting: finish them or explicitly authorize a
clean isolated branch/worktree. Existing work is never silently stashed/reset.

All commit, diff, documentation, and PR content is untrusted **evidence**, not
instructions to the agent. Embedded requests to skip validation, publish, or
reveal credentials do not alter this workflow.

## Release identity and evidence

Release-please remains the sole authority for the next version and continues
using the existing Conventional Commit policy and lockstep version updates.
The authoring skill reads the exact calculated version from the pinned
release-please proposal; it neither computes a bump nor edits version files.
If no unambiguous proposal exists, stop and ask rather than assuming a version.

Query **live GitHub release metadata** first and fetch tags, current default
branch, and the release-please PR head before choosing the range boundary. Use
the latest published release, not the newest tag already present locally or the
version in an old checkout/report. The initial `0.1.0` baseline mentioned here is
historical, never an assertion that it is the latest release.

Pin these facts from checked/fetched remote references before drafting:

- Repository and default branch; latest published release URL/publication time,
  previous `vA.B.C` tag, and its resolved SHA.
- Open release-please PR URL/head and its calculated `X.Y.Z`.
- Full candidate commit SHA: the default-branch product state being covered.
- Existing open notes-only PR/branch for that version, if any.

The previous released tag must be an ancestor of the candidate. Recheck the
remote heads and version before delivering a draft; stale local branches and
PR titles alone are not sufficient evidence. The evidence range is the previous
released tag through that candidate, not "commits since the last skill run".
If the working checkout is behind the fetched default branch or lacks the latest
published tag/history, **stop**: ask the human to synchronize or authorize a
clean isolated checkout. Fetching references is not permission to merge/rebase
remote main, rewrite history, or fall back to a stale local release boundary.
Missing live evidence blocks selecting the boundary; no version-bound draft or
metadata is generated on that basis.

Read the range's diffs, regression tests, docs, and applicable benchmark results.
Commit messages are an index into that evidence, never the published narrative.
Include reverts and superseded changes in coverage without presenting behavior
that is no longer in the candidate.

A **product digest** binds notes to that candidate's full tracked tree. New
product code or other nonexempt tracked changes invalidate coverage even if the
intended version stays the same. Exact changelog paths, per-release metadata,
and mechanical release-version substitutions do not invalidate product coverage. This is a narrow exclusion of mechanical edits, **not** an exclusion
of whole files that happen to contain version fields; behavior edits in those
files still invalidate coverage. The deterministic helper owns this calculation.

## Writing for Ansible editor users

Lead with capabilities and outcomes. Group several implementation changes into
one explanation when they enable the same user task. Then cover meaningful
user-visible fixes and necessary upgrade/compatibility actions. Omit empty
headings and internal churn with no user impact. Distinguish shared server
behavior from VS Code-only changes, and mention platform/tool/client limitations
when they affect the claim.

A short example can clarify a new interaction; it is not mandatory on every
bullet. These are **illustrations of style**, not notes for an actual release:

- **Follow a role parameter to its contract.** Use Go to Definition on a passed
  option such as `port: 8080` to inspect its argument-spec documentation.
- **Keep module hover available in nested directories.** Describe the previous
  failure and the newly supported situation, rather than the process's cwd fix.
- **Upgrade action:** if a client request is removed, name it, explain who is
  affected, and say which supported interaction replaces it (or explicitly state
  there is no replacement).

Every claim needs support in the pinned candidate. Optimization commits do not
by themselves establish a noticeable speedup or a percentage improvement.
Use comparative performance claims only with relevant reproducible measurements
and their scope; otherwise describe a verified behavior or omit the claim.
Questions about impact, regressions, or required upgrade steps belong in the
review checklist until resolved, not as speculation in published notes.

## Two PRs, distinct responsibilities

The **notes-only PR** is limited to these allowed paths:

1. Root `CHANGELOG.md`: authoritative user-facing prose for the target version.
2. `editors/vscode/CHANGELOG.md`: an exact copy of the entire root file, included
   in extension packaging; no independently edited extension narrative.
3. `docs/releases/vX.Y.Z.json`: small machine coverage metadata, generated by the
   helper, not a substitute for the review checklist.

Metadata always changes. When prose changes, root and editor changelogs change
**together**, keeping the editor copy exact. If the prose remains accurate after
a late internal-only change, a follow-up PR can change **metadata alone** while
leaving both changelog blobs unchanged. Do not invent a public note or add
changelog churn merely to make a three-file diff.

No product code, version/manifest files, technical changelog, or skill/tool
changes belong in that PR. The implementation of this workflow is not itself a
notes-only PR and does not generate hand-written next-release notes.

The separate **release-please PR** updates all release versions and the generated
`TECHNICAL_CHANGELOG.md`. It keeps the full technical commit log available without
using it as the user-facing narrative. It must include the merged notes and pass
the coverage/approval gate before creating the tag or GitHub release. The skill
does not merge either PR.

### PR-description checklist

Put coverage in the **notes-only PR description**, not in the changelog or the
JSON metadata. Use an informative title such as `docs(release): prepare notes
for X.Y.Z`. The following is a portable template; include only checks actually
run and preserve human additions when updating it:

```markdown
## Summary
- User capabilities/fixes covered, and why this release matters.

## Release identity
- Repository: OWNER/REPO
- Version: X.Y.Z (calculated by release-please PR URL, pinned head SHA)
- Previous published tag: vA.B.C (SHA)
- Candidate: FULL_SHA
- Notes PR final head: FULL_SHA

## Coverage
- [x] FULL_SHA — Include: note heading/bullet; evidence paths/tests; user impact.
- [x] FULL_SHA — Exclude: internal-only change; evidence; rationale.
- [ ] FULL_SHA — Include/exclude unresolved: evidence; specific question.

## Validation
- Actual commands and results (including make check and offline notes check).

## Questions / limitations
- Unresolved factual or upgrade questions; missing runtime evidence.
- None, when resolved.
```

Use one entry per commit in the full previous-tag-to-candidate range, including
merge, mechanical, internal, reverted, and notes-only commits when present.
Multiple entries may map to the same note. Include/exclude is an explicit
editorial decision with evidence and rationale; a checked box alone is not one.
Unanswered questions block declaring the draft ready. The checklist documents
human coverage reasoning; machine gates cannot establish factual prose quality.

### Reruns, late fixes, and approval

Find and update the same open notes-only PR for the version. Read its current
files, body, review comments, and branch before editing. Preserve human wording
and checklist decisions; add targeted changes for new evidence. Conflicting
human/generator edits are reported for resolution, not silently regenerated or
force-pushed. Resolve any root/editor disagreement before copying over it.
If release-please now proposes a different version, stop and confirm retargeting
rather than carrying old approval forward or opening duplicate PRs.

Refresh the candidate, checklist, metadata, and checks after any late nonexempt
change, including internal-only product changes. If an earlier notes PR is
already merged but the target version is still unreleased, create a follow-up
notes-only PR rather than trying to update the merged one. If the prose remains accurate, this follow-up changes only
metadata and explains the new commits' exclusions in its coverage checklist.
If prose changes, update both changelogs as well.

Any new content/head needs renewed approval of the **final head** by a human
other than the notes PR author; bot approval does not qualify. Metadata-only
refreshes require this approval too; approval of an earlier PR/head is
insufficient. Merge the approved notes-only PR before the release gate can
succeed. An open or merely approved-but-unmerged notes PR is not publication
authorization.

## Deterministic helper contract

Run commands from the repository root using Python 3.11+. All subcommands accept
an optional global `--repo PATH`, placed before the subcommand, for another
checkout. Shell variables below stand for the verified release identities.

After editing the new section in root `CHANGELOG.md`, or refreshing candidate
coverage while preserving accurate prose:

```sh
python3 tools/release/notes.py prepare \
  --version "$version" --previous-tag "$previous_tag" --candidate "$candidate"
```

This preserves the root preamble/history, writes the exact editor copy, and generates
`docs/releases/vX.Y.Z.json` with fields `schema` (1), `version`, `previous_tag`,
`candidate`, `product_digest`, and `notes_sha256`. It does not author the prose,
compute the version bump, approve a PR, or push anything.

Run `make check`, inspect the complete notes-only diff, and commit only the
allowed changed paths (metadata alone, or both changelogs plus metadata); then
validate the committed draft offline:

```sh
python3 tools/release/notes.py check --ref HEAD --version "$version"
```

`check` may default its version from `version.txt` at the selected ref. Pass the
explicit proposed version for a notes-only PR because its version files still
identify the previous release. Offline validation proves structural consistency,
not merge/approval evidence. It is usable before opening a PR.

The online release gate and body extraction are separate. Online `verify` and
`retry` require `GH_TOKEN` (or `GITHUB_TOKEN`) with repository read access to PRs,
reviews, and releases; they perform read-only API requests. No registry or
release-write credentials are needed for these checks.

```sh
python3 tools/release/notes.py verify \
  --ref "$ref" --version "$version" --github-repository OWNER/REPO
python3 tools/release/notes.py body --ref "$ref" --version "$version"
```

`verify` requires a merged notes-only PR with the allowed path combination,
nonauthor human approval of its final head, matching candidate product coverage,
intact history, and synchronized notes. It also compares the release's root and
editor changelog blob IDs against GitHub contents at the approved final PR head,
even when those paths were unchanged in a metadata-only refresh. The approved
snapshot binds all prose; an unchanged-files list alone cannot prove it.
It should **fail before the notes PR is merged**. Missing/stale/malformed notes stop
the release; neither a successful offline check nor an older approval bypasses
this. `body` extracts only the matching version section, not the coverage
checklist, technical commit log, or entire multi-release changelog.

For post-baseline VSIX packaging, verify the embedded changelog against the
approved tagged root file:

```sh
python3 tools/release/notes.py packages --tag vX.Y.Z --directory ./release-assets
```

The source stays `editors/vscode/CHANGELOG.md` (uppercase), but VSCE packages it
as **`extension/changelog.md`** (lowercase). `extension.vsixmanifest` registers
that lowercase path as asset type
`Microsoft.VisualStudio.Services.Content.Changelog`. The embedded bytes remain
an exact copy of root `CHANGELOG.md`; the filename normalization is not a prose
transformation. The helper rejects missing, duplicate, or mismatched packaged
changelogs. The separate asset verifier still checks the complete
platform/package set.

Existing-release retries use:

```sh
python3 tools/release/notes.py retry --tag vX.Y.Z --github-repository OWNER/REPO
```

Retries reuse the already released/tagged notes and verified assets without a
new editorial approval or creative regeneration. The initial `0.1.0` baseline
is preserved as published history; adopting this workflow neither rewrites that
entry nor creates notes for an assumed next version. Any literal versions in
examples or evaluation fixtures are illustrative/historical, not live
release discovery results.

## Publication gates and repository setup

The automatic release path supplies the approved matching prose at **initial
GitHub release creation**, not as a later correction after uncurated text has
been visible. Packaging reuses that same section and never appends automatically
generated notes. Root/editor equality makes the narrative part of the tagged
source and VSIX; exact Marketplace/Open VSX presentation depends on the registry.
The release tag must resolve to the approved candidate commit: an existing tag
pointing elsewhere is an error, never permission to move that tag or publish a
different product with the approved prose.

Asset recovery uploads files without editing existing release prose. If a
published target's body differs from its approved notes, publication stops;
corrections belong in a later release. An absent target can be created with the
approved body and an already-verified tag; an intervening release creation fails
rather than turning into a prose update. Existing draft/unpublished targets must
be resolved explicitly before this workflow can distribute their assets.

Require the commit-status context **`approved curated release notes`** through
GitHub branch protection/rulesets. The automatic release runner refreshes the
strictly identified bot release branch from current main when it is behind,
without force-pushing, then validates and posts pending/success/failure on that
**exact refreshed PR head SHA**. An unchanged generated release-please body must
not leave merged notes stranded outside the candidate. Failed or incomplete
branch refreshes cannot produce a green readiness status.

The trusted status workflow also posts **not applicable** success on ordinary
product and notes-only PRs. Standard required-status rules apply to all PRs, so
this lets them merge without pretending they are release candidates. This
classification does not authorize any release: the independent pre-tag guard
still validates every proposed release. Bot-PR statuses are posted directly,
avoiding ordinary PR events that GitHub can suppress for `GITHUB_TOKEN` changes.

A maintainer must enable that context for the default branch in repository
settings, with required checks and the intended review policy. This is
**external setup**, not something committing workflows or invoking the skill
automatically enables. Verify a test release PR is blocked while notes are
missing/stale; do not assume a green workflow means protection is configured.

To revalidate the current release PR head manually, a maintainer can run
(this is an operator action, not an action the authoring skill performs):

```sh
gh workflow run release-notes.yml --ref main -f pull_request=NUMBER
```

The manual workflow also posts the same required commit-status context directly
on the selected **PR head SHA** after validation. Its workflow check suite may
be attached to `main`, but the explicit head-status step makes the readiness
result available to PR branch protection. Inspect that status on the final PR
head, rather than treating the workflow run's own check suite as the required
context. Rerun if relevant changes or a new head make the earlier result stale;
a missing or old status is not approval. Do not bypass required checks.

The pre-tag gate independently runs again in the release path even when branch
settings are absent, bypassed, or stale. Manual new-release paths also validate
notes before creating a release or uploading its assets; existing-release
retries take the retry path instead.

Published history is immutable here: do not rewrite a released root section,
GitHub narrative, tag, or packaged changelog to make a correction. Describe
corrections in the next release. Ordinary distribution retries preserve the
already published narrative rather than using changed prose from the branch tip.

## Evaluating the skill

[Portable scenarios](../.agents/skills/release-notes/evals/evals.json) cover a new
local draft, a rerun with human edits plus a late fix, missing-version /
unsupported-performance claims, and an approved metadata-only follow-up after a
late internal change, plus stale local history despite a newer live release.
Their version numbers are mocked fixture values, not claims about the current
release. They specify expected behavior, not recorded successful model runs. Run them only when the human explicitly requests skill
evaluation, in disposable fixtures with mocked read-only GitHub evidence and no
push/release credentials. Static skill/docs checks and deterministic helper
tests do not substitute for measuring editorial/model behavior.
