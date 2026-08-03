# 2026-08-01 — Removable-volume import and grid responsiveness field diagnosis

Field evidence from a live session: a FAT32-over-USB SD card (`/Volumes/CAMERA`,
139 files, 521 MB) attached alongside two OneDrive library roots (24,862 + 505 files,
25,367 catalogued assets). Reported symptoms were: no import toolbar, several seconds
to switch import views, "about two minutes" to switch to All Media, thumbnails not
loading, and an import that appeared stuck at 0/139.

Sources: `script/logs.sh show` over the session window, and read-only queries against a
copy of the live catalog. No originals were read or modified by this diagnosis.

## 1. Content hashing dominates removable-source enrichment

| bytes | elapsed | throughput | owner |
|---|---|---|---|
| 52,199,424 | 112,442 ms | 0.46 MB/s | enrichment |
| 29,622,272 | 129,267 ms | 0.23 MB/s | enrichment |
| 24,969,216 | 96,409 ms | 0.26 MB/s | enrichment |
| 565,719 | 117,258 ms | 0.005 MB/s | enrichment |
| 440,499 | 101,530 ms | 0.004 MB/s | enrichment |
| 1,477,858 | 4 ms | 369.46 MB/s | enrichment (local file, same session) |
| 624,627 | 22 ms | 28.39 MB/s | import (staged copy, local) |

`op=contentHash` carries no path field, so sizes were attributed by matching
`media_asset.byte_size` against `library_root_id = 10`. Five of six appear only on the
removable root and in neither OneDrive root.

The 440 KB file taking 101 s began at ~21:26:07, six minutes before the copy batch
started — so the card was already collapsing under enrichment alone, with two large
AVI hashes running concurrently. Concurrency on this device is strongly correlated with
throughput collapse, though no controlled measurement of worker count was taken.

`diskutil info /Volumes/CAMERA` did not return within 120 s during peak load, and again
failed a 20 s deadline, before answering normally once pressure dropped.

Hashing is the only part of enrichment that reads a whole file: `MediaMetadataReader`
uses ranged reads (`FileByteSource` seeks, then `read(upToCount:)`), and Quick Look
reads a portion. Conclusion carried into Plan 0062.

## 2. Enrichment throughput is bounded by materialization, not by the admission loop

Steady state during the stall:

```
op=catalog.enrichment.scheduler phase=route claimed=25 readyQueued=5 enriching=2
   materializationPending=14 materializationInFlight=2 pendingApply=0 dispatched=0 limit=25
op=catalog.enrichment.admission phase=blocked reason=videoEnrichCap rejected=5
   admitted=0 pending=5 inFlight=2 videoInFlight=2
```

Six of eight enrichment slots idle while five ready candidates were rejected. The
initial reading — that the admission loop strands capacity — was wrong: the loop at
`EnrichmentCoordinatorWorkSelection.swift:425` already counts a rejection and continues
to the next candidate. The queue was homogeneous because 14 of 25 claimed assets were
still waiting on OneDrive downloads capped at 2 in flight, so the only locally-available
work happened to be video.

Materialization retries are visible and expensive:

```
op=materialization.request phase=completed relativePath=2026/07/20260731_145223000_iOS.MOV
   providerMs=31767 totalMs=33087 outcome=materialized rerequestCount=25
```

## 3. Projection republishes the whole catalog per enrichment batch

The largest UI finding, and not yet addressed by any plan.

Enrichment applies and projection publications correlate 1:1 across 21:28:40–21:29:58:

```
21:28:42.068 ENRICH 2
21:28:42.866 PROJ gen=72 orderMs=124 count=25367
21:28:43.562 ENRICH 3
21:28:44.056 PROJ gen=73 orderMs=122 count=25367
21:28:45.160 ENRICH 2
21:28:46.321 PROJ gen=74 orderMs=122 count=25367
```

`detailRefreshGeneration` advanced 71 → 102 in 78 seconds: **31 full 25,367-row order
queries driven by roughly 35 enrichment batches averaging 2 assets each** — about 70
assets enriched.

Cost degrades non-linearly as enrichment write pressure rises (WAL 49 KB → 4 MB over
the same window):

| `assetOrderQueryMs` | `projectionMs` | `mediaIdentityEqualityUs` |
|---|---|---|
| 62–124 (at rest) | ~150 | ~3,400 |
| 217 | 254 | 3,305 |
| 727 | 1,524 | 27,898 |
| 2,639 | 2,920 | 17,268 |
| 7,034 | 9,056 | 434,251 |

434 ms of pure identity comparison in a single publication, and a 9 s publication.

Main-thread cost follows:

```
op=mainThreadStall lastOp=MediaGridViewController.applyStructure stallMs=327
   lastLongOperationMs=538 latestItems=139 latestPreviousItems=25367 reorderOnly=false
```

