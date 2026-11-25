# The suite ran no test on GitHub's 3-core runner (2026-11-25)

## Question

CI's `Build And Test (Xcode 27)` job builds, then runs no test at all: `tests=0` on every
heartbeat until `op=check.hang`, on `xcode-27-arm64` (image 20261104.0337.1, Xcode 27.2). The
same `script/check.sh` passes on the owner's Mac. What holds the suite?

## Evidence

Two full-tier runs, both hung the same way. Each `op=check.hang` report (sample plus
`swift-inspect dump-concurrency`) is in the job log:

- Run 45571007151 (`main` at 17581680): `tests=0` from the first heartbeat of the test
  stage; CPU then stopped (`op=check.stall … cpuSeconds=347 blockedFor=8m`).
- Run 45655553012 (PR, a1de131f): `op=check.host cpus=3 os=Darwin-arm64`; `tests=0` for
  60 minutes while the host consumed about 117 CPU-seconds a minute, until the run was
  cancelled.

Both dumps show 998 and 1,161 test cases in flight. Almost all are parked at their first
suspension with no deeper async frame: they were ready to run and waiting for a thread.
In both, exactly four test threads were held, each blocked synchronously
(`op=check.hang phase=threadStack role=test`):

| Test | Blocked in |
| --- | --- |
| `FaceAnalyzerTests.theClassifierSeesAPersonAroundAFaceAndNoneAroundAnObject` | `VNImageRequestHandler.perform` → `VNControlledCapacityTasksQueue dispatchGroupWait` |
| `FaceAnalyzerTests.realPortraitsReadAsTheirPeople`, via `FaceAnalyzer.personConfidence` on the analyzer's queue | the same |
| `SearchReadingTests.sceneLabelsHoldTheConfidentOnesMostConfidentFirst`, via `SearchSceneLabels.classify` | the same |
| `RAWResourcesTests.theWaitEndsWithTheReportFromAnotherQueue`, via `ImageRenderer.fetchResources` | `dispatch_semaphore_wait`, for a block the test put on `DispatchQueue.global()` |

The threads by queue in the second report: four on `com.apple.root.default-qos.cooperative`,
three on `utility-qos.cooperative`, one on `net.melisma.Otos.face.analysis`, and the main
thread.

## Finding

- Swift Testing runs a synchronous test function on the cooperative pool. The pool gives a
  priority about one thread per core (`2026-11-15-cooperative-pool-holders.md`): on a 3-core
  runner, three or four default-priority threads.
- Three of the tests called a blocking API from their own body. Each held a pool thread while
  the work it waited for ran elsewhere: Vision's request work on Vision's own queues, and the
  test's own `DispatchQueue.global()` block. With the fourth (the analyzer's own queue), every
  default-priority thread was held, so no other test could start, and the work they waited
  for never ran: the semaphore's block on a default-priority global queue cannot finish in a
  run where it was not scheduled in 60 minutes. The kernel admits a new thread for a
  default-priority global queue only while fewer threads than cores are active at that
  priority, and it counted the held pool threads (inferred; the semaphore's signal is the
  block's first statement after one flag write).
- On the owner's Mac (10 or more cores) four held threads leave threads free, so the same
  tests pass.
- Production does not do this. Each of these calls runs only on its owner's serial queue,
  which gets a thread of its own: `FaceAnalyzer`'s and `SearchImageEmbedder`'s queues, and a
  render lane's for `openRAW` (ADR 0032 rule 6). Only the tests called them on the pool.

What the second run spent its CPU on is not in the report: the sample's printed stacks are
the test threads and the main thread, and every test thread was blocked.

## Change

`offThePool` (`OtosTests/AsyncTestSupport.swift`) runs a blocking call on a serial queue of
its own and suspends until it returns, as production's owners do. Every test that called
Vision or the RAW support wait from its own body now calls it through `offThePool`.

## Sources

- GitHub Actions runs 45571007151 and 45655553012, job logs (`op=check.hang`, `op=check.host`).
- `docs/research/2026-11-15-cooperative-pool-holders.md` (one thread per core per priority).
- ADR 0032, rule 6 (a wait of seconds leaves the pool).
