# ADR-0005: JSON Schema validation in Zig

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream validates Ansible metadata files against JSON schemas using the `ajv`
npm package. Zig has no equivalent. The schemas use a bounded subset of
draft-07, and upstream only surfaces four custom messages, so full draft-07
support is unnecessary.

## Decision

Implement a **Zig-native draft-07 subset validator** behind a `SchemaValidator`
interface. The supported keyword set is:

`$defs` / `$ref`, `type`, `properties`, `required`, `additionalProperties`,
`items`, `enum`, `const`, `allOf` / `anyOf` / `oneOf`, `not`, `if` / `then` /
`else`, `pattern`, `minLength`.

Diagnostics always use the **document root range**, and only four custom messages
are produced: `required`, `additionalProperties`, `type`, and `enum`. This
matches upstream's observable behavior.

`pattern` is evaluated by a small in-tree ECMA-262 subset regex engine
(`services/regex.zig`): literals, `.`, classes, anchors, quantifiers, groups,
and alternation. Invalid patterns are treated as non-matching rather than
errors.

## Consequences

- No C or JS dependency for validation.
- Unsupported keywords are ignored rather than rejected; this is acceptable
  because the bundled schemas are known and the four-message contract is narrow.
- If a future schema needs a keyword outside the subset, the validator must be
  extended; the interface makes that a local change.
- Because diagnostics use the root range, we do not need to map schema paths back
  to precise YAML ranges — a significant simplification.