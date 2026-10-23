# Blocking work held two actors under NonisolatedNonsendingByDefault

Dated 2026-10-23. Evidence for plan 0107 increment 4 (rule 6: blocking work leaves the
actor explicitly). Context: `docs/research/2026-10-05-owner-state-reentrancy-and-ordering.md`
finding 4 — this target compiles with `NonisolatedNonsendingByDefault`, so a
`nonisolated async` function, and a stored `async` closure, runs on its caller's actor.
Only `@concurrent`, `Task.detached`, a task-group child, or a hop to another actor leaves it.

## Method

A throwaway XCTest-bundle harness (not committed) on Xcode 27.1, macOS 27, Debug build, one
machine, run before and after each change.

- **Coordinator.** A stand-in actor awaits `LiveImportPlanBuilder().build` — exactly how
  `MediaOperationCoordinator` awaits it — on a snapshot whose destination folder holds
  5,000 files. A second task pings the stand-in actor every millisecond; the worst ping
  latency while the build runs is how long the actor was held.
- **Store.** A `CatalogStore` with the production scan cadence (1 s) and an injected
  `CatalogFilesystemWatcher.testing()` over a library whose subfolder holds 8,000 files. After
  the initial scan settles, one directory event for that subfolder triggers a scoped
  (subtree) reconcile. A ping task calls `store.currentLibraries()` every millisecond; the
  worst latency until the reconcile has applied is how long the actor was held.

A first store run used a 10 ms cadence and showed no difference (126 ms before, 125 ms
after): the scanner flushes a batch to the actor at each cadence tick, so a short cadence
hides a walk that the production 1 s cadence lets run for up to a second.

## Results

| Measure | Before | After |
| --- | --- | --- |
| Coordinator: `enumerateMs` for 5,000 destination entries | 285–324 ms | 305–331 ms |
| Coordinator: worst ping while the build ran | 284–324 ms (1 ping answered, after the build) | 0 ms (165–172 pings answered during the build) |
| Store: worst ping during an 8,000-file subtree rescan, 1 s cadence | 995 ms | 121 ms |
| Store: time until the rescan applied | 3,197 ms | 2,867 ms |

The enumeration itself costs the same; what changed is whether the actor that awaited it
could serve anyone else meanwhile. Before, the coordinator actor was unreachable for the
whole destination walk, and the store actor for up to one scan cadence at a time.

## Changes

- `LiveImportPlanBuilder.build` and the `ImportPlanBuilding` requirement are `@concurrent`.
- The scoped (subtree) reconcile in `CatalogStore` runs in `Task.detached(priority: .utility)`,
  as a full scan already did; its post-walk and failure steps are actor methods
  (`completeScopedReconcile`, `endScopedReconcile`) so the lease check, revision bump and
  lease release stay one synchronous region.
- Every comment claiming work is "off the actor" or "off main" now names its mechanism.

## Not done

No Instruments trace was recorded; the ping-latency harness answers the question the trace
was for (how long each actor is held) directly and reproducibly. The installed app was not
driven against a physical card; the synthetic-card seam
(`docs/research/2026-08-21-synthetic-removable-volume.md`) holds 32 MB images, too small
for a 5,000-entry folder.
