# Spec: Remove The Projection Order Cache And Scoped Value Map

## Classification

- Work type: Refactor / performance (completes work deferred by spec 0017)
- Current requirement IDs: FND-043 (rewritten), FND-061, FND-062
- ADRs: `docs/adr/0007-catalog-order-reuse.md` (rewritten)

## Problem

Spec 0017 added a precomputed sort key and deferred two cleanups it made possible:
removing the projection's order cache and its scoped value-map rebuild. With the
cheap sort key, a real-library trace showed the cache's O(n) membership validation
(~56 ms at 25k) and the scoped-map copy (~68 ms) cost more per publication than the
cheap re-sort they avoided. The reuse machinery had become a net cost and dead
weight. This increment removes it.

Current update: ADR 0010 supersedes this spec's full-value-map publication path.
The retained outcome is the removal of the projection order cache; current order
execution is Store-owned SQLite, and the grid receives ordered IDs plus a scalar
detail-refresh generation rather than `CatalogMediaGridState.assetsByID`.

## Scope

In scope:

- Remove `cachedOrderedAssetIDs` and the membership-validation path; the projection
  sorts the current IDs on every publication.
- Superseded by ADR 0010: pass no full value map through grid state. The grid
  faults visible details by ID through the Store-backed reader.
- Remove the now-meaningless diagnostic fields (`assetOrderCacheHit`,
  `assetOrderSorted`, `assetMembershipChanged`, `membershipUs`, `scopedBuildUs`) and
  the matching `script/catalog-diagnostics.sh` summary lines.
- Rewrite ADR 0007 and FND-043 to the new contract.

Out of scope:

- An incremental sorted-order maintenance (deferred unless a much larger-scale trace
  proves the full re-sort is a bottleneck).
- The one-time large structural apply on first fill (macOS `NSCollectionView`
  windowing; separate work).

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-043 (rewritten) | Architecture | Store-owned SQLite queries produce display order by persisted precomputed sort key; Projection publishes scoped ordered IDs without a full value map. | Current | docs/requirements.md, ADR 0010, this spec |

## Architectural Alternatives

### Alternative A (selected): Remove the cache and scoped map

Pros: removes the most intricate projection code; the validation and copy cost more
than the cheap re-sort.

Cons: drops the scoped map's cross-library equality isolation.

Failure mode: a detail change in an unselected library causes one extra publication
(harmless visible-only refresh); no-op-scan suppression removes the common source.

### Alternative B: Keep the cache but make validation cheap (a revision counter)

Pros: O(1) validation.

Cons: a manually maintained revision is exactly the hazard ADR 0007 and FND-042
already retired.

Failure mode: a missed increment silently reuses stale order.

### Alternative C: Keep everything

Pros: no change.

Cons: leaves measured net-negative machinery in place.

Failure mode: per-publication cost stays higher than re-sorting.

## Selected Approach

Alternative A removed the projection order cache. ADR 0010 later moved order
execution to Store-owned SQLite and retired the full value-map publication path.
FND-043 now points at that current contract.

## Retirement Proof

Removed: `cachedOrderedAssetIDs` and validation, the scoped-map helper, the five
order/scoped diagnostic fields, the three `catalog-diagnostics.sh` summary lines,
and the cache-hit assertions in `CatalogProjectionOrderingTests`,
`CatalogProjectionTests`, and `CatalogDiagnosticsTests`. ADR 0007 and FND-043
rewritten. Git history owns the prior cache decision.

## Living Documentation And Comment Audit

Updated at the time: ADR 0007, FND-043, `docs/index.md`, `CatalogProjection` file
guide and comments, `CatalogMediaGridState` comment, `script/catalog-diagnostics.sh`.
ADR 0010 later rewrote the current full-map contract to Store-owned queries and
identity-plus-generation grid state.

## Acceptance Criteria

- `CatalogProjection` has no resident order cache for structural changes; current
  ADR 0010 behavior reuses the last Store-ordered IDs only for detail-only Store
  changes and still resolves visible detail through the grid detail reader.
- Diagnostics no longer emit the removed fields; the summarizer no longer counts
  them.
- `script/verify.sh` passes.

## Verification

- Local: `script/verify.sh` (lint, requirements-authority, Xcode 27 build, tests).
- Performance: re-run on the 25k library confirms no regression and that the
  per-publication scoped-build cost is gone.
- Stale-document audit: ADR 0007, FND-043, index, diagnostics script, and tests all
  reflect the new contract.
