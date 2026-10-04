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

`MediaTrashCoordinator` is the lossless serial actor for this command. Store
supplies a snapshot of one cataloged primary plus its cataloged useful
companions, excluding device/MTP roots. The coordinator acquires a
`RootNamespaceMutationLease` for the root, revalidates ownership before each
filesystem await, calls `FileManager.trashItem` off the MainActor, and moves
companions before the primary. It never calls `removeItem` or unlinks.

A dataless cloud placeholder cannot leave its File Provider domain:
`trashItem` refuses it with `NSFeatureUnsupportedError` (Cocoa 3328), while the
same file trashes normally once local (`docs/research/trash-dataless-placeholders.md`).
So immediately before each member's trash call the coordinator checks
`FileMaterialization.status`; a dataless member is deliberately materialized
through the shared `MaterializationCoordinator` at `command` priority
(user-commanded, off-screen work: ahead of enrichment, behind on-screen work, and
under the bounded background persistence, so a stuck provider fails the member
instead of holding the lease and the serial command indefinitely), and the
lease is revalidated after that await. A member that does not become local fails that path without a trash
call. Every per-path failure logs its reason with the error domain/code or the
materialization outcome.

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
| Permanent deletion or an `removeItem` fallback | Violates recoverability and the explicit system-Trash contract. |
| Delete a dataless placeholder in place through the provider (its cloud recycle bin) | Not recoverable from this Mac's Trash, and provider-specific; materializing first keeps one recoverable path for every root. |
| Refuse dataless members with an explanatory message | Most library media is dataless, so Move to Trash would fail for most items. |
| Delete every same-basename sidecar | Invents physical membership and can destroy an unrelated user file. |
| Change Disliked into deletion or hiding | Curation state and filesystem mutation answer different user questions. |
| Rollback after a partial move | System Trash has already changed filesystem truth; pretending rollback succeeded would be false. |
| Durable deletion journal | A complete next scan already reconciles the exact path truth; add durable state only after fault-injection proves it insufficient. |

## Consequences

Move to Trash is not registered on the app's curation undo stack (APP-039): the
system Trash's Put Back is its undo, and a second, app-side reversal of a
filesystem move would be a competing owner of the same fact.

- Successful moves have no confirmation or success alert because system Trash is recoverable.
- Partial failures retain truthful catalog rows and selected failed identities and expose Show in Finder/Dismiss with bounded counts and no raw paths.
- Device/MTP media remains outside this filesystem mutation path.
- Trashing a dataless member downloads it first; the local-disk cost lands in the system Trash until it is emptied. A slow provider holds the root lease and the serial trash command for the duration of the download.
