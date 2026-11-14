# Unread Immich items' sort date, and whole seconds (2026-11-14)

## Question

`docs/research/2026-11-14-window-reads-and-launch.md` reported two things about Immich
rows whose bytes Otos has not read:

- every unread Immich video had `assumed_utc_offset_seconds` NULL, so its
  `best_capture_local` was NULL and it sorted after every dated item;
- an unread still's sort date carries the server's milliseconds while the read's wall clock
  is whole seconds, so the read moves the still by under a second.

Are both true? What causes each, and what fixes it?

## Method

- Two copies of the owner's catalog, cloned into the worktree's `build/` and opened only by
  `sqlite3` 3.54 and Python's `sqlite3`, then deleted:
  `catalog-v51-before-second-fixes.sqlite` (the copy that note used) and
  `catalog-v53-before-v55.sqlite` (taken from the installed app at 13:20 today). The Immich
  account is root 15 in both. No Otos build opened either copy.
- The code: the Immich sync's row mapping (`ImmichCatalogSync.listedItem`, `motionItem`,
  `refreshedItem`), the listing write (`CatalogStore.writeSourceListingChanges`, which calls
  `upsertScannedFile`), the scan upsert's arguments (`scannedFileUpsertArguments`) and the
  metadata write (`writeMetadataProjection`).

## Findings

### Unread videos are dated

The sync maps a still and a video the same way: each `ScannedMediaFile` carries the
server's `fileCreatedAt` and `fileModifiedAt`. Both go through `upsertScannedFile`, whose
arguments assume an offset for `createdAt ?? contentModifiedAt` with no kind test. Nothing
in the code writes NULL for a video.

The data agrees. In both copies, no row of any root has a NULL `best_capture_local`:

| Copy | Unread Immich videos (no wall clock, no capture instant) | Their offset NULL | `best_capture_local` NULL |
| --- | --- | --- | --- |
| v51 | 14,326 | 0 | 0 |
| v53 | 6,448 | 0 | 0 |

An unread video in the v51 copy, `001b0211…/2022-07-06 18.20.47.mov`: created
1657156847.0, offset −25200, `best_capture_local` 2022-07-06 18:20:47, the time in its
name. The unread videos' sort dates in that copy run from 1980 to 2026.

The first finding was wrong. No sync change and no backfill is needed for it, and none
was made.

A read video does move when its bytes give a wall clock in a zone other than the one
assumed: 4,844 of the v53 copy's 11,894 read videos are a second or more from their
unread value, 3,968 of them an hour or more. That is the read correcting the day, which is
what the read is for.

### Unread stills move by under a second when read

For every read Immich row in the v53 copy, the unread value can be recomputed as
`created_at_unix + assumed_utc_offset_seconds`. That is the server's date, which the
listing keeps for the row and the read does not replace. Compared with the read value:

| Kind | Read | Equal | Under a second off | Equal once the unread value is floored to its second | A second or more off |
| --- | --- | --- | --- | --- | --- |
| image | 40,935 | 667 | 30,922 | 30,922 | 9,346 |
| raw | 10,392 | 8 | 10,126 | 10,126 | 258 |
| video | 11,894 | 7,050 | 0 | 0 | 4,844 |

So 41,048 of 51,327 read stills moved by a fraction of a second, and each of those moves
is the second it falls in. Every one was an enrichment write whose `best_capture_local`
changed. That puts `.captureDate` in the batch's facts (`EnrichmentOverlayBeforeWrite.changedFacts`)
and costs a read of the window's order, though the item stays where it was against every
item outside that one second. Rows from folders, cards and cameras have whole-second dates: 42 of the 19,686 rows in
the other roots have a fraction.

(The earlier note counted 300 of 16,041 under a second. Its v51 copy had fewer read
stills, and its comparison may have been different. The v53 count above is the one this
change rests on.)

## Change

`best_capture_local` takes the absolute time at the second it falls in, the floor, before
the assumed offset is added (`CatalogSchema.absoluteCaptureWholeSecondsSQL`). Both of its
branches are now whole seconds, as a wall clock is. The floor is written as
`CAST(x AS INTEGER) - (x < CAST(x AS INTEGER))` rather than `floor()`, which SQLite has only
when built with its math functions. Migration v56 redefines the generated column and
rebuilds the 12 indexes over it under their own names. No stored column changes: the
server's date keeps its milliseconds in `created_at_unix`.

On the v53 copy the redefinition, run in `sqlite3` with the column's indexes from that
copy, took 7.1 s warm (0.7 s to drop and add the column, 0.3–0.7 s per index). 28,850 rows'
`best_capture_local` moved, every one by under a second, and none became NULL.

What the user sees: an unread Immich still is on the same second as before, and its read
no longer moves it within that second. Unread items taken in the same second now order
among themselves the way read items already do, by root and path (the Immich asset ID),
not by the server's milliseconds.
