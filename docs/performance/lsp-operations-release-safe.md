# LSP operation latency

Generated: 2026-10-06T23:57:18.514300+00:00
Build label: ReleaseSafe; platform: macOS-26.7-arm64-arm-64bit-Mach-O / arm64
Binary SHA-256: `7d3f06574d9e7d1e1cd0183c732ab47d82834480a55ff1cffe092ace4f2234b3`

Fixture: 1000 background files × 20 tasks; 3 fresh sessions/mode; 10 warm samples/session/case.

All times are end-to-end stdio round-trip milliseconds, including JSON transport/decoding.
First = median first observation per session, **not** an isolated cold-cache request; cases share a session.
Warm samples are interleaved in seeded shuffled order. p95 uses nearest rank; max includes outliers.
Ansible tools/docs are deterministic Python fixtures, not measurements of real ansible-doc or plugin discovery.
N/A = no target-specific provider; omitted rather than timing empty/fallback results.
Results = returned locations/items/top-level document symbols, or token count; hover/resolve = 1.
Warmup passes: 2; shuffle seed: 42; filter: `(all)`.

## File watching enabled

Indexed files: 1027; initialize-to-index-ready median: 140.4 ms.

| Target | Operation | First ms | Warm median ms | Warm p95 ms | Warm max ms | Results | Samples |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Variable (role read) | definition | 9.01 | 8.86 | 9.21 | 12.92 | 4 | 30 |
| Variable (role read) | implementation | 9.01 | 8.86 | 9.19 | 9.21 | 3 | 30 |
| Variable (role read) | references | 1.64 | 1.60 | 1.85 | 2.24 | 5 | 30 |
| Variable (role read) | hover | 9.20 | 8.85 | 9.19 | 9.20 | 1 | 30 |
| Variable (binding) | definition | 9.16 | 8.84 | 9.05 | 9.10 | 4 | 30 |
| Variable (binding) | implementation | 8.88 | 8.80 | 9.20 | 9.31 | 3 | 30 |
| Variable (binding) | references | 1.58 | 1.60 | 1.75 | 1.86 | 5 | 30 |
| Variable (binding) | hover | 9.08 | 8.82 | 9.24 | 10.00 | 1 | 30 |
| Variable (Jinja template) | definition | 8.85 | 8.74 | 9.14 | 9.32 | 1 | 30 |
| Variable (Jinja template) | implementation | 8.69 | 8.75 | 9.23 | 9.71 | 1 | 30 |
| Variable (Jinja template) | references | 1.53 | 1.54 | 1.70 | 1.84 | 2 | 30 |
| Variable (Jinja template) | hover | 9.19 | 8.72 | 9.25 | 11.86 | 1 | 30 |
| Variable field (read) | definition | 8.63 | 8.69 | 9.15 | 9.62 | 3 | 30 |
| Variable field (read) | implementation | 8.79 | 8.55 | 8.84 | 9.33 | 2 | 30 |
| Variable field (read) | references | 1.50 | 1.48 | 1.58 | 1.72 | 4 | 30 |
| Variable field (read) | hover | 8.95 | 8.75 | 9.32 | 9.37 | 1 | 30 |
| Role parameter | definition | 5.73 | 5.51 | 5.77 | 5.96 | 1 | 30 |
| Role parameter | implementation | 6.42 | 6.13 | 6.82 | 7.07 | 1 | 30 |
| Role parameter | references | 10.20 | 9.75 | 10.38 | 12.14 | 4 | 30 |
| Role parameter | hover | 5.58 | 5.49 | 5.76 | 5.79 | 1 | 30 |
| Role parameter field | definition | 5.73 | 5.54 | 6.37 | 6.81 | 1 | 30 |
| Role parameter field | implementation | 6.90 | 6.65 | 7.17 | 7.19 | 1 | 30 |
| Role parameter field | references | 5.47 | 5.55 | 5.87 | 5.99 | 4 | 30 |
| Role parameter field | hover | 5.84 | 5.55 | 5.92 | 6.54 | 1 | 30 |
| Role (local) | definition | 9.92 | 9.70 | 10.14 | 12.40 | 1 | 30 |
| Role (local) | implementation | 9.94 | 9.65 | 9.96 | 10.03 | 1 | 30 |
| Role (local) | references | 9.83 | 9.73 | 10.12 | 10.17 | 2 | 30 |
| Role (local) | hover | 5.53 | 5.47 | 5.69 | 5.88 | 1 | 30 |
| Role (collection FQCN) | definition | 9.59 | 9.78 | 10.04 | 14.37 | 1 | 30 |
| Role (collection FQCN) | implementation | 9.81 | 9.71 | 9.99 | 10.05 | 1 | 30 |
| Role (collection FQCN) | references | 10.00 | 9.78 | 10.08 | 10.65 | 1 | 30 |
| Role (collection FQCN) | hover | 5.68 | 5.45 | 5.73 | 5.89 | 1 | 30 |
| Role (Galaxy) | definition | 9.98 | 9.78 | 10.17 | 10.28 | 1 | 30 |
| Role (Galaxy) | implementation | 9.91 | 9.72 | 10.27 | 10.28 | 1 | 30 |
| Role (Galaxy) | references | 9.85 | 9.71 | 10.19 | 14.04 | 2 | 30 |
| Role (Galaxy) | hover | 5.61 | 5.50 | 5.65 | 5.77 | 1 | 30 |
| Role (installed collection) | definition | 9.65 | 9.73 | 10.04 | 10.09 | 1 | 30 |
| Role (installed collection) | implementation | 9.75 | 9.68 | 10.03 | 10.19 | 1 | 30 |
| Role (installed collection) | references | 9.72 | 9.70 | 10.18 | 10.80 | 1 | 30 |
| Role (installed collection) | hover | 5.62 | 5.46 | 5.87 | 6.89 | 1 | 30 |
| Collection (Workspace) | definition | 8.71 | 8.64 | 8.93 | 11.25 | 1 | 30 |
| Collection (Workspace) | implementation | N/A | — | — | — | — | 0 |
| Collection (Workspace) | references | 1.19 | 1.24 | 1.31 | 1.35 | 3 | 30 |
| Collection (Workspace) | hover | 4.14 | 4.40 | 5.01 | 5.87 | 1 | 30 |
| Collection (installed) | definition | 8.79 | 8.56 | 8.81 | 8.84 | 1 | 30 |
| Collection (installed) | implementation | N/A | — | — | — | — | 0 |
| Collection (installed) | references | 1.24 | 1.24 | 1.34 | 1.37 | 3 | 30 |
| Collection (installed) | hover | 4.51 | 4.38 | 4.64 | 5.06 | 1 | 30 |
| Task file | definition | 0.48 | 0.38 | 0.43 | 0.53 | 1 | 30 |
| Task file | implementation | N/A | — | — | — | — | 0 |
| Task file | references | 1.40 | 1.41 | 1.52 | 1.59 | 2 | 30 |
| Task file | hover | N/A | — | — | — | — | 0 |
| Vars file | definition | 8.50 | 8.49 | 8.98 | 9.63 | 1 | 30 |
| Vars file | implementation | N/A | — | — | — | — | 0 |
| Vars file | references | 1.39 | 1.32 | 1.45 | 1.55 | 1 | 30 |
| Vars file | hover | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | definition | 8.73 | 8.68 | 9.07 | 9.25 | 1 | 30 |
| Module (builtin fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | hover | 8.66 | 8.63 | 8.93 | 8.97 | 1 | 30 |
| Module (Workspace fixture docs) | definition | 8.71 | 8.61 | 8.81 | 8.97 | 1 | 30 |
| Module (Workspace fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | hover | 8.48 | 8.59 | 8.96 | 10.41 | 1 | 30 |
| Module option | definition | N/A | — | — | — | — | 0 |
| Module option | implementation | N/A | — | — | — | — | 0 |
| Module option | references | N/A | — | — | — | — | 0 |
| Module option | hover | 8.60 | 8.62 | 9.65 | 11.42 | 1 | 30 |
| Play keyword | definition | N/A | — | — | — | — | 0 |
| Play keyword | implementation | N/A | — | — | — | — | 0 |
| Play keyword | references | N/A | — | — | — | — | 0 |
| Play keyword | hover | 8.70 | 8.61 | 9.00 | 9.04 | 1 | 30 |
| Variable (high fan-out) | references | 74.85 | 74.01 | 80.30 | 100.32 | 20001 | 30 |
| Variable (reads only) | references | 1.63 | 1.58 | 1.78 | 1.80 | 1 | 30 |
| Collections | completion | 1.37 | 1.34 | 1.55 | 1.59 | 2 | 30 |
| Play keywords | completion | 0.27 | 0.27 | 0.32 | 0.40 | 41 | 30 |
| Module options | completion | 101.68 | 0.23 | 0.27 | 0.31 | 3 | 30 |
| Module (fixture docs) | completion resolve | 0.18 | 0.19 | 0.22 | 0.24 | 1 | 30 |
| Roles | workspace symbols | 2.11 | 2.09 | 2.28 | 2.34 | 1 | 30 |
| Collections | workspace symbols | 2.14 | 2.16 | 2.30 | 2.55 | 4 | 30 |
| Modules | workspace symbols | 2.17 | 2.10 | 2.24 | 2.33 | 1 | 30 |
| Plugins | workspace symbols | 2.13 | 2.08 | 2.20 | 2.90 | 1 | 30 |
| Playbooks / plays | workspace symbols | 2.12 | 2.11 | 2.25 | 2.34 | 3 | 30 |
| Task files | workspace symbols | 2.09 | 2.09 | 2.20 | 2.25 | 3 | 30 |
| Playbook | document symbols | 0.09 | 0.08 | 0.14 | 0.15 | 1 | 30 |
| Playbook | semantic tokens | 44.94 | 0.22 | 0.26 | 0.36 | 6 | 30 |
| Variable | code actions | 0.12 | 0.11 | 0.13 | 0.18 | 4 | 30 |
| Debug task | code actions | 0.10 | 0.10 | 0.12 | 0.15 | 3 | 30 |
| Task extraction | code actions | 0.10 | 0.10 | 0.13 | 0.14 | 3 | 30 |

## No file watching (fallback stats)

Indexed files: 1027; initialize-to-index-ready median: 117.6 ms.

| Target | Operation | First ms | Warm median ms | Warm p95 ms | Warm max ms | Results | Samples |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Variable (role read) | definition | 15.31 | 15.34 | 18.09 | 20.68 | 4 | 30 |
| Variable (role read) | implementation | 15.19 | 15.43 | 17.15 | 18.01 | 3 | 30 |
| Variable (role read) | references | 2.61 | 2.65 | 3.60 | 3.77 | 5 | 30 |
| Variable (role read) | hover | 15.26 | 15.49 | 17.95 | 19.41 | 1 | 30 |
| Variable (binding) | definition | 15.29 | 15.75 | 19.44 | 19.95 | 4 | 30 |
| Variable (binding) | implementation | 15.39 | 15.50 | 17.15 | 17.19 | 3 | 30 |
| Variable (binding) | references | 2.43 | 2.56 | 3.05 | 3.42 | 5 | 30 |
| Variable (binding) | hover | 15.45 | 15.38 | 17.47 | 17.68 | 1 | 30 |
| Variable (Jinja template) | definition | 15.29 | 15.49 | 17.85 | 27.19 | 1 | 30 |
| Variable (Jinja template) | implementation | 15.11 | 15.34 | 16.87 | 17.84 | 1 | 30 |
| Variable (Jinja template) | references | 2.43 | 2.52 | 3.52 | 3.63 | 2 | 30 |
| Variable (Jinja template) | hover | 15.36 | 15.63 | 16.65 | 17.51 | 1 | 30 |
| Variable field (read) | definition | 15.37 | 15.35 | 17.28 | 17.84 | 3 | 30 |
| Variable field (read) | implementation | 15.00 | 15.37 | 18.38 | 20.57 | 2 | 30 |
| Variable field (read) | references | 2.40 | 2.45 | 3.11 | 3.27 | 4 | 30 |
| Variable field (read) | hover | 15.66 | 15.37 | 16.70 | 16.92 | 1 | 30 |
| Role parameter | definition | 6.65 | 6.67 | 7.48 | 7.71 | 1 | 30 |
| Role parameter | implementation | 7.25 | 7.39 | 8.46 | 9.18 | 1 | 30 |
| Role parameter | references | 11.44 | 11.59 | 13.15 | 13.54 | 4 | 30 |
| Role parameter | hover | 6.56 | 6.73 | 7.86 | 8.46 | 1 | 30 |
| Role parameter field | definition | 6.66 | 6.73 | 7.49 | 7.84 | 1 | 30 |
| Role parameter field | implementation | 8.73 | 8.88 | 11.08 | 13.19 | 1 | 30 |
| Role parameter field | references | 7.16 | 6.67 | 7.90 | 8.61 | 4 | 30 |
| Role parameter field | hover | 6.62 | 6.68 | 7.57 | 7.70 | 1 | 30 |
| Role (local) | definition | 10.88 | 11.10 | 13.57 | 13.60 | 1 | 30 |
| Role (local) | implementation | 11.64 | 10.92 | 12.06 | 13.00 | 1 | 30 |
| Role (local) | references | 17.76 | 17.15 | 22.05 | 22.58 | 2 | 30 |
| Role (local) | hover | 6.50 | 6.66 | 7.88 | 7.92 | 1 | 30 |
| Role (collection FQCN) | definition | 10.97 | 11.33 | 12.42 | 12.57 | 1 | 30 |
| Role (collection FQCN) | implementation | 11.01 | 10.94 | 12.38 | 13.27 | 1 | 30 |
| Role (collection FQCN) | references | 17.40 | 17.18 | 21.09 | 23.91 | 1 | 30 |
| Role (collection FQCN) | hover | 6.60 | 6.95 | 7.99 | 8.26 | 1 | 30 |
| Role (Galaxy) | definition | 10.95 | 11.68 | 13.62 | 14.25 | 1 | 30 |
| Role (Galaxy) | implementation | 11.11 | 11.04 | 12.17 | 12.80 | 1 | 30 |
| Role (Galaxy) | references | 17.11 | 17.24 | 19.53 | 20.52 | 2 | 30 |
| Role (Galaxy) | hover | 7.14 | 6.71 | 7.57 | 7.69 | 1 | 30 |
| Role (installed collection) | definition | 10.80 | 11.07 | 12.45 | 12.80 | 1 | 30 |
| Role (installed collection) | implementation | 11.07 | 11.28 | 13.16 | 13.87 | 1 | 30 |
| Role (installed collection) | references | 17.06 | 17.44 | 19.47 | 24.17 | 1 | 30 |
| Role (installed collection) | hover | 6.74 | 6.83 | 7.85 | 8.18 | 1 | 30 |
| Collection (Workspace) | definition | 8.78 | 8.74 | 9.48 | 9.76 | 1 | 30 |
| Collection (Workspace) | implementation | N/A | — | — | — | — | 0 |
| Collection (Workspace) | references | 2.13 | 2.16 | 2.58 | 3.00 | 3 | 30 |
| Collection (Workspace) | hover | 4.40 | 4.51 | 4.99 | 5.04 | 1 | 30 |
| Collection (installed) | definition | 8.88 | 8.92 | 10.89 | 16.04 | 1 | 30 |
| Collection (installed) | implementation | N/A | — | — | — | — | 0 |
| Collection (installed) | references | 2.21 | 2.20 | 2.44 | 2.54 | 3 | 30 |
| Collection (installed) | hover | 4.63 | 4.48 | 4.94 | 5.13 | 1 | 30 |
| Task file | definition | 0.39 | 0.40 | 0.49 | 0.54 | 1 | 30 |
| Task file | implementation | N/A | — | — | — | — | 0 |
| Task file | references | 2.30 | 2.35 | 3.15 | 3.22 | 2 | 30 |
| Task file | hover | N/A | — | — | — | — | 0 |
| Vars file | definition | 8.57 | 8.65 | 9.39 | 10.02 | 1 | 30 |
| Vars file | implementation | N/A | — | — | — | — | 0 |
| Vars file | references | 2.76 | 2.25 | 2.72 | 2.95 | 1 | 30 |
| Vars file | hover | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | definition | 9.41 | 8.86 | 10.18 | 11.45 | 1 | 30 |
| Module (builtin fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | hover | 8.51 | 8.79 | 9.52 | 9.55 | 1 | 30 |
| Module (Workspace fixture docs) | definition | 8.74 | 8.96 | 9.57 | 11.36 | 1 | 30 |
| Module (Workspace fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | hover | 8.69 | 8.78 | 9.78 | 11.07 | 1 | 30 |
| Module option | definition | N/A | — | — | — | — | 0 |
| Module option | implementation | N/A | — | — | — | — | 0 |
| Module option | references | N/A | — | — | — | — | 0 |
| Module option | hover | 8.70 | 8.79 | 9.47 | 9.48 | 1 | 30 |
| Play keyword | definition | N/A | — | — | — | — | 0 |
| Play keyword | implementation | N/A | — | — | — | — | 0 |
| Play keyword | references | N/A | — | — | — | — | 0 |
| Play keyword | hover | 8.59 | 8.82 | 9.94 | 10.68 | 1 | 30 |
| Variable (high fan-out) | references | 74.92 | 76.90 | 86.74 | 89.73 | 20001 | 30 |
| Variable (reads only) | references | 2.86 | 2.51 | 3.42 | 3.46 | 1 | 30 |
| Collections | completion | 2.25 | 2.31 | 3.20 | 3.23 | 2 | 30 |
| Play keywords | completion | 0.28 | 0.28 | 0.35 | 0.42 | 41 | 30 |
| Module options | completion | 105.34 | 0.23 | 0.34 | 0.44 | 3 | 30 |
| Module (fixture docs) | completion resolve | 0.19 | 0.19 | 0.25 | 0.27 | 1 | 30 |
| Roles | workspace symbols | 3.36 | 3.10 | 3.80 | 4.33 | 1 | 30 |
| Collections | workspace symbols | 3.08 | 3.13 | 4.13 | 4.30 | 4 | 30 |
| Modules | workspace symbols | 2.88 | 3.07 | 3.83 | 4.21 | 1 | 30 |
| Plugins | workspace symbols | 3.05 | 3.11 | 4.04 | 4.05 | 1 | 30 |
| Playbooks / plays | workspace symbols | 2.94 | 3.09 | 3.62 | 3.90 | 3 | 30 |
| Task files | workspace symbols | 3.12 | 3.11 | 3.79 | 3.83 | 3 | 30 |
| Playbook | document symbols | 0.10 | 0.09 | 0.14 | 0.16 | 1 | 30 |
| Playbook | semantic tokens | 39.67 | 0.23 | 0.28 | 0.31 | 6 | 30 |
| Variable | code actions | 0.12 | 0.12 | 0.17 | 0.20 | 4 | 30 |
| Debug task | code actions | 0.11 | 0.10 | 0.13 | 0.13 | 3 | 30 |
| Task extraction | code actions | 0.10 | 0.11 | 0.19 | 0.20 | 3 | 30 |

