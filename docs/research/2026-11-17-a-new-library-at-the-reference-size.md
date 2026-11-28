# A new library at the reference library's size (2026-11-17)

## Question

A brand-new library of 160,002 small generated files, added through Add Library on an
optimised dev build in a sandbox home, is toured while enrichment has the whole library as its
backlog (`script/scorecard.sh --tour --dev --optimized --seed 160000 --seed-media small
--settled --settle-deadline 60`). On the reference library, settled and of the same size, every target
passes; on the new library six tours measured the first paint of the library at 3,166–4,265 ms
(target 1,000), the first search's first results at 378–1,347 ms (1,000) and the peak
footprint at 554–821 MB (700). What does each wait on, and what is Otos's to change?

## Method

- One baseline tour on 72d6ca52, with the unified log kept whole (`log show` of the
  session's process after the tour; a live `log stream` dropped lines while the change
  journal logged about 4,100 filesystem events in 0.6 s).

## 1. The first paint of the new library

The paint is timed from the window's automatic selection of the new library
(`sidebar.autoSelect phase=initialDefault`) to the grid's first structural apply in it. On
the baseline tour it took 4,220 ms (`first library 4220 1000 FAIL pagedIn=38901`):

| ms after the selection | line |
| --- | --- |
| 0 | `ui.sidebarSelectionToPaint phase=start` |
| 37 | the library published empty (`emptyState=noMedia`, no item) |
| 679 | the walk's first batch handed to the Store (its write began) |
| 3,258 | `catalog.scan.batch count=8729 inserted=8729 writeMs=2599` |
| 4,183 | the next publication pass (`projection.publish phase=start`) |
| 4,205 | published with 8,729 items (`assetOrderQueryMs=11`) |
| 4,221 | `ui.mediaGrid.structuralApply items=8729 totalMs=3`, the paint |

The order read took 7 ms and the grid's apply 3 ms; the window waited on two things:

- **The first batch's write.** The scanner flushed on a one-second cadence only, so its first
  batch held every file the walk met in its first second, 8,729 of them, and their write took
  2.6 s (about 0.3 ms a row at the reference catalog's schema). No row reached the catalog before it
  committed.
- **The cadence after it.** The batch's change (`assetsAdded`) is a background change, so the
  projection took it up on its next cadence tick, 0.93 s later. The same cadence held the Add
  Library intent's own change: the new library was listed 0.46 s after the intent.

The 38,901 page-ins of the paint's window are the process's while the scan wrote and
enrichment rendered; the paint's own reads read 7 ms of index.

**Change.** The walk hands its first `CatalogScanner.firstBatchCount` (256) files over at once
and the rest on the cadence, and a change of which rows exist (`.membership`) publishes at once
while the window shows no item (`CatalogProjection.publishesAtOnce`): the cadence spares the
main actor a shown grid's reorder, and an empty window has none.

## 2. The first search

The tour's first search ("searchMany") showed its first results at 1,401 ms on the baseline
tour, 1,359 ms on the diagnostic tour and 1,118 ms on a tour after #915 and #916. In every
run the order was the same:

- The words reading answered in 67–128 ms (`search.words phase=shown`). It matched nothing,
  because no photo of a new library has had its text read yet (`textMatches=0`). A words
  answer that matches nothing changes nothing on screen (ADR 0048), so the window kept
  searching.
- The tower's reading as typed came next and gave the first results. It took 1,202 ms,
  1,146 ms and 913 ms (`search.encode depth=asTyped first=true`). The next query's reading
  took 25 ms.
- The step read 343 MB, 425 MB and 346 MB from disk (`process.usage diskReadMB`) with
  21,299, 22,002 and 21,346 page-ins.

The prediction now reports what the process read while it ran (`op=search.tower
phase=predicted`). On the third tour:

`op=search.tower phase=predicted cpuMs=3516 diskReadMB=332 ms=860 pageIns=21058`

So the tower's first query prediction spent its time reading back about 330 MB. The tower had
been loaded and warmed 112 s earlier (`search.encoder phase=prepared warmUpMs=41`), and its
pages were evicted in between. The Mac had 65–170 MB free, 3.7–4.0 GB compressed and
5.2–5.7 GB of swap in use, with other worktrees' builds and tests running. Otos's own footprint
was 343 MB. The same query against the settled reference library, on a Mac not under this
pressure, showed first results in 253–278 ms (`2026-11-16-performance-baseline.md`).

**What is Otos's.** Nothing in this wait is a read or an owner Otos can change while keeping
its memory target. A tower kept resident would add its ~330 MB to the footprint. The words
reading cannot answer a library whose text is unread. The CPU figure (3.5 s across about 4
cores in 0.86 s) is enrichment's backlog beside the prediction. The tower's queue runs at user
priority, and the next prediction took 25 ms under the same backlog.

**Floor.** On this Mac, a first search after an idle of about two minutes waits about 0.9 s
for the tower's pages, plus about 0.25 s for the reading, publication and paint. The nearest
achievable figure is about 1.1 s while the system evicts the tower's pages, and 25 ms plus
about 0.25 s once they are resident.

## 3. The peak footprint

On the baseline tour the peak, 657 MB, came at the end of the second whole-root walk. That
walk (`reason=events`) was the change journal replaying the generator's own writes, which
#915 removed. The footprint fell 213 MB in the second after the walk ended (616 → 403 MB).

A diagnostic tour took `heap` and `vmmap -summary` the first time the app's own samples passed
450, 550 and 620 MB. Those captures pause the app, so that tour's timings are not results.

| At | Footprint | Malloc allocated | Of which | IOSurface |
| --- | --- | --- | --- | --- |
| 450 MB, during the second walk | 464 MB | 312 MB | the walk's `ScanBaseline`: its dictionary 48 MB and 816,868 strings 79 MB | 44 MB, 2,328 surfaces |
| 550 MB, after it | 572 MB | 248 MB | non-object 130 MB | 81 MB, 4,750 surfaces |
| 620 MB | 625 MB | 329 MB | non-object 158 MB; six `[MediaAssetID: Int]` 20 MB | 106 MB, 6,437 surfaces |

- **A whole-root walk holds its baseline.** For each settled row it held five strings: the
  path key, the name sort key, the name, the content type and the kind/format. At 160,000
  rows that is 127 MB for the walk's length. Any whole-root walk of a library this size pays
  it: an integrity walk, or a root whose change journal cannot replay. The baseline now holds each row's facts as one SHA-256 of their bytes
  (`ScanFactValues.digest`, 32 bytes inline), which is equal exactly when the facts are
  equal byte for byte.
- **The grid's tile images grow during a backlog.** The surfaces are the grid tile store's
  decoded 64 × 64 thumbnails: `AppleJPEGReadPlugin`, `IIOImageRead`, `CGImage` and
  `IOSurface` each counted about 6,300. While the scan inserted rows and enrichment
  re-rendered and re-dated them, the grid decoded about 75 tiles a second with about 50 on
  screen: 5,933 decodes in the tour's first three minutes. The store keeps every decode under
  its 256 MB budget (ADR 0009), and it reported 99 MB (`tileCacheMB=99`) at the tour's first
  step. That budget is what makes a scrolled-back tile keep its painted image (APP-015), so
  it is left as it is. This note records it as the holder that grows with a long backlog.
- **Not attributed.** 130–158 MB of non-object malloc. Core ML buffers, Vision and string
  bytes are candidates. No allocation backtraces were recorded.

After #915 and the digest, a tour peaked at 480 MB (`peak footprint MB 480 700 PASS`).

## After the changes

The same command was run on main after #915 (the change journal), #916 (the first batch and
an empty window's first rows) and #917 (the baseline digest). The fourth and fifth tours also
ran this note's two new lines (`op=search.tower phase=predicted`,
`op=catalog.scan.firstBatch phase=handed`).

