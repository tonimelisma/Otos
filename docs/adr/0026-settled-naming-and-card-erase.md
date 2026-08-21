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

The plan also owns an immutable `EraseManifest`. It contains only paths classified
as media, useful sidecars, recognized cruft, or recognized source artifacts; unknown
files are never added. A copy path enters the execution candidate set only after
that entry publishes, while preexisting and excluded entries enter from their plan
dispositions. Execution does not enumerate the source volume. `SourceEraser` is the
sole destructive source owner, and source deletion requires its root namespace
lease; a fixed library root is rejected as read-only. Namespace-key collisions are
represented as foreign/ambiguous occupancy and never trap or authorize row
deletion. Persisted capability columns remain unknown until both facts are known.

A naming fact is settled by its own question, not by the enrichment staleness
predicate. That predicate answers whether enrichment should run again for the
current file facts; planning asks whether the file can be named. They diverge on
a state the domain models: an asset with no filesystem mtime can never satisfy the
predicate's `enriched_source_mtime` comparison, so it reads stale forever — and
borrowing that answer held such a source in metadata-waiting permanently, even
after enrichment had supplied its capture wall. A known capture wall is terminal,
as is a durable mtime; only a row with neither is pending.

Source deletion has exactly one implementation. `SourceEraser` is it, every
caller routes through it, and it refuses fixed library roots. The previous
arrangement documented that ownership while a second `FileManager.removeItem`
sat in the erase sweep applying the opposite policy to library roots.

The erase sweep takes the source root's namespace lease for the sweep alone,
after the copy phase, and a denial reports an incomplete erase. Taking it before
the copy suppressed the source root's reconcile and scan scheduling for the whole
batch, and turned a momentarily busy namespace into a failed import announced to
the user as "The card was removed" — the lease acquisition could not distinguish
a busy root from an absent one. It now returns a typed result that can.
