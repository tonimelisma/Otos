# Plan 0104: Recoverable Move to Trash for cloud-only media, with undo

Status: active. Owner decisions D1–D5 recorded 2026-10-04; D6 is a research follow-up.
Opened: 2026-10-04.

## Why

Move to Trash failed for every cloud-only (dataless) OneDrive item, because
`FileManager.trashItem` refuses a dataless File Provider placeholder
(`NSCocoaErrorDomain` 3328). PR #419 fixed the failure by downloading each dataless
member through `MaterializationCoordinator` before trashing it. That left three gaps:

1. **Unbounded wait.** The trash download runs at `.interactive` priority, whose
   `Persistence` has `deadline: nil`, and nothing cancels the trash task. An offline
   provider holds the root namespace lease and disables Move to Trash until relaunch.
2. **No undo.** ADR 0022 and APP-039 keep Move to Trash off the undo stack and point at
   Finder's Put Back. Put Back is reported to be Finder-only, and the catalog purges the
   item's overlay (curation choice, import batch) the moment it is trashed.
3. **Large batches.** Trashing hundreds of cloud-only items, or a few large videos,
   downloads gigabytes inside one serial command with no state and no feedback.

## Owner direction (2026-10-04)

- Option A from the research: Otos owns undo via the system Trash location.
- Keep state for items that are waiting to be downloaded before they can be trashed.
  Many items are queued, not done in one blocking command.
- When a Move to Trash needs more than 100 MB of downloads, prompt: for undo, Otos
  downloads these first and moves them to the Trash only once they're local, rather
  than losing them. The prompt can be dismissed permanently, and a Settings control
  carries the same preference.
- Items waiting for deletion are hidden in Otos until they are actually gone.
- Follow the HIG for the prompt and the setting.

## Research basis

`docs/research/trash-dataless-placeholders.md` (to be extended in increment 1 with the
2026-10-04 findings):

- Finder's Move to Trash downloaded small cloud-only files and put them in the Mac
  Trash. A 1 GiB cloud-only file the owner moved to the Trash by hand did not appear
  in the Mac Trash. The rule behind that difference is unproven (D-research below).
- Media apps with real undo keep the deleted item reachable by the app: Capture One
  (catalog Trash, Edit ▸ Undo Move to Trash), digiKam (`.dtrash`, undo since 6.0),
  Apple Photos and Lightroom desktop (Recently Deleted / Deleted, 30 days), Bridge
  (⌘Z moves back from the system Trash). Lightroom Classic has no undo for Delete
  from Disk, and in cloud-synced folders it is reported to bypass the Trash entirely.
- An app-owned trash (vault, or a trash folder inside media folders) is ruled out by
  Otos's principles. The system Trash plus `trashItem`'s `resultingItemURL` is the
  one route that keeps undo without either.
- HIG Alerts: *"Avoid displaying alerts for common, undoable actions, even when
  they're destructive."* Alerts are for uncommon or costly actions. macOS alerts may
  carry a suppression checkbox; AppKit's default title for a multi-button alert is
  `Do not ask again` (`NSAlert.showsSuppressionButton`; SwiftUI
  `dialogSuppressionToggle`). Button titles are verbs naming the result; `Cancel`
  is always titled `Cancel`; a deliberately chosen destructive act is not styled
  destructive.
- HIG Settings: minimize settings; put infrequently changed, general options in
  Settings; prefer good defaults over options.

## Target behavior

### Item lifecycle

```
present ──Move to Trash──▶ pending (hidden) ──local + trashed──▶ gone
   ▲                          │       │
   │        ⌘Z (still pending)│       └─ file vanished on disk ─▶ gone (no trash)
   └──────────────────────────┘
gone ──⌘Z (file still in Trash)──▶ present (overlay restored)
```

- **Pending** is a durable fact: the user asked for this item to be trashed, and Otos
  has not yet moved it. It survives relaunch. The file still exists on disk, so its
  catalog row and overlay are kept (ADR 0008 lifecycle is unchanged: nothing is
  purged until the file is proven gone from the root).
- Pending items are excluded from every media query: grid, filmstrip, loupe, compare,
  sidebar counts, import-batch counts, empty states. Selection and focus advance as
  they do today after a completed trash.
- An item leaves pending in exactly one of three ways: it is trashed, its file
  vanishes on disk (an external delete or move; the normal scan reconciles it), or
  the user undoes.
- A local item in the same batch as cloud-only ones is trashed immediately; it does
  not wait for the downloads.

### Download and trash pipeline

