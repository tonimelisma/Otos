# Spec: AppKit Jank Instrumentation

## Problem Statement

Running Otos against a large library produced severe beach balls while the media
table was updating. A process sample showed the main thread inside SwiftUI's
AppKit table bridge, especially `NSTableView` row update and `NSHostingView`
creation. Existing catalog diagnostics showed scan and projection counts, but
did not preserve enough timing or UI handoff evidence to correlate a future
stall with the exact state Otos handed to SwiftUI.

## User-Facing Goal

When the media table becomes unresponsive, developers should be able to inspect
repo logs and diagnostics and quickly answer whether time was spent in catalog
snapshotting, projection, state assignment, or AppKit/SwiftUI table work.

## Scope

- Add signposts around app-owned projection, snapshot, state-apply, scan-flush,
  scan-memory, change-notification, and availability-check boundaries.
- Add JSONL diagnostics for each catalog window state handoff to SwiftUI.
- Add projection timing fields to existing `catalog.projection.window`
  diagnostics.
- Add a debug-only main-run-loop stall monitor that records the latest table
  handoff context when the main run loop wakes up late.
- Update diagnostics summary tooling and tests for the new events.

## Non-Goals

- Do not replace SwiftUI `Table`.
- Do not add an AppKit table bridge.
- Do not change scan, persistence, projection cadence, sorting, filtering, or
  table behavior.
- Do not add automatic Instruments capture or process sampling in this
  increment.

## Current Repo State

- `CatalogProjection` already owns the 10 Hz coalesced publication loop.
- `CatalogWindowViewModel` assigns final `CatalogWindowState` to SwiftUI.
- `MediaTableView` receives a plain `[MediaAsset]` and renders a SwiftUI
  `Table`.
- `CatalogDiagnostics` writes debug JSONL under Application Support.
- `script/catalog-diagnostics.sh` summarizes operation counts.
- A live sample from the observed beach ball showed AppKit table update work,
  not filesystem or GRDB work, dominating the main thread.

## Captured Requirements

| ID | Type | Requirement |
| --- | --- | --- |
| JNK-001 | Tooling | Catalog projection diagnostics must include snapshot, projection, and total publication durations. |
| JNK-002 | Tooling | Catalog window state assignment must emit a signpost and JSONL event with update id, previous row count, current row count, row delta, library count, selection, empty state, and apply duration. |
| JNK-003 | Tooling | Debug builds must monitor main-run-loop stalls while the app is active and record stall duration plus the latest table handoff context when available; inactive timer coalescing and App Nap must not be reported as UI stalls. |
| JNK-004 | Tooling | App-owned catalog/UI boundaries around snapshot, scan flushing, scan-memory apply, change notification, root availability, and UI intents must have signposts where timing helps separate store/projection work from SwiftUI/AppKit work. |
| JNK-005 | Process | AppKit and SwiftUI internals are diagnosed by correlating app-owned signposts and JSONL breadcrumbs with `sample` or Instruments; Otos must not pretend it can signpost inside private Apple framework code. |

## Alternatives

### Alternative A: Boundary Instrumentation Plus Stall Breadcrumbs

Add signposts and JSONL at Otos-owned boundaries, and add a debug stall monitor
that records the latest table-sized state handoff.

Pros:

- Simple and Swift-native.
- Preserves current architecture.
- Produces script-checkable evidence after a run.
- Keeps AppKit internals diagnosed through Apple tools instead of fragile hooks.

Cons:

- Does not directly time private SwiftUI/AppKit table internals.
- Requires `sample` or Instruments for stack-level proof.

Failure mode:

- If only JSONL is inspected and no sample/trace is captured, the evidence can
  show correlation but not prove the private framework stack.

### Alternative B: Add An AppKit Table Wrapper For Observability

Replace SwiftUI `Table` with an `NSTableView` wrapper so Otos can instrument
delegate/data-source methods directly.

Pros:

- More direct table lifecycle visibility.
- Could later support custom virtualization behavior.

Cons:

- Much more complex.
- Violates the current SwiftUI-first preference without first proving SwiftUI
  cannot meet the requirement.
- Changes UI behavior while the immediate request is instrumentation.

Failure mode:

- The wrapper becomes a second UI framework surface and distracts from the
  simpler root-cause work.

### Alternative C: External Profiling Only

Rely only on `sample`, `xctrace`, and unified logs without adding app
instrumentation.

Pros:

- No app code changes.
- Direct Apple-framework stack evidence when captured at the right moment.

Cons:

- Weak after-the-fact evidence.
- Hard to correlate a hang with catalog row counts, projection timings, or the
  exact state update that preceded it.

Failure mode:

- A future beach ball is reported after the fact and the repo lacks enough
  durable breadcrumbs to explain what state triggered it.

## Selected Approach

Use Alternative A. It is the simplest correct diagnostic layer: Otos measures the
boundaries it owns, records durable facts in debug JSONL, and uses Apple tooling
for private framework internals.

## Ownership And Data Flow

- `CatalogStore` signposts raw snapshot creation, scan-memory application,
  change notification, and availability checks.
- `CatalogScanner` signposts scanner flushes into the store.
- `CatalogProjection` times snapshot pull, projection build, and full
  publication.
- `CatalogWindowViewModel` signposts and records the final state assignment to
  SwiftUI.
- `CatalogUIUpdateTracker` remembers the latest table handoff on the MainActor.
- `MainRunLoopStallMonitor` is debug-only and records late run-loop wakeups with
  the latest table handoff context.

## Concurrency And Actor Ownership

- Projection work remains off the MainActor.
- State assignment and stall tracking are MainActor work because they describe
  UI handoff state.
- JSONL writing remains actor-isolated through `CatalogDiagnostics`.
- The stall monitor uses the main run loop, not background polling, because it
  measures late wakeups from the UI thread's point of view.

## Instrumentation And Profiling Plan

- Use `script/catalog-diagnostics.sh check` for durable JSONL summaries.
- Use `script/logs.sh UI`, `script/logs.sh Performance`, and
  `script/logs.sh Catalog` for live signposts.
- Use `sample` or `script/profile.sh "Time Profiler" 10s` when the app is
  actively beach balling to see private SwiftUI/AppKit stacks.

## Acceptance Criteria

- Projection JSONL events include timing fields.
- State-apply JSONL events include update id and table row counts.
- Debug stall diagnostics include stall duration and latest table handoff fields
  when a handoff exists.
- Diagnostics summary reports state-apply and stall event counts.
- Tests cover JSONL writing and summary output for the new diagnostic events.

## Captured Outcome And Follow-On

The instrumentation work was completed before changing the media browser. A
reproduction with approximately 23,000 catalog rows eventually stalled after
repeated scope switching and then grew from roughly 2.3 GB to 7.1 GB while the
window remained unresponsive. The capture in
`build/RunawayCaptures/20260618-210811` showed:

- the main thread remained inside SwiftUI/AppKit table update, automatic row
  height, `NSHostingView`, KVO, and AttributeGraph work
- the heap contained about 18.9 million live malloc nodes, millions of
  AttributeGraph allocations, and tens of thousands of table cell hosting views
- CatalogStore and CatalogProjection did not continue publishing new states
  during the runaway period
- no conventional application retain-cycle leak was identified

This proves the runaway was in the rendered table path after Otos handed off
state. It does not prove which private framework condition made the Nth scope
change enter that state. Replacing the failed table is intentionally outside
this spec's original instrumentation-only scope and is specified separately in
Spec 0011 and ADR 0006. The instrumentation from this spec remains in place to
compare the replacement grid with the failed table path.
