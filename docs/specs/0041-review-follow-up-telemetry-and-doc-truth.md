# Spec 0041: Review Follow-Up Telemetry And Doc Truth

## Status

Implemented in this increment.

## Classification

Bug fix, documentation correction, tooling, and regression follow-up.

## Problem Statement And User-Facing Goal

Post-merge review of specs 0039 and 0040 found two moderate issues and several
minor follow-ups in the grid/enrichment diagnostics path. The user asked to fix
all findings after reading the actual code, with no assumptions. The goal is to
keep the implemented architecture simple while making quick smoke-run grid
counters durable, correcting living docs to match code, avoiding wasteful preheat
cancellation, and recording the remaining runtime-evidence boundaries honestly.

## Captured Requirements For Verification

The review findings are concrete enough to record directly:

- Tooling: a `ui.grid.counters` startup row alone is not sufficient post-run
  evidence; quick runs must produce an interval or termination counter row, and
  `script/catalog-diagnostics.sh check` must fail when they do not.
- Tooling: `script/catalog-diagnostics.sh check` must validate the copied JSONL
  artifact that it reports, not a concurrently written live diagnostics file.
- Tooling: grid-counter termination recording must be explicit app-lifecycle work
  rather than a detached `deinit` task racing process exit.
- Non-functional: useful early smoke runs should not wait 60 seconds before the
  first non-start grid-counter interval row.
- Documentation: ADR 0009 must describe the actual `MediaTileImageCache`, which
  is a fixed count/cost Mutex-LRU and does not respond to OS memory pressure.
- Regression: cancelling AppKit prefetch for a subset of the current preheat IDs
  must not cancel the entire in-flight burst while still preventing cancelled IDs
  from merging/warming when the read finishes.
- Regression: overlay corner-mask orientation must be checked against the actual
  code and runtime evidence, with any blocker recorded.
- Non-functional: enrichment lifecycle timestamp formatting should not allocate a
  fresh `ISO8601DateFormatter` for every event.
- Process: the first real dataless-download field run remains a checklist item;
  tests prove the implementation, but this increment must not force user media
  downloads merely to create field data.

## Current Repo State

Inspection found:

- `CatalogWindowViewModel` recorded a `shutdown` grid-counter row only from
  `deinit`, using a detached task that the process could exit before completing.
- The periodic `ui.grid.counters` loop slept 60 seconds before its first
  interval row; quick smoke sessions usually had only the zero-ish `start` row.
- `script/catalog-diagnostics.sh check` accepted any `ui.grid.counters` row, so a
  `start` row alone satisfied the gate.
- The script copied the live diagnostics file into `build/Diagnostics` for the
  evidence bundle, but the Python `check` assertions still parsed the original
  live file.
- `MediaTileImageCache` is a `Mutex`-protected dictionary with LRU eviction by
  `accessStamp`, `totalCostLimit`, and `countLimit`; it has no `NSCache` or
  DispatchSource memory-pressure mechanism.
- `cancelPreheat` cancelled the whole preheat task when any cancelled AppKit ID
  intersected the current burst.
- The tile code now omits the former top-left text scrim. The remaining video
  badge sits at the bottom-right face corner, uses `.layerMinXMaxYCorner`, and
  centers its duration text or fallback symbol inside the right-aligned darkened
  area. Source tests pin that mask and layout policy, while screenshot capture
  remained environment-blocked in spec 0040.
- `EnrichmentCoordinatorCompletion` created a new `ISO8601DateFormatter` inside
  each `diagnosticTimestamp` call.
- No post-merge smoke session had live materialization completions; unit and
  store tests covered the one-second cadence and attribution fields.

## In Scope

- Add an explicit app termination hook for grid-counter recording.
- Emit the first periodic grid-counter interval around 15 seconds, then continue
  at the existing coarse cadence.
- Tighten diagnostics script gates and tests so start-only counters fail.
- Make diagnostics script summaries and checks read the copied artifact snapshot.
- Correct ADR and current docs for the fixed count/cost decoded-image cache.
- Narrow preheat cancellation to cancelled IDs and filter results to active IDs.
- Reuse one locked ISO8601 formatter for lifecycle timestamps.
- Update requirements, onboarding, performance/instrumentation docs, and this
  spec with the review follow-up facts and verification plan.

## Out Of Scope

- Adding OS memory-pressure eviction to the decoded-image cache. That would be a
  new cache policy and lifecycle behavior, not a documentation fix.
- Per-tile JSONL, per-prefetch JSONL, or per-download debug spam.
- Forcing materialization of user cloud media merely to manufacture field data.
- Replacing the current AppKit overlay implementation.

## Linked Current Requirement IDs

FND-006, FND-025, FND-044, APP-006, APP-015, ENR-004, ENR-009, and ENR-010.

## Architectural Alternatives

### Alternative A: Keep Deinit Shutdown Recording And Loosen The Review Claim

Pros: no code change. Cons: contradicted the actual post-merge JSONL sessions,
where only `start` rows existed. Failure mode: quick manual runs keep passing the
script gate without readable cache/preheat/tile/watchdog totals.

### Alternative B: Record Per-Tile Or Per-Prefetch JSONL Rows

