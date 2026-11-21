# ADR 0021: Concurrent Import Planning And Destination Name Reservation

## Status

Accepted. Implemented in `MediaOperationCoordinator` (`ImportSessionMachine`'s `SourceSession`, `ImportExecuting`, `ImportPlanBuilder`) and `MediaTransferPlanner`.
Invariants R1–R5 are proven by adversarial coordinator tests — see Consequences → *Verification*.

## Context

Otos plans an import for **every attached removable source at once**, eagerly on
attach, so a card's plan is ready the moment the user selects it. Several cards may
therefore hold a `.ready` plan into the *same* destination library at the same time,
and the user may start their imports concurrently.

ADR 0019 established how a single plan resolves destination occupancy: enumerate the
destination's folders once, and pass that namespace to a pure, `nonisolated`
`MediaTransferPlanner`. That decision assumed one plan at a time. It left one fact
unowned: `planImport`'s `reserved` set is **per plan**, so names claimed by plan A
are invisible to plan B.

The concurrency surface was audited against the code before choosing. Five candidate
conflicts exist; only two are real:

| # | Conflict | Mechanism | Outcome before this ADR |
|---|---|---|---|
| C1 | Two ready plans reserve the same destination name | `reserved` is per plan. Cards A and B both enumerate D before either executes; both see the name free; both claim it | Second publish fails `.destinationExists` → **silently not imported**, visible only in a log |
| C2 | A ready plan is stale because another import took its name | A settles → D's occupancy bumps → the planning-change stream dirties B → B replans and advances the suffix | Self-heals, *if* the rebuild finishes before the user presses Import on B; otherwise degrades to C1 |
| C3 | Two executions interleave in the same folder | Staging names are UUID-based, so staging never collides; publication is exclusive | Safe. Reduces to C1 |
| C4 | Replan storm | Every per-entry settlement bumps D's occupancy and dirties every source mapped to D; the existing guard covered only the *executing* source | B and C re-enumerate D's namespace continuously throughout A's import |
| C5 | Catalog/filesystem skew | `reserved` seeds from catalog occupants while candidate decisions consult the live namespace | Belt and braces; not a cross-plan issue |

**C1 is the correctness gap. C4 is the performance gap.** C2, C3 and C5 were already
handled by existing mechanisms.

C1 matters because its failure is silent and destructive of user intent: the user sees
a card reach *Ready* with N new items, presses Import, and some of those items never
arrive — with no surface saying so.

## MECE Decision Scope

**This ADR owns:**

- Cross-plan reservation of destination names (the ledger).
- Whether concurrent planning into one destination is serialized, deduplicated, or
  left parallel.
- Suppression and coalescing of destination-driven rebuilds during execution (C4).
- The reporting backstop for names lost to a race despite the ledger.

**References but does not own:**

- Namespace enumeration mechanics and off-actor build ownership — ADR 0019.
- Import execution, journaling, staging, and exclusive publication — ADR 0017.
- Removable/device source identity and detach semantics — ADR 0013.
- Filesystem-as-truth and overlay lifecycle — ADR 0008.

**Related, not owned here:**

- How a destination is *chosen* for a source — the three-step default of saved
  device-identity mapping → last-used → **first-added** available fixed library. That is
  a product rule owned by ARC-047, not an architectural decision. The third step was corrected from alphabetical to first-added order in #186
  and is verified by destination-precedence tests in `OtosTests/MediaOperationCoordinatorTests.swift`.

## Decision

**One in-memory reservation ledger per destination, owned by the coordinator, plus a
reporting backstop. Planning stays parallel and each source reads the namespace
independently.**

Three parts:

### 1. The ledger (solves C1)

`claimsBySource: [LibraryRootPath: Set<MediaRelativePath>]` — for each source with a
live (ready or executing) plan, the set of final destination names that plan claims,
including companions. Unioned on demand per destination.

`planImport` already accepted `reserved` as an in-out set, so the ledger is fed in as
`additionalReserved` at build start. This makes `reserved` mean what its name always
said: **reserved across the app, not merely within one plan.** The planner stays pure
and `nonisolated`; only the coordinator changes, because the coordinator is already
the single owner of ready plans.

Invariants, each testable without UI:

- **R1 — Claim on ready, release on death.** A claim is created when a plan reaches
  `.ready`, and released when that plan is superseded, cancelled, fails, or its source
  detaches.
- **R2 — Conversion, not release, on settlement.** When an entry settles, its name
  becomes real occupancy that the next namespace read observes. The claim is dropped
  at one point per plan death, which keeps the ledger trivially auditable: every
  published name is already on disk, every unpublished name never will be.
- **R3 — Check against the present, not the past.** The conflict check and the
  registration happen in **one synchronous on-actor region against the current
  ledger**, never against the build-start snapshot. This is the "revalidate typed
  ownership facts after every await" rule; the destination's occupancy revision is
  the existing typed fact, so no generated token is introduced.
- **R4 — A conflicting build re-plans; it never evicts.** The loser re-dirties and
  rebuilds, seeding from the now-registered claims. It never removes another source's
  registered claim.
- **R5 — Crash loses the ledger, and that is safe.** Nothing is persisted. Exclusive
  publication remains the floor, and the next plan re-reads the namespace from disk.
  The ledger is coordination state, never a second truth about the destination — when
  ledger and filesystem disagree, the filesystem wins (ADR 0008).

### 2. Parallel planning, independent reads

`MediaTransferPlanner` is already safe to run concurrently: pure, `nonisolated`,
accepts only immutable `Sendable` values, performs no I/O. N sources plan in parallel
with zero shared mutable state.

They share exactly two things. The **name space** of the destination is solved by the
ledger. The **namespace read** is deliberately *not* deduplicated: it is directory
entries plus `lstat` over a bounded folder set with no byte reads, and duplicating it
across a handful of attached cards does not justify the machinery. This is
measure-before-optimizing applied in its cheaper direction — do not build the
deduplication until something proves the simple path insufficient.

### 3. Rebuild suppression and coalescing (solves C4)

While any execution targets destination D, destination-driven rebuilds are suppressed
for every source mapped to D. Dirtiness is retained, not dropped. After the last
execution for D finishes, one rebuild is taken up per source that still owes a plan.

Suppression and flush both emit `op=import.coordinator phase=suppressRebuild` /
`phase=flushRebuild`, so the fix is provable from a log capture rather than by
inspection.

### 4. The backstop

The ledger narrows the C1 window; it does not prove it closed against a foreign writer
(another application writing into the destination between enumeration and publication).
So `.destinationExists` at publish time is **counted and surfaced** as
`skippedForeignCount` in the Done state, alongside `failedCount`, rather than living
only in a log.

## Alternatives Considered

### A. Report the collision, do not prevent it (backstop alone)

Pros:

- No new structure; executor reporting only.

Cons:

- The user must notice the Done summary and re-run the import themselves.

Failure modes:

- Silent-by-default becomes quiet-by-default: a count in a summary is a weak signal for
  "some of your photos did not copy".

**Rejected as the solution; retained as the backstop (§4).**

### B. Serialize planning per destination — only one plan ready per destination

Pros:

- Trivially correct; no ledger.

Cons:

- Defeats eager multi-source planning, whose entire purpose is that several cards are
  ready at once.

Failure modes:

- A slow build for card A blocks card B from ever showing counts, reintroducing exactly
  the attach-to-ready latency ADR 0019 was written to remove.

**Rejected.**

### C. Just-in-time naming inside the executor under a per-destination lock

Pros:

- No cross-plan state at all; names are assigned at the moment of the write.

Cons:

- Plans become intent rather than paths.

Failure modes:

- Pre-flight counts depend on skip-vs-copy classification, which depends on names, so
  the *Ready* state would lose its numbers — the one thing the four-state UX exists to
  show. Also relocates naming into the executor, splitting an owner.

**Rejected.**

### D. Deduplicate the destination namespace read across concurrent builds

Pros:

- One enumeration per destination instead of N.

Cons:

- A shared read needs an owner, an invalidation rule, and a staleness policy.

Failure modes:

- Adds a cache before any measurement showed the read was expensive.

**Rejected for now** — explicitly revisitable if `op=plan.namespace.enumerate` timings
prove the read material.

## Consequences

**Easier:** concurrent import becomes describable in one sentence — N pure plans, N
independent reads, one ledger. The silent `.destinationExists` loss is both narrowed
and, when it still happens, visible.

**Harder:** the coordinator gains one more piece of state whose lifecycle must be right
in five places (ready, supersede, cancel, fail, detach). A leaked claim is invisible in
the UI and manifests only as a plan that mysteriously renames files.

**Constrained:** the ledger must never be consulted by the executor and never
persisted. The moment either happens it becomes a second source of truth about the
destination, which ADR 0008 forbids.

**Verification (closed).** R1–R5 are proven at the coordinator owner level via 14 adversarial tests in `OtosTests/MediaOperationCoordinatorAdversarialTests.swift` plus the existing destination-precedence tests: R1 claim on ready / release on detach/cancel/failure (`claimsReleaseOnDetach`, `claimsReleaseOnCancel`, `claimsReleaseOnFailure`), R2 conversion on settlement (`settlementConversionAfterPublishBStillSuffixDueToRealFile`), R3 current-ledger check (`currentLedgerConflictRebuildsWithDisjointName`), R4 rebuild on conflict (same test), R5 crash safety via exclusive publication (ADR 0017). Stale-completion rejection is proven by `detachDuringSuspendedBuildNoPresentationAfterResume`, `rapidSamePathReattachOldBuildCannotBecomeReady`, `oldCompletionCannotClearNewTask`, `detachDuringExecutionNoRecreation`, `shutdownWaitsForSuspendedWorkAndNoLaterPublication`. Zero-copy Ready observation is proven by `zeroCopyWithoutDeleteRemainsReadyWithoutExecutor` and `zeroCopyWithDeleteExecutorRunsDeletionPath`.

## Retirement Proof

This decision extends rather than replaces ADR 0019; nothing in 0019 is retired.

Superseded by this ADR and already removed from the tree:

- `OtosKit/Services/ImportPlanDetailReader.swift` and `OtosKit/Views/ImportPlanOverlay.swift`
  — the plan-details sheet, replaced by "the grid is the plan view".
- The `.waitingForDestination` presentation state.
- The `copy · preexisting · companion · blocked · skipped packages` summary string.

Must not reappear: any persistence of the ledger, any executor read of it, any
per-destination planning queue.

## Living Documentation Impact

- `docs/requirements.md` — ARC-047 now cites the exact coordinator-level proofs for R1–R5 and stale/zero-copy cases; no `unverified:` clause remains for this decision.
- `docs/architecture.md` — the `MediaOperationCoordinator` ownership row names `SourceSession`, typed stale rejection, derived ledger claims, and rebuild suppression; destination wording is `first-added available`.
- Code comments in `MediaOperationCoordinator.swift` cite this ADR (R1–R5) and the typed `AttachmentGeneration`/`BuildGeneration` stale checks; no plan-revision references remain.
- `docs/index.md` — add this ADR to the table.

## Reversal Plan

If the ledger proves to leak claims in practice — a source whose claim outlives its
plan, renaming later imports for no reason — the cheapest reversal is to drop to
Alternative A: delete `claimsBySource`, stop passing `additionalReserved`, and keep the
`skippedForeignCount` backstop as the whole mechanism. That reversal is one deletion
plus one call-site change, because the planner never depended on the ledger existing.

If instead the *namespace read* proves expensive under several concurrent cards,
revisit Alternative D on the strength of `op=plan.namespace.enumerate` evidence. That
is an additive change and does not disturb the ledger.
