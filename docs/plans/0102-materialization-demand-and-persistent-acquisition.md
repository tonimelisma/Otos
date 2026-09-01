# Plan 0102 — Materialization demand and persistent acquisition

Status: proposed. Supersedes no plan; changes ADR 0016 §2 and the materialization
half of ADR 0009, and rewrites the retry policy introduced in PR #172.

## 1. The problem, stated architecturally

Otos has no model of *"this file is wanted."* It has **attempts**. An attempt is a
bounded thing that succeeds or fails, and every layer that can observe a failed
attempt has invented its own policy about what to do next:

| policy | owner | behaviour on failure |
| --- | --- | --- |
| fail-fast `k=2` probes | `FileMaterialization` (PR #172) | abandon at ~5 s |
| provider breaker | `MaterializationCoordinator` | 60 s per-root cooldown |
| retry ledger `15/60/300/900` | `EnrichmentCoordinatorCompletion:219` | four tries, then **permanent give-up** |
| pane retry | `CatalogWindowViewModelViewMode:345` | re-request every 500 ms, unbounded |

Each is locally sensible. None can see the others. Composed, they produce the
observed behaviour: *give up at five seconds, then restart from zero, forever.*

That composition is the defect. Removing any single policy leaves the shape that
generated it, so this plan removes the shape.

## 2. Evidence

Measured 2026-08-31 on the production library.

**The failure.** 238 interactive materialization requests dispatched, 43 failed —
every one `providerUnavailable`, every one between 2402 ms and 5539 ms, none
reaching the 120 s budget it had been given. One file was requested 39 times,
another 30. Of 23 distinct files that failed at least once, **21 never decoded at
all**. Meanwhile the slowest *successful* materialization in the same window took
**62,316 ms**.

**Why the failure is invisible from inside.** `FileMaterialization.blockingProbe`
opens the file and reads one byte with a **3 s timeout**; `providerUnavailable` is
only `ETIMEDOUT`. A healthy-but-slow provider is therefore indistinguishable from a
dead one. `docs/research/2026-07-11-onedrive-materialization-fsevents.md` measured
healthy hydration on this very library at up to **8.9 s**. The threshold sits inside
the provider's normal latency distribution.

**Why the threshold exists.** PR #172 (`0ad1ebe`, 2026-08-06) added it to stop a
*background* transfer squatting `rootBackgroundCap=1` for two minutes and blocking
32 enrichment probes. Correct for background. It reaches interactive only because
`CatalogWindowViewModel.swift:302` calls
`FileMaterialization.materialize(request.id.fileURL)` and **drops `request.priority`**,
so a rule about a slot interactive work never holds governs the loupe.

**Why it became a hot loop.** ADR 0016 documents the pane's "downloading retry" as
deliberate — correct when an attempt lasted 120 s, i.e. one restart every two
minutes. PR #172 shortened an attempt ~24×, and the same 500 ms retry became a
restart every ~5.5 s. Every restart resets the poll from zero, so an image needing
62 s of patience can never accumulate more than 5.

**The decision was taken without its stated precondition.**
`docs/research/2026-08-03-post-increment-review-experiments.md` §4c named this exact
mechanism — *"a provider that answers 'no, right now' is indistinguishable from a
provider that is merely slow"* — and ruled that it *"should be decided against a
healthy-provider baseline, which does not exist yet."* PR #172 landed three days
later without one, from captures the same research proved were taken against a
provider that was **down**.

## 3. What we do not know, and how the design handles it

**Open question: are provider requests dropped under load?**

The owner's position, from operating the app: yes — `startDownloadingUbiquitousItem`
returns no acknowledgement, and a saturated provider can discard queued work. This
is the assumption this plan adopts.

A probe on 2026-08-31 (`n=5`, sequential, idle machine, warmed provider, no import
or enrichment running) had every file materialize from a single request in 1.78–6.23 s.
**That measurement is not evidence about the loaded case** and is recorded only so
nobody mistakes it for a baseline under load. The observed failures happened during
38 GB of upload with eight concurrent enrichment transfers.

The assumption is also the **safe** one. Its costs are asymmetric:

- Hammer when unnecessary → one wasted XPC round trip per second per wanted file.
- Fail to hammer when necessary → the image in front of the user never appears.

So we hammer by default. But the design keeps cadence a **measured parameter, not a
premise** (§7), because one specific way the assumption could be wrong would invert
it: if re-asserting *restarts* an in-progress transfer, hammering a large file
guarantees it never completes. The historical captures are consistent with both
readings — 114 re-requests over 120,276 ms is either persistence failing, or the
cause of the failure. Nothing in the repo distinguishes them yet. The architecture
below is unchanged either way; only the cadence knob moves.

## 4. Vision

**Materialization has one owner and one verb: *want*.**

An identity is either wanted or not. While it is wanted, `MaterializationCoordinator`
maintains a persistent **acquisition** for it: it re-asserts the provider request on
a cadence set by demand priority, watches for arrival, and does not stop. An
acquisition ends on exactly three events — bytes arrive, nothing wants it any more,
or the app shuts down.

There is no "attempt". Consumers cannot observe a failed materialization, because the
concept no longer exists at that boundary. A consumer either receives the bytes or
withdraws its own demand. This is what removes the four competing policies: three of
them exist solely to answer "what do I do about a failed attempt?", a question that
can no longer be asked.

**Hammering becomes a property of the owner, not of any caller.** Today the pane
hammers because it is the only layer that noticed nothing was happening. Under this
design the pane states demand once and the coordinator does the hammering — at a
cadence appropriate to *why* the file is wanted, which only the coordinator knows.

## 5. Design

### 5.1 Demand — **not built, and here is why**

The registry below was designed before stage 1 existed. Its purpose was to stop consumers
from ever observing a failed attempt. Stage 1 achieves exactly that by simpler means: an
interactive `materialize` does not return until the bytes arrive or the request is
cancelled, so there is no failure to observe and nothing for a consumer to decide about.

Building a per-identity state machine plus subscription lifecycle to reach a property the
call already has would be speculative machinery, which this repo's standards rule out.
Stage 2 therefore deleted the pane's retry and collapsed `PreviewImageLoader.Outcome` to
two cases instead. The design below is retained as the shape to grow into *if* a second
consumer ever needs to observe materialization state independently of asking for it.

```
MaterializationCoordinator
  demand: [MediaAssetID: DemandSet]     // who wants it, at what priority
  acquisitions: [MediaAssetID: Acquisition]
```

`want(id, priority) -> DemandToken` and `withdraw(token)`. A token is scoped to a
consumer (a pane slot, an enrichment claim). The highest live priority for an
identity is its acquisition's priority; withdrawing the last token ends the
acquisition.

Consumers await arrival through an `AsyncStream` of state for that identity, or a
continuation resumed on arrival. They never receive `providerUnavailable`,
`timedOut`, or `.downloading`.

### 5.2 Acquisition

One per wanted identity. Its loop:

1. `startDownloadingUbiquitousItem(url)` — the request. Failure to *issue* is logged
   and retried; it is never terminal.
2. Poll `SF_DATALESS` at 250 ms (unchanged — cheap `lstat`, no byte read).
3. Re-assert the request every `cadence(priority)`.
4. On clear → resume waiters, end acquisition.
5. On withdrawal → end acquisition. The provider download continues; we stop watching.
   Nothing is lost: the next `want` finds it materialized or resumes watching.

**No probe.** The 1-byte blocking read is deleted outright. It was the sole source of
`providerUnavailable`, it cost a thread and up to 3 s per re-request, and its only
consumer was the fail-fast. Arrival is `SF_DATALESS` clearing — the fact we actually
care about — not our guess at provider health.

**No deadline for interactive.** Bounded by demand, not by a clock. This is safe only
because withdrawal is now explicit and reference-counted; today's 120 s timeout is
the only thing preventing an orphaned poll, and §5.1 replaces it with something
better.

### 5.3 Cadence tiers

| priority | re-assert | concurrency | rationale |
| --- | --- | --- | --- |
| interactive | **500 ms, forever** | unbounded (bounded in practice by panes: ≤3) | the only thing the user is looking at; cost is one syscall |
| device | 1 s | 1 (transport limit, ImageCaptureCore serial queue) | unchanged |
| background | 5 s | 1 per root | must never crowd interactive |

Cadence lives with the coordinator because it depends on *why* the file is wanted.
`FileMaterialization` becomes a pure mechanism — status, request, poll — with no
policy at all.

### 5.4 What we can and cannot guarantee

`docs/research/2026-07-14-interactive-materialization-priority.md` established that
`startDownloadingUbiquitousItem` exposes **no priority, ordering, or transfer handle**,
and `NSFileProviderManager` offers no interactive-vs-background contract either.
Therefore:

- **We can guarantee** Otos adds no competing demand while an interactive acquisition
  is live: background acquisitions for that root stop re-asserting and stop polling.
  This closes a real gap — today an already-in-flight background transfer keeps
  running and is only prevented from *starting*.
- **We cannot guarantee** the provider prioritises our file. OneDrive is also
  uploading, and we have no handle on any of it. Any claim of provider-side
  reprioritisation would be fabricated.

The requirement text must say the first and must not imply the second.

### 5.5 Deletions

- `FileMaterialization.blockingProbe`, `probeProviderLiveness`, `probeResult`,
  `probeQueue`, `probeTimeout`, `FileMaterializationProbeResult`,
  `MaterializationOutcome.providerUnavailable`, and the `consecutiveProviderUnavailable`
  short-circuit.
- `CatalogWindowViewModelViewMode`'s 500 ms retry task and `downloadingSlots`
  insert-on-`.downloading` path.
- `PreviewImageLoader.Outcome.downloading`.
- ~~The enrichment retry ledger's permanent give-up.~~ **Withdrawn — the premise was
  wrong.** `retryWorkIfNeeded` returning `nil` after `[15, 60, 300, 900]` is not
  abandonment: it releases the *claim-window* slot and hands pacing to `retryLedger`,
  which `scheduleRetryLedgerSignal` re-wakes at `notBefore` with no cap. Enrichment
  therefore already retries a wanted file every 15 minutes indefinitely. Removing the
  bound would have made one failing file hold a claim slot forever and starve the other
  31 — trading a bug that does not exist for real starvation.
- The provider breaker is **kept** but demoted: it paces background acquisition
  cadence and reports provider health. It must never gate interactive (it already
  does not).

## 6. What changes, file by file

1. **`Otos/Services/FileMaterialization.swift`** — becomes mechanism only: `status`,
   `requestMaterialization`, and a poll that reports arrival. All policy removed.
2. **`Otos/Services/MaterializationCoordinator.swift`** — gains `demand`,
   `acquisitions`, `want`/`withdraw`, the acquisition loop and cadence tiers.
   Admission keeps its byte/video/global caps; the per-root background cap becomes a
   cadence rule rather than an admission rejection.
3. **`Otos/ViewModels/CatalogWindowViewModel.swift:302`** — executor passes priority
   through; device roots unchanged.
4. **`Otos/Services/PreviewImageLoader.swift`** — `decode` states demand and awaits
   arrival; two outcomes remain, `.image` and `.unavailable` (the latter only for
   `lstat` failure, i.e. genuine absence).
5. **`Otos/ViewModels/CatalogWindowViewModelViewMode.swift`** — withdraws demand on
   focus change; retry task deleted. The spinner is driven by "demand outstanding",
   not by a failed attempt.
6. **`Otos/Services/EnrichmentCoordinatorCompletion.swift`** — ledger no longer
   terminal.
7. **`Otos/Services/VideoPreviewLoader.swift`** — same demand API (it currently
   duplicates a second, slightly different downloading state machine; see
   `2026-08-07-mainactor-gravity-and-smells-research.md` §4.3).

## 7. Verification

**Deterministic oracle (must be red before, green after).** `FileMaterializationProviders`
already injects `status`/`request`. An interactive acquisition whose status flips to
`.materialized` at t=60 s must deliver the image. Today this fails at ~5 s.

**Negative controls.** Re-introduce the fail-fast → oracle red again. Remove
withdrawal → orphaned-acquisition test red. Neither should pass by accident.

**Loaded-provider measurement — the missing baseline.** Run under conditions matching
the failure: an active import plus saturated enrichment. Two arms on ≥50 large files
each, interleaved: (A) re-assert at 500 ms, (B) request once and watch. Report the
time-to-materialize distribution and the completion rate.

- If A ≥ B → hammering is free or helps; ship 500 ms and record the evidence.
- If A < B → re-asserting resets the transfer. Cadence drops to once-then-watch; the
  architecture is unchanged.

This is the experiment `2026-08-03` asked for and never got. Its result is recorded
in `docs/research/` regardless of which way it goes.

**Progress instrumentation.** Log `st_blocks` growth per acquisition. If a hydrating
File Provider file shows blocks climbing, we get free progress and can finally
distinguish "slow" from "stalled" without adopting `NSFileProviderManager` — the
fact whose absence caused #172's misdiagnosis. If blocks stay 0 until atomic
completion, record that and stop looking.

## 8. Risks

- **Re-assert may reset the transfer** (§3). Mitigated by making cadence a measured
  parameter and by the loaded-provider experiment being a gate on the cadence choice,
  not on the merge.
- **Unbounded interactive acquisition** depends entirely on correct withdrawal. Every
  consumer path — focus change, view-mode switch, window close, shutdown — needs a
  test. This is the highest-risk part of the change.
- **Scope.** This touches the coordinator, the loader, two ViewModel extensions, and
  enrichment completion. It cannot be a small diff and should not pretend to be. It
  is staged in §9 so each stage is independently green.
- **Single-environment evidence.** Every measurement comes from one OneDrive account
  on one Mac, currently at 17 GB free — which is itself why files are being evacuated
  (300 of 999 just-imported originals, 11.5 GB, verified via `SF_DATALESS`). Behaviour
  on a healthy-disk machine or another provider is unmeasured.

## 9. Staging

1. **Mechanism split** — strip policy from `FileMaterialization`, plumb priority.
   Existing tests stay green unmodified by passing background policy. Oracle added, red.
2. **Pane retry deleted**, spinner driven by an outstanding request rather than a failed
   attempt, `Outcome.downloading` removed. Demand registry not built (§5.1).
3. ~~Enrichment onto demand; ledger give-up removed.~~ **Withdrawn** (§5.5): the ledger
   already retries indefinitely, and the breaker's interactive exemption is already correct.
4. **Loaded-provider experiment**, cadence fixed by its result, research file written.
   Partly done: `research/2026-09-01-onedrive-hydration-shape-and-latency.md` records the
   healthy-provider baseline, atomic hydration, and that re-asserting does not restart a
   transfer. The remaining arm is the same comparison **under load**.
5. **Docs** — ADR 0016 §2, APP-023.

Two of the five stages dissolved on contact with the code. That is the plan working: both
were written from a reading of the failure, and both were checked against the source before
being implemented rather than after.
