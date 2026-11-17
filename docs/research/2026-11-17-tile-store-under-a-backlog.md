# The tile store under a backlog (2026-11-17)

## Question

On a new 160,002-file library of 64 × 64 generated thumbnails, toured while enrichment works
its whole backlog (`script/scorecard.sh --tour --dev --optimized --seed 160000 --seed-media
small --settled --idle 20`), the peak footprint was 582–671 MB on the tree before #920 and
697–1,098 MB on four tours after #920 and #922 (target 700). The grid's tile images were
reported at 56–99 MB before and 100–193 MB after. What holds the rest, and what of it is Otos's
to bound?

## Method

- One diagnostic tour of 6b254b2c (main after #922), with a watcher outside the app that read
  its footprint every 2 s (`proc_pid_rusage`) and, the first time it passed 450, 600 and
  750 MB, took `vmmap --summary`, `heap -s` and `footprint`. `heap` pauses the app while it
  walks, so that tour's timings and its peak (857 MB) are not results.
- `heap` names Swift and Objective-C storage by type. Allocations with no type ("non-object")
  are matched by size: a size whose count follows a typed one capture by capture is
  attributed to it.

## Attribution

| Holder | 453 MB | 608 MB | 754 MB | Why held |
| --- | --- | --- | --- | --- |
| Grid tiles' decoded thumbnails (`AppleJPEGReadPlugin` count) | 3,757 | 5,921 | 8,844 | `TileContentStore` keeps every tile it decoded until its byte budget fills |
| their surfaces (`IOSurface`, resident) | 67.7 MB | 99.7 MB | 148.3 MB | one per tile shown, about 16.8 KB each |
| their decoder buffers (non-object 14 KB, 2.5 KB) | 3,796 + 2,932 | 5,961 + 4,506 | 8,885 + 6,639 | Image I/O's lazy decode holds them with the image |
| their Image I/O, CG and CA objects (typed) | about 15 MB | about 23 MB | about 34 MB | about 3.9 KB a tile |
| the tile store's entries (`[MediaAssetID: Entry]`, detail strings) | 9 MB | 9.4 MB | 14.2 MB | one entry for every tile ever bound |
| grid orders alive (`[Date?]` arrays, position tables) | 4 + 3 (14 MB) | 2 + 2 (8 MB) | 5 + 4 (20 MB) | the published, built, shown and preparing publications: not growing |
| freed large blocks the allocator keeps dirty (`Malloc Large (empty)`) | 22.6 MB | 44.6 MB | 60.2 MB | the churn of order-sized arrays |
| duplicates' same-photo pairs | 0 | 6.4 MB | 12.6 MB | the duplicates build of the backlog's facts |
| other non-object malloc | about 55 MB | about 55 MB | about 59 MB | not attributed (no allocation backtraces) |

- A decoded tile costs about 37 KB: its surface (16.8 KB), two decoder buffers (14 KB and
  2.5 KB) and about 3.9 KB of objects. The store counts 16 KB for it (4 bytes a pixel), so its
  256 MB budget would let it hold about 16,000 such tiles, about 590 MB, before it bound. At
  754 MB the 8,844 tiles held about 330 MB, 44 % of the footprint, and they account for 190 MB
  of the 300 MB rise from the first capture to the last.
- The grid's orders and their position tables do not accumulate: two to five of each at every
  capture, the publications the window and the projection hold. An order's links to earlier
  orders are weak, and a read's publication indexes from its own table, so neither keeps an
  earlier order or table alive.
- The tile store's growth is not #920's change of when it prunes: a reorder keeps every item
  in the scope, so a prune by membership never dropped a reordered tile before #920 either.
  The store grows with the tiles decoded, which a backlog's reorders and the tour's scrolls
  keep bringing on screen and into the look-ahead. The tours after #920 and #922 reported more
  tile images before their peaks (100–193 MB counted against 56–99 MB); why they decoded more
  tiles is not established.

## Change

`TileContentStore` keeps the visible tiles and, off screen, the sixteen screens of the visible
set's size it used most recently (ADR 0006, "What the tile store keeps"); the byte budget stays
as a cap. Deterministic twins: `TileContentStoreTests.offScreenTilesBeyondTheLimitAreDroppedLeastRecentFirst`,
`GridBacklogMemoryTests.aBacklogOfPublicationsHoldsWhatTheWindowShows` (1,000 backlog
publications over 8,000 photos scrolled to 200 places: two orders alive, no index edit across
reads, the store at its limit) and, at the owner's size on demand,
`GridBacklogMemoryTests.aBacklogAtTheOwnersSizeStaysWithinItsFootprint`.

## After the change

The owner-size twin, run alone (`OTOS_SCALE_TEST=1`): 160,000 photos, 1,500 backlog
publications, scrolled to 100 places, 90 tiles visible.

| Store | Tiles held | Images counted | Footprint growth past the settled window |
| --- | --- | --- | --- |
| kept to the byte budget only (the limit set out of reach) | 13,774 | 215 MB | 346 MB |
| visible tiles and sixteen screens off screen | 1,862 | 29 MB | 12 MB |

Both runs held two grid orders at the end, an index edit of 0 across reads, and an edit of 4
positions from the order the grid last applied to the newest.

Two tours of the changed build, one at a time under the owner-scale lock, in an occluded
window. Act values in ms from the act to its main-actor commit.

| Tour | Peak footprint | Peak during | Grid tile images max | Dislike / Like / Not Rated | Move to Trash | five in a row | Put Back | five in a row |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| diagnostic (6b254b2c, paused by `heap`) | 857 MB | the act steps | 140 MB | 10 / 4 / 4 | 40 | 95, 26, 75, 68, 100 | 12 | 15, 33, 31, 11, 11 |
| 1 | 488 MB | the library step | 19 MB | 21 / 22 / 1 | 23 | 13, 26, 23, 20, 16 | 9 | 14, 10, 14, 9, 75 |
| 2 | 486 MB | the idle step | 18 MB | 5 / 5 / 0 | 23 | 28, 37, 27, 62, 20 | 26 | 35, 8, 11, 8, 12 |

- Both tours' captures were complete (`capture=live … dropped=0 … complete=yes`), and after
  each `leftovers=0`, the sandbox home removed, no sandbox image attached and `pgrep -x Otos`
  empty.
- Both peaks are under the 700 MB target and below the 582–671 MB measured before #920.

## What remains

- The other holders in the table were not changed: the allocator's freed large blocks
  (22–60 MB), the duplicates build's pairs (up to 13 MB) and about 55–59 MB of untyped
  allocations no capture attributed.
- A tile's real cost (about 37 KB here) is not what the store counts (4 bytes a pixel); the
  budget is a cap, and the limit, which counts tiles, decides what is kept.
