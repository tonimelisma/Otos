# A card left waiting for metadata, read as a parked trash shutdown

Date: 2026-11-15. Context: a full `script/check.sh` run under parallel load hung on
2026-11-14 with its stall report naming
`MediaTrashCoordinatorOwnershipTests/aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt`
parked in `MediaTrashCoordinator.shutdown`, beside another suite's test. Three code reads
found no defect in the trash coordinator
(`2026-11-15-test-host-footprint-and-a-parked-shutdown.md`). This pass reproduced the hang
instead of reading the code.

## Method

- **The repro tree.** A detached worktree at `origin/main` 3853e440 ran the full
  `script/check.sh` in a loop, one fresh log per pass, its deadlock detector armed. It stopped
  at the first pass that did not pass.
- **The load, beside it.** Two more worktrees looped scoped checks, each in its own build
  folder, the way other sessions run them:
  - `CatalogWindowViewModelEditTests`, `FaceAnalyzerTests` and `CatalogProjectionTests`;
  - `SearchReadingTests`, `MaterializationCoordinatorTests` and
    `CatalogWindowViewModelTrashTests`.
- **Other sessions.** Two other agents' worktrees ran their own checks during the same hour.

## What hung

Pass 3 of the full suite stopped finishing tests at 1,731. Consumed CPU rose 184 s to 195 s
over seven minutes, and the detector fired.

- **The dump listed two tasks with test frames.**
  - `MediaOperationCoordinatorTests.sourceNamingChangeReplansBecauseItRenamesTheCopy`, polling
    `settledReadyGeneration` in `waitForValue`. It is a task-group child of Swift Testing's
    runner: a test case.
  - `MediaTrashCoordinator.shutdown`, under a closure of
    `aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt`. It is an unstructured
    `Task` the test spawned, not a test case.
- **The trash test had passed.** The run's test log reads
  `aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt() passed (30.459 seconds)`.
  The runner's task tree held one test, the import one. The dump lists every task object
  still referenced, and the trash test's `shutdownTask` is held by a closure the coordinator
  keeps, so it listed a task whose test had already finished.
- **The pool was idle.** The sample's threads by queue: 4 user-initiated and 3 default
  cooperative threads, all parked in `__workq_kernreturn`. Every actor was idle with no jobs
  queued.

So the run waited on the import test, and the trash shutdown in the report was a bystander.
The 2026-11-14 report had the same shape, a trash shutdown "beside another suite's test". That
run left no dump to check it against.

## Why the import test waited forever

The test process's unified log (`log show --predicate 'processID == <xctest pid>'`) held the
card's whole story:

1. `op=catalog.scan phase=finish` for the card at 32.637.
2. `op=plan.rebuild phase=schedule` at 32.756, the coordinator's first build.
3. `op=import.readiness phase=waitingForMetadata ... settled=0 total=1` at 32.777.
4. No `catalogChangeWake` for the session afterwards. Nothing else happened in the test.

The test marks every card row as looked at by enrichment (`markEnrichmentLookedAtEveryRow`)
right after starting the coordinator, which stands in for the enrichment the tests do not run.
That batch landed while the first build ran:

- **What the build already handles.** A build that finds naming pending reads the live rows
  again before parking (`MediaOperationCoordinator.namingPending`), so a batch landing
  before that read is seen.
- **The window it missed.** A batch landing after that read and before the build is applied
  emits its catalog change while the session is `.building`. `ImportSessionMachine.applyCatalogChange` wakes only sessions
  already parked on `.waitingForMetadata`, so the change woke nothing.
- **The result.** The build then parked the session on the rows it had read. The wake it
  waits for had already gone by.

The same window exists in the app. When the last enrichment batch of a card lands there, the
import bar stays on waiting for metadata until some unrelated catalog change arrives.

## Change

`ImportSessionMachine` counts the catalog changes it handles. A build records the count when
it is taken up (`BuildContext.catalogChangesAtTakeUp`). A build that ends waiting for metadata
still parks the session and shows its progress. When the count moved since take-up, it also
requests a plan, and `finishBuild` takes that request up at once. This is ADR 0032's rule 2,
a request kept as a counter. The waiting-for-metadata log line carries
`catalogChangedDuringBuild=`.

`ImportSessionMachineTests/aCatalogChangeAfterTheBuildsReadIsTakenUpWhenTheBuildParks` delivers
the change at that exact point: after take-up, before the build's naming-pending outcome. It
asserts that the outcome starts a build.

`check.sh`'s stall report now labels each task with test frames as a test case or a task a test
spawned. A finished test's leftover task no longer reads as a second parked test.