On the All Media switch specifically, the order query completed at 21:27:41.900 but the
window did not publish until 21:27:49.475 — a **7.57 s gap** with three `contentHash`
completions (enrichment DB writes) landing inside it. There is also an unexplained
38-second gap with no log output at all, 21:27:03.573 → 21:27:41.689.

**Not established:** the user-reported "about two minutes" for the All Media switch. No
sidebar click→paint instrumentation exists, so selection latency cannot be timed at all.
The measurements above bound the projection cost; they do not account for the full
reported duration.

## 4. Import copy is one read, into the destination directory

`stagingURL(adjacentTo:)` (`MediaImportExecutor.swift:1017`) creates
`.<uuid>.otos-import-staging` **in the final destination directory**, then
`ExclusivePublication.publish(staging:final:)` renames it into place. This is a single
`copyfile` from source to destination under a temporary name — the standard atomic
write-then-rename — not a separate staging hop. The field name `stagingMs` measures the
copy itself and is misleading.

```
op=mediaOperation.batch phase=start bytes=521476659 files=139 workers=8   21:32:46
op=mediaOperation.copy phase=timings hashMs=2 publishMs=3 settleMs=8 stagingMs=78847 worker=0
op=mediaOperation.copy phase=timings hashMs=28 publishMs=36 settleMs=43 stagingMs=132575 worker=7
```

Six of eight workers finished their first file within 66 ms of each other after ~78.8 s
each — the signature of a saturated device releasing a backlog rather than of parallel
progress. Seven files completed in 2 m 13 s; the counter legitimately read 0/139 for the
first 79 seconds.

## 5. Otos's own staging files churn its own planner

`.otos-import-staging` files land inside a watched destination root and are not
suppressed by the filesystem event classifier:

```
op=catalog.namespaceMutation phase=record scope=file(2026/05/.08ADC04C-….otos-import-staging)
op=catalog.occupancyRevision phase=bump occupancyRevision=1 … 7      (66 ms)
planRevision 4 → 11
op=import.coordinator phase=refresh reason=planningChange
```

Seven occupancy bumps and seven plan-revision bumps in 66 ms, each triggering a
reconcile and an import replan, all self-inflicted. Comments at
`MediaOperationCoordinator.swift:441` and `:535` show a livelock of this class was
already fought once from a different source.

## 6. Import coordinator received no planning change for six minutes

```
op=import.attachToReady phase=ready rootPath=/Volumes/CAMERA elapsedMs=246856 copyCount=139
```

The metadata gate was **not** the cause. The scan alone populates
`content_modified_at_unix` — proven by three CAMERA rows that carry mtime while having no
enrichment at all (`enriched_source_size IS NULL`) — and `hasUsableDate` is satisfied by
mtime, so `shouldWaitForMetadata` should have passed about two seconds after the scan
finished at 21:24:44.

Instead, there are **zero** `op=import.coordinator phase=refresh` lines across the whole
21:24:18–21:31:05 capture, with debug capture verified working (other `.debug` Catalog
lines are present). `handlePlanningChange` unconditionally calls `refreshSources`, which
always logs, so the coordinator appears to have received no planning change at all for
six minutes, then resumed normal refreshes from 21:32:49. Cause unknown.

## 7. SQLite partial-index behaviour for splitting the enrichment staleness predicate

Measured against a copy of the live catalog, SQLite 3.54.0, 26,542 rows. Relevant
because both enrichment claim queries use `INDEXED BY`, which is a hard constraint:
SQLite refuses to prepare a statement whose WHERE clause does not imply the named
partial index's WHERE clause.

**A narrower query can use a broader partial index.** A metadata-only WHERE forced onto
the existing `(metadata OR hash)` index plans successfully:

```
SEARCH media_asset USING INDEX idx_media_asset_needs_enrichment_root (library_root_id=?)
```

SQLite recognises that `A` implies `A OR B`.

**A broader query cannot use a narrower partial index.** A `(metadata OR hash)` WHERE
forced onto a metadata-only index fails at prepare time:

```
Parse error: no query solution
```

Mis-wiring an index to the wrong root kind is therefore a hard, immediate failure rather
than silently missing rows. The reverse mis-wire is **not** caught — it plans fine and
silently loses selectivity, so tests must assert on `EXPLAIN QUERY PLAN`.

Selectivity by root kind:

| root kind | rows | metadata-stale | hash-stale |
|---|---|---|---|
| `library` | 25,373 | 12,739 | 16,442 |
| `removableVolume` | 1,169 | 3 | 3 |

Conclusions carried into Plan 0062.

## 8. Instrumentation gaps found

- No signpost records sidebar selection intent, so click→paint latency cannot be
  measured. This blocked confirming the primary reported symptom.
- `op=contentHash` omits `rootPath`, so a slow hash cannot be attributed to a device
  without matching byte sizes against the catalog.
- `stagingMs` names a plain copy, inviting the reading that a separate staging hop
  exists.
