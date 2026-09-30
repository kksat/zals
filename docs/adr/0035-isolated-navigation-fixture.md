# ADR-0035: Isolate the navigation E2E fixture and dependency

- **Status:** Accepted
- **Date:** 2026-09-30

The checked-in rollout fixture will live under `test/fixtures/e2e-workspace/` with a trackable `fixture-workspace-root` marker, because Git cannot track a nested `.git` and the fixture must not join zals's own Workspace. A dependency collection will be checked in under `test/dependencies/ansible_collections/`, outside the fixture Workspace, and made available through explicit Ansible collection paths; another declared dependency will remain absent. This avoids runtime copies, virtual environments, installation, and network access while allowing tests to distinguish Workspace and Installed collections without indexing the latter's references.
