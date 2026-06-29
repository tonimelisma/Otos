# Spec: Scan Date Freshness, Selective-Sync Contract, And PR-Comment Process

## Classification

- Work type: Bug fix (in-memory staleness) + documentation/contract correction +
  process/tooling (PR-review-comment handling)
- Current requirement IDs: amends FND-056, FND-062; adds FND-064, FND-065
- Future idea or candidate links explicitly requested by the user: none
- ADRs: none new; amends ADR 0008 (corrects an over-claim to match its own
  Consequences and Alternatives)

## Problem

Two unaddressed reviewer findings on recently merged PRs, plus a standing-process
gap the user asked to close:

1. **Stale in-memory dates (PR #14, `CatalogStore.swift`).** The no-op-scan
   notification suppression added in spec 0017 gated the in-memory upsert in
   `applyScannedBatchToMemory` on name/type/size. When a re-scan re-observes a file
   whose name, content type, and size are unchanged but whose `createdAt` or
   `contentModifiedAt` changed (a timestamp-only touch, or a same-size content
   edit), the new dates were upserted into SQLite by `recordScannedBatch` but the
   in-memory `MediaAsset` was not replaced. `currentSnapshot()` reads the in-memory
   map, so it served stale date facts until the next launch reload. The filesystem
   is the source of truth, so the in-memory projection must reflect it.

2. **Selective-sync over-claim (PR #13, ADR 0008).** ADR 0008's Decision clause 4
   listed a user-excluded selective-sync subtree as a current never-purge case.
   `reconcileMissingAssets` deletes `existingPaths.subtracting(observedPaths)` after
   a completed scan of a reachable root, and a selective-sync-excluded subtree
   inside that reachable root enumerates without its paths, so the implementation
   cannot distinguish it from a real deletion and purges it. The Decision therefore
   promised preservation the code does not deliver, contradicting the ADR's own
   Consequences and Alternatives sections, which already flag it as an unsolved
   edge case.

3. **No process for prior-PR comments.** Nothing required an increment to pick up,
   claim, fix, and answer review comments left on earlier PRs, so actionable
   findings (1) and (2) sat unaddressed across four later increments.

## Scope

In scope:

- Always mirror the freshly scanned filesystem facts (including dates) into the
  in-memory catalog, so `currentSnapshot()` is never stale, while keeping the
  FND-062 notification suppression gated on the exactly comparable facts.
- Correct the selective-sync over-claim in ADR 0008, AGENTS.md, and the FND-056
  acceptance so the authoritative contract matches the implementation, reframing
  selective-sync preservation as a forward invariant for the future authored-overlay
  detector rather than a current guarantee.
- Add the PR-review-comment handling rule to AGENTS.md (workflow + DoD) and capture
  it as FND-065.

Out of scope (deferred, with rationale):

- A selective-sync exclusion detector. It is provider-specific and only matters once
  user-authored, non-rebuildable overlay exists (ADR 0008 reversal plan). Today
  purge is lossless, so there is no data-loss bug to fix in code.
- Date-aware sort and scope. (Date *display* arrived with enrichment: the tile shows
  the capture date, which falls back to the filesystem dates — ENR-003. As this spec
  anticipated, that made the notification policy revisit-worthy, so spec 0022 extended
  FND-062's suppression key to include the `createdAt`/`contentModifiedAt` dates at
  whole-second resolution, waking the pipeline on a real date change. Date-aware
  sorting and scoping remain unbuilt.)

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected (the two findings, the reconcile path, the
      sort-key derivation, the SQLite `Double`-seconds date storage).
- [x] Captured user guidance is restated as precise requirements (FND-064, FND-065)
      and contract corrections (FND-056, ADR 0008).
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas (detector, date sort) are kept out of `docs/requirements.md`.
- [x] Ownership, side effects, persistence, cancellation, privacy, and tests are
      addressed.
- [x] At least three alternatives are compared for the in-memory fix.
- [x] Retirement proof is defined (nothing retired; an over-claim is corrected).
- [x] A repository-wide stale-document audit is defined.
- [x] A code-comment accuracy audit is defined.
- [x] Performance consideration is named (off-main reconstruction cost).

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-064 | Architecture | The in-memory catalog always mirrors the latest scanned filesystem facts, including dates, so `currentSnapshot()` never serves stale facts after a completed re-observation, independent of FND-062 notification suppression. | Current | docs/requirements.md, this spec |
| FND-065 | Process | Each increment reviews unresolved review comments on recent PRs, claims by reply the actionable findings it will fix, fixes them in the increment, and replies with how each was fixed (or why not applicable). | Current | docs/requirements.md, AGENTS.md, this spec |
| FND-056 (amended) | Architecture | The overlay-lifecycle acceptance now states which absences are actually protected and marks a user-excluded selective-sync subtree as a documented forward edge case, not a current guarantee. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-062 (amended) | Non-functional | The suppression requirement now notes the in-memory catalog is still refreshed (cross-links FND-064). | Current | docs/requirements.md |

## Architectural Alternatives (in-memory date refresh)

### Alternative A (selected): Always refresh memory; gate notification on comparable facts

`applyScannedBatchToMemory` unconditionally replaces the in-memory `MediaAsset` with
the freshly scanned values and returns whether a user-visible change (new file, or
name/type/size change) occurred; `recordScannedBatch` notifies only on that flag.

Pros:

- One clear invariant: in-memory state equals the latest scan. Correct by
  construction, no date comparison needed.
- Preserves FND-062 exactly: notification is still gated on the exactly comparable
  facts, so the SQLite `Double`-seconds round-trip epsilon cannot defeat suppression.

Cons:

- A no-op re-scan (the once-per-launch saved-root scan) reconstructs unchanged
  `MediaAsset` values, recomputing each `sortKey`. This is off the main actor in the
  scan task, does not wake the projection, and is bounded by the batch already being
  iterated; not optimized absent measurement (Pike rules 1–2).

Failure modes:

- None for correctness. The only cost is the off-main reconstruction above.

### Alternative B: Refresh only when any field including dates differs

Compare dates too and rewrite only on a difference.

Pros:

- Skips reconstruction for a genuinely identical in-session re-scan.

Cons:

- The launch re-scan still reconstructs because reloaded `Double` dates differ from
  fresh `Date` values by epsilon, so it does not actually avoid the launch cost.
- Adds a date comparison whose only safe use is gating a memory rewrite (never
  notification); more concepts for no real-world saving. Rejected for simplicity.

### Alternative C: Store dates losslessly or compare with a tolerance to skip rewrites

Pros:

- Could skip the launch reconstruction.

Cons:

- A tolerance is a fudge factor (code smell); a schema change is unjustified by any
  measurement. Premature optimization. Rejected.

## Selected Approach

Alternative A. `applyScannedBatchToMemory` always writes the scanned values into
`assetsByRootPath` and returns `visibleChange` computed from name, content type, and
size; `recordScannedBatch` gates `notifyCatalogChanged()` on `visibleChange`. The
selective-sync contract is corrected in docs only (no detector). The PR-comment
process is added to AGENTS.md and FND-065.

## Interfaces, Ownership, And Data Flow

- `CatalogStore.applyScannedBatchToMemory(...) -> Bool` now means "did a user-visible
  change occur" (drives notification); memory is refreshed for every observed file.
- No actor, persistence, schema, model, or projection changes. Reconciliation
  deletes still notify. The `catalog.scan.batch` diagnostics `changed` field now
  reports the visible-change flag.

## Retirement Proof

Nothing is retired. ADR 0008's Decision clause 4 over-claim is corrected to match
its existing Consequences and Alternatives; no ADR, schema, test, or construction
path is removed. The `applyScannedBatchToMemory` return-value meaning shifts from
"memory changed" to "visible change"; its one call site and the local diagnostics
field are updated in the same change.

## Living Documentation And Comment Audit

- Updated: `docs/requirements.md` (FND-056, FND-062 amended; FND-064, FND-065
  added), `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`
  (Decision clause 4), `AGENTS.md` (platform baseline selective-sync wording; Git/PR
  workflow rule; DoD answer + checklist), `docs/index.md` (this spec).
- Added: this spec, `OtosTests/CatalogStoreScanFreshnessTests.swift` (the
  `reScanRefreshesInMemoryDatesWhenOnlySizeUnchanged` test).
- Code comments on `applyScannedBatchToMemory` and the `recordScannedBatch` notify
  gate explain the always-refresh invariant and why dates are excluded from the
  notification comparison (round-trip epsilon, not a current UI input).

## Instrumentation And Performance

No new signposts. The existing `CatalogScanBatchApplyMemory` signpost and the
`catalog.scan.batch` JSONL summary still bound the memory apply; the `changed` field
now reports the visible-change flag. The off-main reconstruction cost in Alternative
A is acknowledged and intentionally not optimized without measurement.

## Code-Smell Review

- State duplication: none added; the fix removes a divergence (SQLite vs memory).
- Premature optimization: avoided; the simplest correct refresh is chosen and the
  reconstruction cost is left unoptimized pending evidence.
- Stringly/ambiguous naming: the return value is renamed in intent (`visibleChange`)
  so the call site reads correctly.

## Acceptance Criteria

- A re-scan that re-observes a file with unchanged name/type/size but a changed
  modification date leaves `currentSnapshot()` reporting the new date;
  `reScanRefreshesInMemoryDatesWhenOnlySizeUnchanged` proves it.
- Existing no-op suppression behavior is unchanged (notification still gated on
  name/type/size); the existing scan tests still pass.
- ADR 0008, AGENTS.md, and FND-056 no longer claim selective-sync preservation as a
  current guarantee.
- AGENTS.md and FND-065 require increment PR-comment handling.
- `script/verify.sh` passes.

## Verification

- Local: `script/verify.sh` (lint, requirements-authority, Xcode 27 build, tests
  including the new `CatalogStoreScanFreshnessTests` case).
- PR-comment handling: PR #13 and PR #14 review threads are claimed and answered
  with the resolution and the fixing PR.
- Stale-document audit: requirements, ADR 0008, AGENTS.md, and index updated; no doc
  claims the deferred detector or date-sort work is done.
- CI expectations: fast gate; remote CI does not run Xcode 27 build/test.