## A second park, on the fixed tree: two Move to Trash commands in one millisecond

The fourth full pass on the fixed tree stopped at 1,705 tests. The dump's one test case was
`CatalogWindowViewModelTrashInterleavingTests/aSecondMoveBeforeTheFirstLandsHidesBothAndUndoesEachAlone`.
It was waiting for the published grid to drop both items, while the first command's mark
was held at its hook, as the test intends. The test process's log showed the cause:

```
16:28:02.471 op=trash.move phase=start batch=1794788882493 count=1
16:28:02.472 op=projection.hold phase=held count=1 hold=trash:1794788882493
16:28:02.472 op=trash.move phase=start batch=1794788882493 count=1
```

- **The cause.** The two commands were issued in the same millisecond, so they got the same
  `MediaTrashBatchID`, which was the issue time in milliseconds.
- **What depends on that identity.** Projection's hold keys on it, and so do the undo entry
  and the catalog's pending rows.
- **What went wrong.** The second command's hide took the first's place under one key, so
  the grid never dropped both items.
- **Why it shows under load.** It happens only when the held mark's arrival comes back
  within the millisecond, which is when the machine is busy elsewhere.
- **Change.** `MediaTrashBatchID()` takes one past the last identity this process issued
  whenever the clock has not moved past it. `twoCommandsIssuedInOneMillisecondHaveTwoIdentities`
  covers it.

## Runs

All runs were on one Mac with Xcode 27.2, between 23:35Z on 2026-11-15 and 01:28Z on 2026-11-16 (UTC). Two
scoped load loops, and other agents' checks, ran beside them throughout.

**Full suite, through `script/check.sh`:**

| Tree | Passes | Passed | Hung | Other failures |
| --- | --- | --- | --- | --- |
| `origin/main` 3853e440 | 3 | 2 | 1, the import test above | — |
| With the import fix | 8 | 6 | 1, the trash test above | 1, `PhotoSearchIndexTests` (see below) |
| With both fixes | 17 | 14 | 0 | 3, `DiskEjectorLiveDiskImageTests` (see below) |

**Targeted:** each test ran in parallel through local, uncommitted `@Test(arguments:)`, in
scoped checks under the same load.

| Test | Tree | Runs | Hung |
| --- | --- | --- | --- |
| `sourceNamingChangeReplansBecauseItRenamesTheCopy` | `origin/main` | 800 | 0 |
| `sourceNamingChangeReplansBecauseItRenamesTheCopy` | fixed | 1,600 | 0 |
| `aSecondMoveBeforeTheFirstLandsHidesBothAndUndoesEachAlone` | fixed | 300 | 0 |
| `aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt` | fixed | 500 | 0 |
| `aHeldVolumeIsBusyAndAReleasedOneEjects` | fixed | 30 | 0 |

**Load loops:** 87 scoped passes of `CatalogWindowViewModelEditTests`, `FaceAnalyzerTests`
and `CatalogProjectionTests`, and 37 of `SearchReadingTests`,
`MaterializationCoordinatorTests` and `CatalogWindowViewModelTrashTests`.

**No hang on `origin/main` in 800 targeted runs.** Both windows are a few milliseconds wide.
Running a test many times over does not open them; the full suite's load beside other suites
does.

**Two failures under load that were not hangs:**

- **`PhotoSearchIndexTests/aQueryDuringATextReconcileAnswersAsItsRevisionSays`.** Its last
  check waited for the first new index revision and expected both reading changes in it.
  Under load, blue's new preview can land after the held pass took its snapshot, and its
  reading then leaves one pass later. The test now waits for the answer with both changes
  in, whichever passes they came in.
- **`DiskEjectorLiveDiskImageTests/aHeldVolumeIsBusyAndAReleasedOneEjects`.** Once the
  handle was closed, the eject returned something other than `.ejected`, yet the volume was
  gone by the time the expectation was re-read. This happened in 3 of the
  17 passes with both fixes, and in none of 30 isolated runs. `DiskEjector`
  logged nothing about a refusal, so the step and status are unknown. It now logs
  `op=disk.eject phase=refused step= status=`.

## Residual risk

- **The two mechanisms found are fixed**, each with a test that delivers the competing event
  at the exact point.
- **Neither may be what hung on 2026-11-14.** That run left no dump. Its shape matches the
  first mechanism, but that is not proof.
- **A third rare window would show the same way.** The detector names it in the stall report,
  and the report now labels the task each test frame belongs to.
- **The eject failure is open.** Its cause is unknown until a failing run logs the refusal's
  step and status.
