# ADR 0022: Recoverable Media Deletion Through System Trash

- Status: Accepted
- Date: 2026-08-13

## Context

Otos normally leaves user media untouched. The product now needs an explicit
Move to Trash action that is separate from Disliked and remains recoverable by
the system. A catalog row may also own an inventoried `.xmp` or `.srt` member,
but filename heuristics cannot safely decide what belongs to a media item.
Import publication and library reorganization already have filesystem/catalog
race boundaries, so Trash must share their root exclusion rather than invent a
second lease.

## Decision

Move to Trash is a durable intent drained by a queue, not a blocking command.
Confirming hides the targets by recording `pending_trash_batch_unix_ms` on their
catalog rows (ARC-058); every user-facing media query excludes those rows, while
the files, rows and overlay stay until the files are proven gone. The intent
survives relaunch, and a scan that sees a file vanish ends it by deleting the row.

`MediaTrashCoordinator` owns the queue. Store supplies each pending item as one
cataloged primary plus its cataloged useful companions, excluding device/MTP
roots. A dataless cloud placeholder cannot leave its File Provider domain:
`trashItem` refuses it with `NSFeatureUnsupportedError` (Cocoa 3328), while the
same file trashes normally once local (`docs/research/trash-dataless-placeholders.md`).
So the coordinator first materializes an item's dataless members through the
shared `MaterializationCoordinator` at `command` priority (user-commanded,
off-screen work: ahead of enrichment, behind on-screen work, and under the
bounded background persistence). Downloads run without the root lease. Once
every member is local, the coordinator acquires the `RootNamespaceMutationLease`
for the root, revalidates ownership and rechecks that each member is still local
(a provider may evict again), calls `FileManager.trashItem` off the MainActor,
companions before the primary, and releases the lease. The lease is never held
across a download.

Download outcomes split three ways. Transient ones (timeout, provider unavailable,
cancellation) leave the item pending and retry with backoff. A definitive refusal
(`requestFailed`), or a download that would leave the volume below the 5 GB
`FreeSpaceFloor` measured at the attempt (ADR 0027), asks the user whether to
delete the items immediately. Only a `Delete` answer to that per-occurrence
question reaches `FileManager.removeItem`; Otos never deletes permanently on its
own. `Cancel` re-shows a failed download's items, and at the floor keeps them
pending, asking nothing more until a later pass finds room. Deleting a dataless
placeholder with `removeItem` succeeds immediately without a download (probed
2026-10-04); whether the provider keeps a cloud recycle-bin copy is its own
behavior, and the prompt promises nothing about it. Every per-path failure logs
its reason with the error domain/code or the materialization outcome.

Each path returns an independent success result. Store reconciliation removes
only catalog rows for paths the filesystem operation reports as moved. A
companion failure does not roll back a preceding success; a primary failure
does not claim that the item fully moved. The next complete reachable scan is
the crash-recovery path and remains the source of truth; no speculative Trash
journal or rollback is added.

The namespace lease has typed owners for import publication, reorganization,
and Media Trash. Only one owner may hold a root at a time. Filesystem events
mark the root dirty and reconcile after release. Import publication acquires
the same lease before exclusive publication, preventing it from starting
against a root currently being trashed or reorganized.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| Automatic permanent deletion or a silent `removeItem` fallback | Violates recoverability; permanent deletion exists only behind an explicit per-occurrence user answer. |
| Trash as one blocking serial command (the previous design) | Holds the lease and the user's command across arbitrarily long downloads, and loses the intent on quit. |
| An in-memory pending set or a separate pending table | Loses the intent on quit, or adds a second identity for a fact that belongs to the asset row. |
| Delete a dataless placeholder in place through the provider (its cloud recycle bin) | Not recoverable from this Mac's Trash, and provider-specific; materializing first keeps one recoverable path for every root. |
| Refuse dataless members with an explanatory message | Most library media is dataless, so Move to Trash would fail for most items. |
| Delete every same-basename sidecar | Invents physical membership and can destroy an unrelated user file. |
| Change Disliked into deletion or hiding | Curation state and filesystem mutation answer different user questions. |
| Rollback after a partial move | System Trash has already changed filesystem truth; pretending rollback succeeded would be false. |
| Durable deletion journal | A complete next scan already reconciles the exact path truth; add durable state only after fault-injection proves it insufficient. |

## Consequences

Move to Trash is registered on the window's one undo stack (APP-039). The queue
records, per command, the location `trashItem` reported for each member and the
item's authored overlay (curation choice, import batch) snapshotted before its row
left the catalog. Undo runs inside the queue's drain task, between passes, so it
never interleaves with a half-finished move: items still pending are withdrawn with
no filesystem call; trashed items are moved back primary first under the root
lease, never over an existing file, then re-cataloged from the filesystem and given
back their overlay. Redo hides the items again under a new command. Undo records
are in memory, like every undo entry; after relaunch Finder's Put Back still
restores the file, without its Otos overlay. Finder's own Put Back is not the undo
because it is not reachable from Otos's ⌘Z and the catalog had already purged the
overlay.

- Move to Trash has no confirmation or success alert: it is undoable (HIG: no alerts for common, undoable actions).
- Partial failures retain truthful catalog rows and selected failed identities and expose Show in Finder/Dismiss with bounded counts and no raw paths.
- Device/MTP media remains outside this filesystem mutation path.
- Trashing a dataless member downloads it first; the local-disk cost lands in the system Trash until it is emptied. A slow provider holds the root lease and the serial trash command for the duration of the download.
