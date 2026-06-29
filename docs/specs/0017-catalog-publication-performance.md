# Spec: Catalog Publication Performance — Cheap Sort Key And No-Op Scan Suppression

## Classification

- Work type: Bug fix / performance (measured jank on a real library)
- Current requirement IDs: FND-024, FND-037, FND-038, FND-043; adds FND-061, FND-062
- Future idea or candidate links explicitly requested by the user: none
- ADRs: none new; preserves ADR 0004, 0005, 0007 boundaries

## Problem

Instrumenting the catalog publication pipeline and running the production app
against a real 25,121-asset OneDrive library showed it stalls the main thread at a
size that is small and carries no thumbnails or media metadata yet. Measured per
publication:

- the localized asset sort cost 477–647 ms (`localizedStandardCompare` per
  comparison),
- every re-scan batch of an unchanged library still notified the projection,
  producing ~20 publications each doing ~150 ms of off-main work,
- five main-run-loop stalls (127, 305, 103, 175, 104 ms).

The cost was repetition and an expensive comparator, not data size.

## Scope

In scope:

- Add a precomputed per-asset display-order key so sorting compares cheap strings
  instead of running localized collation per comparison, preserving numeric-aware
  ordering.
- Suppress the Store change notification when a scan batch re-observes identical
  filesystem facts, so re-scanning an unchanged library produces no publications.
- Add per-stage projection timing instrumentation (membership, scoped-build,
  equality microseconds; batch `changed`) used to measure this.

Out of scope (deferred, with rationale):

- Removing the projection order cache and the scoped value-map rebuild. Now done in
  `docs/specs/0018-catalog-order-cache-and-scoped-map-removal.md`, which the cheap
  sort key here made worthwhile (the cache validation and scoped copy cost more than
  the cheap re-sort).
- The one-time large structural apply on first fill. macOS
  `NSCollectionViewDiffableDataSource` has no `applySnapshotUsingReloadData`, so the
  empty-to-N apply cost needs chunked application or windowing — a separate change.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected and measured.
- [x] Captured user guidance is restated as precise requirements.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas are kept out of `docs/requirements.md`.
- [x] Ownership, side effects, persistence, cancellation, privacy, and tests are
      addressed.
- [x] At least three alternatives are compared.
- [x] Retirement proof is defined (nothing retired; cache deletion deferred).
- [x] A repository-wide stale-document audit is defined.
- [x] A code-comment accuracy audit is defined.
- [x] Performance evidence is defined (before/after measurement on the 25k library).
- [x] Open questions are answered or out of scope.

## Measured Before And After (25,121 assets, real OneDrive library)

| Metric | Before | After |
| --- | --- | --- |
| Asset sort time | 477–647 ms | 114–148 ms |
| Projection publications (load + re-scan) | 23 | 6 |
| Re-scan batches notifying | all | 2 of 33 (31 no-op suppressed) |
| Equality check | 31 ms | 4 µs |
| Total per publication (max) | 724 ms | 220 ms |
| Main-run-loop stalls | 5 | 1 (launch, before grid populated) |

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-061 | Non-functional | Catalog display order is produced by comparing a precomputed per-asset sort key, not localized collation per comparison, and preserves numeric-aware ordering. | Current | docs/requirements.md, this spec |
| FND-062 | Non-functional | A scan batch that re-observes identical filesystem facts (name, content type, size) does not notify the projection, so re-scanning an unchanged library publishes nothing. | Current | docs/requirements.md, this spec |

## Architectural Alternatives

### Alternative A (selected): Precomputed sort key + notify-on-real-change, keep cache and scoped map

Pros:

- Fixes the two dominant measured costs (sort and re-scan churn) with small, local
  changes and no ADR retirement.
- Sort stays in the projection (a view choice), so future date/size/asc-desc sorts
  slot in.

Cons:

- Leaves the now-redundant order cache and the one-time structural apply for a
  follow-up.

Failure modes:

- The sort key must reproduce numeric-aware order; covered by `MediaSortKeyTests`.

### Alternative B: Incremental merge of new batches into a maintained sorted order

Pros:

- Avoids re-sorting on scan growth.

Cons:

- More machinery than a precomputed key; with cheap comparisons a full re-sort is
  already single-digit-to-low-hundred ms and rare.

Failure modes:

- Merge bugs on delete or same-path replacement.

### Alternative C: Compare full asset values (including dates) to detect no-op batches

Pros:

- Detects any field change.

Cons:

- Comparing the raw `Double` dates round-tripped through SQLite would let float
  epsilon make every re-scan look changed and defeat the suppression.

Failure modes:

- Silent defeat of the optimization.

(Update: once the tile began showing the capture date, spec 0022 did add the
`createdAt`/`contentModifiedAt` dates to the suppression key — but compared at
whole-second resolution via `MediaAsset.mtimeSeconds`, which sidesteps the float-
epsilon objection above. Comparing full *enriched* asset values is still rejected.)

## Selected Approach

Alternative A. `MediaAsset` gains a precomputed `sortKey` (library segment then
relative path, with digit runs zero-padded for numeric order); `CatalogProjection`
sorts by it with a plain comparison. `CatalogStore.applyScannedBatchToMemory`
returns whether memory changed by comparing name, content type, and size, and
`recordScannedBatch` notifies only when it did.

## Interfaces, Ownership, And Data Flow

- `MediaAsset.sortKey: String` computed in its initializer (`MediaSortKey`).
- `CatalogProjection.sortAssetIDs(_ assetsByID:)` sorts values by `sortKey`.
- `CatalogStore.applyScannedBatchToMemory(...) -> Bool`; `recordScannedBatch` gates
  `notifyCatalogChanged()` on the result.
- No actor, persistence, or schema changes. Reconciliation deletes still notify.

## Retirement Proof

Nothing retired. The order cache (ADR 0007 / FND-043), the scoped value map, and the
structural apply path are intentionally preserved; their further optimization is
deferred and named above.

## Living Documentation And Comment Audit

- Updated: `docs/requirements.md` (FND-061, FND-062), `docs/index.md`.
- Added: this spec, `OtosTests/MediaSortKeyTests.swift`.
- Code comments added on `MediaAsset.sortKey`, `MediaSortKey`, the cheap
  `sortAssetIDs`, and the no-op-suppression path explain the mechanics and the
  float-epsilon hazard.

## Instrumentation And Performance

Per-publication projection timing gained `membershipUs`, `scopedBuildUs`,
`equalityUs`, and a scan-batch `changed` field, recorded in the existing
`catalog.projection.window` and `catalog.scan.batch` JSONL summaries. The
before/after table above is the evidence.

## Code-Smell Review

- State duplication: `MediaAsset.sortKey` is derived from identity (consistent), not
  a second source of truth.
- Premature optimization: avoided — every change is justified by the measurement.

## Acceptance Criteria

- Sorting compares `MediaAsset.sortKey`; `MediaSortKeyTests` proves numeric-aware,
  case-insensitive, library-then-path order.
- A re-scan of unchanged files does not notify; existing scan tests still pass and
  the re-measurement shows 31 of 33 batches suppressed.
- `script/verify.sh` passes.

## Verification

- Local: `script/verify.sh` (lint, requirements-authority, Xcode 27 build, tests
  including `MediaSortKeyTests`).
- Performance: before/after measurement on the real 25k library (table above).
- Stale-document audit: requirements and index updated; no doc claims the deferred
  work is done.
- CI expectations: fast gate; remote CI does not run Xcode 27 build/test.
