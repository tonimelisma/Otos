# ADR 0026: Settled Naming And Explicit Card Erase

- Status: Accepted
- Date: 2026-08-20

## Decision

Import date/time naming is owned by ImportNaming. A source plan is offered only
after every naming fact is **proven**; enrichment that changes capture_wall_compact
advances the import root's naming revision, which re-plans every session reading
that root as its source. It does not advance the namespace revision, so a plan
copying *into* an enriching root is untouched (ARC-046). A row with no embedded
wall clock may use its filesystem modification date **once enrichment has read the
file and established that no embedded date exists**. No date is fabricated.

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
dispositions. An entry a library holds by content (`skipInLibrary`, ADR 0018) enters only
if, at erase time, the catalog still confirms an available library row with that current
digest and no pending trash; a failed read confirms none, and the file stays on the card. Execution does not enumerate the source volume. `SourceEraser` is the
sole destructive source owner, and source deletion requires its root namespace
lease; a fixed library root is rejected as read-only. Namespace-key collisions are
represented as foreign/ambiguous occupancy and never trap or authorize row
deletion. Persisted capability columns remain unknown until both facts are known.

A naming fact is settled by its own question, not by the enrichment staleness
predicate. That predicate answers whether enrichment should run again for the
current file facts; planning asks whether the file can be named. They diverge on
a state the domain models: an asset with no filesystem mtime can never satisfy the
predicate's `metadata_source_mtime` comparison, so it reads stale forever — and
borrowing that answer held such a source in metadata-waiting permanently, even
after enrichment had supplied its capture wall. A known capture wall is therefore
terminal whatever else is outstanding.

A durable mtime is **not** terminal *before enrichment has read the file*. On an
unread row "no capture wall" means "not yet looked at", not "none exists", so naming from the
mtime asserts a fact Otos has not established. For video the assertion is provably
wrong by the clip's own length — a video's mtime is when recording *stopped* — and
because the destination name is also the dedupe key, a later plan computes a
different name, finds nothing at that path, and copies again. The catalog carries
the proof: 23 hash-identical video pairs in one library, both copies written by
Otos, in two import batches five minutes apart, each pair's two names separated by
exactly that video's duration.

A row is terminal once a capture wall is stored, or once enrichment has looked and
found none — its metadata stamp (`metadata_source_size`/`metadata_source_mtime`) present, which
every write of a metadata result sets, so the distinction
needs no new column. The permanent-wait failure this ADR originally fixed stays
fixed: the gate keys on "has enrichment looked", never on the staleness predicate.
Removable volumes make the wait bounded — their bytes are always local, so
enrichment is guaranteed to complete, and only a genuine I/O read failure is
non-terminal. A build that decides to wait revalidates against live rows first,
because a batch landing mid-build is not replayed by the catalog-change wake.

The catalog follows the card as each file is erased. `SourceEraser` reporting a file
deleted, or already gone, is proof of its deletion (ADR 0008), so its catalog row —
media or companion, with its companions re-paired — and its derived images go in the
same durable write that clears its `active_source_erase` journal entry
(`CatalogStore.recordSourceFileErased`, sharing `purgeGonePath` with filesystem-event
reconciliation). Recovery settles both together. Because `.alreadyGone` now removes
overlay, it needs proof: the card's root is a mounted directory and the path answers
`ENOENT`. An unmounted card or any other `lstat` error is a failed erase, which keeps
the row and the journal entry for the next attempt. Leaving the rows to a rescan was the
earlier arrangement: the rescan was deferred behind the erase lease and usually lost
the race with Eject, so the card's next attachment showed files it no longer held.

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
