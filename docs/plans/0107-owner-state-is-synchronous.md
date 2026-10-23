# Plan 0107: Owner state changes synchronously, and requests are never lost

Opened 2026-10-05. Research and evidence:
`docs/research/2026-10-05-owner-state-reentrancy-and-ordering.md`. Read it first;
this plan cites its defect classes (C1–C6) by name.

This plan is written to be implemented end to end by someone new to the codebase.
Every increment states:

- **Goal**: why the increment exists;
- **Read first**: files to read before editing;
- **Steps**: what to change, in order;
- **Tests**: tests to add or keep, by name;
- **Docs**: docs to update;
- **Done when**: acceptance criteria.

The repo-wide rules in `CLAUDE.md` apply to every increment:

- one PR per increment;
- branch from `main` in a fresh worktree;
- `script/check.sh` green;
- CI green;
- merge, then `script/install.sh`;
- one DoD report.

They are not repeated below except where they bite.

## Background in one paragraph

A Swift `actor` is *reentrant*. At every `await` inside an actor method, other
messages to the same actor can run and change its state before the method resumes
(SE-0306). Two owners in Otos were written as if an `await` were an atomic step:

- **`MediaOperationCoordinator`** (import planning and execution) keeps a copy of
  a session across store reads and writes the copy back.
- **`CatalogProjection`** (what the main window shows) cancels a running build to
  start a newer one.

Both also keep "work is needed" in booleans that a finishing operation can clear,
erasing a request made while it ran. Both turn read errors into empty values that
the user sees as facts. The fix is structural:

- state changes only in synchronous code;
- a request is a counter that nothing clears;
- async work reports back as an event that is checked before it is applied.

`MaterializationCoordinator` already works this way; it is the model to copy.

## The rules

ADR 0032 records these in increment 6. Until then, this section is the reference.

1. **State changes are synchronous.** An owner's state is changed only in
   non-`async` code. An async operation:
   - takes the inputs it needs as values;
   - does its awaits without touching owner state;
   - hands its result back as an event.

   The event is applied synchronously, and only after checking it still belongs to
   the identity it was started for (attachment generation, build generation, batch).
   No owner keeps a copy of its state across an `await`.
2. **A request is a revision, never a boolean.**
   - Each request does `requested &+= 1`.
   - Work records `let startedFrom = requested` when it is *taken up*, and sets
     `covered = startedFrom`.
   - When work finishes, the owner starts again if `requested != covered`.
   - Nothing decrements or clears `requested`.
   - Quiescence is `requested == covered` with nothing in flight.
3. **One loop per owner, woken by a doorbell.**
   - The doorbell is `AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))`.
   - Every producer `yield()`s. One task runs `for await _ in stream { pass() }`.
   - Newer work never cancels older work. The older result is checked against the
     identity at completion and dropped if stale.
   - Cancellation is only for teardown, detach and shutdown.
   - A cancelled operation's result is never published.
4. **An error is not a fact.**
   - A failed read publishes nothing: the last published state stands, the request
     stays outstanding (`covered` is not advanced), and the error is logged with
     `errorOperation`.
   - No `catch` or `try?` may substitute `[]`, `0`, `.empty` or `nil` for a value a
     user sees.
   - A value that is genuinely unknown is modelled as optional and shown as unknown.
5. **Intents to an owner travel in one ordered channel.**
   - Commands (must not be dropped, must stay in order) use one
     `AsyncStream<Intent>` with `.unbounded` buffering and one consumer.
   - State-valued intents (only the newest matters) use `.bufferingNewest(1)`.
   - Never one plain `Task { await owner.intent() }` per intent: Swift does not order
     those (SE-0431 excludes implicitly-isolated `Task {}` from its ordering
     guarantee).
6. **Blocking work leaves the actor explicitly.** This repo builds with
   `NonisolatedNonsendingByDefault`. A `nonisolated async` function therefore runs
   **on the caller's actor**, and so does an unannotated stored `async` closure.
   Filesystem walks, planning, decoding and hashing must enter through one of:
   - a `@concurrent` function;
   - `Task.detached`;
   - a task-group child;
   - a dedicated queue, as in `CameraMetadataReader`.

   A comment saying "off the actor" or "off main" must name which.
7. **Interleavings are tested deterministically.** Every `await` in an owner is a
   place where another event can arrive, so each gets a test that delivers an event
   exactly there:
   - for a pure state machine, a sequence of `handle(_:)` calls;
   - for an actor, a seam that parks the async work (e.g.
     `ControlledImportPlanBuilder`, `ProjectionProbe`).

   Tests never use time to create an interleaving, and never wait with a deadline
   (`waitUntil` / `waitForValue` in `OtosTests/AsyncTestSupport.swift` have none, by
   design).

## Conventions you will need (gotchas)

- **New files under `Otos/`.** Every new file there must be added, in sorted
  position, to **both** `membershipExceptions` lists in `Otos.xcodeproj/project.pbxproj`
  (the app-target list near line 88 and the OtosXXH3 list near line 253). The
  `Otos/` folder is shared by three targets; source belongs to OtosKit only.
  Forgetting this fails the build with "cannot find type … in scope".
