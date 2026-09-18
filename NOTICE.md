# Attribution

`zals` is a reimplementation of the Ansible Language Server. It is not derived
from upstream source code, but it follows upstream's behavior and reuses its
public interfaces (LSP capabilities, settings names, custom messages) and test
fixtures.

## Upstream projects

- **vscode-ansible** — <https://github.com/ansible/vscode-ansible>
  Copyright (c) 2021 Red Hat Inc. and others.
  Copyright (c) 2021 Tomasz Maciążek.
  Licensed under the MIT License.

- **ansible-lint** — <https://github.com/ansible/ansible-lint>
  Licensed under the GNU General Public License v3.0.
  The JSON schemas bundled by `zals` originate from this project.

- **tree-sitter** — <https://github.com/tree-sitter/tree-sitter>
  Copyright (c) 2018 Max Brunsfeld.
  Licensed under the MIT License. Vendored as a C runtime dependency.

- **tree-sitter-yaml** — <https://github.com/tree-sitter-grammars/tree-sitter-yaml>
  Licensed under the MIT License. Vendored as a C dependency.

## License

Because `zals` bundles schemas from `ansible-lint` (GPL-3.0), the project as a
whole is licensed **GPL-3.0-only**. See [`LICENSE`](LICENSE) and
[ADR-0020](docs/adr/0020-license.md).