# Plan 0058: Materialization Scheduler Recovery

## Status

Active.

## Purpose

Restore Otos materialization to a genuinely bounded, priority-aware scheduler
after PR #122 introduced unbounded enrichment submission and actor-mailbox
starvation. Keep the correct architectural decision from PR #122—one shared
owner for every deliberate physical transfer—but replace its execution model
with a coordinator-owned supervisor, bounded producer handoff, accurate
effective priority, complete task lifecycle ownership, and diagnostics that
measure application delay separately from provider delay.

This is a blank-slate correction, not a compatibility layer around the current
implementation. Replace incorrect boundaries instead of retaining forwarding
types, duplicate queues, or transitional production paths.

Tests remain permitted to use configured production catalog and library data.
This increment must not introduce a test-only catalog location, a production-data
guard, a safe-test mode, or an XCTest materialization disable switch.

## Incident And Root Cause

### Observed failure

In the live production app on 2026-07-14, loupe opened
`2026/07/20260714_185108.heif` while eager OneDrive enrichment was active:

- Background demand queued and dispatched the asset at 23:01:38.
- Loupe requested it at 23:02:07 and joined the physical transfer at 23:02:10.
- `FileMaterialization` re-requested the provider 114 times and timed out after
  120,276 ms at 23:03:38.
- The coordinator did not process and log that completion until approximately
  67 seconds later, at 23:04:45.
- The file remained dataless with zero allocated blocks.
- Otos consumed approximately 192% CPU.
- At least 919 background requests entered the coordinator in roughly 30 seconds.

The OneDrive provider failed to complete the physical request, but provider
latency does not explain the additional 67-second coordinator delay. That delay
was application scheduler starvation.

### Regression introduced by PR #122

Before PR #122, `EnrichmentCoordinator` admitted only work that fit its bounded
download pool. It had the wrong ownership split—preview and enrichment were
separate deliberate materialization owners—but producer backpressure existed.

PR #122 correctly introduced one `MaterializationCoordinator`, but changed
`dequeueDownloadWork()` to drain every eligible `datalessPending` item in one
pass. `EnrichmentCoordinator.runLoop()` then creates one child task for every
returned item, and every child concurrently calls the coordinator actor.

The coordinator compounds that flood by running `schedule()` synchronously from
every enqueue. Each scheduling pass scans the pending array and repeatedly
reconstructs in-flight accounting. A large library therefore creates:

```text
all discovered dataless assets
        │
        ├─ one Swift task per asset
        │
        ├─ one actor call per asset
        │
        └─ one continuation per asset
                  │
                  v
      MaterializationCoordinator mailbox
                  │
                  ├─ append to growing pending array
                  ├─ rescan pending array on every enqueue
                  └─ completion and interactive calls wait behind the flood
```

This is not the coordinator-owned worker/supervisor design required by the PR
plan. It is unbounded caller-driven push into a serialized actor.

### Additional correctness defects found

1. **An interactive in-flight join does not become active interactive demand.**
   The coordinator adds the interactive continuation to an in-flight background
   entry but leaves the entry classified as background. Its scheduling guard
   checks only the original request priority, so new lower-priority work may
   start while loupe is waiting. This violates APP-023 and ENR-008.

2. **Materialization shutdown does not drain owned operations.** It removes
   in-flight state, cancels tasks, resumes waiters, and returns without awaiting
   physical task completion or proving that every Store suppression window
   closed.

3. **Enrichment shutdown does not await its supervisor task group.** It cancels
   the supervisor and clears bookkeeping while worker completions may still be
   returning.

4. **Claims can outlive their lease while buried in the queue.** Store claims
   last five minutes. A large same-root queue can wait much longer, and queued
   claims are not periodically refreshed as a batch.

5. **Ordinary background materialization failure can churn.** A failed
   non-device request releases its claim immediately. Store can reclaim the same
   still-dataless asset and begin another 120-second attempt without a deliberate
   retry delay.

6. **Admission diagnostics compare incomplete state.** Snapshot equality ignores
   rejection counts, admitted counts, and pending counts, while per-background-
   asset queue notices can themselves create substantial log volume.

7. **The code and current-truth documentation contradict the requirements.** ADR
   0009 and the `EnrichmentCoordinator` file guide still describe two enrichment/
   download pools even though requirements describe a separate shared
   materialization owner.

