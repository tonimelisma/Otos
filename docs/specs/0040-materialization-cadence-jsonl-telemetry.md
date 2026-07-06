# Spec 0040: Materialization Cadence And JSONL Telemetry

## Status

Implemented in this increment.

## Classification

Bug fix, performance/instrumentation, tooling, and documentation correction.

## Problem Statement And User-Facing Goal

Spec 0038 made the media grid visually robust, and spec 0039 fixed the largest
post-review grid apply/preheat issues. The remaining approved plan addressed two
observability gaps: stalled cloud materialization requests were not attributable
after a run, and grid cache/preheat/tile-load counters existed only as live
signposts. The goal is to keep the simple current architecture while making the
next materialization stall or no-blank-grid defense diagnosable from durable
JSONL without adding high-cardinality per-tile JSONL spam.

## Captured Requirements For Verification

The user explicitly approved root `PLAN.md` and asked to implement all increments
through Definition of Done. The guidance was concrete enough to record directly;
where the draft referenced spec 0039, current repo inspection found spec 0039
already implemented, so this increment uses the next available spec number and
records already-satisfied plan items as current repo state rather than
overwriting an accepted spec.

- Functional: cloud materialization shall re-request provider downloads every
  second while a file remains dataless inside the existing timeout.
- Diagnostics: materialization completion records shall include outcome,
  re-request count, request-to-completion milliseconds, attempt milliseconds, and
  source size.
- Diagnostics: dataless hand-off records shall include the refreshed claim lease
  expiry when the refresh succeeds.
- Diagnostics: claim release and refresh failures shall be visible JSONL lifecycle
  phases rather than swallowed errors.
- Tooling: grid cache, preheat, tile-load, nil-load, dropped-load, and watchdog
  counters shall be readable from JSONL after the app quits.
- Tooling: `script/catalog-diagnostics.sh check` shall fail on the core
  post-0038 regressions that are now JSONL-readable.
- Regression: already-implemented spec 0039 work remains current: batched
  preheat, non-main decoded-cache warming, reloadData-class large/reorder apply
  fallback, monotonic sticky-detail recency, and the removed vestigial
  `NSImageView.image` clear.
- Regression: an unresolved PR #46 review thread showed repeated look-ahead
  requests could cancel an in-flight preheat task even when the task already
  covered the newly requested IDs; covered requests shall reuse the in-flight
  burst so the Store detail read can finish.
- Process: root `PLAN.md` is retired after promotion so a proposed plan does not
  masquerade as current guidance.
- Privacy: diagnostics may include developer-local media paths and filenames but
  never media bytes, thumbnails, credentials, or unbounded metadata blobs.

## Current Repo State

Inspection before implementation found:

- `docs/specs/0039-grid-preheat-and-apply-follow-up.md` already existed and the
  grid code already used one batched preheat task, a nonisolated
  `MediaTileImageCache`, access-stamped `MediaTileDetailCache`, and the
  reloadData-class fallback for large/reorder applies.
- `FileMaterialization.materialize` returned only `MaterializationOutcome` and
  retried requests every 15 seconds.
- `EnrichmentCoordinator` discarded re-request count and materialization elapsed
  time, and several claim release/refresh calls used `try?`.
- Cache hits/misses/inserts, prefetch, tile loads, and watchdog events were
  live signposts only.
- `script/catalog-diagnostics.sh check` copied and summarized the JSONL file but
  did not enforce pass/fail thresholds.
- PR #46 still had one unresolved review thread against
  `MediaAssetCollectionPrefetch.swift`: identical covered look-ahead bursts could
  be cancelled and restarted before making progress.
- The untracked root `PLAN.md` and draft
  `docs/process/instrumentation-review.md` needed to land through the normal
  spec path.

## In Scope

- Introduce `MaterializationResult` and thread it through
  `FileMaterialization` and `EnrichmentCoordinator`.
- Change the materialization re-request cadence to one second.
- Add visible lifecycle fields for lease refresh, re-request count, and
  request-to-completion timing; record claim refresh/release failures.
- Add coarse `GridTelemetry` counters and ViewModel-owned JSONL snapshots.
- Extend `script/catalog-diagnostics.sh check` with JSONL gates and PID-qualified
  copied artifacts.
- Reuse an in-flight preheat task when it already covers a repeated look-ahead
  request from the PR #46 review thread.
- Remove the remaining vestigial `imageView.image = nil` clear.
- Add focused unit/source-hygiene tests and update living docs.

## Out Of Scope

- Changing eager materialization policy, pool sizes, claim ordering, lease
  duration, schema, thumbnail storage, projection cadence, or reorder damping.
- Adding per-re-request JSONL rows or per-tile durable rows.
- Verifying overlay corner masks with headless rendering; the current measured
  fact is that headless paths are not faithful to `maskedCorners`.

## Linked Current Requirement IDs

FND-006, FND-025, FND-044, APP-015, ENR-008, ENR-009, and ENR-010.

## Architectural Alternatives

### Alternative A: Keep Signposts Only

Pros: no durable UI JSONL. Cons: post-run diagnosis loses cache/preheat/watchdog
counters, and manual runs cannot be audited after the live log window closes.
Failure mode: the next grid regression has no durable evidence.

### Alternative B: Per-Event JSONL For Requests And Tiles

Pros: maximally detailed traces. Cons: violates the repo rule against
high-frequency UI JSONL, creates write pressure, and risks retaining too much
grid state. Failure mode: diagnostics become part of the performance problem.