| Tour | First library | First search, first results | Tower prediction | Peak footprint |
| --- | --- | --- | --- | --- |
| baseline (72d6ca52) | 4,220 ms FAIL | 1,401 ms FAIL | 1,202 ms (encode) | 657 MB |
| 3 | 1,203 ms FAIL | 1,118 ms FAIL | 860 ms, 21,058 page-ins, 332 MB read | 480 MB |
| 4 | 239 ms | 374 ms | 47 ms, 9 page-ins | 595 MB |
| 5 | 233 ms | 1,468 ms FAIL | 1,175 ms, 20,986 page-ins, 330 MB read | 671 MB |

- **First paint.** On tours 4 and 5 the walk reached its first 256 files in 31 ms and the
  Store took them in 80 and 74 ms. The grid's first apply of them took about 120 ms
  (`commitMs` about 88). On tour 3 the 256-file batch committed 1,063 ms after the selection,
  with the text tower's 905 ms load reading beside it. That tour ran before the first-batch
  line existed, so which of the walk and the hand-off waited is not established.
- **First search.** It follows the tower's pages exactly. With them resident (tour 4) the
  first results took 374 ms. Evicted (tours 3 and 5), the prediction read about 330 MB back
  and took 0.86–1.18 s.
- **Peak footprint.** 480–671 MB, under 700. Tour 5's peak came during the act steps, with
  the grid's tile images at 84 MB.
- **Other FAIL lines.** Tour 4 had `return library 313 300 FAIL`, an order read of
  235 ms (`sql=163 map=71`) against 158–198 ms on the other tours. It also had
  `search again searchFew first results 1052 1000 FAIL`. That search matched nothing, so its
  empty answer read two whole-scope counts before it was published: the photos still owed an
  embedding (`searchEmbeddingPendingCount`, about 320 ms, inferred from the gap between the
  match and the count) and the scope's cataloged count (`catalogedCount execMs=334`). The
  scope's own order already held the second. Neither was changed here.