- One owner, `MediaTrashCoordinator`, drains the durable pending queue: it submits
  downloads for dataless members to `MaterializationCoordinator`, and once all of an
  item's members are local it acquires the root lease, re-checks every member is
  still local (a provider may evict again), trashes companions before the primary,
  and releases the lease.
- **The lease is held only for the moves, never across a download.** That removes
  the unbounded lease hold.
- Downloads use a bounded persistence (deadline + fail-fast on provider refusal).
  A transient outcome (`timedOut`, `providerUnavailable`, `cancelled`) leaves the
  item pending for a later retry with backoff; see D3 for permanent failures.
- Free space: downloads follow the same measured-at-the-attempt floor as import
  (ADR 0027). At the floor the queue pauses and items stay pending (see D4).
- On launch the coordinator resumes the queue from the durable rows.

### Undo and redo

- Each Move to Trash registers one undo entry on the window's single undo manager
  (the same one curation uses): `Undo Move to Trash` / `Redo Move to Trash`.
- **Undo of a batch still pending:** delete its pending rows; items reappear at once.
  Downloads already finished stay local (harmless).
- **Undo of a trashed batch:** for each member, move `resultingItemURL` back to its
  original path under the root lease (companions after the primary). Then restore the
  item's authored overlay from the snapshot taken when it was trashed: curation choice
  and import-batch provenance. Rebuildable overlay (thumbnails, metadata) is
  re-enriched normally.
- Undo fails truthfully per item when the file is no longer at `resultingItemURL`
  (Trash emptied, Put Back used, moved) or the original path is now occupied. It
  never overwrites. Failures reuse the existing Show in Finder / Dismiss alert shape.
- Redo re-queues the batch.
- The undo record (trash locations + overlay snapshot) lives in memory for the
  session, like every other undo entry. After a relaunch, Finder's Put Back is the
  only route back, and it restores the file but not its Otos overlay.
- A restored cloud file is re-uploaded by the provider. The delete had already
  reached the cloud.

### Large-download prompt

Shown when one Move to Trash needs more than **100 MB** of downloads: the summed
catalog `byte_size` of its *dataless* members only (local members need no download).
The size comes from filesystem facts, so no bytes are read to decide.

Draft (DES-035/036/037 wording; final copy reviewed in increment 4):

- Title: `Download 1.2 GB to Move 14 Items to Trash?`
- Message: `These items are only in OneDrive. Otos downloads them first so you can restore them from the Trash. They're hidden in Otos until then.`
- Buttons: `Download and Move to Trash` (default, not destructive-styled, because the
  user deliberately chose the act), `Cancel`.
