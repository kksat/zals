# ADR-0009: Go-to-definition target

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Go-to-definition on a module name should open the module's source. `ansible-doc`
reports `doc.filename`, the path to the module file. The question is where in
that file to place the cursor.

## Decision

Point at the **start of the file** (line 0, character 0).

## Consequences

- Trivial to implement and always correct — the file is the useful destination.
- We do not need to parse the module file to find a symbol, which would add a
  second parser and more failure modes.
- If a future version wants to land on a specific symbol, it can refine this
  without changing the definition provider's interface.