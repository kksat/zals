# ADR-0053: YAML-to-JSON lowering follows ansible-core

- **Status:** Accepted
- **Date:** 2026-11-21
- **Supersedes:** —
- **Superseded by:** —

## Context

JSON-schema validation of Ansible metadata files (`galaxy.yml`,
`requirements.yml`, `meta/*.yml`) lowers the parsed YAML document to
`std.json.Value` before checking it against the schema
([ADR-0005](0005-json-schema-validation-in-zig.md)). Issue #47 reported a
false positive from that lowering: `license_file: ""` — the standard
collection-template default — produced `Incorrect type. Expected "string".`
because any scalar whose text was empty lowered to JSON `null`, conflating
`key:` (an implicit null) with `key: ""` (an empty string).

The deeper problem was that the lowering had no defined authority. It
invented its own scalar resolution: a small boolean set, decimal-only
integers, and a sign-optional float check that also ran on quoted scalars,
so `mode: "0644"` validated as the integer 644. Runtime Ansible parses the
same file differently, and the upstream language server's TypeScript `yaml`
package resolves yet another schema (YAML 1.2 core), where `yes` is a
string even though every Ansible playbook relies on it being a boolean.

ansible-core is the only authority that matters: a diagnostic is wrong
exactly when runtime Ansible would parse the document differently. Its
pipeline is `ansible.parsing.dataloader.DataLoader` (PyYAML under YAML 1.1
implicit rules) followed by
`ansible.module_utils.common.text.converters.jsonify`.

## Decision

1. Scalar nodes carry their presentation style (`plain`, `quoted`, `block`)
   from both parser backends. Implicit resolution applies to **plain scalars
   only**; quoted and block scalars always lower to strings. This fixes the
   issue: `""` is a string, `key:` is null, and `mode: "0644"` is a string.
2. Plain-scalar resolution implements the YAML 1.1 rules PyYAML applies,
   including its quirks: `on`/`off` are booleans but single `y`/`n` are
   strings; `0644` is octal 420 but `08` is a string; `12:30` is a base-60
   integer; `2.5e+3` is a float but `1e3` is not (the exponent sign is
   required); `-.5` is a string (no sign before a leading dot).
3. The lowering is pinned by a generated parity corpus.
   `test/fixtures/yaml-parity/` holds `*.yaml` inputs and `*.json`
   expectations produced by ansible-core itself via
   `test/parity/generate_yaml_fixtures.py`; the Zig test in
   `src/yaml/jsonify.zig` fails unless zals lowers every document
   identically. Regenerate after adding cases or bumping ansible-core.

Corpus scope (enforced by the generator): single documents, string keys, and
values that survive `jsonify` unchanged. Out of scope, as documented
deviations: full timestamps (PyYAML builds `datetime` objects, which JSON
cannot represent — date-like scalars stay strings), `.inf`/`.nan`, integers
beyond i64 (JSON numbers are doubles), tags and anchors (neither backend
models them), multi-line plain-scalar folding, folded-scalar blank-line
handling, and block-scalar keep-chomping (`|+`) and indentation indicators
(`|2`).

## Consequences

Schema validation sees the same types runtime Ansible sees, so quoted
values, octal-like modes, and version strings stop producing false
positives and stop hiding real type errors. The subset parser's comment
rules now match YAML (`#` starts a comment only at line start or after
whitespace, so `a#b` is one scalar), which the corpus also pins.

The parity corpus only guarantees what it covers; the deviations above are
tracked in [docs/deviations.md](../deviations.md) and close by extending the
corpus or the backends, not by editing expectations by hand. Tests must
never edit a generated `*.json` to make a failure pass — regenerate it and
review the diff.
