# Plan 0067 — Measurements and guards that mean what they say

## Status

Not started. Evidence captured 2026-08-04/05 against `main` at `3e94549`, from a
real import of a 1,718-file SD card into the 16,159-asset `Camera Roll` library.
Log files: `logs/run-20260805T032731Z-p3095-prod.log` plus the unified log for the
recovery session.

## Purpose

Three defects found by reading the logs of a real import. They are unrelated in
mechanism but identical in shape: **a number or a guard that does not measure what
its name and comments claim.** Each one silently misleads the next person who
reads it, which is the specific failure mode the repository's instrumentation rule
exists to prevent.

1. Two duration calculations discard whole seconds, so any operation over one
   second is reported as its sub-second remainder.
2. The import-plan staleness guard rejects on a generated counter rather than the
   ownership facts it documents, throwing away completed plans.
3. The main-thread stall monitor has never once attributed a stall, and prints
   `lastOp=none` in a way that reads as "nothing was running".

## Stage 1 — Durations that drop whole seconds

### Evidence

The resumed import batch logged:

```
op=mediaOperation.batch phase=finish batch=1785900613321 bytes=7997310606
   elapsedMs=593 files=282 mbps=13486.19 workers=8
```

8.0 GB in 593 ms is 13.5 GB/s from a USB card reader. `MediaImportExecutor.swift:186`:

```swift
let elapsedMs = max(Int(started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000), 1)
```

`Duration.components` is `(seconds, attoseconds)` where `attoseconds` is the
**sub-second remainder**. Reading it alone discards every whole second. The batch
almost certainly ran ~60.593 s, which is ~132 MB/s — an entirely ordinary figure
for that hardware, and the reason nobody noticed the number was fiction.

The same expression appears at `MediaImportExecutor.swift:536` for per-file copy
timing. Its symptom is visible in the logs as impossible orderings, for example a
worker reporting `phase=timings copyMs=1334` and then `phase=finish elapsedMs=458`
— a copy that finished in less time than its own copy step.

`DiagnosticsTiming.milliseconds(_:)` (`Otos/Support/DiagnosticsTiming.swift:12`)
already does this correctly and is used correctly at five other sites. These two
hand-roll it.

### Root cause

The correct conversion exists and is easy to bypass, because `Duration.components`
is a public API that returns a tuple whose second element looks like "the number of
tiny units" rather than "the remainder after whole seconds".

### The fix

1. Replace both expressions with `DiagnosticsTiming.milliseconds(_:)`. Note the
   existing sites also apply `max(…, 1)` to avoid dividing by zero in
   `throughputMBps`; keep that clamp at the call site, not inside the helper —
   `DiagnosticsTiming.milliseconds` already clamps at 0 and a 0 ms operation is a
   true measurement, not an error.
2. Make the mistake unrepresentable rather than merely fixed. Add a rule to
   `script/ci-text-hygiene.sh` rejecting `components.attoseconds` anywhere outside
   `Otos/Support/DiagnosticsTiming.swift`. This is a script check on source text,
   which the repository already does for hygiene; it is **not** a test asserting on
   source strings, which CLAUDE.md forbids.
3. Re-run an import and record the corrected throughput in the PR. A believable
   MB/s figure for known hardware is the acceptance evidence.

### Done when

- `grep -rn "components.attoseconds" Otos/` returns hits only in `DiagnosticsTiming.swift`.
- `script/ci-text-hygiene.sh check` fails if you reintroduce the pattern elsewhere.
  Verify by adding it temporarily, running, and removing it.
- A real import logs an `mbps` value consistent with the source device, and
  `elapsedMs` at `phase=finish` is never smaller than the `copyMs` reported by the
  same worker's `phase=timings` line.

### Note for whoever fixes this

Every number this bug touched is in the repository's logs and possibly in past PR
evidence. Do not go back and rewrite history, but do not trust a pre-fix `mbps` or
`elapsedMs` from `mediaOperation.*` for anything.

## Stage 2 — The staleness guard rejects on a generated token

### Evidence

```
op=import.plan phase=stale
   sourceOccupancy=1       snapshotSourceOccupancy=1
   destinationOccupancy=0  snapshotDestinationOccupancy=0
```

