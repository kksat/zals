# ADR-0053: YAML parsing parity with ansible-core

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
integers, and type resolution that also ran on quoted scalars, so
`mode: "0644"` validated as the integer 644. Runtime Ansible parses the same
file differently, and the upstream language server's TypeScript `yaml`
package resolves yet another schema (YAML 1.2 core), where `yes` is a string
even though every Ansible playbook relies on it being a boolean.

ansible-core is the only authority that matters: a diagnostic is wrong
exactly when runtime Ansible would parse the document differently. Its
pipeline is `ansible.parsing.dataloader.DataLoader` (PyYAML under YAML 1.1
rules) followed by
`ansible.module_utils.common.text.converters.jsonify`.

## Decision

zals parses YAML to values **exactly as ansible-core does**, and a lint-time
harness enforces it against a frozen ansible-core.

1. **Resolution follows PyYAML.** Scalar nodes carry their presentation
   style (`plain`, `quoted`, `block`) from both parser backends; implicit
   YAML 1.1 typing applies to plain scalars only, including the quirks:
   `on`/`off` are booleans but single `y`/`n` are strings, `0644` is octal
   420 but `08` is a string, `12:30` is a base-60 integer, exponents require
   a sign, and `-.5` is not a float. Integers beyond i64 lower as exact
   digit strings. Timestamps normalize to the ISO 8601 text `jsonify`
   emits. Anchors and aliases resolve, `<<` merge keys fill missing keys
   with Python's `True == 1` key identity, and tags apply the PyYAML and
   ansible constructors (`!!str`, `!!int`, `!!bool`, `!!timestamp`,
   `!!binary`, `!!omap`, `!unsafe`, `!vault`).
2. **Block scalars, folding, and multi-line scalars match PyYAML** through
   one renderer shared by both parser backends (`src/yaml/block_scalar.zig`):
   clip/strip/keep chomping, indentation indicators relative to the parent
   column, folded blank-line and more-indented-line rules, and plain and
   quoted multi-line folding.
3. **The harness runs as part of linting.** `make yaml-parity` (invoked by
   `make lint` and therefore `make check`) creates `test/parity/.venv` from
   the frozen `test/parity/requirements.txt`, then
   `test/parity/yaml_parity.py` runs every `test/fixtures/yaml-parity/*.yaml`
   document through ansible-core's own `DataLoader`/`jsonify` pipeline and
   through zals's production parse path (`zals --yaml-lower`), and requires
   the results to be equal — including the int/float distinction. It also
   regenerates the sibling `*.json` expectations, which the fast Zig-side
   parity test in `src/yaml/jsonify.zig` checks without a Python
   environment; expectations are skipped for values strict JSON cannot
   express (`Infinity`/`NaN`), though the comparison itself still covers
   them. Never hand-edit a generated `*.json` to make a failure pass —
   fix zals.

## Scope

The contract covers every document ansible-core accepts and `jsonify` can
serialize. Outside it, by construction rather than by choice: documents
ansible-core itself rejects (syntax errors, unknown tags like `!foo`,
invalid dates such as `2024-13-01`, recursive anchors) have nothing to
compare against, and zals is deliberately error-tolerant because it must
keep serving an editor on broken files. `!!set` is excluded because
ansible-core serializes a Python set, whose order is not stable across
runs. To extend parity, add corpus documents first, watch the harness fail,
then fix zals.

## Consequences

Schema validation sees the same values runtime Ansible sees, so quoted
values, octal-like modes, and version strings stop producing false
positives and stop hiding real type errors. The subset parser's comment
rules now match YAML (`#` starts a comment only at line start or after
whitespace), and block scalars as sequence items parse in both backends.

The parity corpus only guarantees what it covers; the corpus grows with
every construct that previously diverged. Bumping the frozen ansible-core
version requires re-running the harness and reviewing the regenerated
expectations, since resolution behavior may change between ansible-core
releases.
