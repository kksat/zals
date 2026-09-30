# ADR-0034: Match role references by resolved identity

- **Status:** Accepted
- **Date:** 2026-09-30
- **Supersedes:** the Role find-references matching rule in [ADR-0032](0032-workspace-wide-navigation.md)

The name-based Role find-references rule in [ADR-0032](0032-workspace-wide-navigation.md) conflates distinct roles with the same short name and separates short and fully qualified names for the same Role. Find-references will compare each Workspace Role reference's possible resolved role directories in its own context: sites match when those sets overlap, including ambiguous editor fallback results; a reference that resolves nowhere finds only itself. This trades the simplicity of textual matching for references that agree with go-to-definition and go-to-implementation, while leaving Collection and Variable reference rules unchanged.
