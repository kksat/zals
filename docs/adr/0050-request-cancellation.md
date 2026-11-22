# ADR-0050: Request cancellation

- **Status:** Accepted
- **Date:** 2026-11-22
- **Supersedes:** —
- **Superseded by:** —

## Context

LSP clients send `$/cancelRequest` when a response is no longer needed —
typically during fast cursor movement or typing bursts, where an editor
supersedes hover, completion, or semantic-token requests before the server
answers. The server processes every message synchronously on the main thread
([ADR-0011](0011-threading-topology.md)): a request that has started computing
cannot be interrupted, and with a strictly one-message-at-a-time loop a cancel
would normally only be read after the request it cancels has already been
answered.

## Decision

- Remember `$/cancelRequest` ids in a bounded set (`src/lsp/cancellation.zig`).
- Before dispatching a request, drain already-buffered client input without
  blocking (`Transport.tryReadMessage`): record cancels, and defer every other
  message in arrival order for later dispatch.
- A request whose id was cancelled before dispatch answers with LSP
  `RequestCancelled` (-32800) instead of computing; the id is forgotten when
  the request is dispatched either way.
- A cancel that arrives after its request was answered, or names an unknown
  id, is remembered briefly and then dropped; the set is capped and cleared
  when exceeded.
- In-flight requests are never interrupted, and partially received or
  malformed drained input is left to the normal blocking read.

## Consequences

- During bursts, the server skips superseded intermediate requests instead of
  computing answers the client will discard.
- Deferred read-ahead preserves message order: notifications such as
  `didChange` still apply in arrival order.
- Cancellation is best-effort, as the LSP spec allows: a request that has
  started is completed, and a cancel racing a just-dispatched request may
  arrive too late to help.
