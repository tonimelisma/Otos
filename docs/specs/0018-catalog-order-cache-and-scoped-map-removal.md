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

## Scope

In scope:

- Remove `cachedOrderedAssetIDs` and the membership-validation path; the projection
  sorts the current IDs on every publication.
- Pass the snapshot's full value map by copy-on-write as
  `CatalogMediaGridState.assetsByID`; the grid looks up only the visible IDs.
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
| FND-043 (rewritten) | Architecture | Projection sorts by precomputed key every publication with no order cache, and passes the full value map by copy-on-write. | Current | docs/requirements.md, ADR 0007, this spec |

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

Alternative A. The projection sorts every publication (cheap), holds no order cache,
and shares the snapshot's full value map by copy-on-write. ADR 0007 is rewritten;
FND-043 is rewritten; diagnostics and tests are updated.

## Retirement Proof

Removed: `cachedOrderedAssetIDs` and validation, the scoped-map helper, the five
order/scoped diagnostic fields, the three `catalog-diagnostics.sh` summary lines,
and the cache-hit assertions in `CatalogProjectionOrderingTests`,
`CatalogProjectionTests`, and `CatalogDiagnosticsTests`. ADR 0007 and FND-043
rewritten. Git history owns the prior cache decision.

## Living Documentation And Comment Audit

Updated: ADR 0007, FND-043, `docs/index.md`, `CatalogProjection` file guide and
comments, `CatalogMediaGridState` comment, `script/catalog-diagnostics.sh`. Tests
updated to assert the full-map contract and the renamed behaviors.

## Acceptance Criteria

- `CatalogProjection` has no order cache and builds `assetsByID` from the full
  snapshot map; tests prove scoped order plus full-map resolution.
- Diagnostics no longer emit the removed fields; the summarizer no longer counts
  them.
- `script/verify.sh` passes.

## Verification

- Local: `script/verify.sh` (lint, requirements-authority, Xcode 27 build, tests).
- Performance: re-run on the 25k library confirms no regression and that the
  per-publication scoped-build cost is gone.
- Stale-document audit: ADR 0007, FND-043, index, diagnostics script, and tests all
  reflect the new contract.
