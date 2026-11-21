---
name: delete-comment
description: Repeat the comment-deletion pass; shrink the comment ratchet left by ADR-0048.
compatibility: Pi with project trust, Git, Python 3.11+, make and the repository build prerequisites; GitHub CLI for filing excuse follow-up issues.
---

# Delete comments

Inline comments are banned ([ADR-0048](../../../docs/adr/0048-no-inline-code-comments.md)).
The ban is enforced as a ratchet: `tools/lint/comments.py` holds a per-file
budget in `tools/lint/comment_ratchet.json` that may only shrink. This skill
is the repeatable pass that deletes the remaining stock. Run repository
commands from the repository root, not from this directory.

## 1. Inventory the remaining comments

```sh
python3 tools/lint/comments.py --list
```

Prints `file:line` for every counted comment line (Zig `//`, `///`, `//!`;
Python/shell/Make `#`; TypeScript `//`) across the lint's scope. Doc comments
(`///`, `//!`) are in scope. `test/fixtures/`, vendored, and generated code are
not. Pick a batch you can review carefully — a directory or a handful of files
— rather than the whole repository at once.

## 2. Categorize every comment in the batch

Read each comment **in context** (the inventory is syntax-based; a marker line
inside a string literal is not a comment). Exactly one category applies:

- **Tautology** — repeats what the code already shows: restates a name or
  signature, section markers like `// Tests.`, narrates the next statement.
- **Excuse** — justifies or apologizes for a hacky or limited implementation
  ("workaround", "for now", "upstream does X so we...", "simplification").
  The comment is what lets the hack survive review.
- **Stale** — describes code, names, counts, or behavior that no longer
  exists or is now wrong.
- **Decision record** — a non-obvious *why*: an invariant, ordering
  constraint, protocol requirement, lifetime rule, or security property not
  derivable from the code.

## 3. Act on each comment

- **Tautology / Stale** — delete the comment lines. Also delete blank lines
  orphaned by the deletion; a removed block must not leave doubled blank
  lines. Never reformat or rewrite surrounding code.
- **Excuse** — file an issue **before** deleting, then delete:
  ```sh
  gh issue create --repo kksat/zals --title "<imperative problem statement>" --body "<what is hacky, why, and the fix direction>"
  ```
  The issue replaces the comment as the tracker for the debt.
- **Decision record** — move it into an ADR, then delete it:
  1. If the comment cites an ADR, check whether that ADR already covers the
     content. If it does, just delete the comment.
  2. Otherwise write a new ADR (`docs/adr/00NN-<slug>.md`, next free number,
     following the format of existing ADRs; add it to the index table in
     `docs/adr/README.md`) or extend the ADR it belongs under. Record the
     decision, its context, and consequences — not the comment verbatim.
  3. Delete the comment.
- **Functional markers** — never delete shebangs (`#!` line 1) or lines
  containing `x-release-please-version`; the lint allowlists them.

Only delete comment lines and orphaned blanks. Never change code logic.

## 4. Verify

```sh
make fmt
make check
```

A comments-only deletion cannot break the build. A failure means code was
deleted — restore it and retry.

## 5. Tighten the ratchet

```sh
python3 tools/lint/comments.py --update-ratchet
```

This refuses to raise any budget. Never use `--force`; it exists only for the
initial baseline, which is already committed. The ratchet file change belongs
in the same commit as the deletions it records.

## 6. Commit

Conventional Commits, one logical change per commit, e.g.:

```
chore(comments): remove tautological and stale comments in src/workspace

21 tautology, 4 stale. Excuse follow-ups: #51, #52. Ratchet: 412 -> 387.
```

Reference the excuse issue numbers in the commit body so deletions and the
filed debt stay traceable.