- **Logging.** `op=`/`phase=` lines go through `OtosLog.<category>.noticeOperation`
  / `errorOperation` / `debugOperation`. A hand-written `.debug("op=…")` fails lint
  (`structured_log_via_helper`). Debug-level lines are not persisted, so use
  `noticeOperation` for anything you will need to read after a failure. SwiftFormat
  removes `self.` inside `os_log` interpolations, so copy an actor property into a
  local before interpolating it.
- **Tests.**
  - Tests may not read source files as text.
  - A test cited by a requirement row must contain an explicit `#expect` after its
    waits, or `script/requirements-authority-check.sh` rejects it.
  - Waits use `waitUntil { … }` / `waitForValue { … }` or an owner's quiescence
    fact, never `Task.sleep` and never a deadline.
- **Requirements.** A behavior change updates its row in `docs/requirements.md`
  in the same PR, citing tests as `OtosTests/File.swift#testName`. Run
  `script/requirements-authority-check.sh` before committing.
- **Lint tools.** `script/check.sh` must see the Brewfile-pinned versions
  (swiftformat 0.62.1, swiftlint 0.65.0). If Homebrew has drifted, put pinned
  release binaries first on `PATH` when running it.
- **Running the check.**
  - Run `script/check.sh` in the background, never `verify.sh`/`test.sh` directly.
  - Read its `op=check.heartbeat … tests=N` lines. `tests=` unchanged for three
    heartbeats means a hang: run `xcrun swift-inspect dump-concurrency <xctest
    pid>` to see which test is parked and on what.
  - Kill the whole process tree, never just the parent.
- **Proving a regression test.** For each fixed defect, temporarily revert the
  fix, run only that test (`xcodebuild test-without-building … -only-testing:
  "OtosTests/Suite/test()"`, parentheses included), see it fail or hang, then
  restore the fix. Record the result in the PR.

## Increment 0 — landed stopgaps (done by the plan author)

PR #442 (`fix/projection-lost-intent`, merged before increment 1 starts) carries
stopgaps for the defects that started this plan. Each has a regression test that
fails or hangs on the old code:

| Fix | Regression test |
| --- | --- |
| Projection: coalesced immediate wake instead of cancel-and-replace; a cancelled pass publishes nothing | `CatalogProjectionTests#newerIntentDuringPublicationNeverCancelsTheRunningBuild` |
| Coordinator: re-read the session after each await (`sessionOwnedByBuild`); a finishing build no longer clears `isDirty` | `MediaOperationCoordinatorAdversarialTests#aPreferenceChangeDuringABuildIsPlannedAfterIt` |
| Coordinator: a destination change held during a run applies at settlement (`reconcileDestination`) | `MediaOperationCoordinatorAdversarialTests#executingDestinationSurvivesLibraryReorder` |
| Undo tests wait for the undo registration, not for the file move | `CatalogWindowViewModelTrashTests#undoPutsItemsBackAndRedoMovesThemAgain`, `CatalogWindowViewModelUndoTests#undoNeverAdvancesTheSelection` |

Increments 1 and 2 **replace** the projection and coordinator stopgaps. These tests
are the behavioral oracle: they must stay green, unmodified.

## Increment 1 — `CatalogProjection`: one publication loop, revision-counted

**Goal.** Replace three tasks and five flags with one loop and two counters, so
that:

- a request can never be lost;
- a build is never cancelled by newer work;
- a failed read never publishes.

Closes C2, C3 and C4 for the projection.

**Read first.**

- `Otos/Services/CatalogProjection.swift`, whole file:
  - the publication loop starts at `ensurePublicationLoop`;
  - `markDirty`, `markDetailDirty`, `scheduleImmediatePublication`,
    `publishIfDirty`, `finishPublication`, `removeContinuation`.
- `Otos/Services/CatalogProjectionWindowStateBuild.swift`.
- `Otos/Services/MaterializationCoordinator.swift`: `wake()`, `runSupervisor()`,
  `schedulePass()`, `isQuiescent`. This is the pattern to copy.
- `OtosTests/CatalogProjectionTests.swift`: `ProjectionProbe`, `StateRecorder`, and
  the `publicationLoop…` and `newerIntent…` tests.
- ADR 0005, ADR 0011, and requirement rows ARC-019 and APP-044.

**Target shape.** These replace `dirty`, `publishing`, `immediateWakePending`,
`immediatePublicationTask` and `publicationTask`:

```swift
private var requested: UInt64 = 0      // bumped by every intent and store change
private var covered: UInt64 = 0        // the `requested` value the last *successful* pass started from
private var pendingKind: DirtyKind = .none   // merged since the last pass started; structural beats detailOnly
private var doorbell: AsyncStream<Void>.Continuation?
private var loopTask: Task<Void, Never>?     // the one consumer; runs every build
private var cadenceTask: Task<Void, Never>?  // rings the doorbell every `cadence` while behind
private var publishedBeforeCatalogLoad = false   // unchanged: a fact, not request state

var isQuiescent: Bool { requested == covered && !passRunning }
```