### Alternative C: Coarse Counter Snapshots Plus Lifecycle Completion Fields

Pros: keeps high-frequency paths cheap, makes post-run checks JSONL-readable, and
adds only bounded scalar rows. Cons: individual cache hits and duplicate provider
requests are not separately timestamped. Failure mode: if a future bug needs
per-event timing, a fresh spec must add a narrow capture mode. Spec 0041 tightens
the grid-counter durability details by requiring an interval or termination row
instead of accepting the startup row alone.

## Selected Approach

Choose Alternative C. The product behavior stays simple: one materialization
helper, one coordinator, one grid cache, and one diagnostics actor. The only new
state is a set of scalar counters guarded by `Mutex`; the ViewModel records
startup and periodic snapshots through the existing diagnostics owner. Spec 0041
adds the explicit app-termination flush that supersedes this spec's original
best-effort deinit shutdown row.

## Interfaces, Ownership, Data Flow, And Persistence

- `FileMaterialization.materialize` returns `MaterializationResult` containing
  `outcome`, `rerequestCount`, and `elapsedMs`.
- `EnrichmentCoordinator` receives that result, records bounded visible lifecycle
  fields, releases the claim, and hands successful downloads back through
  `freshly`.
- `CatalogStore.refreshEnrichmentClaims` returns the refreshed lease expiry for
  diagnostics; the lease remains process-local scheduler state.
- `GridTelemetry` is nonisolated rendering telemetry. It never answers product
  truth and is never persisted except as scalar JSONL snapshots.
- `MediaAssetCollectionViewController` owns one preheat task and one current
  preheat ID set. A new request whose IDs are already covered by that task is
  ignored; requests with uncovered IDs remain newest-burst work and replace the
  old task.
- `script/catalog-diagnostics.sh check` reads a chosen JSONL file, copies it with
  a PID-qualified artifact name, summarizes it, and runs pass/fail gates.

No schema, catalog persistence, thumbnail persistence, or user-original files
change.

## Concurrency And Actor Ownership

- File materialization helpers are explicitly nonisolated and run off-main.
- The coordinator actor owns claim refresh/release sequencing and records
  lifecycle rows after awaited Store operations.
- UI/AppKit work remains MainActor-owned; grid counters are synchronous
  thread-safe increments, not actor hops.
- The ViewModel owns the grid-counter snapshot task and cancels it in `deinit`.
  Spec 0041 moves process-exit recording to an explicit app-termination hook that
  awaits the diagnostics actor with a bounded timeout.

## Instrumentation And Profiling Plan

- FileAccess debug logs retain live request/re-request lines.
- Durable JSONL gains `catalog.thumbnails.visibleLifecycle` fields:
  `leaseRefreshedUntil`, `rerequestCount`, `requestToCompleteMs`, `attemptMs`,
  `outcome`, and `sourceSize`.
- Durable JSONL gains `ui.grid.counters` snapshots with cache, preheat, tile-load,
  and watchdog totals; spec 0041 requires a non-start row for post-run evidence.
- `script/catalog-diagnostics.sh check` fails on missing non-start grid counter
  evidence, watchdog count, apply/stall thresholds, slow `requested:"1"`
  tile-detail records, download completions missing attribution, and materialized
  lifecycle stragglers without re-claim.

## Test And Acceptance Criteria

- `FileMaterializationTests` proves one-second-cadence re-request counting with
  injected status/request providers.
- `EnrichmentCoordinatorTests` proves dataless download lifecycle records lease,
  re-request, elapsed, and fresh re-claim evidence.
- `CatalogDiagnosticsTests` proves the script summarizes healthy fixtures, fails
  watchdog fixtures, and uses non-conflicting artifacts under parallel tests.
- Source hygiene proves no swallowed coordinator claim release/refresh calls, no
  vestigial `imageView.image = nil`, covered preheat requests do not restart
  in-flight work, and presence of diagnostics gates.
- Runtime smoke evidence must run `script/smoke-run.sh` and
  `script/catalog-diagnostics.sh check`, or record the exact environment blocker.

## Stale Document And Comment Audit

Affected current docs: `docs/index.md`, `docs/requirements.md`,
`docs/adr/0009-enrichment-storage-and-staleness.md`,
`docs/specs/0038-no-blank-grid-invariant.md`, `docs/onboarding.md`,
`docs/process/performance.md`, `docs/process/testing.md`, and
`docs/process/instrumentation-review.md`. Spec 0041 later updates the grid-counter
termination and start-only gate details. ADR 0006 and spec 0039 already described
the implemented grid apply/preheat state; this increment only adds backlinks where
needed. Planning docs were not used except the explicitly approved root `PLAN.md`,
which is retired by this spec.

Affected file guides and comments were checked in
`FileMaterialization.swift`, `EnrichmentCoordinator.swift`,
`EnrichmentCoordinatorCompletion.swift`, `GridTelemetry.swift`,
`CatalogWindowViewModel.swift`, `MediaAssetTileView.swift`, and
`script/catalog-diagnostics.sh`.

## Code Smells Review

- MainActor gravity: addressed by marking materialization helpers nonisolated and
  keeping grid counters off-main.
- Diagnostic payload sprawl: avoided by scalar counter snapshots and completion
  fields, not per-request/per-tile JSONL rows.
- State duplication: accepted only for rendering telemetry counters; they are not
  catalog truth.
- Test coupling: source-hygiene tests assert architecture guardrails where the
  guardrail itself is the contract.