8. **Tests cover local scheduling rules but not survivability.** Existing tests
   use a handful of requests and do not exercise producer floods, actor-entry
   delay, completion delivery delay, bounded task counts, joined effective
   priority, claim refresh, retry pacing, or full shutdown drain.

## Requirements And Fixed Product Decisions

Preserve these current product decisions unless runtime evidence gathered in
this increment proves a safety limit invalid:

- `CatalogStore` remains catalog truth and the owner of enrichment claims and
  known-materialization suppression state.
- `FileMaterialization` remains the provider-agnostic one-URL mechanism. It
  reads `SF_DATALESS` with `lstat`, requests through
  `FileManager.startDownloadingUbiquitousItem(at:)`, polls every 250 ms,
  re-requests once per second, and times out after 120 seconds.
- `MaterializationCoordinator` remains the only production owner of deliberate
  physical materialization scheduling.
- Priority order is interactive, then device, then background.
- Loupe and compare both use interactive priority.
- Pending or effectively active interactive demand prevents new device and
  background dispatch.
- Device staging retains still-before-video, newest-capture-date, then stable
  path ordering before submission.
- Background work uses at most 15 of 16 global transfer slots and at most one
  active transfer per library root.
- All priorities share the 2 GiB logical byte budget and the cap of two videos
  at least 256 MiB.
- Unknown source size counts as 4 MiB.
- An oversized request may run alone.
- Active provider transfers are not cancelled or claimed to be reprioritized
  when interactive demand arrives.
- Same-ID demand creates one physical operation and one Store suppression
  window. Queued lower-priority demand promotes; in-flight lower-priority demand
  is joined without a duplicate request.
- Preview decode remains in `PreviewImageLoader`; enrichment and thumbnail work
  remain in `EnrichmentCoordinator` / `MediaEnricher`.
- The materialization queue remains process-local. Do not add schema, durable
  status, generated asset identity, or persisted request IDs.
- Otos continues eagerly materializing all cataloged media for enrichment and
  accepts the resulting local disk growth.
- No new third-party dependency is permitted.

## Target Separation Of Concerns

```text
PreviewImageLoader ── interactive request ─┐
                                           │
EnrichmentCoordinator ─ background demand ─┼─> MaterializationCoordinator
                                           │         │
Device staging ─────── device request ─────┘         ├─ priority and coalescing
                                                     ├─ physical admission
                                                     ├─ operation/shutdown lifetime
                                                     ├─ Store suppression pairing
                                                     └─ one-URL executor
                                                              │
                                          ┌───────────────────┴──────────────────┐
                                          v                                      v
                               FileMaterialization                  DeviceStagingRegistry
```

### `CatalogStore`

Owns:

- Catalog truth and Store queries.
- Cursorless enrichment claims and five-minute claim leases.
- Known-materialization event suppression state.
- Source-signature validation and batched enrichment writes.

Must not own:

- Transfer queues, priorities, or provider concurrency.
- Preview decode or enrichment worker scheduling.

### `EnrichmentCoordinator`

Owns:

- Which catalog assets need enrichment.
- A bounded window of claimed work.
- Eight local byte-reading enrichment workers and their byte/video admission.
- A bounded handoff of dataless/device demand to the shared materializer.
- Claim state transitions, batch refresh/release, retry timing, the `freshly`
  handoff, and batched result application.

Must not own:

- Physical provider-transfer admission.
- Materialization priority arbitration across preview, device, and background.
- Direct `FileMaterialization.materialize` calls.

### `MaterializationCoordinator`

Owns:

- Pending interactive, device, and background demand.
- Per-ID waiter coalescing and effective priority.
- Stable FIFO selection within priority.
- Global, byte, video, reserve, and per-root physical admission.
- Physical operation task lifetime and completion delivery.
- Exactly one Store suppression begin/end pair per physical operation.
- Aggregate admission and operation diagnostics.
- Draining shutdown.

Must not own:

- Catalog candidate discovery or enrichment claims.
- Viewport facts, capture-date policy, or thumbnail/decode behavior.
- Background retry policy after a completed provider attempt.

### `FileMaterialization`

