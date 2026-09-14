# ADR 0027: Destination Free Space Is Measured Only At The Attempt

- Status: Accepted
- Date: 2026-09-13

## Decision

An import never refuses to start because the whole source does not fit. It copies
entries in plan order and, before submitting each one, requires the destination
volume to keep at least the free-space floor after that entry and every entry still
in flight lands: `capacity − inFlightBytes − entryBytes ≥ FreeSpaceFloor.bytes`,
with capacity read fresh from `volumeAvailableCapacityForImportantUsage` each time.
The first entry that would breach the floor ends the run: nothing after it is
attempted, entries already in flight finish, and the run settles as **stopped** —
the same shape as a user Cancel, carrying `ImportStopReason.diskFloor(bytesFree:)`,
a real partial batch, `isFullyClean: false`, no auto-eject and no end-of-run erase
sweep. Delete-after-import of entries that landed is unchanged — each is erased
on its own settle, once proven in the library — and the entries the floor
refused, which exist nowhere but the card, are never touched. The remainder is
offered by the ordinary post-settlement re-plan.

A write that fails for space anyway (`ENOSPC` / `NSFileWriteOutOfSpaceError`) is a
per-entry `EntryFailure.outOfSpace` and stops the run the same way. It is the
backstop, not a second outcome.

Free space is never a property of a plan, never gates a control, and is never
observed on a timer. `FreeSpaceFloor.bytes` (5 GB) is one constant with one home,
used by the import executor and by device staging.

## Context

The owner clicked `Import 38 Items` on a card that could not fit and saw nothing:
the run was refused before any byte by a run-level precheck, and the refusal was
drawn for 24 ms before a speculative re-plan erased it. Four days later the card
had grown to 680 items / 54.8 GB against 37.7 GB free — both sides of the
comparison had moved, and neither move was observable from inside Otos.

The research behind this decision
(`docs/research/2026-09-09-destination-free-space-and-import-failure-recovery.md`)
established three platform facts:

1. macOS offers no notification for free space crossing an app-defined threshold.
   `diskspaced` fires at system thresholds; `NSBundleResourceRequestLowDiskSpace` is
   On-Demand-Resources-specific; FSEvents carries no capacity. Sampling is the only
   mechanism that exists.
2. The capacity figure is not authoritative at the instant it is read: it is
   CacheDelete's cached calculation, documented reporting 100 GB available while a
   copy was refused, and macOS returns `ENOSPC` while `deleted` is purging.
3. Prior art (Lightroom Classic) does not predict; it advises, guards at the
   attempt, and reports a partial outcome mid-run.

The owner's decision on 2026-09-13 followed: import as much as fits, stop at a
floor, make the stop a designed and resumable outcome.

## Rejected alternatives

- **A run-level precheck that refuses when the whole plan does not fit.** Forbidden
  by the rule, and it could refuse falsely (finding 2) with no override.
- **Sampling free space on a timer, or a free-space service.** Freshness cannot
  become a guarantee — the disk can change between the last sample and the write —
  so it buys nothing reliable while adding an owner, a lifetime and a cadence.
- **Free space on `MediaOperationPlanTotals`.** The plan describes one destination
  folder and revises on namespace/naming changes; free space is a whole-volume fact
  with an unrelated change rate. A sample riding the plan cadence is freshest when
  it does not matter and stalest when it does.
- **A blocking "won't fit" Ready variant.** A gate raised from an unobservable,
  unreliable number can never be cleared truthfully.
- **Skipping a non-fitting entry and continuing with smaller ones.** Produces a
  size-selected scatter instead of a contiguous prefix in plan order; "the first N
  were imported" is what the bar counts and what the user can reason about.
- **Stopping only on `ENOSPC`.** Leaves the volume at zero, where macOS itself
  starts failing ordinary operations (~135 MB) and warns the user (~1 GB).
- **Treating the floor stop as a failure (state G).** Nothing went wrong that
  `Try Again` could fix; the run did what it was designed to do. Cancel already has
  the right shape: partial batch, never clean, remainder re-planned.

## Consequences

- No forecast is ever shown, so partial completion must be honest: the Stopped bar
  states the run's own `copied of planned` and names the floor as the cause.
- Every stop is resumable by construction: the plan is rebuilt from the filesystem
  and already yields `skipCount` for what landed, so the next Import copies only the
  remainder. The cost of having no forecast is bounded and recoverable, which is
  why no forecast is needed.
- With `workerCount = 8`, the floor check must count in-flight bytes; a check that
  looks only at the next entry can overshoot the floor by eight items.
- The figure's unreliability is now in the conservative direction only: a stale-low
  capacity stops a little early, and the remainder is offered again; a stale-high
  one is caught by the `ENOSPC` backstop one entry later.
- Device staging keeps the same promise with the same constant; its previous 10 GB
  floor and the precheck's 64 MB headroom are gone.
- Ready carries one line of advice when the plan's bytes plus the floor exceed the
  destination's reported available capacity — `Not everything will fit yet ·
  37.7 GB available` — sampled by the coordinator on each Ready publish with the
  same reader the floor uses. It is two measured values and this rule, not a
  forecast; it gates nothing and the act stays the whole plan (owner decision,
  2026-09-13).
