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
companions before the primary, reports the moves to the Store
(`reconcileTrashedPaths`, which takes that lease and refuses a report without it),
and releases the lease. Without it the reconcile a report requests could find a moved
file gone before its row names the Trash and purge the row with its overlay. The
lease is never held across a download.

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

Each path returns an independent success result. A media row whose file
`trashItem` moved is **kept**, still hidden under its command, with the file path
the Trash reported (`media_asset.trash_path`): an item in the system Trash is not
proven deleted (ADR 0008), so everything Otos holds for it — curation, edit, import
batch, thumbnail and preview — stays on the row. A scan purges such a row only
when the Trash no longer holds that file (`lstat` reports `ENOENT`; any other
answer keeps it for the next scan). A file seen again at the row's own path —
Finder's Put Back, in this run or after a relaunch, or Otos's own undo — shows the
row again, because path is identity. A companion row, and a file deleted
immediately, leave the catalog at once. A companion failure does not roll back a
preceding success; a primary failure does not claim that the item fully moved. The next complete reachable scan is
the crash-recovery path and remains the source of truth; no speculative Trash
journal or rollback is added.

The one question asked before anything is hidden, a download of more than 100 MB of
cloud-only members (APP-045, DES-090), is a property of the targets and is read when they
change, not when the command arrives. The window holds no locality fact of its own, and
nothing is stored: whenever a target writer changes the targets, a ViewModel lane (ADR 0032)
sizes the command they would make with `MediaTrashCoordinator.downloadBytes` off the main
actor and keeps that reading, of exactly those files, in memory. A command of the same files
asks or hides in the step that applies it; any other command reads for itself before
anything is hidden. The reading can be seconds or minutes old: a file evicted since moves
without the question, and the queue still downloads it under the free-space floor and asks
when a download fails; a file downloaded since is still asked about. The queue checks every
member again under the lease before it moves it, as above
(`docs/research/2026-11-15-trash-question-at-selection.md`).

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
| Purge the row once the file is in the Trash, snapshotting overlay for undo | Loses the overlay for good after a relaunch, though the file is recoverable; the item is not proven deleted. |
| A separate trashed-items table re-matched on Put Back | A second record of the same asset; the kept row already is that record, and Put Back returns the file to the row's own path. |
| Size the large-download question when the command arrives | Waits one actor hop and an `lstat` per target before anything is hidden, a wait with no bound on a starved cooperative pool. |
| Hide the targets known local and ask about the rest | Splits one command into two: what is hidden, what Undo covers and what the question names stop being the command the user gave. |
| Persist the undo stack across launches | Not a macOS idiom; Finder's Put Back is the system's way back, and the kept row makes it complete. |

## Consequences

Move to Trash is registered on the window's one undo stack (APP-039). The queue
records, per command, the location `trashItem` reported for each member. Undo runs
inside the queue's drain task, between passes, so it never interleaves with a
half-finished move: items still pending are withdrawn with no filesystem call;
trashed items are moved back primary first under the root lease, never over an
existing file, and reconciled from the filesystem, which shows their kept rows
again. Undo shows its result before that work, as the move does (DES-119, APP-085):
the window shows the items again in the step that applies Undo, and items the queue
then cannot put back leave again under the put-back alert. The file work takes from a
few milliseconds to tens (a cloud placeholder's put-back waits on its provider), and the
act's result must be visible within 100 ms whatever it takes; a failure is rare and is
reported, as a failed move is. Waiting for the Store before showing anything was the
rejected alternative: it made Undo the one act whose result waited on the filesystem.
Redo hides the items again under a new command. Undo records are in memory,
like every undo entry; after a relaunch, Finder's Put Back is the way back, and it
returns the item with its overlay because the row was kept.

The trash status bar's **Cancel** withdraws every item still waiting to move, read
from the pending rows themselves, so a request left from an earlier run can be taken
back when no undo entry remains (DES-089). Items already in the Trash stay there.

- Move to Trash has no confirmation or success alert: it is undoable (HIG: no alerts for common, undoable actions).
- Partial failures retain truthful catalog rows and selected failed identities and expose Show in Finder/Dismiss with bounded counts and no raw paths.
- Device/MTP media remains outside this filesystem mutation path.
- Trashing a dataless member downloads it first; the local-disk cost lands in the system Trash until it is emptied. A slow provider holds the root lease and the serial trash command for the duration of the download.