Owns only one URL's detection, request, polling, re-request count, cancellation,
timeout, and final `MaterializationResult`. It must not gain catalog knowledge,
priority queues, worker limits, root fairness, or suppression calls.

### `PreviewImageLoader`

Owns full-size loupe/compare decoding, its decode cache, per-ID decode
coalescing, and immediate status rechecks. It submits interactive materialization
demand but does not schedule provider work.

### `DeviceStagingRegistry`

Owns resolving a staging URL to the active camera session and performing the
device download, including insufficient-space outcomes. It remains an executor
behind the shared coordinator rather than a separate scheduler.

## Materialization Coordinator Design

### 1. One owned supervisor and coalesced wakeup

Create one process-lifetime supervisor task owned by the actor. Back it with an
`AsyncStream<Void>` using `.bufferingNewest(1)` or an equivalent testable
coalescing wake primitive.

Public `materialize(_:)` calls perform only bounded actor bookkeeping:

1. Reject if shutdown has begun.
2. Allocate a process-local waiter token.
3. Join an existing in-flight entry, join/promote a pending entry, or append one
   new pending identity.
4. Signal the supervisor.
5. Suspend for the shared result.

The public call must not run a scheduling pass. Multiple enqueue/completion/
cancellation events may collapse into one wake because the supervisor always
examines current actor state.

The supervisor owns each scheduling pass:

1. Remove pending entries with no waiters.
2. Determine the highest eligible priority from pending and effective in-flight
   demand.
3. Search that priority queue for admissible candidates without allowing a
   blocked head to starve later independent work.
4. Update in-flight accounting before launching child operations.
5. Launch only admitted operations.
6. Publish one completed-pass diagnostic snapshot.
7. Sleep for the next wake rather than polling.

### 2. Separate waiter demand from physical transfer facts

Use one entry per `MediaAssetID`. A waiter records its requested priority; an
entry's effective priority is the maximum priority among its current waiters.

Suggested internal shapes:

```swift
private struct Waiter {
    let token: UInt64
    let priority: Priority
    let continuation: CheckedContinuation<MaterializationResult, Never>
}

private struct PendingEntry {
    let request: Request
    var effectivePriority: Priority
    var waiters: [UInt64: Waiter]
    let sequence: UInt64
}

private struct InFlightEntry {
    let request: Request
    var effectivePriority: Priority
    var waiters: [UInt64: Waiter]
    let estimatedBytes: Int64
    let dispatchedAt: ContinuousClock.Instant
    var task: Task<Void, Never>
    var suppressionOpened: Bool
}
```

The physical request retains the facts used at dispatch. Effective priority is
demand state and may change while the transfer is active.

Required join behavior:

1. Background transfer is active.
2. Loupe requests the same ID at interactive priority.
3. The waiter joins the existing entry.
4. Effective priority becomes interactive immediately.
5. No new device/background work dispatches.
6. Cancelling only the loupe waiter does not cancel the transfer needed by
   enrichment.
7. Effective priority falls to the maximum remaining waiter priority.
8. Lower-priority dispatch may resume only when no interactive waiter remains
   pending or in flight.

### 3. Three stable FIFO queues plus one identity index

Keep explicit process-local queues:

```swift
private var pendingByID: [MediaAssetID: PendingEntry]
private var interactiveQueue: [MediaAssetID]
private var deviceQueue: [MediaAssetID]
private var backgroundQueue: [MediaAssetID]
```

Ordinary arrays are sufficient because producer handoff is bounded; do not add a
heap, linked list package, or third-party ordered collection before measurement.

Promotion removes the identity from its old queue and appends it to the promoted
queue without creating a second physical entry. FIFO is stable within a priority
class. Device ordering is decided before submission; the shared coordinator does
not learn capture-date policy.

### 4. Incremental in-flight accounting

Maintain these counters directly as operations dispatch and complete:

- Total physical count.
- Estimated physical bytes.
- Large-video count.
- Background count per `LibraryRootPath`.
- Effective interactive waiter count or an equivalent directly maintained fact.

Do not rebuild these values by walking the in-flight dictionary once per pending
candidate.

`MaterializationAdmissionPolicy` remains a pure, nonisolated value type. It
accepts one candidate and one already-computed snapshot and returns one rejection
reason or admission.

### 5. Physical operation and suppression lifecycle

One helper owns the complete physical operation:

