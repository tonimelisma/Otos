# Plan 0064 — Import and grid responsiveness defects

## Status

Complete. Implemented 2026-08-03: Stage 1 (instrumentation gaps), Stage 2 (staging-file
suppression), Stage 3 (projection republication coalescing), Stage 4 (coordinator
silence — investigation concluded, observability added, metric semantics documented).
Deleted on completion.

## Purpose

The 2026-08-01 removable-import session surfaced four defects that are independent of
content hashing (Plan 0062) and of the red test baseline (Plan 0063). Each is recorded
here with its field evidence so none is carried only in review threads.

Stage 1 is a measurement prerequisite: the session's primary reported symptom could not
be measured at all, so it must not be "fixed" by guesswork.

## Stage 1 — Close the instrumentation gaps (do this first)

Nothing else in this plan should be optimised before these land, because the current
signals cannot attribute cost to a user action or to a device.

- **Sidebar selection intent → paint.** No signpost records when a sidebar selection is
  made, so click→paint latency cannot be measured. The user reported "about two minutes"
  to switch to All Media; the projection cost measured in Stage 3 does not account for
  that duration, and the remainder is currently unattributable. Add an interval spanning
  the selection intent through published window state to the structural apply that
  renders it.
- **`op=contentHash` omits `rootPath`.** Slow hashes had to be attributed to a device by
  matching byte sizes against `media_asset.byte_size`. Add `rootPath` (and ideally
  `relativePath`) to the operation's fields.
- **`stagingMs` is misnamed.** It measures a plain `copyfile` from source into the
  destination directory under a temporary name; there is no separate staging hop for
  filesystem sources. Rename to `copyMs` so the field stops implying an extra copy.

## Stage 2 — Suppress Otos's own staging files in the event classifier

`.otos-import-staging` files are written into the destination root, which Otos watches,
and the classifier does not filter them. Observed:

```
op=catalog.namespaceMutation phase=record scope=file(2026/05/.08ADC04C-….otos-import-staging)
op=catalog.occupancyRevision phase=bump occupancyRevision=1 … 7        (66 ms)
planRevision 4 → 11
op=import.coordinator phase=refresh reason=planningChange
```

Seven occupancy bumps and seven plan-revision bumps in 66 ms, each firing a reconcile
and an import replan — entirely self-inflicted by the import that was running.

The scanner already declines to catalogue these files as assets; the leak is on the
event path, which records a namespace mutation and bumps occupancy regardless. Suppress
them at classification, keyed on the `.otos-import-staging` suffix that
`MediaImportExecutor.stagingURL(adjacentTo:)` produces.

Comments at `MediaOperationCoordinator.swift:441` and `:535` record that a planning
livelock of this class was already fought once from a different source; the guard added
then keys on occupancy rather than planRevision, and does not help when occupancy itself
is what churns.

## Stage 3 — Coalesce enrichment-driven projection republication

Enrichment applies and projection publications correlate 1:1. Across 21:28:40–21:29:58,
`detailRefreshGeneration` advanced 71 → 102: **31 full 25,367-row order queries driven
by ~35 enrichment batches averaging 2 assets each**, about 70 assets enriched.

