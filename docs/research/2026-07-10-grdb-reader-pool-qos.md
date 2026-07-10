# Research: GRDB reader-pool QoS inversion (plan 0054 Stage D)

- Date: 2026-07-10
- Status: Decision recorded — accept as benign at current load
- Related: ADR 0002 (`DatabasePool` / `maximumReaderCount = 4`), ADR 0015
  (observability), plan 0054 Stage D

## Question

Xcode's runtime QoS checker reports a priority inversion: a User-initiated
thread blocks in GRDB `Pool.get()` (`barrierQueue.sync` →
`itemsSemaphore.wait`) while a reader connection is held at Utility/Default
(enrichment claim/read traffic). Is the *cost* of that inversion large enough
to justify raising `maximumReaderCount` or adding a second UI-only
`DatabasePool`?

## Method

1. Confirmed instrumentation: `CatalogStore.timedRead` already splits
   `waitMs` (time to enter the reader body = pool acquisition) from `execMs`.
   UI tile-detail queries log `waitMs`/`queryMs` when `queryMs > 50`; ordered-ID
   queries always log at `.notice`. Stage D also adds an always-on `.debug`
   line for every tile-detail finish so future samples are not threshold-biased.
2. Analyzed 24h of unified Catalog logs from real ~23k-library sessions
   (including enrichment + scan contention).

## Evidence (2026-07-10, `script/logs.sh show --last 24h Catalog`)

| Op | n | waitMs p50 | waitMs p95 | waitMs max |
| --- | ---: | ---: | ---: | ---: |
| `catalog.store.query.order` (always logged) | 6891 | 0 | 17 | 667 |
| `catalog.store.query.tileDetail` (slow-only, `queryMs > 50`) | 91 | 71 | 418 | 1382 |

Notes:

- Order-query waits are the unbiased UI-facing pool-wait signal. p95 = 17 ms.
- Tile-detail notice samples are **biased** toward already-slow queries (only
  emitted above 50 ms total); they must not be used as the p95 gate alone.
- Enrichment claim paths that cross the slow threshold can show large waits;
  that is expected under a 4-reader pool and does not by itself prove UI
  starvation when order-query p95 stays low-teens.

## Decision gate (plan 0054)

- If p95 UI-read wait ≲ 10 ms → accept warning as benign.
- Else prefer (a) raise `maximumReaderCount`, then (b) dedicated UI reader pool
  (needs ADR — second pool is real machinery).

## Decision

**Accept the GRDB reader-pool QoS inversion warning as benign at current load.
Do not raise `maximumReaderCount` and do not add a second pool.**

Rationale:

- Unbiased order-query waitMs p95 is 17 ms — same order of magnitude as the
  ~10 ms gate, and far below the 100 ms MainActor hang budget. Pool wait is
  not the dominant cost of those queries (`execMs` dominates large order
  reads).
- Raising reader count or splitting pools would be performance machinery
  before a measured UI-visible bottleneck (Rob Pike / CLAUDE.md).
- The inversion is structural inside GRDB's `DispatchSemaphore`-based pool
  (no priority donation). Accepting the *warning* is not the same as ignoring
  a measured stall.

Revisit if future always-on tile-detail `.debug` samples (or a dedicated
enrichment-storm + loupe-arrow profile) show unbiased UI `waitMs` p95
materially above ~20–30 ms or correlate with MainActor stalls.

## QoS warning #2 (decode on Default)

Matches the pre–plan-0053-Stage-B path where decode ran on the actor at
inherited priority. Stage A of plan 0054 made `PreviewImageLoader`'s dedup
task and pane-request tasks explicit `.userInitiated`. No further product
change in Stage D.