All four values match, twice in one session. The occupancy revalidation passed, so
the only clause that could have rejected the finished plan is the third
(`MediaOperationCoordinator.swift`, in `buildPlan`):

```swift
guard sourceOccupancy == snapshot.sourceOccupancyRevision,
      destinationOccupancy == snapshot.destinationOccupancyRevision,
      generation == planGeneration || dirty.contains(source) == false
else { … discard, re-dirty, rebuild … }
```

A completed enumerate-and-plan — ~490 ms against the real library — was discarded
and redone because a counter moved. The comment directly above that guard says
staleness is keyed on occupancy precisely so unrelated churn cannot cause this.

### Root cause

`planGeneration` is one counter doing three unrelated jobs:

| Job | Where | Needs a counter? |
| --- | --- | --- |
| identity of a **published** plan, so `ImportPlanDetailReader` can refuse to serve dispositions for a plan the footer is no longer showing (`ImportPlanDetailReader.swift:25`) | `snapshot.generation` → `plan.generation` | yes — this is its real purpose |
| "has a newer build been scheduled" | `scheduleBuildIfNeeded` | no |
| "has Import been queued" | `queueImport` (`:153`) | no |

Because `queueImport` bumps the same counter, **pressing Import while a plan is
building invalidates that build** — which is exactly what happened here. The user
pressed Import, the in-flight plan was thrown away, and planning started over.

Two supporting facts:

- `MediaImportExecutor` contains no reference to `generation` at all. The plan
  generation gates nothing in execution; it is purely the detail-reader's token.
- `queuedStart` is declared `[LibraryRootPath: UInt64]` but its **value is never
  read** — only `queuedStart[source] != nil`. It is a set wearing a dictionary.

### The fix

The guard needs to answer one question after the off-actor suspension: *is the plan
I just built still a plan for the thing I was asked to plan?* That is answered by
domain facts, not by a token — and CLAUDE.md says so explicitly: "revalidate the
operation's current typed ownership facts after every await… Prefer existing
domain/persistence identity over a generated token."

1. Replace the third clause with the typed ownership fact it was standing in for:

   ```swift
   destinationBySource[source] == destination
   ```

   This catches the case that actually matters and that occupancy revisions cannot
   see: the user re-mapped the source to a different destination while the build
   was in flight, so the finished plan targets the wrong library. Do not skip this
   — deleting the third clause outright would let a stale-destination plan publish.

2. Stop `queueImport` from bumping `planGeneration`. Change `queuedStart` to
   `Set<LibraryRootPath>`. Pressing Import is not a planning event.

3. Leave `planGeneration` as the published-plan identity, incremented only in
   `scheduleBuildIfNeeded`. Update its declaration comment to say that is its only
   job, and that `ImportPlanDetailReader` is its only consumer.

4. Extend the `phase=stale` line to carry the fact that decided it —
   `mappedDestination` alongside the four occupancy values. Today the line logs the
   occupancy values only, so when it fired with all four matching, the deciding
   clause had to be *inferred*. A diagnostic that cannot say why it fired is half a
   diagnostic; this one is new in `bdd31e4` and should have carried its inputs from
   the start.

### Done when

- Queueing an Import while a plan is building publishes that plan and executes it,
  with no `phase=stale` line and no second build. Verify against the real card:
  attach, press Import while the footer still reads Planning, and check the log.
- Re-mapping the destination mid-build produces exactly one `phase=stale` line
  naming the changed mapping, followed by one rebuild against the new destination.
- `grep -n "planGeneration" Otos/Services/MediaOperationCoordinator.swift` shows it
  incremented in one place only.
- Existing `MediaOperationCoordinatorTests` pass unmodified except where they
  construct `queuedStart`.

Add a test for the re-map case. It is deterministic — `setDestination` is an owner
intent and needs no timing — and it is the invariant the third clause exists for,
which nothing currently covers.

## Stage 3 — A stall monitor that has never attributed a stall

### Evidence

Five main-thread stalls across every captured session, worst **553 ms** against a
100 ms threshold. All five:

