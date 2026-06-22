# Spec 0010: Catalog UI Jank Instrumentation

## Classification

- Work type: Bug investigation, instrumentation, and regression evidence
- Current requirement IDs: FND-006, FND-025, FND-041
- Rendering decision: Spec 0011 and ADR 0006

## Problem And Goal

A high-cardinality media browser can stall inside private framework work after
Otos hands state to AppKit. App-owned spans alone cannot identify private
SwiftUI/AppKit stacks, while uncontrolled diagnostic work can itself perturb the
path being measured.

The current strategy must correlate four layers:

1. Store snapshot construction
2. Projection derivation and publication
3. MainActor state assignment
4. AppKit collection receipt, application, layout, and cell configuration

When the main run loop actually stalls, durable evidence must identify the latest
scalar catalog handoff without retaining the catalog state itself.

## Captured Failure Evidence

The media browser previously used a high-cardinality table. Repeated scope
switching could trigger an abrupt permanent beach ball, 100 percent CPU, and
roughly linear heap growth to OOM. Process samples and heap inspection placed the
main thread in private SwiftUI/AppKit table row update and hosting-view layout
work after Otos had handed off approximately 23,000 rows.

That evidence established the rendering boundary decision in ADR 0006. It did
not prove that snapshot construction or Projection formed an application-level
feedback loop. The current NSCollectionView grid replaced the failed rendering
surface; this spec keeps the evidence only because it still explains why the
narrow AppKit collection boundary and its instrumentation are required.

## Scope

In scope:

- app-owned snapshot, Projection, state-assignment, collection, and run-loop
  telemetry
- signposted spans for timed boundaries
- scalar counts, scope, cache outcome, and update identifiers
- durable JSONL for coarse catalog operations, Projection summaries, failures,
  availability transitions, and actual stalls
- unified logging for high-frequency UI events
- repo scripts for logs, diagnostics summaries, and Instruments traces

Out of scope:

- attempting to instrument inside private Apple framework internals
- per-cell durable event logging
- retaining full CatalogWindowState for correlation
- automatic crash upload, analytics, or release diagnostic export

## Requirements

| Label | Type | Current requirement |
| --- | --- | --- |
| JNK-001 | Tooling | Snapshot construction, Projection, ViewModel assignment, and collection work emit Logger/signpost evidence. |
| JNK-002 | Tooling | High-frequency UI telemetry never creates per-update JSONL tasks. |
| JNK-003 | Tooling | One ViewModel-owned active-app run-loop monitor records only actual stalls. |
| JNK-004 | Privacy | Stall context contains bounded scalar fields, not retained catalog state or media payloads. |
| JNK-005 | Process | Private framework attribution uses sample or Instruments evidence, not speculation from app spans. |

## Instrumentation Strategy

### Store And Projection

- currentSnapshot begin/end signposts include library and asset counts
- Projection publication spans include snapshot, derivation, ordering-cache hit,
  membership change, sort duration, selected scope, and equality suppression
- coarse Projection summaries are written to JSONL for post-run checks

### ViewModel

- each final state assignment receives a monotonically increasing scalar update
  ID
- Logger/signposts record library count, grid count, scope, and assignment
  duration
- the ViewModel passes those scalar fields to its owned
  MainRunLoopStallMonitor
- no CatalogWindowState is captured by the monitor

### AppKit Collection

Logger/signposts cover:

- collection state receipt
- structural diffable apply
- newest-pending replacement while an apply is active
- apply completion
- same-identity visible-item reload
- layout replacement
- cell configuration only when it exceeds the 5 ms interaction budget

These paths do not call CatalogDiagnostics and do not create Tasks.

### Main Run Loop

The ViewModel-owned monitor samples the active app's main run loop. Inactive
timer coalescing and App Nap are ignored. When active delay exceeds the stall
threshold, the monitor logs the duration plus latest scalar handoff and creates
one rare JSONL task containing scalar values only.

## Alternatives

### JSONL Every UI Event

Pros:

- durable event-by-event timeline

Cons:

- actor queue and task creation can distort the measured UI path
- duplicates unified logging and signposts

Failure mode: instrumentation contributes to task or memory pressure.

### Logger And Signposts Only

Pros:

- lowest app-level overhead and first-class Instruments integration

Cons:

- post-run durable summaries depend on log capture

Failure mode: a stall report lacks the last app-owned scalar context after logs
roll over.

### Split Native UI Telemetry And Coarse JSONL

Pros:

- native high-frequency evidence
- durable operational and actual-stall evidence
- no full-state retention

Cons:

- diagnosis consults both unified logs/traces and JSONL summaries

Selected: split telemetry.

## Evidence Workflow

1. Build and launch through repo scripts.
2. Capture focused UI/Catalog unified logs.
3. Run script/catalog-diagnostics.sh check for durable coarse evidence.
4. Use script/profile.sh "Time Profiler" for CPU-heavy stalls.
5. Use script/profile.sh "Swift Concurrency" for task/executor pressure.
6. Use sample or heap tools when private framework stacks or object growth need
   attribution.
7. Correlate timestamps and scalar update IDs across evidence; do not infer
   framework behavior from a single layer.

## Performance Budgets

- MainActor app-owned spans must remain below 100 ms.
- Collection interaction paths target below 5 ms.
- Only one Projection derivation and one structural collection apply may be in
  flight within their respective owners.
- Runtime verification should show RSS reaching a bounded plateau rather than a
  sustained linear climb.

## Acceptance And Tests

- source hygiene proves ViewModel and AppKit high-frequency paths do not call
  CatalogDiagnostics or spawn JSONL tasks
- diagnostics tests prove coarse event append, reset/reopen, disabled behavior,
  and summary vocabulary
- collection state-machine tests prove one-in-flight and newest-pending behavior
- Projection tests prove coalescing and equal-state suppression
- agent-controlled logs and traces contain the expected native categories/spans
- script/verify.sh passes

## Living Documentation

The factual failed-table evidence remains because it justifies ADR 0006. No
current document describes that table as the implemented browser. All current
instrumentation language names the NSCollectionView grid, native high-frequency
telemetry, ViewModel-owned stall monitor, and coarse JSONL policy.