1. Mark the operation in flight and account for it.
2. Call `CatalogStore.beginKnownMaterialization(for:)` exactly once.
3. Run the injected executor.
4. Call `CatalogStore.endKnownMaterialization(for:success:)` exactly once.
5. Return one typed completion to the coordinator.
6. Remove in-flight accounting.
7. Resume every remaining waiter with the same result.
8. Wake scheduling.

Cancellation, timeout, provider rejection, executor failure, and shutdown must
all pass through the same cleanup path. A queued entry that loses all waiters
before dispatch never opens suppression.

Do not add a generated durable request ID. Prefer prohibiting a new same-ID
physical operation until the prior operation has fully exited. If tests prove
that cancellation plus immediate re-enqueue can deliver an old completion to a
new entry, add only a process-local operation generation for stale-completion
rejection.

### 6. Cancellation semantics

- Cancelling one waiter resumes only that waiter with `.cancelled`.
- A queued entry with no remaining waiters is removed.
- An in-flight operation continues when any waiter still benefits.
- Ordinary waiter cancellation does not cancel an active provider request.
- Coordinator shutdown cancels owned operation tasks because the process owner is
  ending, then awaits their cleanup.
- Recompute effective priority whenever a waiter joins or leaves.

### 7. Two-phase draining shutdown

`MaterializationCoordinator.shutdown()` must:

1. Atomically stop accepting requests and stop new admission.
2. Cancel and resume queued waiters.
3. Cancel every owned physical-operation task.
4. Await every operation task's termination.
5. Close every opened suppression window, using failure unless success was
   already established.
6. Resume any still-owned waiter exactly once.
7. Clear pending queues, in-flight entries, counters, and diagnostic state.
8. Assert through test-visible state that no bookkeeping remains.
9. Return only after the drain is complete.

Do not remove in-flight bookkeeping before the operation cleanup path has enough
state to close suppression safely.

## Bounded Enrichment Handoff

### 1. Replace unbounded dequeue

Replace `dequeueDownloadWork()` with a name that describes the new boundary,
such as `dequeueMaterializationSubmissions()`.

It returns only work that fits the enrichment-originated handoff window. It must
never drain all `datalessPending` entries.

Introduce a small testable policy:

```swift
nonisolated struct EnrichmentMaterializationHandoffPolicy: Sendable {
    let globalOutstandingLimit: Int
    let backgroundOutstandingPerRoot: Int
}
```

Initial production defaults:

- At most 16 enrichment-originated materialization requests outstanding globally.
- At most two background enrichment requests outstanding per root: one may be
  physically active while one provides look-ahead.

These limits govern producer handoff and claim/task retention, not physical
provider admission. `MaterializationCoordinator` remains the only physical
admission owner.

### 2. Bound the complete claimed-work window

The coordinator must not merely cap submitted requests while continuing to
discover an unlimited `datalessPending` backlog. Bound the full process-local
claim window containing:

- `claimedEnrichQueue`
- `inFlightEnrich`
- `datalessPending`
- `submittedMaterializations`
- `pendingApplyIDs`

Use the existing claim batch size of 32 as the initial discovery window unless
focused runtime measurement supports a different value. Store remains the
durable/derived backlog; the actor-local queue is only a bounded working set.

When the window is full, do not claim additional fallback candidates. Completion
or release wakes the supervisor and opens capacity.

### 3. Explicit claim state transitions

Represent one current process-local state for every claimed identity:

```swift
enum ClaimedWorkState {
    case queuedEnrichment
    case enriching
    case awaitingMaterialization
    case materializing
    case awaitingApply
}
```

This can be an internal dictionary or an equivalent invariant-preserving owner;
it is not persisted. Centralize transitions so an ID cannot silently appear in
multiple sets with ambiguous claim ownership.

The normal path is:

```text
queued enrichment
    → enriching
        → awaiting materialization
            → materializing
                → freshly / queued enrichment
                    → enriching
                        → awaiting apply
                            → Store apply and claim release
```

Every failure, cancellation, stale result, source detach, and shutdown path must
either move the state forward or release its claim exactly once.

### 4. Batch claim refresh

The Store claim lease is five minutes. Refresh all claimed identities awaiting or
performing materialization in one batch before they approach expiry. Use an
injectable two-minute refresh cadence initially.

