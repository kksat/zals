# LSP operation latency

Generated: 2026-10-06T23:58:59.091893+00:00
Build label: Debug; platform: macOS-26.7-arm64-arm-64bit-Mach-O / arm64
Binary SHA-256: `a4e748a64415e4f6f6419c2b9b60ab4a18c27f6e5dbdaff3c7e98aa09bb02092`

Fixture: 1000 background files × 20 tasks; 3 fresh sessions/mode; 10 warm samples/session/case.

All times are end-to-end stdio round-trip milliseconds, including JSON transport/decoding.
First = median first observation per session, **not** an isolated cold-cache request; cases share a session.
Warm samples are interleaved in seeded shuffled order. p95 uses nearest rank; max includes outliers.
Ansible tools/docs are deterministic Python fixtures, not measurements of real ansible-doc or plugin discovery.
N/A = no target-specific provider; omitted rather than timing empty/fallback results.
Results = returned locations/items/top-level document symbols, or token count; hover/resolve = 1.
Warmup passes: 2; shuffle seed: 42; filter: `(all)`.

## File watching enabled

Indexed files: 1027; initialize-to-index-ready median: 279.0 ms.

| Target | Operation | First ms | Warm median ms | Warm p95 ms | Warm max ms | Results | Samples |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Variable (role read) | definition | 49.67 | 49.41 | 51.23 | 51.63 | 4 | 30 |
| Variable (role read) | implementation | 48.48 | 49.74 | 53.62 | 53.75 | 3 | 30 |
| Variable (role read) | references | 7.64 | 7.86 | 8.65 | 8.92 | 5 | 30 |
| Variable (role read) | hover | 49.23 | 49.64 | 53.01 | 60.19 | 1 | 30 |
| Variable (binding) | definition | 50.18 | 49.34 | 52.15 | 52.38 | 4 | 30 |
| Variable (binding) | implementation | 50.68 | 49.73 | 51.14 | 52.75 | 3 | 30 |
| Variable (binding) | references | 7.73 | 7.78 | 8.73 | 9.69 | 5 | 30 |
| Variable (binding) | hover | 50.73 | 49.61 | 50.88 | 51.82 | 1 | 30 |
| Variable (Jinja template) | definition | 49.78 | 49.71 | 53.10 | 53.50 | 1 | 30 |
| Variable (Jinja template) | implementation | 48.81 | 49.27 | 51.38 | 51.41 | 1 | 30 |
| Variable (Jinja template) | references | 7.67 | 7.64 | 8.30 | 8.64 | 2 | 30 |
| Variable (Jinja template) | hover | 49.17 | 49.43 | 51.18 | 54.21 | 1 | 30 |
| Variable field (read) | definition | 48.56 | 49.60 | 53.26 | 64.78 | 3 | 30 |
| Variable field (read) | implementation | 49.12 | 49.00 | 51.45 | 54.49 | 2 | 30 |
| Variable field (read) | references | 7.20 | 7.21 | 7.71 | 7.88 | 4 | 30 |
| Variable field (read) | hover | 49.67 | 48.82 | 56.74 | 58.71 | 1 | 30 |
| Role parameter | definition | 12.35 | 12.41 | 13.38 | 13.47 | 1 | 30 |
| Role parameter | implementation | 13.46 | 13.46 | 14.31 | 14.42 | 1 | 30 |
| Role parameter | references | 18.54 | 18.40 | 19.37 | 19.40 | 4 | 30 |
| Role parameter | hover | 12.75 | 12.53 | 13.43 | 13.81 | 1 | 30 |
| Role parameter field | definition | 13.04 | 12.54 | 12.94 | 13.02 | 1 | 30 |
| Role parameter field | implementation | 19.57 | 19.47 | 22.30 | 26.69 | 1 | 30 |
| Role parameter field | references | 12.55 | 12.66 | 14.23 | 14.28 | 4 | 30 |
| Role parameter field | hover | 12.62 | 12.46 | 13.66 | 16.73 | 1 | 30 |
| Role (local) | definition | 17.93 | 18.00 | 19.32 | 20.41 | 1 | 30 |
| Role (local) | implementation | 18.04 | 17.55 | 19.71 | 19.74 | 1 | 30 |
| Role (local) | references | 55.33 | 55.62 | 57.67 | 57.98 | 2 | 30 |
| Role (local) | hover | 12.33 | 12.46 | 13.65 | 13.85 | 1 | 30 |
| Role (collection FQCN) | definition | 17.63 | 17.91 | 18.99 | 19.39 | 1 | 30 |
| Role (collection FQCN) | implementation | 18.42 | 17.72 | 21.63 | 22.10 | 1 | 30 |
| Role (collection FQCN) | references | 55.36 | 55.66 | 59.64 | 86.90 | 1 | 30 |
| Role (collection FQCN) | hover | 12.34 | 12.46 | 13.36 | 14.29 | 1 | 30 |
| Role (Galaxy) | definition | 17.77 | 17.89 | 19.08 | 21.97 | 1 | 30 |
| Role (Galaxy) | implementation | 18.24 | 17.70 | 19.30 | 19.52 | 1 | 30 |
| Role (Galaxy) | references | 54.88 | 55.39 | 57.60 | 59.93 | 2 | 30 |
| Role (Galaxy) | hover | 12.54 | 12.57 | 13.31 | 13.66 | 1 | 30 |
| Role (installed collection) | definition | 17.62 | 17.87 | 20.27 | 20.38 | 1 | 30 |
| Role (installed collection) | implementation | 17.67 | 17.84 | 19.27 | 21.19 | 1 | 30 |
| Role (installed collection) | references | 54.55 | 55.79 | 58.64 | 71.64 | 1 | 30 |
| Role (installed collection) | hover | 12.44 | 12.40 | 13.00 | 13.40 | 1 | 30 |
| Collection (Workspace) | definition | 10.80 | 11.01 | 12.48 | 16.31 | 1 | 30 |
| Collection (Workspace) | implementation | N/A | — | — | — | — | 0 |
| Collection (Workspace) | references | 7.21 | 6.89 | 8.04 | 11.29 | 3 | 30 |
| Collection (Workspace) | hover | 5.62 | 5.71 | 6.07 | 6.26 | 1 | 30 |
| Collection (installed) | definition | 10.99 | 10.98 | 11.33 | 11.50 | 1 | 30 |
| Collection (installed) | implementation | N/A | — | — | — | — | 0 |
| Collection (installed) | references | 6.78 | 6.94 | 7.45 | 7.74 | 3 | 30 |
| Collection (installed) | hover | 5.50 | 5.61 | 6.25 | 6.25 | 1 | 30 |
| Task file | definition | 0.62 | 0.63 | 0.71 | 1.09 | 1 | 30 |
| Task file | implementation | N/A | — | — | — | — | 0 |
| Task file | references | 7.01 | 7.16 | 8.11 | 8.18 | 2 | 30 |
| Task file | hover | N/A | — | — | — | — | 0 |
| Vars file | definition | 10.67 | 10.82 | 11.52 | 11.91 | 1 | 30 |
| Vars file | implementation | N/A | — | — | — | — | 0 |
| Vars file | references | 6.89 | 6.98 | 8.01 | 10.42 | 1 | 30 |
| Vars file | hover | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | definition | 11.22 | 11.16 | 11.61 | 11.78 | 1 | 30 |
| Module (builtin fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | hover | 10.98 | 11.08 | 12.72 | 12.74 | 1 | 30 |
| Module (Workspace fixture docs) | definition | 11.17 | 11.20 | 12.75 | 13.48 | 1 | 30 |
| Module (Workspace fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | hover | 11.44 | 11.10 | 11.58 | 11.81 | 1 | 30 |
| Module option | definition | N/A | — | — | — | — | 0 |
| Module option | implementation | N/A | — | — | — | — | 0 |
| Module option | references | N/A | — | — | — | — | 0 |
| Module option | hover | 10.91 | 11.03 | 11.71 | 12.75 | 1 | 30 |
| Play keyword | definition | N/A | — | — | — | — | 0 |
| Play keyword | implementation | N/A | — | — | — | — | 0 |
| Play keyword | references | N/A | — | — | — | — | 0 |
| Play keyword | hover | 11.31 | 10.94 | 11.86 | 12.12 | 1 | 30 |
| Variable (high fan-out) | references | 250.82 | 245.99 | 255.95 | 262.02 | 20001 | 30 |
| Variable (reads only) | references | 7.54 | 7.74 | 8.48 | 9.63 | 1 | 30 |
| Collections | completion | 7.60 | 7.15 | 7.91 | 8.12 | 2 | 30 |
| Play keywords | completion | 0.53 | 0.55 | 0.71 | 0.78 | 41 | 30 |
| Module options | completion | 107.59 | 0.41 | 0.56 | 0.57 | 3 | 30 |
| Module (fixture docs) | completion resolve | 0.30 | 0.32 | 0.35 | 0.37 | 1 | 30 |
| Roles | workspace symbols | 13.22 | 13.17 | 14.62 | 18.62 | 1 | 30 |
| Collections | workspace symbols | 13.17 | 13.67 | 15.02 | 15.78 | 4 | 30 |
| Modules | workspace symbols | 12.98 | 13.03 | 13.56 | 14.14 | 1 | 30 |
| Plugins | workspace symbols | 13.10 | 13.19 | 13.89 | 13.95 | 1 | 30 |
| Playbooks / plays | workspace symbols | 13.69 | 13.58 | 14.77 | 15.95 | 3 | 30 |
| Task files | workspace symbols | 12.67 | 12.64 | 13.35 | 13.38 | 3 | 30 |
| Playbook | document symbols | 0.24 | 0.20 | 0.25 | 0.29 | 1 | 30 |
| Playbook | semantic tokens | 42.56 | 0.40 | 0.49 | 0.50 | 6 | 30 |
| Variable | code actions | 0.28 | 0.28 | 0.34 | 0.36 | 4 | 30 |
| Debug task | code actions | 0.25 | 0.26 | 0.31 | 0.32 | 3 | 30 |
| Task extraction | code actions | 0.26 | 0.26 | 0.30 | 0.31 | 3 | 30 |

## No file watching (fallback stats)

Indexed files: 1027; initialize-to-index-ready median: 286.0 ms.

| Target | Operation | First ms | Warm median ms | Warm p95 ms | Warm max ms | Results | Samples |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Variable (role read) | definition | 56.11 | 57.81 | 62.00 | 66.73 | 4 | 30 |
| Variable (role read) | implementation | 58.09 | 57.65 | 65.28 | 81.70 | 3 | 30 |
| Variable (role read) | references | 9.36 | 9.18 | 10.19 | 11.56 | 5 | 30 |
| Variable (role read) | hover | 57.40 | 58.14 | 61.48 | 62.40 | 1 | 30 |
| Variable (binding) | definition | 57.42 | 57.40 | 65.55 | 66.95 | 4 | 30 |
| Variable (binding) | implementation | 57.35 | 57.86 | 66.48 | 69.13 | 3 | 30 |
| Variable (binding) | references | 9.23 | 9.09 | 9.71 | 10.28 | 5 | 30 |
| Variable (binding) | hover | 58.39 | 58.14 | 73.72 | 73.98 | 1 | 30 |
| Variable (Jinja template) | definition | 58.25 | 57.38 | 70.15 | 79.29 | 1 | 30 |
| Variable (Jinja template) | implementation | 57.89 | 57.57 | 65.58 | 84.50 | 1 | 30 |
| Variable (Jinja template) | references | 8.83 | 8.99 | 10.31 | 10.53 | 2 | 30 |
| Variable (Jinja template) | hover | 56.17 | 57.94 | 64.09 | 75.76 | 1 | 30 |
| Variable field (read) | definition | 56.42 | 57.29 | 65.11 | 80.42 | 3 | 30 |
| Variable field (read) | implementation | 57.52 | 56.81 | 58.56 | 65.65 | 2 | 30 |
| Variable field (read) | references | 8.46 | 8.61 | 9.82 | 9.93 | 4 | 30 |
| Variable field (read) | hover | 56.44 | 56.90 | 64.60 | 70.93 | 1 | 30 |
| Role parameter | definition | 14.42 | 13.97 | 16.81 | 17.22 | 1 | 30 |
| Role parameter | implementation | 14.56 | 14.92 | 18.52 | 19.88 | 1 | 30 |
| Role parameter | references | 19.44 | 20.07 | 23.30 | 23.63 | 4 | 30 |
| Role parameter | hover | 13.91 | 14.19 | 17.38 | 19.04 | 1 | 30 |
| Role parameter field | definition | 13.36 | 14.35 | 15.85 | 15.98 | 1 | 30 |
| Role parameter field | implementation | 21.39 | 22.39 | 24.65 | 25.72 | 1 | 30 |
| Role parameter field | references | 14.17 | 13.93 | 17.57 | 23.61 | 4 | 30 |
| Role parameter field | hover | 13.81 | 13.89 | 16.54 | 16.87 | 1 | 30 |
| Role (local) | definition | 18.90 | 19.60 | 25.66 | 774.29 | 1 | 30 |
| Role (local) | implementation | 19.59 | 19.37 | 23.15 | 23.22 | 1 | 30 |
| Role (local) | references | 66.50 | 64.61 | 69.90 | 79.72 | 2 | 30 |
| Role (local) | hover | 14.13 | 14.43 | 16.05 | 313.30 | 1 | 30 |
| Role (collection FQCN) | definition | 19.14 | 19.82 | 21.62 | 21.67 | 1 | 30 |
| Role (collection FQCN) | implementation | 19.06 | 19.48 | 22.83 | 23.54 | 1 | 30 |
| Role (collection FQCN) | references | 68.19 | 65.75 | 75.98 | 99.41 | 1 | 30 |
| Role (collection FQCN) | hover | 13.50 | 14.01 | 16.50 | 22.02 | 1 | 30 |
| Role (Galaxy) | definition | 19.05 | 19.52 | 24.38 | 64.31 | 1 | 30 |
| Role (Galaxy) | implementation | 18.93 | 19.48 | 22.73 | 23.24 | 1 | 30 |
| Role (Galaxy) | references | 66.72 | 65.02 | 66.65 | 74.10 | 2 | 30 |
| Role (Galaxy) | hover | 14.98 | 14.20 | 16.00 | 16.52 | 1 | 30 |
| Role (installed collection) | definition | 19.02 | 19.28 | 22.70 | 23.97 | 1 | 30 |
| Role (installed collection) | implementation | 18.91 | 19.74 | 24.81 | 25.60 | 1 | 30 |
| Role (installed collection) | references | 63.73 | 64.85 | 68.97 | 73.56 | 1 | 30 |
| Role (installed collection) | hover | 13.60 | 14.32 | 36.34 | 89.23 | 1 | 30 |
| Collection (Workspace) | definition | 10.96 | 11.21 | 14.40 | 15.35 | 1 | 30 |
| Collection (Workspace) | implementation | N/A | — | — | — | — | 0 |
| Collection (Workspace) | references | 8.06 | 8.22 | 8.80 | 9.14 | 3 | 30 |
| Collection (Workspace) | hover | 5.49 | 5.75 | 7.93 | 8.21 | 1 | 30 |
| Collection (installed) | definition | 10.84 | 11.10 | 14.32 | 16.06 | 1 | 30 |
| Collection (installed) | implementation | N/A | — | — | — | — | 0 |
| Collection (installed) | references | 7.91 | 8.26 | 9.12 | 9.34 | 3 | 30 |
| Collection (installed) | hover | 5.84 | 5.74 | 8.92 | 10.77 | 1 | 30 |
| Task file | definition | 0.57 | 0.62 | 0.70 | 1.08 | 1 | 30 |
| Task file | implementation | N/A | — | — | — | — | 0 |
| Task file | references | 8.50 | 8.42 | 9.04 | 9.32 | 2 | 30 |
| Task file | hover | N/A | — | — | — | — | 0 |
| Vars file | definition | 10.87 | 10.98 | 14.88 | 31.73 | 1 | 30 |
| Vars file | implementation | N/A | — | — | — | — | 0 |
| Vars file | references | 8.14 | 8.27 | 9.22 | 9.80 | 1 | 30 |
| Vars file | hover | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | definition | 11.05 | 11.30 | 14.82 | 16.09 | 1 | 30 |
| Module (builtin fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (builtin fixture docs) | hover | 23.93 | 11.38 | 15.69 | 16.00 | 1 | 30 |
| Module (Workspace fixture docs) | definition | 11.24 | 11.19 | 15.28 | 130.26 | 1 | 30 |
| Module (Workspace fixture docs) | implementation | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | references | N/A | — | — | — | — | 0 |
| Module (Workspace fixture docs) | hover | 11.01 | 11.25 | 15.46 | 46.33 | 1 | 30 |
| Module option | definition | N/A | — | — | — | — | 0 |
| Module option | implementation | N/A | — | — | — | — | 0 |
| Module option | references | N/A | — | — | — | — | 0 |
| Module option | hover | 11.13 | 11.23 | 15.00 | 17.68 | 1 | 30 |
| Play keyword | definition | N/A | — | — | — | — | 0 |
| Play keyword | implementation | N/A | — | — | — | — | 0 |
| Play keyword | references | N/A | — | — | — | — | 0 |
| Play keyword | hover | 10.94 | 11.25 | 14.66 | 722.84 | 1 | 30 |
| Variable (high fan-out) | references | 246.75 | 252.88 | 282.00 | 362.88 | 20001 | 30 |
| Variable (reads only) | references | 9.25 | 9.04 | 11.22 | 11.49 | 1 | 30 |
| Collections | completion | 8.55 | 8.35 | 9.47 | 10.72 | 2 | 30 |
| Play keywords | completion | 0.54 | 0.56 | 0.67 | 0.75 | 41 | 30 |
| Module options | completion | 100.03 | 0.43 | 0.61 | 0.91 | 3 | 30 |
| Module (fixture docs) | completion resolve | 0.30 | 0.32 | 0.63 | 5.47 | 1 | 30 |
| Roles | workspace symbols | 14.75 | 14.50 | 15.32 | 16.70 | 1 | 30 |
| Collections | workspace symbols | 15.76 | 15.02 | 19.17 | 19.60 | 4 | 30 |
| Modules | workspace symbols | 14.44 | 14.49 | 19.79 | 19.83 | 1 | 30 |
| Plugins | workspace symbols | 14.02 | 14.40 | 25.36 | 39.45 | 1 | 30 |
| Playbooks / plays | workspace symbols | 14.69 | 14.83 | 16.20 | 50.23 | 3 | 30 |
| Task files | workspace symbols | 13.61 | 14.12 | 14.98 | 15.33 | 3 | 30 |
| Playbook | document symbols | 0.24 | 0.21 | 0.29 | 0.32 | 1 | 30 |
| Playbook | semantic tokens | 44.14 | 0.39 | 0.48 | 0.52 | 6 | 30 |
| Variable | code actions | 0.30 | 0.28 | 0.38 | 3.30 | 4 | 30 |
| Debug task | code actions | 0.25 | 0.26 | 0.31 | 0.34 | 3 | 30 |
| Task extraction | code actions | 0.25 | 0.26 | 0.35 | 0.35 | 3 | 30 |

