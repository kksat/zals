# ADR-0033: Semantic navigation E2E oracles

- **Status:** Accepted
- **Date:** 2026-09-30

A Zig runner will drive zals over stdio against one indexed, static Workspace; each navigation case will declare complete expected locations based on `GLOSSARY.md`, the accepted ADRs, and the fixture's intended graph, never captured from current server output or derived by enumerating fixture references. Test-side `cursor(...)` and `span(...)` helpers will require unique snippets and compute UTF-16 request positions and exact expected ranges; references will compare as order-independent lists preserving duplicates, definitions and implementations in order, and both `includeDeclaration` modes will have separately enumerated answers. Every supported syntax form will be exercised through each applicable navigation method, with distinct resolution outcomes and deliberate non-matches (accept `null` or an empty list as no result, never an error) but not arbitrary malformed YAML or a full syntax-by-resolution cross-product; this keeps tests readable under unrelated line shifts while requiring updates when the relationship graph changes.