Do not create one timer per asset. Keep one owned refresh task or fold the next
refresh deadline into the enrichment supervisor wakeup mechanism.

### 5. Background retry pacing

Keep retry state process-local and owned by `EnrichmentCoordinator` because the
coordinator owns why background work should be attempted again.

Required behavior:

- Interactive callers receive the actual result of their current attempt.
- Device staging retains distinct insufficient-space behavior and its current
  retryability.
- Failed background enrichment materialization remains eventually eligible but
  cannot be reclaimed in an immediate tight loop.
- Reset retry state when materialization succeeds, the source signature changes,
  or the process restarts.

Use an injectable exponential policy. Initial values to verify at runtime:

```text
failure 1: 15 seconds
failure 2: 1 minute
failure 3: 5 minutes
later:    15-minute cap
```

One retry wake task is sufficient; schedule it for the earliest pending deadline.

### 6. Enrichment shutdown

`EnrichmentCoordinator.shutdown()` must:

1. Stop accepting viewport/device work.
2. Cancel Store-change, retry, claim-refresh, and apply-timer producers.
3. Cancel the supervisor.
4. Await the supervisor and its child task group.
5. Apply or deliberately discard the pending result batch according to the
   existing shutdown contract.
6. Release every still-owned Store claim exactly once.
7. Clear bounded working state.
8. Return only after worker completion cannot re-enter cleared state.

## Preview And Device Consumers

### Preview

Keep `PreviewImageLoader` as the only full-size decode owner. Preserve its cache,
target-long-edge validation, Image I/O and QuickLook paths, per-ID decode
coalescing, and immediate status recheck before reading bytes.

Focused requirements:

- `.dataless` submits one `.interactive` request.
- A successful materialization result is followed by a live status recheck.
- A failed attempt returns `.downloading` without reading bytes.
- `.unknown` returns `.unavailable` without submitting demand.
- ViewModel expected-ID checks remain the sole stale-pane paint guard.
- The 500 ms ViewModel retry may join an existing operation but must not create a
  duplicate physical request.
- Cancelling a pane request removes only its waiter and promptly lowers effective
  priority when no interactive demand remains.

### Device staging

Keep device candidate order in `EnrichmentCoordinator` before submission. Submit
`.device` through the same coordinator. Keep `DeviceStagingRegistry` behind the
live executor and preserve insufficient-local-space outcomes and retry behavior.

Source quiesce/drain must account for both bounded enrichment state and shared
materialization state under the root. Add a coordinator query or drain primitive
if enrichment-local `submittedMaterializations` cannot prove the shared physical
operation has exited; do not inspect coordinator internals from the ViewModel.

## Composition And Lifetime

Production construction remains explicit in `CatalogWindowViewModel`; do not add
an ambient singleton.

Construction order:

1. `CatalogStore`
2. `DeviceStagingRegistry`
3. one `MaterializationCoordinator` with the staging-first/live-file executor
4. `EnrichmentCoordinator` injected with that instance
5. production `PreviewImageLoader` injected with that same instance

If the new coordinator requires explicit `start()`, start it before enrichment.

Shutdown order:

1. Stop pane requests and other interactive producers.
2. Stop device/enrichment submissions.
3. Await `EnrichmentCoordinator.shutdown()`.
4. Await `MaterializationCoordinator.shutdown()`.
5. Release or shut down Store ownership.

An asynchronous `Task` launched from `deinit` remains only a defensive fallback.
Where the application lifecycle provides an explicit async shutdown path, that
path must own and await the drain.

Tests must retain seams for a fake `PreviewLoading`, a fake
`MaterializationRequesting`, a controlled executor, an in-memory Store, and a
prebuilt enrichment coordinator.

## Diagnostics

### Per-operation fields

Use fixed machine-greppable fields:

```text
op=materialization.request
phase=queued|promoted|joinedInFlight|dispatched|completed|cancelled|failed
priority=
effectivePriority=
rootPath=
relativePath=
queueWaitMs=
providerMs=
completionDeliveryMs=
totalMs=
inFlight=
inFlightBytes=
sameRootBackground=
rerequestCount=
outcome=
```

Definitions:

