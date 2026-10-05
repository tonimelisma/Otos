# Owner state, reentrancy, cancellation and intent ordering

Dated 2026-10-05. Research behind plan 0107. It opened after Plan 0106's
deadline removals turned several "flaky" test failures into hangs. Under load,
every hang so far traced to a product defect in how an owner keeps state across
`await`, not to a slow machine.

## Defects found so far (stopgaps landed in PR #442, plan 0107 increment 0)

| Hang / symptom | Root cause | Class |
| --- | --- | --- |
| `sidebarSelectionChangesRouteThroughProjection` hung (PR #429 blamed starvation; that was wrong) | `CatalogProjection.markDirty` cancelled the running immediate publication and started a new one. In the cancelled task, GRDB reads threw `CancellationError`, the build's `catch` turned that into `[]`, and an empty catalog was published as fact. The VM then auto-selected for an empty library list. | C3, C4 |
| `executingDestinationSurvivesLibraryReorder` | A destination change held during a run was never applied when the run settled. | (logic) |
| `aCardThatGainsFiles…`-family hang (`volume:c2-count-hold`) | `buildPlan` copied the session, awaited store reads, then wrote the copy back with `isDirty = false`. That erased the dirty mark a scan batch set mid-build, so the empty plan was final. | C1, C2 |
| `undoPutsItemsBackAndRedoMovesThemAgain` hang | Test called undo before the undo was registered; `undoCuration` is a no-op then. A test defect, but an ordering one: the file move and row purge are not ordered against the main-actor registration. | (test) |

## Swift semantics that decide these designs (sources below)

1. **Actors are reentrant, and they are not FIFO.** Interleaving at every
   `await` is by design (SE-0306). After an `await`, actor state may have
   changed: "developers must be sure not to break invariants across an await".
   The runtime picks the next job by priority, so jobs are not FIFO.
2. **`Task {}` from main-actor code has no ordering guarantee.** SE-0431 makes a
   task with *explicit* isolation (`Task { @MainActor in }`) start on its
   executor in creation order. It excludes closures that are "only implicitly
   isolated", which is every plain `Task {}` in a `@MainActor` type.
   `Task.immediate` (SE-0472) does not order two tasks after their first
   suspension either. The established answer is one `AsyncStream` with a single
   consuming task (Swift Forums thread below). Otos already uses this for catalog
   mutations (`mutationContinuation`, `.unbounded`) and queries
   (`queryContinuation`, `.bufferingNewest(1)`).
3. **Cancellation does not stop work, but GRDB reads fail in a cancelled
   task.** GRDB 7.11's async `read`/`write` document "`CancellationError` if the
   task is cancelled" (`DatabaseReader.swift:216`, `DatabaseWriter.swift:131`). So
   a cancelled build does not end early. It finishes, holding errors, and
   whatever the caller substitutes for those errors becomes the result.
4. **Otos compiles with `NonisolatedNonsendingByDefault`.** The build log for
   this tree shows `-enable-upcoming-feature NonisolatedNonsendingByDefault`
   (from `SWIFT_APPROACHABLE_CONCURRENCY = YES`). A probe compiled with
   `swiftc -swift-version 6` showed that a `nonisolated async` function called
   from the main actor ran on the main thread only with the flag. The same held
   for an unannotated stored `async` closure. A `@concurrent` function ran off
   main either way. So **`nonisolated async` means "runs on the caller's actor"
   here**, and only `@concurrent`, `Task.detached`, a task-group child, or a hop
   to another actor leaves it. The repo has one `@concurrent`
   (`CatalogWindowViewModelOpenWith.swift:73`).
5. **The established pattern for actor state machines is a synchronous state
   machine that returns actions.** swift-nio's
   `NIOThrowingAsyncSequenceProducer.StateMachine` has `yield()`, `finish()` and
   `cancelled()` return `YieldAction`, `FinishAction` and `CancelledAction`. The
   caller performs the effects outside the critical section, because resuming
   inside it "can deadlock". All transitions are synchronous, so no transition
   can be interleaved.

## In-house precedents that already follow the right rules

- `MaterializationCoordinator`: one supervisor loop with a `bufferingNewest(1)`
  doorbell. `wakeGeneration` / `passedWakeGeneration` are revision counters, not
  booleans. `schedulePass()` is synchronous. `isQuiescent` is
  `passedWakeGeneration == wakeGeneration`, a fact rather than a guess.
- `CatalogStore`: it mutates in-memory state *before* suspending
  (`reorderLibraries`, `CatalogStore.swift:1900`) and revalidates ownership after
  every await (`owns(scan)`, namespace leases).
- `CatalogWindowViewModel`: catalog mutations travel as a lossless serial
  stream.
- `CameraMetadataReader`: a documented decision about where blocking work may
  run (a dedicated serial queue, not the cooperative pool).

## Codebase inventory by defect class

**C1 · A stale copy written back across an await.** A value copied out of actor
state before an `await` and written back after it. This erases whatever another
handler recorded in between. Everything found is in `MediaOperationCoordinator`
(a heuristic scan of all `Otos/` for `var x = state[k]` … `await` …
`state[k] = x` / `upsert(x)`, plus reading):

- `buildPlan` post-build tail (snapshot → revisions → skipped-count awaits).
  Patched on the branch with `sessionOwnedByBuild`.
- `buildPlan` missing-snapshot path (`await store.currentLibraries()`). Patched.
- `shouldWaitForMetadata` (`await store.planningMedia`). Patched.
- `beginExecutionIfPossible` (`MediaOperationCoordinator.swift:564`): it checks
  `.ready(generation)`, awaits `currentLibraries()`, then writes the whole stale
  copy. That can resurrect `.ready` over a `.building` session. **Open.**
- `finishExecution` failure branch (`~:957`): it awaits `importBatchAssetCount`,
  then writes the pre-await copy. **Open.**
- `CatalogStore`: none found; it uses the precedent above.

**C2 · A completion clears a request it never saw.** A boolean "needs work"
flag cleared when work *finishes* rather than when it *starts* drops a request
made during the work. `MediaOperationCoordinator.SourceSession.isDirty` has 34
touch sites, and its build completion set `isDirty = false` until the branch
patch. A preference change during a build was lost, proven by
`aPreferenceChangeDuringABuildIsPlannedAfterIt`, which fails on the old code.
`CatalogProjection` keeps the same request state as five flags (`dirty`,
`dirtyKind`, `publishing`, `immediateWakePending`, `publishedBeforeCatalogLoad`)
spread over three tasks.

**C3 · Cancel-and-replace of work whose output is published.** Seven
`x?.cancel(); x = Task {…}` sites. Only `CatalogProjection`'s immediate wake
published (fixed on the branch). The rest are newest-wins UI work or timers
(Open With menu, loupe video prepare, grid scroll coalescing, trash timer,
materialization breaker), plus camera catalog flows keyed by identity, where
replacement is a re-attach.

**C4 · An error substituted with a fabricated value.** This violates MED-002.

- `CatalogProjection.swift:472, 500, 553, 556`: import batches and ordered IDs
  `catch` → `[]`.
- `CatalogProjectionWindowStateBuild.swift:55, 101`: counts → fallback count or
  `.empty`.
- `MediaOperationCoordinator ~:957`: `(try? importBatchAssetCount) ?? 0`, a
  published count of zero.

The 25 `try? await store.abandonImportOperation` / `completeSourceEraseOperation`
calls in `MediaImportExecutor` are best-effort journal cleanup, not facts, and
are out of scope here.

**C5 · Intents and events with no delivery order.**

- `CatalogWindowViewModelMediaOperations.swift`: `setDestination`,
  `setSessionPreferences`, `queueImport`, `cancelImport`, `retryImportPlanning`
  and `preferencesDidChange` each spawn their own implicitly-isolated `Task {}`.
  "Change destination, then Import" can reach the coordinator in either order.
- `MediaOperationCoordinator.swift:700`: the execution progress handler spawns
  one `Task` per callback, so progress can apply out of order.
- The device delegates use `Task { @MainActor … }`, which is *explicitly*
  isolated, so SE-0431 orders them. Correct as written.

**C6 · `nonisolated async` that actually runs on the caller's actor (finding 4).**

- `LiveImportPlanBuilder.build`: synchronous destination enumeration and
  planning run **on the `MediaOperationCoordinator` actor**. Its doc comment and
  ADR 0019 both say "off the coordinator actor". `op=import.plan enumerateMs`
  already measures how long the actor is held.
- `CatalogStore` subtree rescans (`CatalogStore.swift:3785`): the plain
  `Task {}` inside the actor calls `scanner.scanSubtree` → `LiveCatalogScanner.scan`.
  The directory walk runs **on the store actor**, yielding only at batch flushes.
  Full scans use `Task.detached` (`:2950`) and do not have this problem.
- Checked and correct: `PreviewImageLoader` (`Task.detached`),
  `MediaGridPrefetch`, `PanePresentation`, `OtosApp`, `unmountAndEjectDeviceOffMain`,
  the device staging sweep (`Task.detached`), enrichment workers (task-group
  children), `CameraMetadataReader` (dedicated queue), Open With (`@concurrent`).

## Why the stress loop was slow, and what replaces it

Each loaded loop iteration found at most one hang, about 10 minutes apart, and
each hang needed a log-and-dump diagnosis. The classes above are syntactic or
structural, so a code audit finds them in minutes. Interleavings are better
tested deterministically. The coordinator already has the seam: the
`ControlledImportPlanBuilder` suspends a build so a test can inject an event at
that exact suspension. A synchronous state machine makes this cheaper still:
every interleaving becomes a sequence of events fed to a pure value, with no
store, temp directory, or timing.

## Sources

- SE-0306 Actors: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md>
- SE-0431 `@isolated(any)` function types (task start ordering): <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md>
- SE-0472 `Task.immediate`: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0472-task-start-synchronously-on-caller-context.md>
- Swift Forums, ordered delivery via one `AsyncStream` consumer: <https://forums.swift.org/t/how-do-you-use-asyncstream-to-make-task-execution-deterministic/57968>
- swift-nio `NIOThrowingAsyncSequenceProducer` state machine: <https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/AsyncSequences/NIOThrowingAsyncSequenceProducer.swift>
- Approachable concurrency flags in Swift 6 mode: <https://www.donnywals.com/what-is-approachable-concurrency-in-xcode-26/>
- GRDB 7.11.0 source, `build/DerivedData/SourcePackages/checkouts/GRDB.swift`
- Local probes: `swiftc -swift-version 6 [-enable-upcoming-feature NonisolatedNonsendingByDefault]`
  on a `nonisolated async` method, a `@concurrent` method and a stored async
  closure, each called from `@MainActor` and checked with `pthread_main_np()`.
