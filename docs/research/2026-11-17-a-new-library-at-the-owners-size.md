# A new library at the owner's size (2026-11-17)

## Question

A brand-new library of 160,002 small generated files, added through Add Library on an
optimised dev build in a sandbox home, is toured while enrichment has the whole library as its
backlog (`script/scorecard.sh --tour --dev --optimized --seed 160000 --seed-media small
--settled --settle-deadline 60`). On the owner's settled library of the same size every target
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
  2.6 s (about 0.3 ms a row at the owner's schema). No row reached the catalog before it
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