- `queueWaitMs`: first request enqueue to physical dispatch.
- `providerMs`: executor start to executor result.
- `completionDeliveryMs`: executor result to coordinator completion processing.
- `totalMs`: individual caller request to waiter completion.

The incident must become attributable as provider delay plus coordinator delay,
not one ambiguous duration.

Keep interactive lifecycle, provider timeout/failure, promotion/join, and final
completion at notice level. Routine background queue entries belong at debug.
Do not log polling or every identical re-request at notice; preserve final count.

### Aggregate admission state

After each supervisor scheduling pass, build one pure snapshot containing:

- Selected priority.
- Rejection count by reason.
- Admitted count.
- Pending count by priority.
- In-flight count and bytes.
- Large-video count.
- Relevant per-root background counts.
- Effective interactive pending/in-flight demand.

Snapshot equality must compare all fields that make the scheduler state
meaningfully different. Emit:

- One blocked record per reason when the complete snapshot changes.
- One aggregate dispatched record per pass with admitted work.
- One unblocked transition when a previously blocked state becomes dispatchable
  or drains.

Use an injected diagnostic sink or pure builder for tests. Never test unified-log
strings by reading Swift source.

## Documentation Corrections

Update current truth in the implementation PR:

- `docs/requirements.md`
  - ARC-034: sole physical owner plus bounded deliberate submission.
  - ARC-036: exactly paired suppression and draining shutdown.
  - APP-023: effective interactive demand includes an in-flight join.
  - ENR-008: background producer handoff is bounded separately from physical
    admission.
  - ENR-009: enrichment owns a bounded claim/handoff window, not a download pool.
  - ENR-011: device staging submits to shared device priority, not an "existing
    download pool."
- ADR 0009: remove the stale 4-enrich + 4-download and two-pool summary; state the
  bounded handoff, shared physical owner, claim refresh, and retry ownership.
- ADR 0013: replace "existing download pool" with device-priority submission to
  the shared scheduler.
- ADR 0016: explain that an interactive waiter raises effective priority even
  when joining an already-active background physical transfer.
- `docs/architecture.md`: show the bounded enrichment working set before the
  shared materialization scheduler.
- `AGENTS.md`: replace the stale statement that `EnrichmentCoordinator` is the
  materializing byte-reading owner.
- `docs/research/2026-07-14-interactive-materialization-priority.md`: add the
  second runtime incident and before/after measurements without rewriting the
  original evidence.

Architecture-boundary file guides and comments must describe resulting ownership,
backpressure, effective priority, cancellation, claim, suppression, and shutdown
mechanics. Do not narrate PR history in production source comments.

Delete this plan after the completed implementation has merged.

## Test Plan

### Materialization coordinator

Use controlled continuations, an injectable monotonic clock, and a diagnostic
recorder. Cover:

1. Interactive dispatch before queued device/background.
2. Device dispatch before background when interactive is absent.
3. No lower-priority dispatch while interactive is pending.
4. No lower-priority dispatch while an interactive waiter has joined an active
   background transfer.
5. Cancelling that interactive waiter lowers effective priority without
   cancelling the useful background transfer.
6. Background one-active-per-root.
7. Different-root background concurrency when capacity exists.
8. One global slot reserved from background.
9. Interactive use of the reserved slot and remaining global capacity.
10. Same-ID requests share one executor call, result, and suppression window.
11. Queued background promotion produces no duplicate operation.
12. In-flight join produces no duplicate provider request.
13. Cancelling one waiter preserves work required by another.
14. Last queued waiter cancellation removes the physical entry without opening
    suppression.
15. Byte budget, unknown-size estimate, large-video cap, and oversized-solo
    exception.
16. A blocked large candidate does not starve a later admissible candidate.
17. Enqueue does not run a full scheduling pass inline.
18. Ten thousand background enqueue attempts cannot starve an interactive actor
    call when producer handoff is bounded.
19. Physical completion is processed promptly during continuous background
    production.
20. Completion from a cancelled/old operation cannot finish a newer same-ID
    operation.
21. Begin/end suppression occur exactly once for success, failure, timeout, and
    shutdown cancellation.
22. Shutdown awaits operation cleanup and leaves zero waiters, tasks, queue
    entries, bytes, root counts, and open suppression ownership.
23. Admission snapshots deduplicate only equal complete states and emit one
    unblocked transition.