- Suppression checkbox: `Do not ask again` (AppKit's default title).

Naming the provider (`only in OneDrive`) requires an API that reports a root's File
Provider domain display name. Increment 4 verifies one exists before using it;
without a verified source the message says `only in the cloud`. Otos never infers the
provider from the path.

### Setting

Settings ▸ General gains one checkbox, bound to the same preference the suppression
checkbox writes:

- `Ask before downloading more than 100 MB to move items to the Trash`

The 100 MB threshold is fixed, not a setting (HIG: minimize settings). Clearing the
checkbox and ticking `Do not ask again` are one fact with two editors.

## Increments

Each increment is one PR with its own requirement/ADR updates, `script/check.sh`
evidence and DoD.

1. **Bounded trash download + research.** Trash downloads use a bounded persistence;
   a stuck provider fails the item truthfully instead of holding the lease forever.
   Extend `docs/research/trash-dataless-placeholders.md` with the Finder probes, the
   1 GiB manual result, the media-app survey and the HIG findings. Small, ships first.
2. **Durable pending queue + hiding.** Catalog schema: a pending-trash table keyed by
   `(library_root_id, relative_path)` with batch identity and request time
   (migration with an explicit version step). Store excludes pending rows from every
   media query. `MediaTrashCoordinator` becomes the queue owner described above:
   resume on launch, lease only around moves, retry with backoff, free-space floor.
   ADR 0022 rewritten; APP-027 updated; new ARC row for the pending fact.
3. **Undo / redo.** Overlay snapshot at trash time; `resultingItemURL` recorded per
   member; undo and redo on the shared undo manager through the serial trash owner.
   APP-039 rewritten (Trash joins the stack); DES-076 updated for undo failures.
4. **Large-download prompt + setting.** Threshold computed from catalog facts; prompt
   with suppression; Settings ▸ General checkbox; DES rows for the prompt; APP row
   for the setting. Design check (C) in full: L1 fact, zones, light/dark, grayscale,
   keyboard-only, Reduce Motion.

## Tests (per increment, observable behavior only)

- 1: a provider that never materializes fails the item within the deadline and
  releases the lease (`hasNamespaceMutationLease == false`); trash stays available.
- 2: a pending item is absent from grid, counts and import-batch queries while its
  file exists; relaunch (new Store on the same database) resumes and trashes it; an
  externally deleted pending file leaves pending without a trash call; a local item
  in a mixed batch is trashed before the cloud items finish; the lease is not held
  during a download (lease probe from another owner succeeds mid-download).
- 3: undo of a pending batch restores visibility with no filesystem call; undo of a
  trashed batch moves each member back and restores its curation choice and import
  batch; undo with the Trash item gone fails that item and moves nothing else;
  undo never overwrites an occupied path; redo re-queues.
- 4: threshold counts only dataless bytes; prompt shown above 100 MB and not below;
  `Do not ask again` and the Settings checkbox read and write one preference.

## Instrumentation

- `op=mediaTrash.queue phase=enqueue|resume|materialized|trashed|retry|dropped|undone`
  with batch id, counts and bytes.
- `op=mediaTrash.undo phase=start|finish movedBack= failed= reason=`.
- `op=mediaTrash.prompt phase=shown|confirmed|cancelled|suppressed bytes=`.

## Owner decisions (2026-10-04)

- **D1: Routine confirmation is dropped once undo ships.** Move to Trash (⌘⌫, menu,
  context menu) acts immediately and ⌘Z undoes it, as in Finder; HIG: *"Avoid
  displaying alerts for common, undoable actions."* The large-download prompt is then
  the only prompt. Increment 3 removes the confirmation and rewrites APP-027 and
  DES-076 together with the undo that makes it safe.
- **D2: Progress shows in the bottom status bar.** While any item is pending, the
  content pane's bottom status surface owns the trash work (DES-040), using the
  shared status vocabulary (DES-030): `Working` with a determinate count
  (`3 of 14 items moved to the Trash`) and bytes left to download at L3 (DES-031/032,
  no synthesized percentage). Delivered in increment 2 with the queue it reports on;
  its design spec goes in `docs/design/` and passes check (C).
- **D3: A definitive download failure asks about immediate deletion.** A failure is
  *definitive* when the provider rejects the download (`requestFailed`) or the item's
  bytes are unobtainable. It is *transient* when the attempt times out, the provider
  is unavailable, or the attempt is cancelled; transient failures stay pending and
  retry with backoff, with no prompt. On a definitive failure Otos asks:
  - Title: `Delete 2 Items Immediately?`
  - Message: `They couldn't be downloaded, so they can't be moved to the Trash. You can't undo this.`
  - Buttons: `Delete` (destructive style; the user did not choose permanent deletion
    up front), `Cancel` (default). Cancel unhides the items.
  - `Delete` removes the files with `FileManager.removeItem`. For a File Provider item
    the provider propagates the deletion to its own cloud recycle bin; whether that
    holds for OneDrive is verified in the increment before it ships, and the message
    is not allowed to promise it.
  This **reverses** the current "no permanent-delete fallback" rule (ADR 0022,
  MED-001, APP-027). The increment that ships it rewrites those in the same PR:
  permanent deletion exists only as this explicit, per-occurrence, user-confirmed
  choice, never automatically (the same holds for D4). Delivered in increment 2.
- **D4: At import's 5 GB free-space floor, ask about immediate deletion.** The floor
  is measured at the attempt (ADR 0027). When the next download would breach it, the
  queue pauses and Otos asks, using the D3 dialog shape:
  - Title: `Delete 14 Items Immediately?`
  - Message: `There isn't enough free space to download them so they can be moved to the Trash. You can't undo this.`
  - Buttons: `Delete` (destructive style), `Cancel` (default).
  `Delete` deletes the remaining pending items of that batch immediately (D3
  mechanics). `Cancel` keeps them pending and hidden: the queue resumes when a later
  attempt finds room, and meanwhile the status bar shows `Needs attention` (DES-030)
  with the reason. The question is asked once per batch per pause, not on every
  retry.
- **D5: The 100 MB threshold counts only bytes that need downloading.**
- **D6 (research follow-up): gold-standard Finder behavior.** Whether Finder's Move to
  Trash downloads large cloud-only files is unproven; only the owner's manual 1 GiB
  result exists. It doesn't change this plan (Otos always downloads first, for
  undo). The research doc records the answer once the owner's manual small
  cloud-only test is done.
