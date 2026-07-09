# ADR 0007: Catalog Ordering And Value Materialization

- Status: Superseded by ADR 0010 for current order execution and value materialization
- Last updated: 2026-06-30

## Context

This ADR records the pre-ADR-0010 ordering decision and the evidence that removed
the projection order cache. ADR 0010 now owns current order execution and value
materialization: `CatalogStore` persists `sort_key` and returns ordered IDs from
SQLite, while Projection and the UI no longer receive a full asset value map.

This ADR originally decided to cache the globally ordered `[MediaAssetID]` in the
projection and reuse it whenever direct identity validation proved membership was
unchanged, and to materialize a scoped value map so changes outside the selected
scope stayed equality-suppressed. That decision assumed re-sorting was expensive.

Measurement overturned the assumption. With the precomputed per-asset sort key
(`MediaSortKey`, FND-061), sorting 25k assets dropped from ~500 ms of localized
collation to ~140 ms of plain key comparison, and a real-library trace showed the
order cache's O(n) membership validation (~56 ms) and the scoped-map rebuild
(~68 ms) cost more per publication than the cheap re-sort they were avoiding. The
reuse machinery had become a net cost.

## MECE Decision Scope

This ADR owns:

- where catalog identity sorting occurs
- whether the projection caches order or re-sorts each publication
- how the grid receives asset values (scoped copy versus shared full map)

It references but does not own:

- SQLite and scan reconciliation: ADR 0002
- UI ownership: ADR 0004
- coalesced publication and availability: ADR 0005
- descriptor query ownership and generated best values: ADR 0011
- collection rendering and diffable application: ADR 0006
- the precomputed sort key itself: spec 0017

User sort modes, metadata ordering, and selection of individual media assets are
outside this decision. Scan-time media eligibility is owned by ADR 0002.

## Superseded Decision

Before ADR 0010, `CatalogProjection` was the sorting owner and sorted current ids
on every publication by comparing each asset's precomputed `sortKey`. There was no
order cache and no membership-validation step.

ADR 0010 supersedes the materialization half of that decision. The current grid
receives ordered IDs and a scalar detail-refresh generation only. It faults visible
details through the Store-backed detail reader instead of receiving
`CatalogMediaGridState.assetsByID`.

## Alternatives Considered

### Cache order and validate membership (the previous decision)

Pros:

- avoids re-sorting on detail, selection, availability, and activity changes

Cons:

- the O(n) `allSatisfy` membership validation measured ~56 ms at 25k, more than the
  cheap re-sort it guarded; the cache became a net cost once the sort was cheap

Failure mode: spending more time validating a cache than re-sorting would take.

### Materialize a scoped value map

Pros:

- a detail change in an unselected library stays equality-suppressed

Cons:

- a per-publication O(n) dictionary copy (~68 ms at 25k) for a property the grid
  reads only a few visible entries from

Failure mode: copying the whole scoped map every publication to render a screenful.

### Maintain an incremental sorted order

Pros:

- avoids even the cheap full re-sort on scan growth

Cons:

- more machinery than a precomputed key; at 25k the full re-sort is already
  ~140 ms and rare after no-op-scan suppression

Failure mode: merge bugs on delete or same-path replacement. Deferred unless a
trace at much larger scale proves the full re-sort is a bottleneck.

## Consequences

- ADR 0010 keeps the useful part: persisted precomputed sort keys.
- Projection no longer performs full asset sorting or carries a full value map.
- Projection diagnostics now report Store ordered-ID query timing and scalar
  detail-refresh generation changes.

## Retirement Proof

Removed in the implementing increment: `cachedOrderedAssetIDs` and its validation,
the scoped-map helper, the `assetOrderCacheHit` / `assetOrderSorted` /
`assetMembershipChanged` / `membershipUs` / `scopedBuildUs` diagnostic fields, the
matching unified-log `op=` boundaries, and the tests that asserted
cache-hit reuse. FND-043 is rewritten. Git history owns the prior cache decision.

## Living Documentation Impact

- FND-043 rewritten to the sort-every-publication, full-map contract.
- `CatalogProjection` file guide and comments updated.
- `CatalogMediaGridState` comment updated (full map, not scoped).
  increment; spec 0017 introduced the sort key this decision depends on.

## Verification

- Projection tests cover first sort, detail change keeping order, insertion,
  deletion, same-count replacement, availability/scope filtering, and the full-map
  contract.
- `script/verify.sh` supplies the full local gate.
