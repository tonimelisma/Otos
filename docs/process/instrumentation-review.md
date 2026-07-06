# Instrumentation Review — Post-Run Audit Checklist

Purpose: after any manual test run or smoke run, audit the run's instrumentation
end to end. `script/catalog-diagnostics.sh summary|check` prints worst-value
aggregates; this checklist covers what it cannot: per-asset attribution,
invariant enforcement, counter cross-checks, stragglers, and baseline drift.

## 0. Sources for one run

| Source | Where | What it holds |
| --- | --- | --- |
| Diagnostics JSONL | `~/Library/Application Support/net.melisma.Otos/Diagnostics/catalog-diagnostics-<sessionID>-prod.jsonl` (newest prod file; `script/catalog-diagnostics.sh path`) | Durable coarse events: scan/enrichment/projection/apply/stall/lifecycle/grid counters |
| Unified log | `log show --start … --end … --predicate 'subsystem == "net.melisma.Otos"' --info --debug` (or a `logs/run-*.log` capture) | High-frequency UI/bridge lines, signpost events, error-level messages |
| Smoke artifacts | `build/Diagnostics/`, `build/Profiles/` | Copied JSONL + summary, traces |

Confirm first: the file's pid/time span actually covers the run you performed
(first/last `timestamp`), and `catalog.start` phases appear once per launch.

## 1. Invariant and grid (blocker class)

| Check | How | Pass | Red flag |
| --- | --- | --- | --- |
| No-blank watchdog (APP-015) | JSONL `ui.grid.counters.totalWatchdogCount`; unified log `MediaTilePaintInvariantViolation` for live attribution | 0 total watchdogs | Any event = an upstream path attempted to blank a painted tile (defended, user saw nothing; still a bug to trace) |
| Structural applies | JSONL `ui.mediaGrid.structuralApply`: count, `applyMs` p50/p90/max, `reorderOnly`/`largeApply`/`zeroDuration` flags | p50 ≤ ~100 ms; max ≤ ~200 ms | Multi-second `applyMs` (diff machinery pathology — seen 5.1 s / 25.2 s on 2026-07-05); apply count ≫ projection publications |
| Main-thread stalls | JSONL `ui.mainRunLoop.stall`: count + `stallMs` distribution | 0 ideally; a few ≤ ~150 ms tolerable | Anything ≥ 500 ms; growing counts vs baseline (was 76 pre-0038, 0–6 after) |
| Inserted/removed sanity | `inserted`/`removed` per apply vs what the run did | Matches user actions | Structural churn with no user-visible cause |
| Detail refresh volume | `visibleDetailRequestCount` per apply; `MediaGridVisibleDetailQuery` lines | Bounded by viewport (~30–40) | Requests for hundreds of IDs |

## 2. Paint pipeline and caches

| Check | How | Pass | Red flag |
| --- | --- | --- | --- |
| Cache effectiveness | JSONL `ui.grid.counters`: `totalCacheHits`, `totalCacheMisses`, `totalCacheInserts`, `totalCacheHitRatePermille`; unified signposts for live attribution | Hits dominate once warm | Miss-heavy scroll-back (cache too small or keys unstable) |
| Prefetch reality | JSONL `ui.grid.counters`: AppKit vs manual request/ID totals; `preheatCount` per apply | Known split recorded | AppKit prefetch ≈ 0 is acceptable only when manual lookahead and preheated-ID totals show the load was carried elsewhere |
| Preheat query shape | JSONL `catalog.store.query.tileDetail` slow records: `requested` field | 0 records, or rare batched (`requested` ≈ 30+) | `requested:"1"` storms with high `waitMs` = per-item preheat regression saturating the reader pool (94 records seen 2026-07-05 00:23) |
| Tile load health | JSONL `ui.grid.counters`: `totalTileLoadsStarted`, `Applied`, `Dropped`, `Nil`; unified signposts for live attribution | Applied ≈ Started; few Dropped | Many nil loads (missing/unreadable thumbnail files) or many dropped loads (reuse churn) |
| Slow cell configures | `MediaGridSlowCellConfiguration` events | ~0 | Bursts correlated with applies (sync configure path got expensive) |

## 3. Store, database, projection

| Check | How | Pass | Red flag |
| --- | --- | --- | --- |
| Slow queries (all kinds) | JSONL `catalog.store.query.*` records exist only when > 50 ms threshold | 0 records | Any sustained presence; check `waitMs` (pool contention) vs `execMs` (query cost) split |
| WAL pressure | `catalog.database.wal` `walBytes` max | Modest, checkpoints keep up | Monotonic WAL growth |
| Write pressure | `catalog.scan.batch` / `catalog.enrichment.batch` `writeMs` = `waitMs`+`execMs` worst | ≤ ~100 ms typical | ≥ 1 s writes (seen: scan 1031 ms — known open item) |
| Projection cadence | `catalog.projection.window` count ≈ 1/s while active; `totalMs` worst | ≤ ~250 ms | Publications without corresponding change causes; `totalMs` ≥ 500 ms |
| Batch acceptance | `catalog.enrichment.batch` `attempted` vs `count`; coordinator `flush` outcome | applied == attempted | Partial applies (stale/deleted churn) or `writeFailed` |

