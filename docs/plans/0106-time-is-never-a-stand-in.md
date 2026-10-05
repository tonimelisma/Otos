# Plan 0106: Time is never a stand-in for a fact that can be known

Opened 2026-10-05. The owner decided the rule in this plan's title after
PRs #429 and #436 removed wall-clock deadlines from test waits. Those PRs showed
that a fixed time limit fails tests whose state was still arriving, and hides tests
that assert nothing: `settlementConversionAfterPublishBStillSuffixDueToRealFile`
passed on `nil` after its 5 s loop in all 88 logged runs.

## The rule

Never use time to stand in for a fact that can be known. If something can report
that work finished, state changed, or an item is ready, wait on that report. Time
appears in code only when nothing can report the fact:

- an external system that may never answer (File Provider, a camera's PTP link):
  the limit is a product decision about when the user is told it failed;
- a measurement, or a schedule the product defines (integrity scan every 24 h);
- backoff after an external failure.

A rate limit (a cadence or a debounce) states that work is not worth doing more
often. That is a performance claim: it stands on a recorded measurement, or the
work is coalesced through its owner with dirty and in-flight flags instead.

No allowlist and no exceptions: the guard lands only when nothing violates it.

## Increments

1. **Tests.** Fix the deadline loops #436 missed: `waitUntilPending` ×2 (15 s) and
   `waitForVideoState` (5 s, falls through silently). Fix `waitForBoth`, whose
   `try? await Task.sleep` loop spins once cancelled. Replace every fixed sleep in
   `OtosTests` that stands in for a condition. A "did not happen" assertion awaits
   the completion of the work that could have violated it. A fake that simulates
   work that never finishes blocks until cancelled.
2. **Production, own state.** `EnrichmentCoordinator.drainWork` (100 ms poll,
   5 s cap) waits on the coordinator's own signal. The eject busy retries, whose
   comment says they outlast Otos's own card readers, are revisited once the drain
   is real.
3. **Production, OS state.** Research what DiskArbitration and ImageCaptureCore
   report, then replace `RemovableVolumeMonitor`'s 2 s detach guess,
   `CameraSourceMonitor.waitForCatalogStability` (two equal samples 500 ms apart),
   and `SmokeLibrarySelection`'s 100 ms poll.
4. **Cadence audit.** Projection cadence (1 s), filesystem-event debounce (1 s),
   scan flush cadence, enrichment apply flush, import progress emit, grid scroll
   coalescing. Each points at its measurement or becomes owner coalescing.
5. **Rule and guard.** An ADR and a CLAUDE.md principle, plus a CI check over
   `Otos/`, `OtosTests/` and `script/`. This increment deletes this plan.
