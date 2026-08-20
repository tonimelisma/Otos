# ADR 0025: Volume-Aware Path Equality

- Status: Accepted
- Date: 2026-08-20

## Context

Filesystem paths remain Otos's asset identity, but raw SQLite/string equality
treated PRIVATE/... and private/... as different on a case-insensitive volume.
The same defect existed in scan reconciliation, import destination occupancy,
and cross-source reservations.

## Decision

FilesystemNamespaceSemantics.nameKey(relativePath:capabilities:) is the single
owner of path equality. A root stores its probed case-sensitivity and Unicode
normalization capabilities. Catalog rows retain their physical/display spelling
in relative_path and store a derived relative_path_key for equality lookup. The
same owner is used by catalog reconciliation, import namespace/reservation
planning, and reorganization planning.

A respelling updates the existing catalog row in place; it is not a deletion.
Migration collisions keep, in order, an imported row, an enriched row, then the
lexicographically first spelling. SQLite NOCASE, unconditional lowercasing, and
content hashing are rejected because they are ASCII-only, destroy
case-sensitive-volume distinctions, or contradict ADR 0008 identity.

## Consequences

The schema gains capability and derived-key columns plus indexes. Overlay and
import provenance survive a respelling. Unknown/detached roots use the shared
case-insensitive fallback until probed. The filesystem remains authoritative and
no durable generated identity is introduced.
