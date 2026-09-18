# ADR-0010: Hand-rolled LSP/JSON-RPC transport

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Zig has no official LSP library. Options are to depend on a third-party Zig LSP
package or to implement the transport ourselves. The protocol we need is small:
`Content-Length` framing, JSON-RPC request/response/notification envelopes, and
the subset of LSP types used by Tier 1.

## Decision

Implement the **LSP/JSON-RPC transport from scratch** using `std.json`. This
covers framing, message parsing and serialization, request/response correlation,
and capability negotiation.

## Consequences

- No third-party dependency and no version-skew risk.
- We control the hot path and can avoid unnecessary allocations.
- We own the correctness of framing and JSON handling, including edge cases like
  partial reads and large messages; these need tests.
- We must define the LSP types we use. Keeping them minimal and explicit avoids
  pulling in the entire LSP schema.