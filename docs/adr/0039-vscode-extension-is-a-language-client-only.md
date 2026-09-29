# ADR-0039: VS Code extension is a language client only

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** —
- **Superseded by:** —

## Context

`redhat.ansible` runs playbooks, encrypts vault files, shows an Ansible status
bar, and ships Lightspeed and content creator. The extension in this repository
is a thin client around `zals`
([ADR-0038](0038-vscode-extension-in-this-repository.md)). Those other features
are not part of the server.

## Decision

The extension contributes the `ansible` language, the YAML grammar, and the
nine settings, and it starts the bundled server. It adds no commands, status
bar, telemetry, walkthrough, or webview. Server logs go to the language
client's output channel.

## Consequences

- Playbook run, vault, Lightspeed, and content creator stay in `redhat.ansible`
  or in the terminal. With both extensions installed, those commands still come
  from `redhat.ansible` ([ADR-0032](0032-no-coordination-with-other-language-servers.md)).
- Restarting the extension host is how the server is restarted.
- There is no "open log" command. The output channel is the log.
