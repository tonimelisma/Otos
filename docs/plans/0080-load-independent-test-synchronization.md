# Plan 0080 — Load-Independent Test Synchronization

## Goal

Remove the remaining wall-clock assumptions from the test suite so that whole-suite
runs are deterministic. Every failure should mean "the code is wrong", never "the
machine was busy".

Scope is **tests and test support only**. No production behavior changes, so
`docs/requirements.md` rows and ADRs are untouched by this plan.

## Why now

A whole-suite run showed two different tests failing across different runs, both
green in isolation, in files neither recent PR touched. That is the signature of
load-dependent synchronization, not a product regression.

This is not a new bug class in this repo — it was diagnosed and named in plan 0065
Stage 4. `OtosTests/AsyncTestSupport.swift:50-53` records the conclusion verbatim:

> Polls actor state rather than sleeping a fixed interval — a fixed sleep is either
> flaky under parallel-suite load or needlessly slow, and usually both.

That pass built `withTestTimeout` (`AsyncTestSupport.swift:24-48`), `AsyncValueRecorder`
(`:110-154`), and `ManualSleepGate` (`:156-211`), and converted 15 test files. The
files below were never converted. Plan 0080 finishes that migration.

## Root cause

Swift Testing runs `@Test` functions **in parallel by default**. A test that sleeps a
fixed duration and then asserts that background work has progressed is asserting a
property of the machine's scheduler, not of the code. In isolation the cooperative
thread pool is idle and the work lands in microseconds; under whole-suite load the
pool is saturated and no fixed duration is a bound.

The load is not incidental. `EnrichmentCoordinatorTests.swift:366-371`
(`largeDatalessLibraryKeepsClaimAndMaterializationHandoffBounded`) builds a
**25,000-asset** catalog and is **not** gated behind `OTOS_SCALE_TEST`, unlike the
repo's other 25k test (`ProjectionEnrichmentScaleTests.swift:59`, which uses
`@Test(.enabled(if:))`; see the gate rationale in `script/test.sh`). The two
"unrelated" failing tests are coupled through the machine: this one generates the
load, the sleep-based ones are its victims.

## Defect inventory

| # | Site | Defect class | Failure mode |
| --- | --- | --- | --- |
| A1 | `OtosTests/ImportPlanBuilderTests.swift:91` | Fixed sleep as happens-before edge | `async let buildA/buildB` then `sleep(100ms)` then `#expect(pending.count == 2)`. Nothing bounds when the two child tasks get scheduled, enter the actor, and register in `pending`. Under load, observed count is 0 or 1. |
| A2 | `OtosTests/ImportPlanBuilderTests.swift:118` | Fixed sleep as happens-before edge | Same, for a single `Task`; `#expect(pendingBefore.contains(source))` at `:120` fails if the task has not yet suspended. |
| A3 | `OtosTests/ImportPlanBuilderTests.swift:123` | Fixed sleep after `cancel()` | Sleeps 100 ms then asserts `recordedCancelled().contains(source)` at `:125`. Cancellation delivery into `withTaskCancellationHandler` plus the actor hop to `recordCancel` is unbounded under load. |
| B1 | `OtosTests/EnrichmentCoordinatorTests.swift:673` | Wall-clock budget assertion | `#expect(elapsed < .milliseconds(150))` measures wall time across an `await`. Scheduler delay alone can exceed 150 ms while `drainWork` behaved correctly. This asserts machine speed, not behavior. |
| B2 | `OtosTests/EnrichmentCoordinatorTests.swift:410` | Wall-clock budget assertion | `#expect(shutdownDuration < .seconds(2))`. Same defect. The real invariant is already asserted at `:411` (`waiters == 0`). |
| C1 | `OtosTests/EnrichmentCoordinatorTests.swift:395-404` | Poll deadline doubling as the assertion | Polls up to 2 s for `materializing >= 2`, then asserts `== 2` at `:404`. Under load the loop exits on the deadline and the failure is reported as a wrong value rather than as a timeout. |
| C2 | `OtosTests/MaterializationCoordinatorTests.swift:353-360` | Poll deadline doubling as the assertion | A second, weaker `waitForStarts` with a 2 s deadline and `#expect(starts.count >= count)`. Duplicates the correct one at `EnrichmentCoordinatorTests.swift:848-854`, which wraps the same loop in `withTestTimeout`. Two owners of one helper. |
| D1 | `OtosTests/EnrichmentCoordinatorTests.swift:366` | Ungated scale test | 25k assets, no `OTOS_SCALE_TEST` gate. Primary load source for the rest of the suite. |

### Explicitly not a defect — do not "fix" these

