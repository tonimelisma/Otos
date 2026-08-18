# ADR 0024: Import Source Readiness Gate

## Status

Accepted. Implemented in `Otos/Services/ImportSourceReadiness.swift` and
`MediaOperationCoordinator` (`readyState(for:ctx:)`, `beginExecutionIfPossible`).
Increment 6 (plan 0095) extends this ADR with the single presentation-writer
rule referenced below; that section is not yet written.

## Context

`MediaOperationCoordinator` builds an import plan for an attached source the
moment its catalog root becomes `.available`, reading whatever rows the
catalog currently holds. For a filesystem-backed removable volume this is
almost always fine — a full-root scan is fast and the catalog already reflects
the true directory listing by the time anyone looks. For an MTP camera it is
not: `ImageCaptureCore` enumeration can take 15+ seconds, and the catalog
holds rows from the *previous* session at the same device path (ADR 0008: a
detached device's rows persist until proven deleted). Plan 0095 D1 traced a
production run where the plan reached `.ready` 259ms after attach — 14.7
seconds before enumeration produced a single live row — so the bar offered
Import against a plan built entirely from stale data, and every copy attempt
failed `staleSource`.

The plan already carries the two facts needed to answer "is this trustworthy
yet": `CatalogLibraryState.availability` (is the root reachable at all) and
`.activity` (`.idle` / `.scanning` / `.enumerating`). Nothing derived from them
existed to gate the *offer* — the coordinator conflated "a plan was built" with
"the plan reflects reality."

## MECE Decision Scope

**This ADR owns:**

- The pure readiness classification (`ImportSourceReadiness`) and its
  precedence: unreachable beats preparing beats ready.
- Where the readiness check applies: gating the `.ready` presentation state
  and gating execution start (`beginExecutionIfPossible`). It does not gate
  session creation or plan building — those stay eager, matching ADR 0019's
  attach-to-ready latency goal; only the *offer* is withheld.
- The empty-card proof (`!session.isDirty`) that closes the residual race
  where readiness and a fresh occupancy bump land in the same beat.

**References but does not own:**

- Occupancy revision bumping and the planning-change stream that wakes the
  coordinator — plan 0095 increment 3 / this ADR's sibling fix for D2.
- Device enumeration and `ICCameraFile` date derivation — `CameraSourceMonitor.swift`.
- Import plan namespace resolution and build ownership — ADR 0019.
- Cross-plan destination reservation — ADR 0021.

**Related, not owned here (increment 6):**

- `MediaOperationCoordinator` currently has two presentation-construction
  paths: `presentation(for:)` (the polled, always-correct derivation from
  `session.phase`) and `markExecutionUnavailable`'s one-shot stream yield of
  `.executionUnavailable`, which `presentation(for:)` cannot reproduce (it
  re-derives `.failed` from the phase that call also sets). This ADR's
  readiness gate does not touch that split; increment 6 is expected to
  collapse it to one writer and will extend this document.

## Decision

**A pure three-case enum, evaluated at presentation-construction time from
facts the session already carries — no new coordinator state, no streaming
partial counts.**

```swift
enum ImportSourceReadiness { case preparing, ready, unreachable }
```

`.preparing` while `.scanning`/`.enumerating`; `.unreachable` while
unavailable/unknown; `.ready` only once the root is available and idle. Owner
decision, 2026-08-17: gate, not stream. While a source is still being read,
the bar holds state A ("Checking the camera…"/"Checking the card…") with
Import disabled; it never shows a partial or growing count that might still
change once enumeration finishes.

Two call sites:

1. `readyState(for:ctx:)` — the `.ready(ctx)` branch of `presentation(for:)`
   returns `.inventory` instead of `.ready(...)` unless readiness is `.ready`,
   regardless of what the internally-built plan already contains. The plan
   still builds eagerly and immediately (ADR 0019 is unchanged); only what
   gets *shown* is withheld.
2. `beginExecutionIfPossible` refuses to start execution unless readiness is
   `.ready`, logging `op=import.execute phase=deferred reason=sourceNotReady`.
   `importRequested` stays set, so the next occupancy-driven rebuild (D2's
   fix, increment 3) or the catalog-change refresh that observes activity
   flip idle retries the same request — `refreshSources` gained a matching
   retry call for the case where readiness turns `.ready` without an
   occupancy change of its own (idle-flip alone).

### The empty-card proof

Readiness turning `.ready` and a fresh occupancy bump can land in the same
scheduling beat, before the session's own plan has rebuilt against the new
occupancy. For a **non-empty** plan this is harmless — the numbers are simply
one beat stale and the next rebuild corrects them visibly. For the **empty**
case it is not: showing "This card is empty" for even one frame is a
fabricated proof of absence (exactly D1's failure shape). The fix checks
`!session.isDirty` — the coordinator's own accounting of whether it owes a
rebuild against a staleness signal it has already received — rather than
comparing `lastSeenOccupancy` against the plan's `sourceOccupancyRevision`
directly. The first implementation used that direct comparison and failed
under test load: a source whose inventory never changes again after settling
(an empty card that never gains a file) never earns a *further* occupancy
bump to reconcile two independently-sampled values, so an equality check
between them can permanently disagree with no future event able to fix it.
The dirty bit has no such failure mode — it is cleared by the same rebuild
that would fire regardless.

## Alternatives Considered

### A. Stream partial/growing totals while enumerating

Pros: the user sees progress instead of a blank "Checking…" state.

Cons: a growing count is itself an unproven claim — the whole point of D1 is
that a partial catalog snapshot cannot be trusted enough to show.

Failure modes: the exact bug this ADR fixes, just with a number attached
instead of a static plan.

**Rejected — explicit owner decision, 2026-08-17.**

### B. Compare live occupancy against the plan's snapshot occupancy directly

Pros: no new coordinator concept: `store.occupancyRevision(for:)` is already
read elsewhere.

Cons: for a source whose occupancy stops changing after it settles, this
comparison has no future event able to correct a stale mismatch — a
permanent-stall failure mode, confirmed empirically (§Decision).

**Rejected**, replaced by the `!session.isDirty` check.

### C. Gate session/plan creation itself, not just the offer

Pros: conceptually simpler — nothing exists until it's trustworthy.

Cons: throws away ADR 0019's attach-to-ready latency (the plan is what
*proves* the count once readiness clears; building it late means an extra
full round trip after enumeration finishes, adding visible delay for no
correctness benefit — nothing about D1 required the plan itself to be late,
only the *display* of it).

**Rejected.**

## Consequences

**Easier:** "is this safe to show" is one pure function call at the one place
that renders state, not scattered `activity ==` checks. Adversarial testing
of the gate needs no real filesystem — `CatalogLibraryState` fixtures suffice.

**Harder:** a queued Import request now has two independent retry paths
(occupancy-driven rebuild, idle-flip catalog-change refresh) instead of one,
because readiness can turn `.ready` without occupancy changing. Both are
covered by `MediaOperationCoordinatorAdversarialTests`.

**Constrained:** the gate must stay a presentation-time check, never session
state — a `SourceSession.isReady` field would be a second, driftable copy of
what `session.root` (refreshed every `refreshSources`) already answers.

**Verification.** `ImportSourceReadinessTests` covers all six
availability/activity combinations. `MediaOperationCoordinatorAdversarialTests
.importIsRefusedWhileDeviceIsStillEnumerating` proves a plan already built
from a live batch stays hidden and Import stays refused while a device is
still enumerating, then resolves once enumeration completes.
`ImportBarPresentationTests.preparingWordingIsCameraForDeviceMTPAndCardForRemovableVolume`
proves the mapper's camera/card wording split.

## Retirement Proof

Additive to ADR 0019 and ADR 0021; nothing in either is retired. No prior
mechanism performed this classification — there is nothing to remove.

## Living Documentation Impact

- `docs/requirements.md` — ARC-047 updated to describe the readiness
  precondition on `.ready`.
- `docs/index.md` — this ADR added to the table.

## Reversal Plan

If the gate proves too conservative in practice (e.g. a source kind whose
`.scanning` activity never reliably reaches `.idle`), the reversal is
localized: delete the two `ImportSourceReadiness.evaluate` call sites and the
`readyState` wrapper, restoring the unconditional `.ready(...)` construction.
`ImportSourceReadiness` itself and its tests can stay dead code briefly or be
deleted in the same change — nothing else depends on the type.