## 4. Enrichment and materialization (per-asset attribution)

Build per-asset timelines from `catalog.thumbnails.visibleLifecycle` (phases:
`claimed → dispatched → generated → batchAccepted`, downloads add
`notMaterialized → downloadDispatched → materialized`; failures
`materializationFailed`, `claimReleaseFailed`, `claimRefreshFailed`, `transient`,
`batchWriteFailed`):

If a smoke run has no download lifecycle rows, treat the one-second materialization
cadence and attribution fields as test-covered but field-unexercised for that run.
The first real dataless-region run after this checklist should explicitly inspect
`rerequestCount`, `requestToCompleteMs`, and the post-materialization re-claim
timeline rather than inferring provider behavior from local-file enrichment.

| Check | Pass | Red flag |
| --- | --- | --- |
| Local-file pipeline: `claimed → batchAccepted` gap | ≤ ~2 s | Multi-second gaps for already-materialized files |
| Download dispatch latency: `notMaterialized → downloadDispatched` | ≤ a few s (slot available) | Long gaps = slot starvation (eager pool holding all slots — reserved-slot regression) |
| Transfer attribution: `downloadDispatched → materialized` gap ≈ `attemptMs`; completion fields include `rerequestCount` and `requestToCompleteMs` | Equal-ish → time is genuine provider transfer; nonzero re-request count is attributable | Gap ≫ `attemptMs`, missing request fields, or no re-claim after materialization = broken hand-off |
| Outcome cases on downloads | `materialized` / `alreadyMaterialized` with `sourceSize`, `attemptMs`, `requestToCompleteMs`, `rerequestCount` | `timedOut`, `requestFailed`, `statusUnavailable` — correlate with `sourceSize`, re-requests, and provider state |
| Size vs time | Transfer time scales with `sourceSize` | Small files (< 10 MB) taking ≥ 30 s = queued behind large transfers (provider bandwidth contention) |
| Stragglers | Every tracked asset reaches `batchAccepted` (or app quit mid-transfer) | Assets with `materialized` but no later `claimed`/`generated` (fell out of the enrichment queue); repeated `notMaterialized` loops |
| Claims sanity | `catalog.enrichment.claims` count vs batches × size; visible lifecycle has `leaseRefreshedUntil` on dataless hand-off | Lease refresh is visible and bounded | Claim volume with idle library (lease churn); any claim refresh/release failure needs an owner explanation |

## 5. Scan and filesystem events

- `catalog.scan.batch`: count, changed flags — batches during an idle run mean
  something is rewriting filesystem facts (provider sync churn).
- `catalog.filesystemEvent` schedule/drop counts: materializing files generates
  events (downloads change on-disk state) — expect correlation with downloads,
  not an unexplained storm.
- Skipped-package / skipped-non-media counts stable vs baseline.

## 6. Errors, anywhere

- Unified log, error level only, whole session: every line must be explainable.
  Known noisy-but-harmless lines get fixed or demoted, not ignored.
- JSONL phases: any `queryError`, `writeFailed`, `promotionFailed=true`,
  `discardedThumbnails>0`, `shutdownRelease` outside quit.

## 7. Baseline comparison

Keep the previous run's numbers next to today's (sessions are cheap to diff):
apply count/p50/max, stall count/p50/max, slow-query record count, cache
hit/miss ratio, download p50/p90 by size bucket, straggler count. Regressions
in any column need a cause or an issue before the run is called healthy.

Reference baselines:
- 2026-07-05 storm (pre-0038): 153 applies/8.6 min all reloadData, 76 stalls
  p50 200 ms, 0 slow queries, blanking every ~3.4 s.
- 2026-07-05 00:23 (post-0038): 0 stalls, watchdog 0, but 94 slow tile-detail
  records (per-item preheat) and applies of 5.1 s / 25.2 s (diff pathology).
- 2026-07-06 05:23 (latest): 54 applies p50 78 / max 95 ms, 6 stalls ≤ 205 ms,
  0 slow queries, watchdog 0; downloads fully attributed, transfer-bound.

## 8. Automated gate coverage

`script/catalog-diagnostics.sh check` is the first-line gate. It fails when the
run has no `ui.grid.counters` record, has only a startup grid-counter row without
an interval or app-termination row, any nonzero watchdog count,
structural-apply or stall timing outside the current budgets, slow requested-one
tile-detail records, materialization completion rows missing request attribution,
or a materialized visible lifecycle with no later re-claim/generated/batch
acceptance evidence. This checklist remains the human-readable audit for trend
drift, per-asset interpretation, unified-log attribution, and cases where an
environment blocker prevents the check from running.