`passRunning` is a plain `Bool` set at the top of `pass` and cleared at every exit.
It is not request state: it only says a build is between its first and last line.

**Steps.**

1. **Requests.** Write one private helper:

   ```swift
   func request(_ kind: DirtyKind, ringNow: Bool) {
       requested &+= 1
       pendingKind = max(pendingKind, kind)
       if ringNow { doorbell?.yield() }
   }
   ```

   Give `DirtyKind` an order with `.structural > .detailOnly > .none`. Route every
   current `markDirty` / `markDetailDirty` call through it:
   - intents (`updateQueryRequest`, `updateQueryDescriptor`, `updateSidebarSelection`)
     use `ringNow: true`;
   - store changes use `ringNow: publishedBeforeCatalogLoad` (today's behavior);
   - detail-only changes use `.detailOnly` and `ringNow: false`.
2. **The loop.** In `ensurePublicationLoop`, create the doorbell stream and two tasks:

   ```swift
   loopTask = Task { [weak self] in
       for await _ in stream {
           guard let self else { return }
           await self.pass(store: store)
       }
   }
   cadenceTask = Task { [weak self] in
       while !Task.isCancelled {
           do { try await Task.sleep(for: cadence) } catch { return }
           guard let self else { return }
           await self.ringIfBehind()      // yields only when requested != covered
       }
   }
   ```

   Both tasks hold `self` weakly and **return** when the upgrade fails. A loop that
   only skips a beat keeps the store alive forever: that is the zombie-loop defect
   the integrity scheduler had. The cadence sleep is the existing ~1 s
   background-change rate limit; it stays as is (plan 0106 increment 4 decides
   whether it survives measurement).
3. **The pass.** Replace `publishIfDirty` + `finishPublication` with
   `pass(store:)`:

   ```swift
   func pass(store: CatalogStore) async {
       guard requested != covered else { return }
       passRunning = true
       defer { passRunning = false }
       let startedFrom = requested
       let kind = pendingKind
       pendingKind = .none
       let selectedRequest = queryRequest
       // loading-state branch: unchanged, except it sets `covered = startedFrom`
       do {
           let (state, metrics) = try await buildWindowState(…)   // now `throws`
           try Task.checkCancellation()
           covered = startedFrom
           … retainResolvedSelection, diagnostics, yield-if-changed (today's finishPublication body)
       } catch {
           pendingKind = max(pendingKind, kind)   // the work is still owed
           OtosLog.catalog.errorOperation("projection.publish", phase: "failed", fields: [
               "generation": "\(selectedRequest.generation)",
               "error": String(describing: error),
           ])
           return                                  // `covered` not advanced: the next wake retries
       }
       if requested != covered { doorbell?.yield() }   // work arrived during the build
   }
   ```

   - Do **not** ring the doorbell from the `catch`. Doing so would retry a
     persistent error in a tight loop. The next intent or cadence tick retries it.
   - Keep the detail-only reuse logic exactly as it is today, keyed on `kind`.
4. **Make the build throw.**
   - `buildWindowState` and every helper in
     `CatalogProjectionWindowStateBuild.swift` become `throws`.
   - Delete each `catch` that substitutes a value (import batches → `[]`, ordered
     IDs → `[]`, counts → fallback, filter options → `.empty`); just `try`.
   - The test seam `stateBuilder` becomes `@Sendable (…) async throws ->
     CatalogWindowState`, so a test can make a build fail.
5. **Teardown.** `removeContinuation` cancels `loopTask` and `cadenceTask`, finishes
   the doorbell, and resets the counters to `0`/`0`. A build running at teardown
   throws `CancellationError` and publishes nothing.
6. **Delete.** Remove `dirty`, `publishing`, `immediateWakePending`,
   `immediatePublicationTask`, `publicationTask`, `scheduleImmediatePublication`,
   `runImmediateWake`, `publishIfDirty`, `markDirty`, `markDetailDirty`, and the
   increment-0 "abandoned" guard: step 3's `checkCancellation` replaces it. Keep
   the `projection.intent` / `projection.publish phase=start` diagnostics.
7. **Comments.**
   - Rewrite the file guide at the top of `CatalogProjection.swift` to describe:
     one loop, the two counters, the doorbell, what rings it, and why nothing
     cancels a build (GRDB reads throw `CancellationError` in a cancelled task;
     research, finding 3).
   - Remove the sentence "`dirty` is cleared before awaited reads/build work…".

**Tests** (`OtosTests/CatalogProjectionTests.swift`).

- Keep green unmodified: every existing test, especially
  `newerIntentDuringPublicationNeverCancelsTheRunningBuild`,
  `publicationLoopRunsOneProjectionAtATimeAndRerunsWhenDirtyDuringRun`,
  `detailOnlyStoreChangePublishesGridRefreshGeneration`,
  `publicationLoopDoesNotYieldUnchangedWindowState`, and the sidebar test in
  `CatalogWindowViewModelTests`.
- Add `aFailedBuildPublishesNothingAndTheNextIntentRetries`:
  1. Give `ProjectionProbe` a "throw on call N" switch.
  2. Make call 1 throw and record `publicationCount` before.
  3. Send `updateSidebarSelection(.library(x))`.
  4. Wait until `probe.callCount() >= 2` and the recorder holds a state whose
     `resolvedSidebarSelection == .library(x)`.
  5. `#expect` that no published state came from call 1 (the probe stamps
     `title: "Call 1"`), and that `isQuiescent` becomes true.
- Add `aStoreChangeDuringABuildIsPublishedAfterIt`:
  1. Park build 1 (`probe.waitUntilInFlight()`).
  2. Run `try await store.addLibrary(url:)` for a temp folder.
  3. Release build 1.
  4. `waitForCount` a state whose `libraries.count == 1`, then `#expect` it.
- Add `teardownDuringABuildPublishesNothing`:
  1. Park build 1.
  2. Cancel the recording task, which terminates the stream and runs
     `removeContinuation`.
  3. Release.
  4. Wait for `isQuiescent`.
  5. `#expect(await projection.publicationCount == before)`.

**Docs.**

- ARC-019: replace the coalescing description with the loop and counters, and
  state that a failed read publishes nothing. Cite the three new tests.
- ADR 0005: publication section.
- `docs/architecture.md`: the projection row.

**Done when.**

- `CatalogProjection` has no `Bool` request state and no task other than
  `loopTask`, `cadenceTask` and `changeTask`.
- Neither projection file has a `catch` that returns or assigns a substitute value.
- All tests are green; the new tests were shown to fail by reverting step 4 or step
  3 temporarily.

## Increment 2 — `MediaOperationCoordinator`: a synchronous session state machine

**Goal.** Make C1 (stale copies) and C2 (lost requests) impossible in the import
coordinator by construction, and make its logic testable without a store.

**How.**

- **The machine.** All session state moves into a value type,
  `ImportSessionMachine`. It changes only through
  `mutating func handle(_ event: Event) -> [Effect]`, which is synchronous.
- **The shell.** The actor becomes a thin shell that:
  - reads the store;
  - runs builds and executions;
  - feeds results back as events;
  - performs the returned effects.

This is the swift-nio "state machine returns actions" pattern (research, finding 5).

**Read first.**

- `Otos/Services/MediaOperationCoordinator.swift`, all of it. Map it with
  `grep -n "func " Otos/Services/MediaOperationCoordinator.swift`.
- `Otos/Services/ImportPlanBuilder.swift`, `Otos/Services/ImportExecuting.swift`.
- `OtosTests/MediaOperationCoordinatorTestSupport.swift`: `ControlledImportPlanBuilder`,
  `waitForPendingBuilder`, `waitForCoordinatorQuiescence`,
  `markEnrichmentLookedAtEveryRow`.
- `OtosTests/MediaOperationCoordinatorAdversarialTests.swift` and
  `OtosTests/MediaOperationCoordinatorTests.swift`. These ~70 tests are the oracle.
- ADR 0017, 0019, 0021, 0024, 0026, 0027; requirement rows ARC-046, ARC-047,
  ARC-057, APP-029; `docs/design/import-bar.md`.

### Target design

**Files.**

- New `Otos/Services/ImportSessionMachine.swift` (add it to both
  `membershipExceptions` lists).
- New `OtosTests/ImportSessionMachineTests.swift`.
- `MediaOperationCoordinator.swift` shrinks to the shell plus presentation
  derivation.

**The machine** (`nonisolated struct ImportSessionMachine`, internal so tests can
use it):

- **Owns.** `sessions: [LibraryRootPath: SourceSession]`,
  `destinationBySource`, `lastSeenRevisions`, `draining: [ImportBatchID:
  DrainingRun]`, `libraries: [CatalogLibraryState]` (the last snapshot), and
  `nextAttachmentGeneration`. All are `private(set)`.
- **Moves in.** `SourceSession`, `SourcePhase`, `ReadyContext`,
  `AttachmentCompletion`, `AttachmentFailure`, `SettledOutcome`, `NamingProgress`
  move into this file unchanged, **except**:
  - **No task or executor handles.** `BuildContext.task`, `ExecutionContext.task`,
    `ExecutionContext.executor` and `UnreadableRetry.task` are removed; the
    machine stores identities only.
  - **`isDirty` becomes two counters.** `planRequested: UInt64` and
    `planCovered: UInt64`. Add
    `var needsPlan: Bool { planRequested != planCovered }` and
    `mutating func requestPlan() { planRequested &+= 1 }`.
  - **Taking up a build** (today's `scheduleBuildIfNeeded`) sets
    `planCovered = planRequested`. **Nothing else ever writes `planCovered`.**
  - **The failure count becomes optional.** `AttachmentFailure.publishedCount`
    becomes `Int?`; `nil` means the count could not be read (rule 4, C4).
    Presentation states it only when non-nil and non-zero.
- **Identities** (new small structs):
  - `BuildID { source, attachment, generation }`;
  - executions are identified by `ImportBatchID`, as today.

**Events** (`enum Event`). Each case lists the current function it replaces:

| Event | Replaces |
| --- | --- |
| `librariesRefreshed(SourcesSnapshot)` (all libraries plus the planning revisions of every available removable source, read before the event is sent) | `refreshSources` |
| `planningChanged(RootPlanningChange)` | `handlePlanningChange` (the `await store.currentLibraries()` becomes a read of the machine's `libraries`) |
| `catalogChanged` | `handleCatalogChangeForMetadataGate` |
| `batchAssetCountRead(batch, count: Int)` | the write half of `confirmExecutingBatchAssetCounts` |
| `destinationPicked(source, destination)` | `setDestination` |
| `preferencesChanged` | `preferencesDidChange` |
| `sessionPreferencesChanged(source, prefs)` | `setSessionPreferences` |
| `importQueued(source)` | `queueImport` |
| `cancelRequested(source)` | `cancelImport` (state half) |
| `retryRequested(source)` | `retryPlanning` |
| `buildFinished(BuildID, BuildOutcome)` | the state half of `buildPlan`, `shouldWaitForMetadata`, `deferBuildOnUnreadableDestination` |
| `unreadableRetryFired(source, attachment)` | `retryDeferredBuild` |
| `executionProgress(batch, MediaOperationProgress)` | `applyExecutionProgress` |
| `executionFinished(batch, MediaImportExecutionResult, failedPublishedCount: Int?)` | `finishExecution`, `applyExecutionResult`, `settleDetachedExecution` |
| `shutdown` | the state half of `shutdown` |

**Effects** (`enum Effect`), performed by the shell **in order**:

| Effect | Shell action |
| --- | --- |
| `startBuild(BuildRequest)` (`BuildID`, destination, `ImportPolicy`, seeded ledger claims) | Start a build task (see the pipeline below). |
| `cancelBuild(BuildID)` | Cancel that build task (detach and shutdown only). |
| `startExecution(ExecutionRequest)` (batch, plan, source kind, device identity, prefs, runID) | Create the executor with `makeExecutor`, start the execution task, register it. |
| `cancelExecution(batch)` | `await executor.cancel()` inside an owned task. |
| `scheduleUnreadableRetry(source, attachment, delay)` / `cancelUnreadableRetry(source)` | Owned sleep task that sends `unreadableRetryFired`. |
| `readBatchAssetCount(source, batch)` | Owned task: read, then send `batchAssetCountRead`. |
| `persistDestinations` | `persistDestinationMappings()` with the machine's map. |
| `autoEject(LibraryRoot)` | Owned task running `autoEjectIfRequested`. |
| `publish` | `publish()`. Emit it exactly where today's code calls `publish()`, to keep frame counts identical. |

`OtosLog` calls stay inside the machine where they are today. Logging is not
state, and moving it would only make the diff harder to review.

**The build pipeline** (shell only; it never touches the machine). One task per
`startBuild`:

1. `snapshot = try await store.importPlanningSnapshot(…)`. If it returns `nil`:
   `libraries = await store.currentLibraries()`, then outcome
   `.noSnapshot(availableRoots)`.
2. If `MediaTransferPlanner.needsDate(policy:)` and the snapshot has a pending,
   readable row: `liveMedia = await store.planningMedia(for:)`, then outcome
   `.namingPending(settled:total:liveMediaSettled:)`. This is
   `shouldWaitForMetadata`'s inputs, computed as data.
3. Otherwise: `build = await planBuilder.build(…)`, then read
   `store.planningRevisions(for: source)`,
   `store.namespaceRevision(for: destination)` and
   `store.skippedPackageCount(for: source)`. Outcome
   `.built(snapshotRevisions, build, revisionsNow, skipped)`.
4. Any thrown error: outcome `.failed(error)`.
5. `await send(.buildFinished(id, outcome))`, then decrement the running-build
   count.

**`handle(.buildFinished)`** is synchronous:

1. Check the identity; if stale, log `staleCompletion` and return `[]`.
2. Apply exactly today's rules from `buildPlan`, in today's order:
   - missing snapshot → `.planningFailed`;
   - naming pending → `.waitingForMetadata`, or `requestPlan()` if the live media
     settled;
   - destination changed → `.inventory` + `requestPlan()`;
   - revisions moved → `requestPlan()`;
   - unreadable folders → defer (effect) or `.planningFailed(.destinationUnavailable)`;
   - ledger conflict → `requestPlan()`;
   - otherwise `.ready`.
3. Then, if `importRequested` → evaluate execution readiness from the stored
   `libraries` snapshot (today's `beginExecutionIfPossible`, now synchronous).
4. Finally, if `needsPlan` → take up the next build.

`ledgerClaims` and `planClaims` move into the machine unchanged. They read only
sessions.

**Refreshes are serialized** (rule 3; this fixes the `refreshSources`
check-then-act race in the research).

- The shell owns one refresh doorbell and one consumer task:
  `for await _ in refreshBell { let snapshot = await readSourcesSnapshot(); send(.librariesRefreshed(snapshot)) }`.
- `readSourcesSnapshot()` reads `store.currentLibraries()` and then
  `store.planningRevisions(for:)` for each available removable source. It writes
  nothing.
- `start()`, every catalog change and every planning change ring the bell instead
  of calling `refreshSources` directly. One consumer means two snapshots can never
  be applied out of order.
- Add `refreshRequested` / `refreshCovered` counters to `isQuiescent`.

**The shell** (`actor MediaOperationCoordinator`):

- **Holds.** `machine`, `buildTasks: [BuildID: Task<Void, Never>]`,
  `executions: [ImportBatchID: (task: Task<Void, Never>?, executor: any ImportExecuting)]`,
  `retryTasks: [LibraryRootPath: Task<Void, Never>]`, `effectTasks` (owned,
  awaited at shutdown), the continuations, the store consumers, and the refresh
  loop.
- **One entry point.** `private func send(_ event: Event)` is **synchronous**:
  `let effects = machine.handle(event); for effect in effects { perform(effect) }`.
  `perform` is synchronous too: anything async becomes an owned task.
- **Public methods become one-liners.** `setDestination`, `queueImport`, …
  become `send(.destinationPicked(…))`. They keep their `async` signatures so
  callers do not change.
- **Presentation stays in the shell, reading only.** `presentation(for:)`,
  `heldPlanState`, `interimState`, `executingState`, `settlementState`,
  `completedState`, `readyState`, `executingBatchID`, `makePresentation`,
  `sortedPresentations` and `publish` stay in the actor and read
  `machine.sessions`. They use the injected `volumeCapacity` reader, which is why
  they are not pure.
- **Execution progress** keeps its per-callback hop for now (increment 3 replaces
  it). `isStale` already drops out-of-order samples.
- **`isQuiescent`** = handled store changes == delivered, refresh covered, running
  builds == 0, effect tasks == 0.

### Sub-increments

Each lands separately and green. Existing coordinator tests stay **unmodified**;
if one has to change, stop and ask.

- **2a — Machine and build lifecycle.**
  1. Create the machine with the session types, `requestPlan`/`needsPlan`, the
     build events and effects, the pipeline, `librariesRefreshed`,
     `planningChanged`, `catalogChanged`, the destination/preference/retry events
     and the refresh loop.
  2. Execution paths still run through today's code, adapted to read and write
     `machine.sessions` through narrowly named mutating methods on the machine
     (e.g. `machine.beginExecution(…)`). No shell code may copy a session and
     write it back.
  3. Delete `sessionOwnedByBuild`, `scheduleBuildIfNeeded`'s `isDirty` handling
     and every `isDirty` use.
- **2b — Execution lifecycle.**
  1. Move `importQueued`, `cancelRequested`, `executionProgress`,
     `executionFinished`, draining, `batchAssetCountRead` and `autoEject` into
     events and effects.
  2. `failedPublishedCount` is read by the execution task before it sends
     `executionFinished`, as `try? await store.importBatchAssetCount(batch)`.
     `nil` stays `nil`.
  3. `beginExecutionIfPossible`'s stale write-back (research C1) disappears
     because the method disappears.
- **2c — Settlement, shutdown, cleanup.**
  1. Move settlement destination reconciliation, the destination flush after a
     run, and the `shutdown` event in.
  2. Delete every remaining direct `sourceSessions` access. The property itself is
     gone; `machine.sessions` is `private(set)`.
  3. Update the file guides of both files.

### Tests

**Oracle.** All of `MediaOperationCoordinatorAdversarialTests`,
`MediaOperationCoordinatorTests`, `ImportBarPresentationTests`,
`CatalogWindowViewModelMediaOperationsTests` and `ImportSourceReadinessTests` stay green **unmodified** through 2a, 2b and
2c. Increment 0's tests are in this set.

**New** `ImportSessionMachineTests`. These are pure: no store, no files, no
`await` except `#expect`.

- **Fixtures.** Build `CatalogLibraryState` values directly, as
  `OtosTests/ImportSourceReadinessTests.swift` does:
  `CatalogLibraryState(root: LibraryRoot(path: LibraryRootPath(rawValue: "/Volumes/CARD"), kind: .removableVolume), availability: .available, activity: .idle)`.
  Add the small `makeSource`/`makeLibrary` helpers you need at the bottom of
  `ImportSessionMachineTests.swift`.
- **Plan facts.** Build `ImportPlanBuildResult` / `MediaOperationPlan` values the
  way `OtosTests/ImportPlanBuilderTests.swift` and
  `OtosTests/MediaOperationCoordinatorTestSupport.swift` do (`ControlledImportPlanBuilder`
  calls `LiveImportPlanBuilder().build(snapshot:additionalReserved:)` on a real
  snapshot). If a machine test needs a plan with a given `copyCount`, run the pure
  `MediaTransferPlanner` on a hand-built `ImportPlanningSnapshot` the way
  `OtosTests/MediaTransferPlannerTests.swift` does; do not invent a fake plan type.
- **Shape.** Each test feeds events and asserts on the returned effects and on
  `machine.sessions`.
- **Required cases.** One per interleaving the old code got wrong, plus the
  obvious lifecycle:
  1. `aRevisionMovedDuringABuildRequestsAnotherPlan`: start the build; send
     `planningChanged` (namespace moved); send `buildFinished(.built)` carrying the
     *old* revisions; expect a second `startBuild`.
  2. `aPreferenceChangeDuringABuildRequestsAnotherPlan`: same shape with
     `sessionPreferencesChanged`.
  3. `aDestinationPickedDuringABuildDiscardsItsResult`: expect `.inventory` and a
     new `startBuild` for the new destination.
  4. `aStaleBuildResultIsDropped`: `buildFinished` with an older generation or
     attachment changes nothing and returns no effects.
  5. `queueingDuringABuildStartsExecutionWhenItIsReady`.
  6. `detachDuringExecutionDrainsTheRunAndIgnoresItsProgress`.
  7. `progressAfterFinishIsIgnored`.
  8. `aFailedRunWhoseCountCannotBeReadStatesNoCount`: `failedPublishedCount: nil`
     gives `lastFailure.publishedCount == nil`.
  9. `twoRefreshesApplyInOrder`: the second snapshot wins.
  10. `aReorderDuringARunAppliesAtSettlement`.
  11. `namingSettledDuringABuildRequestsAnotherPlan`.
- **Per suspension.** For each `await` in the pipeline (snapshot, live media,
  plan build, revisions, skipped count), one test delivers a competing event "at
  that point". In a pure machine that means: send the event between `startBuild`
  and `buildFinished`.

### Docs

- ADR 0019: the build-ownership paragraph names the machine and the
  identity-checked `buildFinished`, and drops "dirty bit".
- ADR 0017.
- ARC-047: "a change recorded while a build runs is never cleared by that build's
  completion"; cite the machine tests.
- ARC-046: one event per planning change, unchanged semantics.
- `docs/architecture.md`: the coordinator row and the dataflow.

### Done when

- `grep -n "isDirty\|sessionOwnedByBuild\|sourceSessions" Otos/` finds nothing.
- `ImportSessionMachine.handle` is the only writer of session state.
- No function in either file holds a `SourceSession` value across an `await`.
- All oracle tests pass unmodified.
- The new machine tests pass.
- A loaded stress confirmation passes, run once at the end of 2c: the full test
  bundle 15 times in a row with six `yes > /dev/null` CPU hogs, every run green, no
  hang. Kill the hogs afterwards.

## Increment 3 — ordered intent and progress delivery

**Goal.** User actions reach the coordinator in the order the user made them
(rule 5, C5).

**Steps.**

1. **Intent stream.** In `CatalogWindowViewModel`, add
   `importIntentContinuation: AsyncStream<ImportIntent>.Continuation`:
   - `.unbounded` buffering, one consumer task started where the coordinator
     starts (`CatalogWindowViewModelMediaOperations.swift`, `mediaOperationStartTask`);
   - the consumer holds `self` weakly, calls the coordinator per intent with
     `await`, and exits when the stream ends;
   - `ImportIntent` is an enum with one case per method below.
2. **Route through it.** Replace each `Task { await coordinator.x(…) }` in
   `CatalogWindowViewModelMediaOperations.swift` with a `yield`. These are
   `setDestination`, `setSessionPreferences`, `queueImport`, `cancelImport`,
   `retryPlanning`, `preferencesDidChange`, plus `refreshRemovableDestinations`
   where it follows `setDestination`. Copy the pattern of `submitCatalogMutation`
   / `mutationContinuation` in the same type, including how it logs a
   `.terminated` yield.
3. **Progress.** Replace the per-callback `Task` in the execution progress handler
   (in the shell after increment 2) with a per-run
   `AsyncStream<MediaOperationProgress>` (`.bufferingNewest(1)`):
   - the executor's callback yields;
   - one task per run consumes it and sends `executionProgress`;
   - the run's task finishes the stream before sending `executionFinished`, so no
     progress can follow settlement.

   Keep `isStale` as a guard.
4. **Classify the remaining intents.** For every other
   `Task { … await <owner>.<method>(…) }` in `Otos/ViewModels/` (trash, curation,
   reorganization, open-with):
   - decide whether it is a lossless command, newest-wins, or genuinely unordered;
   - route commands through an ordered stream like step 1;
   - leave a one-line comment at each call stating the classification and why.

**Tests.**

- `CatalogWindowViewModelImportIntentTests#destinationThenImportImportsIntoTheNewDestination`:
  call `setDestination(B)` then `queueImport` synchronously, back to back, with a
  `ControlledImportPlanBuilder` or a fake executor; `#expect` the executed plan's
  destination is B.
- A progress test asserts no `executionProgress` is applied after the session left
  `.executing`.

**Docs.** The requirement row for import intents (APP-029, or the row that cites
`queueImport`) states the delivery order.

**Done when** no plain `Task {}` in `Otos/ViewModels/` exists solely to forward one
intent to another owner without a classification comment.

## Increment 4 — blocking work leaves the actor explicitly

**Goal.** Make the code match ADR 0019 and keep long filesystem walks off the
coordinator and store actors (rule 6, C6).

**Steps.**

1. **Measure before changing.** Run the installed app or the smoke seam with a card
   or a synthetic removable volume
   (`docs/research/2026-08-21-synthetic-removable-volume.md`). Record:
   - `op=import.plan phase=finish enumerateMs/planMs`, i.e. how long the
     coordinator actor is held per build today;
   - for the store, an FS-event subtree rescan of a folder with ≥ 5,000 files,
     with an Instruments trace (`script/profile.sh "Swift Concurrency" 20s`)
     showing the `CatalogStore` actor busy for the walk, and any projection
     publication delayed behind it.

   Save the numbers in the PR and in a short `docs/research/` note.
2. **Plan builder.** Mark `LiveImportPlanBuilder.build` `@concurrent`. Mark the
   `ImportPlanBuilding` protocol requirement `@concurrent` too, if the compiler
   requires it to match.
3. **Subtree rescans.** At `CatalogStore.swift` (search `scanner.scanSubtree`), make
   them leave the actor the same way full scans do (search `Task.detached(priority:
   .utility) { [scanner, scanCadence]`). Keep the batch handler's hop back into the
   store as it is.
4. **Remeasure** and attach the before/after numbers.
5. **Fix the comments.** Fix every comment found by
   `grep -rniE "off (the )?(main|actor)|off-main|off-actor" Otos/` so that it
   names its mechanism.

**Tests.** Behavior is preserved, and the whole suite stays green. Do not write a
test that asserts which thread something ran on: the measurement is the evidence
(CLAUDE.md, Instrumentation).

**Done when** the before/after measurements are attached and ADR 0019's "off the
coordinator actor" is true of the code.

## Increment 5 — audit the remaining owners

**Goal.** Check every other owner against rules 1–6.

**Steps.** For each of these, read every `async` method and every stored
`Task`:

- `EnrichmentCoordinator` (+ its `Completion` and `WorkSelection` files)
- `MediaTrashCoordinator`
- `CatalogStore`
- `LibraryReorganizationRunner`
- `PreviewImageLoader`
- `CatalogWindowViewModel*`

For each, answer:

- Does any value read before an `await` get written back after it? (rule 1)
- Is "work needed" a `Bool` that a completion clears? (rule 2)
- Does newer work cancel older work whose result is published? (rule 3)
- Does a `catch`/`try?` substitute a user-visible value? (rule 4)
- Are intents ordered? (rule 5)
- Does a `nonisolated async` call do blocking work? (rule 6)

Fix each finding in this increment, with a regression test that fails before the
fix (rule 7). Record the clean answers per owner in the PR description.

**Done when** every owner has an answer to all six questions in the PR, and every
finding is fixed or explained.

## Increment 6 — make the rules durable

**Steps.**

1. **ADR.** Write `docs/adr/0032-owner-state-requests-and-intent-ordering.md`:
   - context: the hangs and the research;
   - decision: rules 1–7;
   - rejected alternatives (below);
   - consequences.
2. **CLAUDE.md.** Replace the bullets under "Swift And Concurrency" about
   coalescing, delivery semantics and revalidation with rules 1–6 in brief, citing
   ADR 0032. Add to Code Review lens (A): "for each `await` in the diff: what can
   change here, and is it re-read before being written?"
3. **Plan 0106.** In `docs/plans/0106-time-is-never-a-stand-in.md`, change "with
   dirty and in-flight flags" to "with a revision counter (ADR 0032)".
4. **Lint.** Add SwiftLint `custom_rules` to `.swiftlint.yml` **only** where the
   pattern is syntactic and the tree passes with no exceptions:
   - `projection_catch_substitutes_value`: in `CatalogProjection*.swift`, `catch`
     followed within its block by `= []`, `= .empty` or `return 0`/`return []`;
   - `live_async_without_concurrent`: `func .* async` inside a type named `Live*`
     without `@concurrent`.

   If a rule cannot be made precise, leave it out and say so in the PR. Never add
   an allowlist.
5. **Close the plan.** Delete this plan file and update `docs/plans/README.md`
   with its closure summary, in the style of the other closed plans.

Then plan 0106 resumes at its increment 3.

## Rejected alternatives

- **Keep fixing instances found by stress loops.** One finding per ~10 minutes
  under load, and the class remains. It is how `beginExecutionIfPossible` was
  missed.
- **Serialize each actor with an async lock or queue.** That reintroduces the
  deadlocks reentrancy exists to prevent (SE-0306), and it holds UI intents
  behind long builds.
- **Only swap `isDirty` for a counter and add an `inout` mutate helper.** It
  closes C2, but stale copies stay expressible. The transitions stay mixed with
  I/O, so they still need real stores and temp folders to test.
- **A third-party deterministic test executor.** It needs an ADR for the
  dependency, and it replaces production interleavings with a test-only schedule.
  Rule 7's injected events test the real ones.
- **`Task.immediate` for ordered intents.** SE-0472 gives no ordering between two
  such tasks after their first suspension.

## Risks

- **Increment 2 is large.** Its safety net is the unmodified oracle suite and the
  sub-increment split; a failing oracle test means the port changed behavior, and
  the test is right by default.
- **Increment 4 makes the build await a real suspension in production for the
  first time.** Interleavings that only tests produced today will then happen
  live. That is why it comes after increment 2.