**Implemented resolution (2026-08-03).** `CatalogStore.applyEnrichmentBatch` now
detects, per applied result, whether the write changes the *effective* generated
ordering/scope columns (`best_capture_unix`, `best_kind`, `best_format` — recomputed
with the same COALESCE the generated columns use). A batch that changes none emits the
detail-only `.assetsDetailChanged`; the projection advances `detailRefreshGeneration`
and reuses the last ordered-asset query result (guarded by the freshly-resolved
descriptor matching the reused order's descriptor), so the grid refreshes visible
detail through its existing cheap same-identity `.refreshVisible` path instead of a
full re-sort. The grid's structural apply and the no-blank-grid invariant are
untouched — only the wasted re-query is removed. Verified by
`ProjectionEnrichmentCoalescingTests`: 35 detail-only batches run ~0 order queries and
the reused identity comparison short-circuits on the shared array buffer, while a
`best_capture`-changing batch still re-runs the query once and reorders.

Cost degrades non-linearly under enrichment write pressure (WAL 49 KB → 4 MB):

| `assetOrderQueryMs` | `projectionMs` | `mediaIdentityEqualityUs` |
|---|---|---|
| 62–124 (at rest) | ~150 | ~3,400 |
| 727 | 1,524 | 27,898 |
| 7,034 | 9,056 | 434,251 |

A single publication spent 434 ms on identity comparison alone and 9 s in total.
Main-thread cost follows: `op=mainThreadStall stallMs=327
lastOp=MediaGridViewController.applyStructure lastLongOperationMs=538`.

A full-catalog re-sort per one-to-two enriched assets is the defect. The one-second
apply cadence already batches durable writes and UI notifications, but it does not
prevent each flush from triggering a whole-window rebuild.

Constraints on any fix:

- The no-blank-grid invariant is absolute. A tile that has painted a thumbnail for an
  asset in this process must never revert to placeholder content; coalescing must not
  be implemented by dropping or delaying state such that a repaint blanks a tile.
- Do not add caches or scale machinery ahead of measurement. Stage 1's instrumentation
  plus these figures are the baseline; re-measure after the change and attach evidence.
- `bestDate` reordering is the reason enrichment changes order at all. Whether the fix
  is coalescing publications, avoiding a full re-sort when only non-ordering facts
  changed, or narrowing the identity comparison, is an implementation decision to be
  made from Stage 1 evidence.

## Stage 4 — Investigate the import coordinator silence

`op=import.attachToReady phase=ready elapsedMs=246856 copyCount=139` — four minutes from
volume attach to a ready import plan.

The metadata gate was **not** the cause. The scan alone populates
`content_modified_at_unix`, proven by three CAMERA rows carrying mtime with no enrichment
at all, and `hasUsableDate` is satisfied by mtime — so `shouldWaitForMetadata` should
have passed roughly two seconds after the scan finished.

Instead there are **zero** `op=import.coordinator phase=refresh` lines across the entire
21:24:18–21:31:05 capture, with debug capture verified working. `handlePlanningChange`
unconditionally calls `refreshSources`, which always logs, so the coordinator appears to
have received no planning change for six minutes, then resumed normal refreshes from
21:32:49.

Cause unknown. Start from the planning-change stream subscription and its lifetime:
`startMediaOperationsIfNeeded` (`CatalogWindowViewModelMediaOperations.swift:41`) is
called once during window setup (`CatalogWindowViewModel.swift:311`), so a lazy-start
explanation was already ruled out.

Note that `attachToReadyMs` measures from volume attach, so it includes any time the
source spent in `.waitingForDestination` awaiting user input. Confirm what the metric is
intended to mean before treating its value as pure system latency.

**Implemented resolution (2026-08-03).** Investigation concluded the subscription is
correctly wired: `MediaOperationCoordinator.start()` establishes the unbounded
`RootPlanningChange` stream once, and `MediaOperationCoordinatorTests` prove occupancy
bumps emitted by the store reach the coordinator (e.g. `bumpPlanRevision`/occupancy
reactions and source discovery). The six-minute silence is therefore consistent with an
idle app: the CAMERA scan's occupancy bumps happened before or around the capture start,
and between then and the user pressing Import no occupancy/planning change was emitted —
`handlePlanningChange` refreshes only on real events, and enrichment emits catalog
changes, not planning changes. `attachToReadyMs` was inflated by user destination-wait,
exactly as the note above warns. The remaining gap was attribution, now closed with
end-to-end observability: `op=catalog.planningChange phase=emit` (emit side, with
`listeners=`), `op=catalog.planningChange phase=subscribed` and
`op=import.coordinator phase=subscribed` (liveness markers), and
`op=import.coordinator phase=receive` (receive side). A future capture can now match
`emit`/`subscribed`/`receive` lines to prove whether a silence is "no events" or "events
not received", and `attachToReadyMs` is documented as user-inclusive latency.
`planningChangeStreamDeliversAttachedSourceWithoutIntent` pins the full
emit → subscribe → refreshSources chain in tests.

## Explicitly out of scope

- Content hashing on removable sources — Plan 0062.
- The red test baseline — Plan 0063.
- Enrichment admission caps and materialization root caps. The `dispatched=0` stall was
  traced to a homogeneous ready queue caused by materialization delivering only video,
  not to a defect in the admission loop, which already skips rejected candidates
  (`EnrichmentCoordinatorWorkSelection.swift:425`).
- Import copy worker count. Concurrency on a slow FAT32 volume correlates with
  throughput collapse, but no controlled measurement of worker count was taken and none
  should be changed without one.
- Staging removable volumes to local cache wholesale — a separate product decision with
  a disk-cost tradeoff.