### Enrichment coordinator

Retain current enrichment correctness tests and add:

1. A 25,000-item dataless workload never exceeds the configured outstanding
   materialization handoff or claim window.
2. `dequeueMaterializationSubmissions()` returns only available handoff capacity.
3. Same-root handoff retains at most active-plus-look-ahead demand.
4. Completion opens one handoff slot and wakes exactly the next eligible item.
5. Local materialized enrichment remains capped at eight workers and respects
   byte/video admission.
6. Blocked video work does not starve an admissible still.
7. Claims move through one explicit process-local state.
8. Queued/materializing claims refresh in one batch before lease expiry.
9. Successful materialization releases the old claim and re-enters through
   `freshly`.
10. Background timeout/provider failure uses process-local backoff rather than
    immediate reclaim.
11. Source signature change or success clears retry state.
12. Device insufficient-space behavior remains retryable.
13. Device still/video/date/path ordering remains unchanged.
14. Root drain observes all work under the root.
15. Shutdown awaits workers and releases queued/in-flight claims exactly once.
16. One hundred unchanged blocked wakes produce one blocked diagnostic and one
    later transition/unblocked record.

### Preview and composition

Cover:

- Materialized JPEG skips materialization and decodes.
- Dataless preview submits correct interactive facts.
- Successful materialization rechecks status before bytes.
- Failure/timeout returns `.downloading` without reading.
- Unknown status returns `.unavailable` without demand.
- Decode coalescing and long-edge cache behavior remain unchanged.
- Loupe retry joins one physical request.
- Rapid pane navigation cannot paint a stale identity.
- Cancelling the last interactive pane promptly removes interactive demand.
- Production composition injects one shared coordinator into both consumers.
- Shutdown order is enrichment, materialization, then Store lifecycle end.

Do not add source-text substring tests.

## Load And Runtime Verification

### Deterministic scheduler load

With a fake provider and at least 25,000 dataless candidates:

1. Hold the first same-root background transfer.
2. Produce at least 10,000 scheduler wakes.
3. Confirm enrichment-originated outstanding tasks and claims stay within their
   configured bounds.
4. Submit interactive demand during continuous background production.
5. Measure actor-entry, queue-wait, dispatch, and completion-delivery latency.
6. Complete a physical request while background production continues.
7. Confirm completion processing remains prompt.
8. Confirm CPU/work scales with the bounded working set rather than catalog size.
9. Confirm no candidate-times-wake diagnostic growth.

Set explicit test thresholds from controlled local measurements. Do not use a
timing threshold so tight that normal CI scheduling causes flakiness; the primary
assertions are bounded counts and eventual ordering, with latency used to catch
multi-second starvation.

### OneDrive acceptance

Run the app against the existing configured OneDrive library without requiring
the user to operate it:

1. Start eager enrichment.
2. Confirm at most one active background transfer per root.
3. Enter loupe on an unsubmitted dataless asset; confirm interactive dispatch
   precedes queued background.
4. Enter loupe on a queued background asset; confirm priority promotion.
5. Enter loupe on an already-active background asset; confirm in-flight join and
   effective interactive demand.
6. Confirm no lower-priority dispatch until all interactive waiters drain.
7. Navigate rapidly across dataless loupe assets; confirm stale images never
   paint.
8. Exit loupe; confirm background dispatch resumes.
9. Allow a provider timeout if reproducible; confirm coordinator completion
   delivery remains prompt after the executor returns.
10. Confirm outstanding background tasks and claims remain bounded for the full
    run.

Provider-side success is not required. Application-side success means:

- Interactive demand reaches the coordinator promptly.
- Otos submits interactive work before all not-yet-started lower-priority work.
- No new lower-priority provider request starts during interactive demand.
- At most one same-root background request was already competing.
- Provider duration and application completion delay are measured separately.
- Actor completion delivery does not add a second long delay.

Capture `script/logs.sh` artifacts, worst-span summaries, CPU, queue/task counts,
provider duration, completion-delivery delay, re-request count, promotion/join,
and final outcomes. Run Instruments only if the corrected implementation still
shows actor contention, high CPU, main-thread delay, or decode regression.

## Automated Verification

Run the repository's full required gate with the configured Xcode 27 beta:

```bash
script/verify.sh
```

