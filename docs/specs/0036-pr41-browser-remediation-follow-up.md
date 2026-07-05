# Spec 0036: PR 41 Browser Remediation Follow-Up

## Status

Implemented in this increment.

## Current-State Note

Spec 0038 supersedes this spec's large reorder-only apply policy. The current
grid uses duration-zero true diffable applies for background reorders, and the
no-blank invariant does not depend on AppKit preserving item instances because
tiles repaint synchronously from decoded cache when possible.

## Classification

Bug fix, performance/instrumentation, and refactor.

## Problem Statement And Goal

PR 41 fixed the main catalog-browser flicker path and added the timing split
needed to understand jank, but follow-up review and the latest real-library smoke
still found correctness and diagnostic gaps. The most user-visible failures are:
queued enrichment claims can be abandoned for the full 300-second lease on
shutdown/relaunch, priority claims can under-fill visible batches under
contention, fallback enrichment can walk path order while the UI is showing
newest media, and background resorting can repeatedly push huge full-grid
structural applies through AppKit.

The goal is to make the current simple architecture correct and observable: no
lost process-local claims, no visible thumbnail starvation behind path-ordered
fallback work, no filesystem-event JSONL flood, no repeated multi-second
animated full-grid reorders from background enrichment, and no brittle source
tests that lock in accidental code spelling.

## Scope

In scope:

- fix all eight PR 41 review findings
- include the verified near-misses and generation-guard residue
- address real-library smoke evidence from the PR 41 follow-up run
- update the current docs, source comments, tests, and DoD evidence

Out of scope:

- thumbnail memory caches or pools
- changing the enrichment lease duration as the primary fix
- prefetch systems
- user-visible import, export, or editing changes
- writing into user media folders

## Current Repo State

Inspection found these current facts:

- `EnrichmentCoordinator.shutdown()` cancels tasks and clears
  `claimedEnrichQueue` without releasing queued SQLite leases.
- `CatalogStore.start()` loads roots and starts scans, but does not clear
  abandoned enrichment claims at process start.
- `priorityEnrichmentCandidates` precomputes only the first `limit` eligible
  priority candidates, so failed claims are not replaced by later eligible
  priority IDs.
- Fallback enrichment uses `ORDER BY sort_key`, while the default browser order
  is best date descending.
- `MediaAssetCollectionViewController.applyStructure` builds both previous and
  next `Set`s on MainActor for telemetry counts only.
- Real-library diagnostics showed repeated structural applies with
  `inserted=0`, `removed=0`, `items≈22493`, and worst `applyMs=15059`.
- Filesystem events wrote per-event `receive` and per-debounce JSONL rows; one
  sampled diagnostics file had 2,624 receive rows and 2,624 debounce rows.
- `CatalogDiagnostics` runs retention only after a successful enabled write.
- `CatalogStore` has repeated wait/exec timing wrapper code and a claim result
  type that duplicates the shared timing shape.
- `CatalogScanner.stableIssueDescription` reports enum issues through unstable
  reflected/case-index text.
- `MediaAssetCollectionSelection.swift` is an AppKit-boundary file without a file
  guide.
- Query-generation equality is the correct freshness guard, but the matching
  branch contains a dead self-assignment and lacks a normalization regression
  test.
- There were 181 app-owned staged thumbnail `.tmp` files under Application
  Support during inspection.

## Captured Requirements

Current requirements touched: FND-002, FND-006, FND-025, FND-041, FND-044,
FND-046, FND-057, FND-061, FND-065, FND-067, ENR-001, ENR-002, ENR-009, and
APP-001.

New or clarified current-increment requirements:

- Enrichment claims are process-local scheduler leases. Startup and shutdown must
  not leave abandoned leases that delay visible thumbnails.
- Viewport priority must fill as far as available and must remain ahead of
  background fallback work.
- Default fallback enrichment must favor default browser usefulness
  (best-date/newest first) rather than persisted path order.
- Background detail-only or reorder-only updates must not repeatedly perform
  huge animated AppKit applies when membership has not changed.
- Durable JSONL diagnostics must remain coarse and bounded; high-frequency
  filesystem/UI details belong in unified logs/signposts or aggregated records.
- App-owned staged thumbnail temps may be cleaned from Application Support;
  originals and user media folders must never be touched.

## Alternatives

### Alternative A: Patch Only The Two Claim Bugs

Pros:

- smallest visible behavior fix
- directly addresses the two highest-severity review findings

Cons:

- leaves fallback newest-thumbnail starvation possible
- leaves multi-second reorder applies and filesystem JSONL spam
- leaves brittle tests and stale comments

Failure modes:

- smoke still reports jank and giant logs with no path to attribution
- review findings are only partially handled

Rejected because the user explicitly asked for the whole plan and real fixes, not
the narrowest release-blocker patch.

### Alternative B: Add Caches, Pools, Or Lease Tuning

Pros:

- could mask thumbnail latency
- could reduce repeated disk reads in some scroll paths

Cons:

- adds complexity before proving the simple owner model is exhausted
- does not fix lost leases or wrong ordering
- creates new lifecycle/memory policy not required by current behavior

Failure modes:

- stale thumbnails, memory growth, and harder jank attribution
- abandoned claims still stall work after relaunch

Rejected under the repo's measure-before-optimizing rule.

### Alternative C: Tighten Existing Owners And Keep Diagnostics Bounded

Pros:

- fixes the actual incorrect leases and claim semantics
- keeps Store as the only SQLite owner, Projection as the ordered-state owner,
  and AppKit as a passive rendering bridge
