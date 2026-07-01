# Spec 0014: Catalog Task And Mutation Ownership

## Classification

- Work type: Refactor and concurrency/lifecycle bug fix
- User-visible feature: none
- Current requirement IDs: FND-023, FND-034, FND-051, FND-052
- ADRs: ADR 0004 amended; ADR 0005 clarified
- Future ideas: none

## Problem And Goal

`CatalogWindowViewModel` is the MainActor boundary between synchronous SwiftUI
actions and asynchronous catalog actors. Two implementation details contradicted
that ownership:

1. The ViewModel stored a task that consumed Projection's effectively indefinite
   state stream, while the task closure strongly captured the ViewModel. The
   ViewModel therefore could not reach the `deinit` that was supposed to cancel
   the task.
2. Every add/remove action created an independent unstructured task. The
   ViewModel retained no handle, could not cancel those tasks, and defined no
   ordering across Store suspension points.

The goal is truthful task ownership: the ViewModel can deinitialize while its
state subscription is active, and every accepted add/remove command reaches
Store serially in submission order without delaying sidebar selection.

## Current Repository State

- `CatalogStore` owns SQLite, root runtime catalog state, Store-owned catalog
  queries, startup coalescing, serial scans, and scan callback ownership.
- `CatalogProjection` owns off-MainActor derivation and a 10 Hz one-in-flight
  publication loop.
- `CatalogWindowViewModel` owns final MainActor state, sidebar selection, user
  intents, task lifetimes, and scalar stall correlation.
- SwiftUI views are passive and call synchronous ViewModel intents.
- Catalog errors remain logs and debug diagnostics only.

These boundaries remain. This increment corrects lifetime and delivery inside
the ViewModel boundary. It also incorporates the latest PR review by making
Store's cheap change stream carry a lossless typed root-removal event, allowing
Projection to preserve selection semantics across a coalesced same-path re-add.

## Captured Requirements

| ID | Type | Requirement |
| --- | --- | --- |
| TASK-001 | Architecture | Every task created by `CatalogWindowViewModel` has a named owner and cancellation path. |
| TASK-002 | Lifecycle | State consumption does not strongly retain the ViewModel while awaiting the next projected state. |
| TASK-003 | Architecture | Views call synchronous ViewModel intents and create no catalog tasks. |
| TASK-004 | Concurrency | Add/remove commands execute one at a time in submission order. |
| TASK-005 | Concurrency | Sidebar selection remains a separate newest-value lane and is not delayed by catalog mutation delivery. |
| TASK-006 | Reliability | Accepted add/remove commands are not silently dropped while the ViewModel is alive. |
| TASK-007 | Lifecycle | Ending the ViewModel prevents queued mutations from starting; an already-dequeued Store mutation may safely finish. |
| TASK-008 | MainActor | MainActor owns only intent submission, task lifecycle, trivial routing, final state assignment, and stall correlation. |
| TASK-009 | Product | No mutation progress, busy state, catalog alert, or other user-visible behavior is added. |
| TASK-010 | Regression | Removing and re-adding the selected root at the same path inside one publication interval leaves the replacement unselected. |

Acceptance examples:

- Releasing the last external ViewModel reference while its Projection stream is
  active deinitializes the ViewModel and terminates the subscription.
- Submitting add A, remove A, then add B produces a catalog containing only B.
- A failed duplicate add does not terminate mutation delivery; later commands
  still execute.
- Cancelling the owner while one command is suspended prevents the next buffered
  command from beginning.
- Rapid sidebar selection remains newest-value coalesced independently of a
  catalog mutation.
- Remove and same-path re-add before the next Projection tick publishes the
  replacement under All Media rather than silently retaining old selection.

## Task And Stream Ownership

| Lane | Producer | Consumer task | Buffering | Owner | Cancellation |
| --- | --- | --- | --- | --- | --- |
| Projected state | `CatalogProjection` | `stateConsumptionTask` | Projection stream, newest published state | ViewModel | ViewModel deinit cancels iteration; Projection removes its continuation |
| Sidebar selection | ViewModel control intents | `selectionForwardingTask` | `.bufferingNewest(1)` | ViewModel | ViewModel deinit cancels consumer and finishes continuation |
| Catalog mutation | ViewModel add/remove intents | `mutationForwardingTask` | `.unbounded` | ViewModel | ViewModel deinit cancels consumer before finishing continuation |
| Store startup | ViewModel start intent | `catalogStartupTask` | one finite operation | ViewModel and Store startup coalescing | ViewModel deinit cancels its caller; Store preserves its own consistency |

The lanes stay separate because they encode different facts. Obsolete sidebar
input may be discarded; accepted constructive or destructive commands may not.
Combining them would either delay selection behind database work or give
mutations an incorrect dropping policy.

## State Consumption Design

The ViewModel copies Projection, Store, and initial selection into local values
before creating `stateConsumptionTask`. The task strongly retains those
dependencies but captures the ViewModel weakly.

Each loop iteration follows this sequence:

1. Wait for one `CatalogWindowState` without retaining the ViewModel.
2. Upgrade the weak ViewModel reference inside that iteration only.
3. Apply the completed state on MainActor.
4. End the temporary strong-reference scope before awaiting again.

Strongifying before the loop would recreate the lifetime defect. Cancelling the
consumer causes `AsyncStream` iteration to terminate; Projection's existing
termination callback removes the subscriber and stops publication when it is the
last subscriber.