Pros: every counter source is visible without relying on interval/termination
snapshots. Cons: violates the high-frequency diagnostics policy and risks making
diagnostics part of the jank problem. Failure mode: write pressure obscures the
UI behavior being measured.

### Alternative C: App-Lifecycle Termination Flush Plus Early Coarse Interval

Pros: preserves scalar counters, gives quick runs a useful row, and makes app
termination recording explicit. Cons: app termination waits briefly for a small
diagnostics write. Failure mode: if the diagnostics actor is stuck, the flush
times out and logs an error rather than blocking termination indefinitely.

Selected: Alternative C.

### Cache Documentation Alternatives

1. Add a DispatchSource memory-pressure hook.
2. Revert to `NSCache`.
3. Correct the ADR to describe the current fixed count/cost LRU.

Selected: correct the ADR. The reviewed defect is a documentation contradiction;
no current requirement or measurement proves that OS memory-pressure behavior is
needed. Adding it now would introduce unrequested policy complexity.

## Selected Approach

- `OtosApp` observes `NSApplication.willTerminateNotification` and calls the
  ViewModel's explicit termination recorder.
- `CatalogWindowViewModel` captures the current `GridTelemetry` totals, cancels
  the interval task, writes a `willTerminate` row through a detached task, and
  waits up to two seconds for that diagnostics actor write. The detached task does
  not hop back to the MainActor, so the wait does not deadlock on itself.
- The grid-counter interval loop records `start`, then sleeps 15 seconds for the
  first `interval`, then sleeps 60 seconds for later coarse interval rows.
- The diagnostics script still summarizes all counter rows, but `check` requires
  at least one `interval`, `willTerminate`, or legacy `shutdown` row.
- The diagnostics script redirects its current input to the copied JSONL artifact
  before writing the summary or running the check gate, so reported artifacts and
  validated input are the same stable snapshot.
- Preheat cancellation subtracts only cancelled IDs from the active ID set; it
  cancels the task only when no IDs remain. When the read completes, only active
  IDs merge into sticky tile details and warm the decoded cache.
- `EnrichmentCoordinatorCompletion` uses one `Mutex`-guarded
  `ISO8601DateFormatter`.

## Interfaces, Ownership, Data Flow, And Persistence

No catalog schema, thumbnail files, user originals, or persisted preferences
change. The affected interfaces are:

- `CatalogWindowViewModel.recordGridTelemetryForTermination(timeout:)`.
- `ui.grid.counters` phases: `start`, `interval`, and `willTerminate`.
- `script/catalog-diagnostics.sh check` pass/fail interpretation.

`GridTelemetry` remains process-local rendering telemetry. `CatalogDiagnostics`
remains the single JSONL append owner.

## Concurrency And Actor Ownership

- Termination recording captures scalar counters on the MainActor, then writes
  through a detached utility task that awaits only the diagnostics actor.
- App termination waits for that bounded diagnostics write with a timeout.
- Preheat result filtering happens on the MainActor where `preheatIDs` is owned;
  cache warming remains off-main.
- The ISO8601 formatter is shared only inside a `Mutex`.

## Instrumentation And Profiling Plan

- `ui.grid.counters` rows must include `interval` or `willTerminate` evidence in
  quick runs.
- `script/catalog-diagnostics.sh check` must fail a start-only fixture and pass a
  healthy interval fixture.
- Runtime smoke should run `script/smoke-run.sh && script/catalog-diagnostics.sh
  check`; visual screenshot capture should be attempted for overlay mask
  orientation, with any macOS capture blocker recorded.
- No extra profiling is required unless the smoke run shows new stalls or script
  gate failures.

## Test And Acceptance Criteria

- `CatalogDiagnosticsTests` proves start-only grid counters fail the script gate.
- Source-hygiene tests prove the app termination hook, 15-second first interval,
  tightened script gate, copied-artifact diagnostics check, narrowed preheat
  cancellation, active-result filtering, and formatter reuse remain in place.
- `script/verify.sh` passes.
- Runtime smoke diagnostics pass and include either `interval` or `willTerminate`
  grid-counter rows.
- Screenshot or equivalent visual evidence is captured for the overlay masks, or
  the exact environment blocker is recorded.

## Stale Document And Comment Audit

Affected current docs: `docs/index.md`, `docs/requirements.md`,
`docs/adr/0009-enrichment-storage-and-staleness.md`, `docs/onboarding.md`,
`docs/process/performance.md`, `docs/process/instrumentation-review.md`, and
`docs/specs/0040-materialization-cadence-jsonl-telemetry.md`. ADR 0006 already
describes the overlay placement; it remains current. Planning docs were not used.

Affected file guides/comments: `CatalogWindowViewModel.swift`,
`CatalogWindowViewModelGridTelemetry.swift`,
`MediaAssetCollectionPrefetch.swift`, `EnrichmentCoordinatorCompletion.swift`,
`MediaTileImageCache.swift`, and `script/catalog-diagnostics.sh`.

## Code Smells Review

- MainActor gravity: avoided by keeping diagnostics writes in the existing actor
  and preheat warming off-main.
- Diagnostic payload sprawl: avoided by retaining scalar counter snapshots only.
- State duplication: accepted only for process-local rendering counters, not
  catalog truth.
- AppKit bridge sprawl: unchanged; preheat cancellation remains inside the
  existing AppKit boundary.