- `ShouldHashRecorder.waitForBoth` (`EnrichmentCoordinatorTests.swift:772-776`) polls
  with a 20 ms sleep and **no** internal deadline. That is correct, because its only
  call site wraps it in `withTestTimeout` (`:751`). Leave it alone.
- `waitForProjectionQuiescence` (`AsyncTestSupport.swift:54-63`) and `waitForStarts`
  (`EnrichmentCoordinatorTests.swift:848-854`) also sleep internally. Also correct,
  for the same reason.

The distinction that matters: **polling until a condition is true, under an outer
timeout, is correct. Sleeping a fixed duration and assuming the condition is now true
is not.** A sleep inside a `while !condition` loop is a backoff; a sleep followed by
an assertion is a race.

## Stages

Each stage is independently mergeable and leaves the suite green.

### Stage 1 — Share the builder gates

`MediaOperationCoordinatorAdversarialTests.swift` already contains exactly the gates
`ImportPlanBuilderTests` needs, for the same `ControlledImportPlanBuilder` type, but
they are `private` to that file:

- `waitForPendingBuilder(_:source:timeout:)` — `:59-73`
- `waitForPendingBuilderCount(_:source:count:timeout:)` — `:75-90`
- `waitForPendingExecution(_:source:timeout:)` — `:92-106`

Move the two builder gates out of that file into shared test support. Preferred home
is `OtosTests/MediaOperationCoordinatorTestSupport.swift`, next to the
`ControlledImportPlanBuilder` actor they gate (`:14-104`) — that keeps the double and
its gates under one owner. Express them with `withTestTimeout` so a timeout is
reported as a timeout rather than as `TestError.timeout` thrown by hand.

Add one new gate for the cancellation edge (needed by Stage 2, defect A3):

```swift
func waitForRecordedCancellation(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath
) async throws {
    try await withTestTimeout("builder recorded cancellation \(source.rawValue)") {
        while await !builder.recordedCancelled().contains(source) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
```

Update `MediaOperationCoordinatorAdversarialTests.swift` to call the shared versions
and delete its private copies. Its existing call sites (`:165`, `:214`, `:226`, and
the others found by grepping `waitForPendingBuilder`) must keep passing unmodified —
that is the oracle for this stage being behavior-preserving.

`waitForPendingExecution` gates `ControlledExecutionControl`, not the builder; leave
it private unless Stage 1 finds a second caller.

### Stage 2 — Convert `ImportPlanBuilderTests`

Fixes A1, A2, A3. Replace all three `Task.sleep` calls with the Stage 1 gates.

- `:91` → `try await waitForPendingBuilderCount(controlled, source: sourceA, count: 1)`
  and the same for `sourceB`. Then the existing `pendingSources()` assertions at
  `:92-95` still hold and now cannot race.
- `:118` → `try await waitForPendingBuilder(controlled, source: source)`.
- `:123` → `try await waitForRecordedCancellation(controlled, source: source)`.

Keep every `#expect` currently in the file. The assertions are correct; only the
synchronization is wrong. In particular keep `:128`'s "still pending after cancel"
check — that is the real invariant (cancellation does not auto-resume) and it must
survive the rewrite.

After this stage the file should contain no `Task.sleep` at all.

### Stage 3 — Replace wall-clock budgets with behavioral assertions

Fixes B1 and B2. A duration is not the invariant; it is a proxy for one. Assert the
invariant directly.

**B1 — `ejectDrainIgnoresPureInteractivePreviewTraffic` (`:642-678`).** The claim
under test is "drain does not wait on purely interactive preview traffic". Delete the
`start`/`elapsed` measurement (`:669`, `:671`) and the `#expect(elapsed < .milliseconds(150))`
(`:673`). Keep `#expect(drained)` (`:672`) and add the load-independent half: the
`HeldMaterializationExecutor`'s interactive request is **still held and unreleased**
at the moment drain returns. If drain had waited on it, drain could not have returned
while the request was still held. That is the same claim with no clock in it.

The `timeout: .milliseconds(300)` argument to `drainWork` at `:670` is a production
API parameter, not a test assertion — keep it, since exercising a short drain timeout
is part of the test's point.

**B2 — `largeDatalessLibraryKeepsClaimAndMaterializationHandoffBounded` (`:407-410`).**
Delete `shutdownStart`/`shutdownDuration` and the `#expect(shutdownDuration < .seconds(2))`.
Wrap the `await coordinator.shutdown()` call in `withTestTimeout("coordinator shutdown")`
instead: a hang still fails the test, with a clear message, and a merely slow machine
does not. The behavioral invariant is already asserted at `:411` (`waiters == 0`) —
shutdown released its waiters rather than blocking on in-flight materialization.

