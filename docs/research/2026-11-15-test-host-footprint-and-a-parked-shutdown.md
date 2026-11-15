# What took the test host past its footprint ceiling, and a parked trash shutdown

Date: 2026-11-15. Context: in one full `script/check.sh` run under parallel load the xctest
host reached 2,175 MB against `script/test.sh`'s 2,048 MB ceiling, and
`MediaTrashCoordinatorOwnershipTests/aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt`
once hung parked in `MediaTrashCoordinator.shutdown`.

## Footprint

**Method.** A probe beside each run sampled the host's `footprint` every second, with the
count of finished tests; at 1,300 MB it took `vmmap --summary` and a one-second `sample`, and
once the run went quiet, `leaks`. The guard's ceiling was lifted for the probe runs only
(`OTOS_TEST_HOST_FOOTPRINT_LIMIT_MB=9000`), so a spike was seen to its top instead of killed.

**Results.**

| Run | Peak | Notes |
| --- | --- | --- |
| Full suite | 2,449 MB | killed by the guard 15 s into testing, from 1,059 MB 5 s earlier |
| Full suite, ceiling lifted | 1,416 MB | back to 845 MB a second later; 712 MB at the end |
| Model suites + `CatalogWindowViewModelEditTests` | 1,350 MB | 457 MB a second before, 559 and 219 MB after |
| The same, edit models in one window after another | 1,389 MB | the spike came before any test finished |
| The same, one shared `EditAnalyzer` | **412 MB** | |

- **Nothing leaks.** `leaks` found 0 leaked bytes (571,358 live nodes, 76 MB) once the spike had
  passed, and the host fell back to about 220 MB.
- **What the spike is.** At 1,300 MB, `vmmap` showed 837 MB of resident mapped files and
  254 MB of small mallocs. The sample's test frames were the `CatalogWindowViewModelEditTests`
  cases (auto crop, level, crop geometry, undo) beside `FaceAnalyzerTests`.
- **Why the edit tests.** Opening a photo in the editor reads it with Auto crop and Auto
  straighten (`requestEditAnalysis`). The models are `FocalNet` and `GeoCalib`, 79 MB of
  weights, and `EditAnalyzer` loads them on first use, one analyzer per window. The edit test
  support made a window per test, so every edit test running at once loaded both models.
  Fourteen test files go through it.
- **Serializing the model suites did not help.** The search, face and glossary suites were
  run one after another, nested under one serialized parent. The peak was still 1,389 MB,
  because the edit windows were still loading in parallel.

**Change.** The edit test support gives every window it makes one shared `EditAnalyzer`, so
the models load once per test process. That is what the app does: one per window, and Otos
has one window. The ceiling is unchanged.

## The parked shutdown

**Lead checked: an exhausted cooperative pool.** This was a code read; no run reproduced the
hang.
- Every job `shutdown` awaits runs on the cooperative pool:
  - the download tasks;
  - `ReleaseSignal`, a default actor;
  - the coordinator actor;
  - the drain task.
- So a pool with every thread blocked would park the test exactly where it was seen.
- But only three places in the suite can block a pool thread without a bound:
  - two `hdiutil` waits in the disk-image tests;
  - the text-reading child's pipe read in `SearchReadingTests`.
- Each belongs to one test, so together they cannot hold eight threads at one priority.
- The other blocking work is CPU-bound, such as model loads and Vision requests, and holds a
  thread for seconds, not minutes.

**Conclusion.** The cause is unknown. Pool exhaustion would explain a delay of seconds, not a
park long enough for the deadlock detector.

**Instrumentation.** `check.sh`'s stall report already keeps a full `sample` beside the
swift-inspect dump. Its excerpt now also counts the sampled threads by the queue they run. A
pool whose every thread is held reads as one line:
`com.apple.root.<qos>-qos.cooperative` with the core count beside it. A pool that is idle
while a task stays parked reads differently, which points at a continuation that is never
resumed.
