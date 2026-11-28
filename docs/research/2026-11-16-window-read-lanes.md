# Window read lanes (plan 0116 bet 5)

Date: 2026-11-16. Method: `StallReproductionTests.windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns`
(`OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests`) on a generated reference-size
catalog (`ReferenceShapedCatalog`, scale 1: 166,990 assets, 2.16 GB), the test target unoptimized.
A quiet replay times every read alone; then every background owner runs
(`RunningBackgroundOwners`) while the window's reads of five scope changes, three rounds, are
asked together (order, filter options and imports at once, then the visible tiles) and timed
from their ask. The summary lines are `build/stall-reproduction/reference.txt`; the reads' own
`op=catalog.store.query.order` lines give the sub-spans. No benchmark was run.

## The design

One pool of eight readers. A background read takes one of four turns
(`CatalogReadAdmission`) before it asks the pool for a connection, and gives it back on the
connection's queue as the connection goes back; a window read asks at once. The caller's
handle picks the lane (`CatalogStore.windowReads`, `.backgroundReads`). The second,
read-only pool of two readers that served the visible tiles and the inspector is gone.

## Waits

| | Before (four shared readers, plan 0116 proof of concept) | Lanes, run 1 | Lanes, run 2 (load average 60) |
| --- | --- | --- | --- |
| Window waits for a connection, p95 | about 1.9 s | 0–4 ms (reads' own `waitMs`) | 0 ms |
| Window reads that waited 1 s or more | 14 | 0 | 0 |
| Window stall lines at a 250 ms threshold | – | – | 0 |

## Answer times (ms, live; quiet in brackets)

| Read | Run 1 p50 / max | Run 2 p50 / max |
| --- | --- | --- |
| `orderedAssetIDs` | 405 / 858 (149 / 481) | 964 / 6,346 (507 / 1,499) |
| `filterOptions` | 62 / 455 (38 / 514) | 244 / 5,490 (64 / 1,308) |
| `importBatches` | 375 / 515 (148 / 160) | 868 / 5,120 (605 / 707) |
| `mediaTileDetails` | 4 / 43 (2 / 9) | 20 / 85 (10 / 233) |

Run 2 ran while other sessions' checks held the Mac at a load average of 60 on 8 cores; its
quiet times are inflated as much as its live ones.

## Why the answer-time check changed

The reproduction asked each window read to answer within 250 ms of its quiet time. With lanes
that compared CPU, not waiting: All Media's order read waited at most 4 ms for a connection,
while its sub-spans grew from the quiet read's (stack rule 80 ms, stack read 54 ms) to 230–273
ms and 152 ms live, the owners' own work sharing the 8 cores in an unoptimized test host. A
click-budget form (1,000 ms, 2,000 ms for All Media's first order read) held in run 1 and failed
in run 2 under the other sessions' load: a wall-clock bound, which a test must not hold
(a failure that only load causes is a test defect). So the test asserts what it owns on any
machine: no window read waits for a connection longer than 250 ms while every owner runs (the
live store's stall threshold); each window read visits at most four rows per row it returns or
its scope holds, its stack read at most each candidate once per index; and each walk at most
once per drain. The answer times, live and quiet, with the load average, are reported in
`reference.txt`; the click budget is enforced by the tour's scorecard on the reference library.

## Walks once per drain

The reads that find what they owe only by walking the library visit each row at most once
per index they join, once per drain:

| Read | Returned | Visited | Rows × indexes |
| --- | --- | --- | --- |
| `searchEmbeddingCandidates.drain` | 24 | 331,714 | 166,990 × 2 |
| `searchTextCandidates.drain` | 85,816 | 322,132 | 166,990 × 2 |
| `photoDescriptionCandidates` (one page) | 16 | 104,436 | 166,990 × 2 |
| `unnamedPlaceCells` | 0 | 210,052 | 105,026 located × 2 |
| `metadataRefreshCandidates` (one page) | 64 | 1,444 | – |
| `duplicateCopies` | 0 | 4,715 | hashed rows |
| `mirrorProbes` | 0 | 17,703 | mirrored rows |
| `peopleSnapshot` | 102,979 | 361,499 | within 4 × returned |

## Record run on the merged tree

The same test on the lanes change rebased onto `main` after v73: the derived folder's
counters (v72), whose reads take a lane (the load's journaled renames in the window lane, the
launch's reconciliation and a card's renames in the background lane), and the People gallery's
own read (v73), which is the window's (the gallery, a photo's faces, the Person sheet's newest
faces). Other sessions' checks ran throughout: load average 31.4 at the start of the recorded
run, 24.4 during its live phase, 23.5 at its end (8 cores); it reached 199 earlier that morning.

Two earlier runs on the way failed on work bounds, and the test was corrected, not loosened:
- `importBatches` visited 40,609 rows for 5,076 returned: it counts each batch's photos through
  the stack rule, so it reads the 24,078 stack candidates of its scope's roots, as the order
  read does. The test now takes the stack read out of every window read that applies the stack
  rule and bounds it by itself (each candidate at most once per index). The batch read's own
  visits, 16,531, are within four per row it returns.
- `peopleGallery` (new with v73) visited 3,740 rows and returned none: the generated catalog
  holds 748 people and no stored gallery facts, so the gallery is "not known yet". It asks for
  every person and reads five rows for each by key (the person, the key face and its photo, the
  newest face and its photo). The replay now states what it asks for (the people count), and
  the test bounds a read by key at the rows it joins per row (`rowsReadByKey`).

| | Recorded run |
| --- | --- |
| Assets | 166,990 (2.25 GB, generated in 20 s) |
| Window reads (5 scopes × 3 rounds × 4 reads) | 60, all answered |
| Window stall lines (250 ms) | 0 |
| Window connection wait, max | 0 ms for every read |
| Test result | passed, no known issue |

Answer times, ms, live p50 / max (quiet p50 / max), load average 24.4:

| Read | Live | Quiet |
| --- | --- | --- |
| `orderedAssetIDs` | 400 / 1,065 | 156 / 415 |
| `filterOptions` | 75 / 507 | 35 / 245 |
| `importBatches` | 350 / 578 | 162 / 177 |
| `mediaTileDetails` | 9 / 20 | 2 / 2 |

An earlier run on a nearly identical tree took 4.6 s for the quiet All Media order read against
415 ms here, with nothing else in the test process: other sessions' load, which is why answer
times are reported and not asserted.

Rows visited per window read, quiet (returned in brackets):

| Scope | `orderedAssetIDs` | `filterOptions` | `importBatches` | `mediaTileDetails` |
| --- | --- | --- | --- | --- |
| All Media | 217,857 (164,766) | 538,472 (3) | 40,609 (5,076) | 120 (60) |
| Pictures library | 35,034 (16,914) | 59,200 (3) | 40,609 (5,076) | 120 (60) |
| Account | 179,811 (147,064) | 474,290 (3) | 40,609 (5,076) | 120 (60) |
| Archive library | 788 (788) | 2,758 (2) | 40,609 (5,076) | 127 (60) |
| One import batch | 24,366 (254) | 890 (3) | 40,609 (5,076) | 127 (60) |

`filterOptions` is bounded by its scope's rows (four per row the scope's order returns), not
by the three option groups it returns. `peopleGallery`: 3,740 rows for 748 people asked, 5 ms.
`peopleSnapshot`, now assignment's read alone: 360,553 rows for 102,979 faces, 763 ms. The
other background walks visited what the table above shows.