```
op=mainThreadStall lastOp=none …
```

Five out of five, at Fault level. The contexts were app startup and the removable
card's availability change on eject.

### Root cause

Two independent reasons, both structural (`Otos/Support/UIJankDiagnostics.swift`):

1. **The timer cannot fire during the stall it is measuring.** `recordStall` runs
   from a `Timer` on the main run loop, so it necessarily runs *after* the run loop
   is free again. `operationStack.last` — the `currentOperation` field — is only
   non-nil if the stalling work is somehow still in flight, which for a synchronous
   bracketed operation it never is. The primary attribution source is
   near-permanently nil by construction.
2. **The fallback discards anything below a threshold.** `endOperation` (`:124`)
   only retains `lastLongOperation` when `durationMs >= longOperationThresholdMs`,
   so a 90 ms `applyStructure` immediately followed by a 112 ms stall reports
   nothing at all.

And only four sites are bracketed — `CatalogWindowViewModel.applyState`,
`MediaGridViewController.layoutInstall`, `.reconfigureVisibleItems`,
`.applyStructure` — all in the grid apply path. The observed stalls happen at
startup and at availability change, which no bracket covers.

`lastOp=none` is then printed as if it were a finding. It is not: it means the
monitor cannot see. A field that always says `none` is worse than an absent field,
because it reads like an answer.

### The fix

Accept what the mechanism can and cannot do, and make the log say exactly that.

1. **Keep `lastLongOperation` regardless of duration.** Delete the threshold filter
   in `endOperation` and always record the last completed bracketed operation with
   its duration. The threshold's job — not spamming — is already done by the fact
   that this is only read when a stall fires.
2. **Rename the field.** `lastOp` → `bracketedOp`, and its empty value from `none`
   to `unattributed`. The renamed field states a fact ("no bracketed operation was
   in flight or recently completed") instead of implying a cause. Keep
   `currentOperation` / `lastLongOperation` detail fields as they are; they are
   accurate when present.
3. **Bracket the two main-actor entry points the evidence implicates**, and only
   those: the window-attach/`start()` path in `OtosApp`, and the availability-change
   apply path that runs on eject. Do not bracket speculatively — a bracket that
   never explains a stall is the sprawl this stage is cleaning up.
4. **Say where attribution actually comes from.** Add to the `UIJankDiagnostics`
   file guide: this monitor *flags* a stall with the state around it; naming the
   code that stalled is `script/profile.sh` with Time Profiler. That is the
   repository's documented division of labour and it should not be implied
   otherwise by a field name.

### Done when

- A startup run produces a stall line naming a bracketed operation, or
  `bracketedOp=unattributed` with a Time Profiler trace attached to the PR showing
  what actually ran. **Either outcome is acceptable; a third `none` with no
  investigation is not.**
- `grep -rn "beginOperation" Otos/` shows six sites, and each one is named in the
  PR with the stall it explains.
- The 553 ms startup stall is either explained or recorded in the PR as an
  accepted, understood cost with its profile.

### What this stage does not promise

It does not fix the stalls. It makes them attributable. Whether the 553 ms startup
stall is then worth optimising is a separate decision that needs the profile this
stage produces — and per CLAUDE.md, no optimisation happens before that
measurement exists.

## Sequencing

Stage 1 first and alone: it is small, self-contained, and every other performance
number in the repository depends on durations being real. Stages 2 and 3 are
independent of each other and of Stage 1.

Separate PRs. Stage 2 touches import correctness and deserves its own review.

## Requirements, ADRs, and docs

- `docs/requirements.md`: ARC-047's row covers plan-build ownership and will need
  its staleness wording adjusted by Stage 2 — the guard's deciding facts become
  occupancy plus destination mapping. Stages 1 and 3 are instrumentation and add no
  rows.
- `docs/adr/0019-import-plan-namespace-and-build-ownership.md`: Stage 2 changes a
  decision that ADR records. Amend its "Decision" section; do not append a
  changelog entry.
- `docs/adr/0015-observability.md`: Stage 3 should record what the stall monitor
  can and cannot attribute, so the next person does not re-derive it from the
  source.
- Delete this plan file when all three stages have landed.
