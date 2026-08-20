# ADR 0026: Settled Naming And Explicit Card Erase

- Status: Accepted
- Date: 2026-08-20

## Decision

Import date/time naming is owned by ImportNaming. A source plan is offered only
after every naming fact has reached the existing enrichment predicate's settled
state; enrichment that changes capture_wall_compact advances the import
occupancy revision and causes a re-plan. A settled row with no embedded wall
clock may use its filesystem modification date. No date is fabricated.

An explicit card Erase uses one typed source disposition set. It removes copied
media, preexisting media, useful sidecars, recognized cruft, and recognized
source artifacts only after validating every path under the source root. Unknown
files are untouched. The single preference “Copy sidecars into the library”
controls copying, not cleanup. Zero-byte media is excluded from the library plan
and is nevertheless included in the explicit erase set.

The erase outcome reports actual deleted/skipped/failed counts and bytes. An
erase-only run has no import batch and renders “Card erased · N items deleted”
with Eject Card. This permanent source deletion is distinct from ADR 0022:
Move to Trash remains recoverable system Trash for catalog-proven library
members, while card Erase is explicitly requested to reclaim card space. The
zero-byte exception is unrecoverable only in the vacuous sense that zero bytes
were present.
