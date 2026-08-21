# ADR 0025: Volume-Aware Path Equality

- Status: Accepted
- Date: 2026-08-20 (amended 2026-08-21: normalization is not a capability)

## Context

Filesystem paths remain Otos's asset identity, but raw SQLite/string equality
treated PRIVATE/... and private/... as different on a case-insensitive volume.
The same defect existed in scan reconciliation, import destination occupancy,
and cross-source reservations.

## Decision

FilesystemNamespaceSemantics.nameKey(relativePath:capabilities:) is the single
owner of path equality. A root stores its probed case-sensitivity — the one
namespace fact Otos probes per volume. Catalog rows retain their physical/display
spelling
in relative_path and store a derived relative_path_key for equality lookup. The
same owner is used by catalog reconciliation, import namespace/reservation
planning, and reorganization planning.

Unicode normalization is *not* a per-volume capability and nameKey always
decomposes. A comparison key has one requirement — both sides normalize the same
way — so the form is arbitrary and consistency is everything. Modelling it per
volume created the possibility of two keys for one path, and that possibility
shipped: two disagreeing "unknown" values keyed the same accented filename two
ways. Measurement found no per-volume variation to probe either; see
docs/research/2026-08-21-volume-normalization-is-not-a-capability.md.

An inconclusive probe reports unknown rather than recording a guessed
case-insensitive as a fact, and persists as NULL so isKnown survives a round
trip. Unknown compares case-insensitively, which can only merge two names, never
split one.

A respelling updates the existing catalog row in place; it is not a deletion.
Migration collisions keep, in order, an imported row, an enriched row, then the
lexicographically first spelling. SQLite NOCASE, unconditional lowercasing, and
content hashing are rejected because they are ASCII-only, destroy
case-sensitive-volume distinctions, or contradict ADR 0008 identity.

## Consequences

The schema gains a probed case-sensitivity column and derived-key columns plus
indexes; migration v19 drops the normalization column v17 added. Overlay and
import provenance survive a respelling. Unknown/detached roots use the shared
case-insensitive fallback until probed. The filesystem remains authoritative and
no durable generated identity is introduced.
