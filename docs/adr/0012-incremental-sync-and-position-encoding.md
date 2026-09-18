# ADR-0012: Incremental sync and position encoding

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

LSP clients send document changes either as full text or as incremental ranges.
Incremental sync is far cheaper for large playbooks but requires maintaining a
line index and translating between the client's position encoding and our byte
offsets. LSP 3.17 lets a client advertise `utf-8` position encoding; older
clients use `utf-16`.

## Decision

- Advertise **incremental** sync (`TextDocumentSyncKind.Incremental`).
- Maintain a **line index** mapping UTF-8 byte offsets to line/character
  positions.
- Negotiate **`utf-8`** position encoding when the client supports it, and fall
  back to **`utf-16`** otherwise.

## Consequences

- Large documents are not re-sent on every keystroke.
- The line index and encoding conversion are correctness-critical and must be
  tested against multi-byte characters, CRLF, and astral-plane code points.
- Supporting both encodings means position conversion is a parameterized
  operation rather than a constant.
- Incremental sync interacts with validation's line reconciliation
  ([ADR-0015](0015-validation-behavior.md)).