- removes proven MainActor waste and log spam
- uses query-plan evidence before adding indexes

Cons:

- may still need profile-guided follow-up if AppKit itself hitches on large
  nonanimated reorder applies
- newest-first claim ordering may need an index if SQLite shows a temp sort

Failure modes:

- a new index would be an ADR/documentation obligation if it changes durable
  persistence architecture
- if reordered membership is still too expensive, later evidence may justify a
  different AppKit update policy

Selected. It is the simplest correct fix because it repairs current ownership
and observability without hiding the symptoms behind speculative caches.

## Interfaces, Ownership, And Persistence

- `CatalogStore` remains the only SQLite owner.
- `CatalogStore.start()` clears process-local enrichment claims during initial
  load before enrichment can request candidates.
- `CatalogStore.enrichmentCandidates(prioritizing:limit:)` keeps the same public
  return shape, but fills priority claims from later eligible IDs when earlier
  claims fail.
- Fallback enrichment claim SQL selects eligible keys in best capture date
  descending order with stable path tie-breakers, claims only still-free rows, and
  fetches the claimed rows back in selected order. Query-plan tests cover the
  supporting partial indexes; ADR 0009 records the durable scheduling policy.
- `EnrichmentCoordinator` keeps one actor-local queue, but async shutdown
  releases undispatched queued claims before dropping the queue.
- `CatalogMediaGridState` may carry bounded structural summary values computed
  off the AppKit hot path if needed. AppKit does not build two full sets for JSONL
  counters.
- Thumbnail temp cleanup is limited to `ThumbnailStore`'s Application Support
  directory and staged `.*.tmp` naming convention.

## Concurrency And Cancellation

- Coordinator shutdown cancels producers, releases queued leases, then clears
  process-local state. In-flight worker outcomes may still release/apply through
  existing completion paths if they win the race before cancellation completes.
- Store startup cleanup is idempotent and happens inside Store's actor-owned
  load path.
- Projection still consumes Store changes through one stream and publishes on its
  cadence. Store notifications for successful scan-batch writes happen before
  actor-suspending diagnostics awaits.
- UI high-frequency logging stays in Logger/signposts and does not retain
  catalog state.

## Instrumentation And Profiling Plan

Keep durable JSONL for:

- Store ordered-ID, tile-detail, enrichment-candidate, scan-batch, and
  enrichment-batch timings
- WAL byte samples for scan and enrichment write pressure
- Projection window summaries
- structural apply summaries
- actual active-app run-loop stalls

Remove durable JSONL for:

- per-filesystem-event receive rows
- per-debounce scheduling rows
- high-frequency visible/cell/tile events

Add bounded instrumentation:

- filesystem batch summaries with decoded flag/action counts
- thumbnail/enrichment lifecycle rows only for slow or visible-priority cases
- staged-thumbnail cleanup count in app-owned storage

Smoke verification must summarize worst spans for ordered-ID query, tile detail,
enrichment query, enrichment batch, scan batch, structural apply, WAL size, JSONL
row counts by operation, and run-loop stalls.

## Tests And Acceptance Criteria

Focused tests:

- queued coordinator claims are released on shutdown
- Store startup clears abandoned enrichment claims
- priority claim batching fills after contention
- fallback enrichment order prioritizes newest/default-visible assets
- diagnostics retention runs while writes are disabled
- filesystem event JSONL is batch-level and decoded
- scanner issue descriptions use stable keys
- source hygiene avoids exact source spelling locks
- query normalization does not bump or roll back generation
- staged thumbnail cleanup deletes only app-owned temp files
- reorder-only structural apply uses true diffing with zero-duration animation
  suppression instead of AppKit's reloadData-class nonanimated path
- ViewModel sidebar selection routing uses deterministic Store scan input so the
  post-merge DoD test no longer depends on concurrent real filesystem scanning

Acceptance examples:

- Given a full claim queue and app shutdown, relaunching immediately can claim the
  same still-stale queued assets without waiting 300 seconds.
- Given visible newest assets need enrichment, fallback path-order work does not
  keep those thumbnails gray behind thousands of older path-ordered assets.
- Given a OneDrive filesystem-event burst, diagnostics contain one bounded batch
  summary rather than thousands of receive/debounce rows.
- Given background enrichment changes best dates for many rows but membership is
  unchanged, AppKit does not repeatedly perform multi-second animated full-grid
  structural applies.

## Code-Smell Review

Observed smells:

- MainActor gravity: AppKit structural apply computed O(n) sets for telemetry.
- State duplication risk: claim leases existed in SQLite while queued claims were
  also process-local.
- Diagnostic payload sprawl: filesystem event JSONL dominated useful evidence.
- Test coupling: source tests locked no-op aliases and implementation spelling.
- Stringly/stability risk: scanner issue diagnostics used unstable case-index
  descriptions.

Selected remediation removes or narrows each smell without adding speculative
caches or alternate owner paths.

## Living Documentation Plan

Update after implementation:

- `docs/requirements.md`
- `docs/onboarding.md`
- `docs/process/performance.md` if the performance workflow changes
- `docs/index.md`
- `docs/adr/0009-enrichment-storage-and-staleness.md`
- `docs/index.md`
- ADR 0009/0011 only if claim-order indexes become durable architecture
- file guides and focused comments in touched Store, Projection, AppKit,
  diagnostics, scanner, and thumbnail boundaries

Stale-document audit must cover specs 0033 through 0035, requirements,
onboarding, process docs, ADRs, scripts, tests, and backlinks.