### Stage 4 — Fix the poll-deadline assertions

Fixes C1 and C2.

**C1 (`:395-404`).** Replace the hand-rolled `ContinuousClock` deadline loop with
`withTestTimeout("two materializations in flight")` wrapping an unbounded
`while await coordinator.workStateSnapshot().materializing < 2 { try await Task.sleep(for: .milliseconds(10)) }`.
The existing `#expect(state.materializing == 2)` at `:404` then means what it says: a
timeout reports as a timeout, and a wrong steady-state value reports as a wrong value.
These are different bugs and must not share one failure message.

**C2 (`MaterializationCoordinatorTests.swift:353-360`).** Delete this weaker
`waitForStarts` and use the `withTestTimeout`-based one. Because both are private
extensions on different local test doubles, check first whether the two
`HeldMaterializationExecutor`-shaped doubles can be unified into one shared double in
test support; if they genuinely differ, at minimum make this one delegate to
`withTestTimeout` and drop the `#expect(starts.count >= count)` deadline assertion.

### Stage 5 — Gate the 25k-asset enrichment test

Fixes D1, and removes the load that triggers the rest.

`largeDatalessLibraryKeepsClaimAndMaterializationHandoffBounded` (`:366`) builds 25,000
assets (`:370`) on every run. The repo's existing convention for this cost is
`@Test(.enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))`
(`ProjectionEnrichmentScaleTests.swift:59`), with `script/test.sh` forwarding the
variable as a trailing build-setting argument.

Decide between two options and record the choice in the PR:

1. **Gate it** behind `OTOS_SCALE_TEST`, matching `ProjectionEnrichmentScaleTests`.
   Cheapest, consistent with existing convention. Cost: the claim-bounding invariant
   stops being checked on ordinary runs.
2. **Shrink it.** The invariants asserted are `claimed <= 32` (`claimBatchSize: 32`),
   `materializing == 2`, and `inFlight == 1`. None of those obviously requires 25,000
   assets — they require "enough assets to exceed the claim batch and the
   materialization concurrency cap". A few hundred assets likely proves the same
   thing at a fraction of the cost, keeping the check on every run.

**Option 2 is preferred if it holds.** Verify empirically before committing to it:
drop the count, confirm the test still fails when `claimBatchSize` bounding is broken
(mutate the production cap and watch it go red), and only then keep the smaller
number. If the invariant turns out to genuinely need scale, take option 1.

## Verification

Stages 1-2 and 4 are behavior-preserving refactors of synchronization: the existing
`#expect`s must stay green **unmodified**. Stage 3 changes assertions, so it needs the
inverted check — break the production behavior deliberately (make `drainWork` wait on
interactive traffic; make `shutdown` block on in-flight work) and confirm the new
assertions go red. An assertion that cannot fail is worse than the flaky one it
replaced.

Run the full local gate:

```bash
script/verify.sh
```

To reproduce the flake before fixing and confirm its absence after, run the suspect
tests repeatedly while the machine is loaded, rather than in isolation — isolation is
precisely the condition under which these tests pass:

```bash
/usr/bin/xcodebuild -project Otos.xcodeproj -scheme Otos -configuration Debug -destination "platform=macOS" -derivedDataPath build/DerivedData -only-testing:OtosTests/ImportPlanBuilderTests -test-iterations 50 -run-tests-until-failure test
```

Generate competing load in a second shell while that runs (a parallel build, or the
suite's own 25k test via `OTOS_SCALE_TEST=1 script/test.sh`). A clean 50-iteration
run under load is the bar for calling a stage done.

## Status of the evidence

The defect inventory above is established from the source, and the bug class is one
this repo has already diagnosed and fixed elsewhere (plan 0065 Stage 4). The specific
whole-suite failures that prompted this plan were **not** reproduced under a
controlled load harness before writing it — reproduction is the first task of
Stage 2, using the command above. If the reproduction does not implicate A1-A3, stop
and re-investigate rather than converting tests speculatively.

## Done criteria

- No `Task.sleep` followed by an assertion anywhere in `OtosTests/`. Sleeps survive
  only as backoff inside a `while !condition` loop under an outer `withTestTimeout`.
- No `#expect` on a measured wall-clock duration.
- One owner for each test gate; no duplicated `waitForStarts`.
- 50 consecutive green iterations of `ImportPlanBuilderTests` and
  `EnrichmentCoordinatorTests` under artificial load.
- `script/verify.sh` green.
- This plan deleted when all five stages have landed, per `AGENTS.md`.
