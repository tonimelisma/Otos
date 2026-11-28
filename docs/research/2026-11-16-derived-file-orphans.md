# Derived files no row names (2026-11-16)

## Question

The static survey (`2026-11-16-broad-survey-static.md`) counted 11,334 files (3.58 GiB) in
the installed app's Thumbnails folder that no catalog row names. How does a derived file
outlive its row, and what keeps the folder to exactly what the rows name?

## Method

- **A census of the installed app's folder.** Read-only, later the same day: one listing of the folder (names and `stat` only, no file bytes) against every `thumbnail_path`, `preview_path` and `face_frames_path` in the catalog, opened `mode=ro`.
- **Code reading** of every writer of those columns and every caller of `ThumbnailStore.promote`, `delete`, `move` and the camera's provisional thumbnail write.

## Census, 2026-11-16 afternoon

| | Files | Size | Written |
| --- | --- | --- | --- |
| In the folder | 322,421 | | |
| Named by a row | 321,418 | | |
| Not named: thumbnails | 1,000 | 11 MiB | all on Aug 31 |
| Not named: other names | 3 | 0 | Oct 25 and Oct 31 |
| Not named: previews | 0 | | |

**The morning's 10,330 "orphan previews" were never unnamed: the count was a census error.** That census compared the folder with `thumbnail_path` and `preview_path` only. It never read `face_frames_path`, and it took every `.heic` for a preview.

The folder holds 10,336 `.faces.heic` files: a video's face frames (ADR 0047). 10,336 rows name them in `face_frames_path`. Read without that column, exactly those files (3.57 GiB) come out unnamed. No write cleared a name and none restored one.

The 1,000 thumbnails of Aug 31 are one event of an older build. Their rows are gone, and how they went is not recorded.

What is unnamed today is about 11 MiB.

## How a file can outlive its row, by path

| Path | Before | Now |
| --- | --- | --- |
| A camera's provisional thumbnail | Written straight to its final name with `replaceItemAt`, before and outside the write that names it. A failed or row-less write left it unnamed. It also overwrote a thumbnail Otos had rendered, because the name is the same. | Staged. `applyProvisionalThumbnails` promotes it in the write that names it, only for a row with no thumbnail, and discards the rest. |
| An enrichment write that fails after its promotions | The promotion happens inside the transaction; a later statement's failure rolls back the row, and the promoted file stays | Unchanged mechanics; the launch's reconciliation removes it |
| A crash between a promotion and its commit | The file is in place and no row names it | The launch's reconciliation removes it |
| A file moved or respelled outside Otos | The row keeps its old names until the next render, which writes the new names and deletes the superseded ones (`EnrichmentBatchWriteOutcome.replaceImage`) | Unchanged (covered by the guard test) |
| A root path that changes | Each image moves to the new identity's name after the commit (`migrateNormalizedRootThumbnails`) | Unchanged |
| A purge, a library removal | Delete what the removed rows named, after the commit | Unchanged (covered by the guard test) |
| An edit's re-render | Same deterministic names, overwritten in place | Unchanged |

## What keeps the folder honest

**Superseded the same day.** On the reference library (installed `ece1ffe1`) the pass below listed 322,829 files and read 501,645 protected names in 89 s. One read transaction held a reader for 34.9 s. At the footprint peak the heap held the listing: 321,853 `NSPathStore2` (52 MB), 107,035 `_FileCache` (34 MB) and 227,436 `CFString` (32 MB). It removed 1,003 files (11.6 MB) as designed, but every launch paid that cost. ADR 0009 now describes the replacement: stored counters, a reconciliation only when a fact owes one, keyed pages of rows and a `readdir` stream. The rest of this section records the pass that was measured.

- `CatalogStore.reconcileDerivedFiles` ran once a launch, after the first grid.
  - It lists the folder's top level (never `.staging`).
  - It then reads the protected names. These are every name a row holds in any of the three columns, and every name a present row's identity derives (`ThumbnailStore`'s SHA-256 of root path and relative path, with each kind's extension).
  - Every listed file that is not protected is re-checked against the protected names, read again inside one write transaction, and deleted there.
- **A file a row will name again is never removed.** Names are a function of identity, so a row whose column is empty for a while (a promotion not yet named, a row about to render again) still protects its file.
- A promotion happens only inside a write transaction, so no file can become named while the reconciliation holds the writer.
- It logs `op=derived.reconcile phase=finish` with counts and bytes by kind, then `op=derived.folder phase=census`. The scorecard reads the census as the session's disk (`disk.derivedFolderMB`, compared between sessions with `--compare`).
- It also removes the July `Diagnostics/catalog-diagnostics-*.jsonl` that the removed JSONL sink wrote (17 MB on the test Mac).
- `DerivedFileLifecycleTests` renders, re-renders, moves a file outside Otos, renders it again, deletes a file, offers a camera thumbnail and plants leftovers, all on a generated library. The leftovers include the purged file's own names, and one file of a present row's own identity that its column does not name. After each step the test asserts that the folder holds exactly the names the rows hold. The present row's own file stays.

## Left to the user

The catalog folder holds two pre-migration copies, `pre-baseline-2026-10-24` (77 MB) and `pre-v8-2026-10-26` (62 MB). No code wrote or reads them: they were made by hand before two migrations. The app does not delete folders it did not make. Removing them is the user's choice.
