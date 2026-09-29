# ADR-0034: YAML grammar only

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

The extension contributes the `ansible` language
([ADR-0033](0033-ansible-language-document-selector.md)). Without a grammar,
those files are plain text except for the keys `zals` marks with semantic
tokens. `redhat.ansible` ships a YAML grammar, Jinja injections, and a
generated keyword grammar. The editor binds one grammar to the language id.

## Decision

Ship a YAML TextMate grammar for `ansible`, plus language configuration for
`#` comments and brackets, and the editor defaults `redhat.ansible` sets for
that language (tab size 2, insert spaces). Do not ship Jinja injections or the
generated Ansible keyword grammar.

## Consequences

- Installed alone, Ansible files highlight as YAML. Play, task, module, and
  option keys are colored again by `zals` semantic tokens.
- Jinja stays YAML text.
- Installed beside `redhat.ansible`, one of the two grammars wins.
- The generated keyword grammar is not an accidental omission. Semantic tokens
  already cover those keys, and that grammar would have to track upstream.