Success requires:

- Requirements-authority checks pass.
- SwiftLint passes under the existing warning policy.
- Swift 6 strict-concurrency build succeeds.
- All tests pass.
- No source-text assertion test is introduced.
- No third-party dependency is added.
- No test/production-data isolation behavior changes.

## Review Checklist

Review the final diff specifically for:

- A second direct production call to `FileMaterialization.materialize`.
- Any materialization queue outside `MaterializationCoordinator`.
- Unbounded task creation or continuations proportional to library size.
- Scheduling work performed inline by every enqueue.
- O(pending) or O(in-flight) reconstruction inside a per-candidate loop.
- Lost, double-resumed, or indefinitely retained waiters.
- Interactive joins that fail to raise effective priority.
- Lower-priority dispatch during effective interactive demand.
- Suppression begin/end imbalance.
- Shutdown returning before child operation cleanup.
- Claims with ambiguous owner state, expired leases, or double release.
- Immediate background timeout/reclaim churn.
- MainActor filesystem, provider, metadata, thumbnail, or preview-decode work.
- Per-candidate admission logging storms.
- Stale comments or ADR text describing an enrichment-owned download pool.
- Any change to production-data test access.

Perform a cold code review using both required lenses: implementation fidelity
against this plan and blank-slate architecture. A confirmed correctness,
lifecycle, priority, or boundedness failure blocks merge.

## Delivery

Implement on a dedicated conventional refactor/fix branch and worktree. Before
opening the implementation PR, inspect the last five PRs for unresolved review
threads and handle every in-scope comment through the normal workflow.

The increment is complete only after:

- Code, requirements, ADRs, architecture, comments, and research describe the
  same current truth.
- Focused deterministic load tests pass.
- `script/verify.sh` passes under Xcode 27 beta.
- OneDrive runtime evidence is captured and summarized.
- Cold review finds no blocking correctness or architecture issue.
- The implementation PR is merged to `main`.
- This completed plan file is deleted.
- Increment-owned branch, worktree, and stashes are cleaned up.
- The next-start tree is clean.
- One complete final DoD report is posted on the PR and sent to the user verbatim.

## Explicitly Rejected Fixes

- **Revert PR #122 as the final architecture.** It would restore producer
  backpressure but also restore separate preview/enrichment materialization
  owners and the original priority failure.
- **Pause eager enrichment only while loupe mode is visible.** That can be a
  later product decision if provider evidence requires it, but it does not repair
  actor starvation, completion delay, shutdown, or claim bugs.
- **A second preview-specific priority queue.** One physical owner is required
  for DRY coalescing, suppression, and provider admission.
- **Swift task priority as provider priority.** It cannot reorder OneDrive or
  replace explicit application scheduling.
- **One task per catalog asset.** Tasks, continuations, claims, and actor messages
  must remain bounded by the working-set policies.
- **A durable materialization queue or status column.** Materialization status is
  transient filesystem truth; Store already derives enrichment need.
- **Catalog queries inside `MaterializationCoordinator`.** Candidate discovery
  and claim ownership belong to enrichment.
- **Provider cancellation/reprioritization claims.** The current File Manager API
  exposes no reliable transfer handle or documented ordering guarantee.
- **A new dependency or generalized queue framework.** Simple bounded arrays,
  dictionaries, one supervisor, and owned child tasks are sufficient.
- **Production-data test isolation.** Explicitly out of scope.

## Definition Of Green

The architecture is green only when all of the following are true:

- One coordinator owns every physical materialization operation.
- Enrichment submission, tasks, continuations, claims, and working queues are
  provably bounded independently of library size.
- Enqueue and completion processing stay responsive during a full-library eager
  sweep.
- An interactive waiter joined to background work counts as active interactive
  demand.
- No lower-priority operation dispatches while interactive demand is pending or
  effectively active.
- One physical request and one suppression window exist per asset.
- Cancellation and shutdown cannot lose waiters or leave suppression open.
- Enrichment claims remain valid or are released exactly once.
- Provider failures retry with deliberate pacing.
- Diagnostics distinguish queue, provider, and completion-delivery latency.
- Documentation contains no obsolete enrichment-owned download-pool model.
- Full automated and live OneDrive verification pass on the application side,
  even when the provider itself remains slow or times out.