## Mutation Delivery Design

`CatalogMutationIntent` is a private `Sendable` enum containing either an add URL
or typed removal path. Public ViewModel methods synchronously yield an intent and
perform no Store call, filesystem work, diagnostics write, or task creation.

One `mutationForwardingTask` drains an unbounded stream sequentially. It checks
cancellation before each command, then awaits Store and completes existing
signpost/error diagnostics before requesting the next command. The task captures
Store, diagnostics, and the stream, not the ViewModel.

The buffer is intentionally unbounded. `AsyncStream` has no producer
backpressure, and Otos has no implemented rejection UI. A bounded policy would
eventually discard an accepted user command. Payloads are small path values
generated at human interaction speed. A future busy/rejection feature requires
its own implemented product requirement rather than silent dropping now.

Cancellation is cooperative. If Store already began a mutation, it may finish
its transaction and in-memory update. Cancellation prevents another buffered
command from beginning; it does not interrupt SQLite or invent rollback behavior.

## Concurrency And Actor Ownership

- ViewModel and SwiftUI-visible state remain MainActor isolated.
- Stream submission and command switching are trivial MainActor work.
- Store actor performs path validation, database work, in-memory mutation, scan
  enqueueing, and catalog notification.
- Projection actor continues all sorting, filtering, scope derivation, and
  publication outside MainActor.
- UI serialization does not replace Store reentrancy safety. Store remains
  correct for direct tests and internal callers that may enter concurrently.
- Store change events are lossless and lightweight. Ordinary events invalidate;
  root-removal events additionally carry only the typed path needed to reset
  Projection before same-path replacement can hide the removal in a snapshot.

## Alternatives

### Weak State Capture With Per-Action Tasks

Pros: smallest patch; fixes indefinite ViewModel retention.

Cons: add/remove tasks remain unowned and unordered.

Failure mode: rapid actions overlap across Store suspension points.

### Retained Task Registry

Pros: each mutation can be canceled individually.

Cons: task IDs, completion cleanup, and concurrency policy add bookkeeping while
allowing completion order to diverge from user order.

Failure mode: stale handles or registry cleanup create a second lifecycle bug.

### One Stream For Every User Intent

Pros: one enum, continuation, and consumer.

Cons: selection and mutation need incompatible buffering and latency semantics.

Failure mode: selection queues behind disk work or mutations are dropped.

### Selected: Separate State, Selection, And Mutation Lanes

Pros: precise semantics, explicit ownership, serial mutations, responsive
selection, and no task-per-click fan-out.

Cons: one additional stream, continuation, and owned task.

Failure mode: a blocked mutation can accumulate small commands. Lossless
buffering is preferred until an explicit rejection surface exists.

## Interfaces And Retirement

Public View and ViewModel method signatures do not change.

Private changes:

- add `CatalogMutationIntent`
- add mutation stream and continuation
- add `mutationForwardingTask`
- rename generic task properties to `stateConsumptionTask`,
  `catalogStartupTask`, and `selectionForwardingTask`
- replace per-action tasks with synchronous stream submission
- replace `AsyncStream<Void>` Store invalidation with
  `AsyncStream<CatalogStoreChange>` and preserve successful root-removal events

Retire from current source and documentation:

- `stateTask`, `startTask`, and `selectionTask` property names
- per-action `Task` creation in add/remove methods
- claims that cancellation is reachable merely because a task handle is stored
- generic intent wording that does not distinguish lossy selection from lossless
  mutation delivery

## Instrumentation And Privacy

Existing add/remove signposts, Logger events, and JSONL error records remain.
Intent submission adds no JSONL task and retains no catalog state. Paths may
remain in developer diagnostics under the current policy. No original media is
modified; removal still deletes only Otos catalog rows.

## Tests And Verification

- ViewModel lifetime: active state subscription does not prevent deallocation;
  no later Projection build occurs after subscription termination.
- Mutation order: immediate add/remove/add produces the ordered final catalog.
- Failure continuation: a duplicate add does not terminate later delivery.
- Cancellation: owner termination drops the queued command while allowing the
  already-dequeued command either to complete safely or observe cancellation.
- Coalesced replacement: remove and same-path re-add inside one cadence resets
  selected scope through Store's typed removal event.
- Regression: startup idempotence, state delivery, selection coalescing,
  normalization without feedback, Projection lifecycle, and Store race tests.
- Source hygiene: public add/remove methods create no task or direct Store call;
  retired generic task property names are absent.
- Full local gate: `script/verify.sh` under the configured Xcode 27 beta.

## Code-Smell Review

Addressed:

- self-retaining long-lived task
- unreachable deinit cancellation
- task-per-intent fan-out
- implicit mutation ordering
- ambiguous task names

Accepted:

- unbounded mutation buffering, because lossless commands currently have no
  rejection UI and are produced at human speed
- concrete Store/Projection dependencies, because no real substitution boundary
  requires protocols

## Non-Goals

- broader Store or Projection redesign beyond the typed removal invalidation
- schema or scan behavior changes
- mutation progress, busy state, rejection UI, or catalog alerts
- manual scans, FSEvents, sandboxing, bookmarks, or durable scan identity
- metadata, thumbnails, preview, import, export, or audio behavior
