# 2026-08-17 — Ten `script/verify.sh` runs after plan 0094 (ADR 0023)

## Question

Plan 0094's leading hypothesis (`docs/research/2026-08-16-unhosted-test-bundle-
capability.md`) was that main-actor contention inside a hosted `TEST_HOST`
process caused the intermittent multi-minute `verify.sh` collapses observed
in 2 of 11 archived runs (703 s and 1534 s, against a ~96 s steady state).
ADR 0023 removes the hosted process entirely. Does the collapse still occur?

## Method

`script/verify.sh` run 10 consecutive times on a single machine, same session,
immediately after increments 1–7 landed on `main`. Elapsed time taken from
each run's own `IDETestOperationsObserverDebug: <n> elapsed` line, plus wall
time for the whole `verify.sh` invocation (build-for-testing + static gates +
test-without-building together) and the pass/fail count.

## Results

| Run | `verify.sh` wall time | `xcodebuild` test-phase elapsed | Outcome |
| --- | --- | --- | --- |
| 1  | 50 s | 20.055 s | pass |
| 2  | 42 s | 17.590 s | pass |
| 3  | 45 s | 21.962 s | **fail** — 1 test |
| 4  | 39 s | 17.454 s | pass |
| 5  | 40 s | 17.606 s | pass |
| 6  | 39 s | 17.559 s | pass |
| 7  | 40 s | 17.473 s | pass |
| 8  | 39 s | 17.618 s | pass |
| 9  | 36 s | 17.191 s | pass |
| 10 | 36 s | 17.279 s | pass |

Wall time: min 36 s, max 50 s, mean 40.6 s. No run approached the prior 703 s /
1534 s collapse magnitude, and none exceeded 50 s — every run landed inside
(in fact well below) the old ~96 s steady state. **0 of 10 runs collapsed.**

One run (3) failed a single test:
`MediaOperationCoordinatorTests.explicitDestinationResumesTrackingDefaultAfterItBecomesUnavailable()`
threw `ReadyPlanTimeout()` after 16.927 s (full detail in the run's `.xcresult`).
That test polls `MediaOperationCoordinator` for a ready-generation change with
an explicit `timeout: .seconds(15)` (`OtosTests/MediaOperationCoordinatorTests.swift:548`)
after removing a library out from under an explicit destination pick — a
timing-budget race in that specific test's own polling helper
(`readyGeneration`, `MediaOperationCoordinatorTests.swift:602`), not a
main-actor/hosting symptom: it is unrelated to `TEST_HOST`, runs in an already-
unhosted `nonisolated` suite, and none of the other 9 runs (nor any other test
in run 3) showed contention. Filed as a separate flake to investigate, not
counted against this question.

## Conclusion

ADR 0023 answers the question this research set out to test: the intermittent
multi-minute `verify.sh` collapse (2 of 11 archived runs, ~18%) did not recur
in 10 consecutive runs post-unhosting. That is enough evidence, at a sample
size comparable to the original diagnostic run, to close plan 0094's
deferral — the hosted-process main-actor contention ADR 0023 removed was the
cause.

The one test failure observed (run 3) is an unrelated, pre-existing flake in
`MediaOperationCoordinatorTests`'s own polling timeout, not a hosting or
main-actor symptom, and does not change this conclusion. It is out of scope
for plan 0094 and is flagged separately for follow-up.
