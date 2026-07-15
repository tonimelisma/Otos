# Plan 0059: Materialization Scheduler Review Fixes

## Status

Active.

## Purpose

Fix the defects found by the cold code review of PR #125 (the plan 0058
implementation, commit `18983af`). The review confirmed the rewrite's core
scheduling is sound — suppression pairing, continuation lifetimes, incremental
accounting, and priority gating all verified clean — but found one
blocking-class correctness defect, three further confirmed defects, and four
smaller items. This increment lands the fixes as a follow-up rather than a
revert.

The findings below are the review output verbatim in severity order. Each fix
must reproduce the failure in a focused test first, then make it pass.

## Findings And Required Fixes

### 1. Unbounded background retry exhausts the claim window (CONFIRMED, blocking)

`Otos/Services/EnrichmentCoordinatorCompletion.swift:164` — `retryWorkIfNeeded`'s
non-device branch has no attempt ceiling (delays `[15, 60, 300, 900]` saturating
at 900 s) and `finishDownload` re-parks the failed record as
`.awaitingMaterialization` inside `claimedWork` with `ownsStoreClaim` preserved
and the lease refreshed every 120 s. No eviction, staleness, or window-pressure
path releases it. Once 32 (`claimWindowLimit`) permanently-failing background
assets accumulate — the exact provider-timeout incident population plan 0058 was
written for — `remainingClaimCapacity == 0` in `dequeueEnrichmentWork` and no
new enrichment candidate is ever claimed: library-wide enrichment stalls
permanently while the dead assets churn retries. This inverts the pre-#125 bug
(immediate-reclaim churn) into a worse one.

**Fix.** Failed background work must not retain claim-window capacity without
bound. After a bounded number of in-window retry attempts (device work already
caps at 3), release the record's Store claim and remove it from `claimedWork`,
keeping only a small process-local not-before ledger (ID → earliest reclaim
time, attempt count) so Store re-claiming honours the same exponential pacing
without holding a window slot. The ledger is bounded state, not a second queue:
it stores no work payload, only pacing facts, and is consulted at claim/enqueue
time. Reset a ledger entry on materialization success, source-signature change,
or process restart, exactly as plan 0058 required. The pacing values stay
`[15, 60, 300, 900]` seconds unless runtime evidence says otherwise.

### 2. Spurious `unblocked` diagnostic during effective interactive demand (CONFIRMED)

`Otos/Services/MaterializationCoordinator.swift:396` — with a non-empty
background queue, `effectiveInteractiveCount > 0`, and an empty interactive
queue (an interactive waiter joined an in-flight transfer, or an interactive
operation is running), `selectedPendingPriority()` returns nil, `schedulePass`
skips its loop entirely, `rejections` stays empty, and `recordAdmission` calls
`publishUnblockedIfNeeded()` — logging `phase=unblocked` and clearing
`lastBlockedSnapshot` during exactly the interactive-starvation window the
blocked diagnostic exists to expose. The `reason=interactivePriority` recording
at lines 374–378 is unreachable dead code: `selectedPendingPriority` only
returns `.device`/`.background` when `effectiveInteractiveCount == 0`, so the
guard's two conditions can never both hold.

**Fix.** When lower-priority work is pending and effective interactive demand
(queued or in-flight) is the reason nothing dispatches, the pass must record an
`interactivePriority` blocked state including the deferred counts, and must not
emit `unblocked`. Remove the dead recording branch. The aggregate snapshot must
include effective interactive pending/in-flight demand as plan 0058's
"Aggregate admission state" required.

### 3. `.cancelled` outcome treated as retryable failure (CONFIRMED)

`Otos/Services/EnrichmentCoordinatorCompletion.swift:148` —
`MaterializationOutcome.cancelled.isMaterialized == false`, so a cancelled
background materialization passes `retryWorkIfNeeded`'s guard and schedules a
retry while holding its claim slot, instead of releasing the claim. Only
shutdown-time cancels are exempted (by the `isShuttingDown` early return);
any other cancellation — e.g. during a per-root drain — is retried like a
provider failure, compounding finding 1.

**Fix.** Treat `.cancelled` as a release, not a failure: release the claim and
remove the record without touching retry pacing. Cancellation says nothing
about the provider's ability to materialize the asset.

### 4. Eject drain blocked by unrelated preview traffic (CONFIRMED regression)

`Otos/Services/EnrichmentCoordinator.swift:325` — `hasInFlightWork` now adds
`materializationRequester.activeRequestCount(under: rootPath)`, which counts
every request on the root from every consumer of the shared coordinator,
including `PreviewImageLoader` interactive previews. Ejecting a removable root
while previews on it are active spins `drainWork` for the full 5 s timeout and
logs a misleading `drainTimedOut` on every such eject. The old code checked
only enrichment-local state. Eject still proceeds, so the impact is a spurious
stall plus a wrong diagnostic, not a failed eject.

**Fix.** The drain question is "has the work this coordinator is responsible
for under this root exited?", which includes its own submissions still active
in the shared coordinator but not other consumers' interactive traffic. Scope
the shared count to enrichment-originated requests (device/background
priorities under the root, or an explicit origin fact on the request), and keep
interactive preview demand out of the eject drain.

### 5. `stageDevice` clobbers an in-flight `.materializing` record (PLAUSIBLE)

