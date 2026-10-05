# 2026-10-05 — Parallel `check.sh` runs, and the live-builder reattach

Two questions, one method: run the suite under the load it actually meets — several
`check.sh` runs in separate worktrees at once, with the installed Otos running — and
treat every failure or hang as a defect to name from evidence.

## 1. The reattach "stall" in `reattachedSourceGetsRememberedDestination`

The test's docstring recorded a 2026-08-19 study: under full-suite load the live
`ImportPlanBuilding` path for a same-path reattach never reached `.ready` at any
wait bound (30–180 s), so the test was rerouted through `ControlledImportPlanBuilder`.

| Tree | Runs under full-suite load | Result |
|---|---|---|
| `067535f^` (the studied tree), live builder, 24 parallel copies, 3600 s waits | 1 | 7 passed (~2.4 s); 17 never reached `.ready` |
| `main` at `5e7a5c3`, live builder, 1 copy | 1 | passed, 5.36 s |
| `main` at `5e7a5c3`, live builder, 24 parallel copies, no deadline | 1 | 24/24 passed, ~5.5 s each |

On the old tree, `swift-inspect dump-concurrency` showed the parked tests polling
`readyGeneration` with **no plan build and no store call in flight** for their
coordinators: a lost wakeup in session state, not starvation and not slowness. The
test host's `op=import.*` lines were not persisted (`.notice` from `xctest` is not
kept by the unified log), so the exact stuck phase on that tree was not recovered. The
current coordinator does not reproduce it, so the test now runs the live builder: a
reattach that never reaches `.ready` parks the test, and `check.sh`'s detector names it.

## 2. What actually broke when checks ran in parallel

Three concurrent `check.sh` runs (same commit, three worktrees, Otos running), repeated
until clean. Builds never collided — each worktree has its own `build/DerivedData` —
and `check.sh` already tracks only its own descendants. Every failure was a test defect:

| Test | Failure under load | Cause | Fix |
|---|---|---|---|
| `CatalogWindowViewModelOpenWithTests/staleMenuBuildIsDiscarded` | menu still `Open in Preview` (10.04 s) | 10 ms and 120 ms `Task.sleep`s raced an 80 ms simulated LaunchServices query | a gate holds the JPEG query until the target has moved; the test awaits the MOV menu |
| `CatalogWindowViewModelTrashTests/moveToTrashActsWithoutAskingAndRegistersUndo` | `canUndo == false` | asserted undo right after the files vanished; logs show the queue trashed at 18.805 and undo registered at 19.719 — two async facts with no order between them | waits for `canUndo` itself |
| `MediaTrashCoordinatorTests/pendingItemsAreTrashedCompanionFirstAndTheirRowsLeave` | asset row still present | the fake trash executor left `a.jpg` on disk; the store's reconcile of that path correctly re-cataloged it (filesystem wins) | the fake moves members out of the root, as the Trash does |
| `CatalogWindowViewModelTests/sidebarSelectionChangesRouteThroughProjection` | **hang**, 2 of 6 runs, `check.sh` stall detector fired | see below | test windows order in with `animationBehavior = .none` |

### The hang: window animations pinning threads

The stall dump showed one actor `state=scheduled` with a queued job and **no thread
running any task**, and a projection publication suspended on a `CatalogStore` hop.
The full `sample` (now saved by `check.sh`) showed **40 threads** parked in
`-[NSAnimation _runBlocking]`, each spinning its own run loop on a
`com.apple.root.user-interactive-qos` worker, while libdispatch's manager sat in
`_pthread_workqueue_add_cooperativethreads`.

An `lldb --waitfor` breakpoint on `-[NSAnimation startAnimation]` over only the four
window-hosting suites caught **78** starts, every one from
`-[NSWindow _doOrderWindow:] → -[_NSWindowTransformAnimation startAnimation]`: the
window order-in/order-out animation, from the harnesses' `makeKeyAndOrderFront` in
`init` and `close()` in `deinit`. In the xctest host those animations never finish,
so each pins a worker thread for the rest of the run. Under parallel load the pinned
threads exhaust the worker pool and an unrelated actor's job never runs.

`orderedInTestWindow(width:height:contentView:)` (`OtosTests/TestHostWindow.swift`)
is now the one way a test puts a view in a window, with `animationBehavior = .none`.
The same breakpoint afterwards caught **0** starts.

## Conclusions

- Parallel checks in separate worktrees, with Otos running, are supported; the
  failures were test defects, and each is fixed at its owner.
- A test that fails only under load is not "flaky": it encodes a wall-clock bound, an
  unowned ordering, or shared machine state. Measure it, then fix it.
- `check.sh` keeps the full `sample` of a parked host: the thread that explains a
  hang is often not among the excerpted lines.