`Otos/Services/EnrichmentCoordinator.swift:292` — device staging writes to a
`.tmp` path until completion, so the `fileExists` guard passes mid-transfer and
a camera disconnect/reconnect re-running `runCameraCatalogFlow` overwrites a
`.materializing` record back to `.awaitingMaterialization`, producing a second
submission. Same-ID coalescing and the `finishDownload` guard absorb the worst
outcomes, but `materializingCount` transiently undercounts, letting
`dequeueMaterializationSubmissions` overshoot `globalOutstandingLimit` by one.

**Fix.** In `stageDevice`, skip seeds whose ID already has a `claimedWork`
record in `.materializing` or `.awaitingMaterialization`; the active record
already represents the demand.

### 6. `inFlightEnrichVideoCount` is not a derived view (CONFIRMED invariant violation)

`Otos/Services/EnrichmentCoordinator.swift:141` — every sibling per-state fact
(`enrichingCount`, `materializingCount`, `enrichingBytes`,
`awaitingMaterializationWork`) is a computed view over `claimedWork`; the video
count alone is an independently mutated stored counter with `max(0, …)` clamps,
decremented behind a `guard claimedWork[id]` that any future removal path can
bypass, leaking the counter and permanently blocking video enrichment
(`videoEnrichCap = 2`). No current path arms the leak — it is latent — but plan
0058 explicitly required per-state facts to be derived views, never
independently mutated.

**Fix.** Replace the stored counter with a computed view over `claimedWork`
(count of `.enriching` records whose work `isVideo`), and delete the clamps
and all four mutation sites. `claimedWork` is bounded at 32, so the scan is
trivially cheap.

### 7. Silent-zero default on `activeRequestCount(under:)` (PLAUSIBLE)

`Otos/Services/MaterializationCoordinator.swift:7` — the protocol requirement
ships a default implementation returning 0, so a conformer that forgets to
implement it compiles cleanly while making `drainWork` under-report in-flight
work — a silent wrong answer at the drain boundary.

**Fix.** Remove the default so every conformer must answer, or drop the
protocol member and have `EnrichmentCoordinator` query the concrete coordinator
it already holds. Whichever the finding-4 fix makes natural wins; do not keep a
0-returning default either way.

### 8. Duplicated milliseconds conversion and hand-built log lines (CONFIRMED reuse)

`Otos/Services/MaterializationCoordinator.swift:658` — the private
`milliseconds(from:to:)` is the fourth hand-rolled Duration→milliseconds
conversion (`CameraSourceMonitor.swift:711`, `MediaOperationModels.swift:163` —
the latter with a seconds-dropping bug now fixable only per-copy), and
`logLifecycle` hand-builds `op=`/`phase=` strings instead of the
`otosLogFields` / `noticeOperation` helpers in `Otos/Support/Instrumentation.swift`.

**Fix.** Add a `ContinuousClock.Instant` overload to `DiagnosticsTiming`,
migrate the four copies to it (fixing the `MediaOperationModels` bug in
passing), and route the coordinator's lifecycle logs through the shared
field-formatting helpers.

## Verified Clean — Do Not Re-Litigate

The review verified and cleared: suppression begin/end pairing on every path;
continuation resume-exactly-once; incremental counter pairing in the
coordinator; priority gating and same-ID coalescing; device-seed overflow
recovery through durable Store rows (REFUTED as data loss); `drainWork`
false-drained (REFUTED as user harm — the apply flush is eject-independent);
plan deletion, ADR rewrites, and requirements updates (no convention
violations). Fixes must not unwind these verified behaviors.

## Test Plan

Each finding lands with a failing-first focused test:

1. Thirty-two permanently-failing background assets do not block a fresh
   enrichment candidate from being claimed; failed assets release claims after
   the bounded in-window attempts and re-enter paced by the ledger.
2. Background queue pending + interactive joined in flight emits one
   `interactivePriority` blocked record and no `unblocked` until interactive
   demand drains.
3. A cancelled background materialization releases its claim and holds no
   retry slot.
4. Eject drain returns promptly with only interactive preview requests active
   under the root.
5. Re-staging a seed whose ID is `.materializing` neither clobbers the record
   nor produces a second submission.
6. Video enrichment admission derives from `claimedWork`; no stored video
   counter remains.
7. (Compile-time) no conformer inherits a 0-returning `activeRequestCount`.
8. Existing timing/log assertions stay green through the `DiagnosticsTiming`
   and `noticeOperation` migration.

## Documentation

- `docs/requirements.md`: update ENR-009 (bounded retry ledger and claim
  release on exhausted in-window attempts) and the admission-diagnostics
  acceptance to include the effective-interactive blocked state.
- ADR 0009: state the retry ledger and the claim-release-on-failure policy.
- Architecture-boundary file guides updated where ownership facts change
  (retry ledger, drain scoping). No history narration.

## Delivery

Standard code increment: dedicated `fix/` worktree branch, focused tests first,
`script/verify.sh` under the configured Xcode 27 beta, cold `/code-review`
before merge, OneDrive runtime spot-check that a provider-timeout asset
releases its claim slot and enrichment proceeds past it. Findings 1–3 are the
blocking core; 4–8 may ship in the same PR or a small follow-up if review size
demands. Delete this plan when the work has fully landed on `main`.

## Definition Of Green

- A library with any number of permanently-failing dataless assets continues
  enriching everything else indefinitely.
- Retry pacing survives without holding claim-window capacity.
- The blocked/unblocked admission diagnostic is truthful during effective
  interactive demand.
- Cancellation never converts into retry-with-claim.
- Eject drain answers only for enrichment-owned work.
- No independently mutated per-state counter remains beside `claimedWork`.
- One shared milliseconds conversion and one log-field formatter serve the
  coordinator.
