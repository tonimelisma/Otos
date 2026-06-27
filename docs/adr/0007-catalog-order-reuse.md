# ADR 0007: Catalog Ordering And Value Materialization

- Status: Accepted
- Last updated: 2026-06-23
- Specs: `docs/specs/0011-placeholder-media-grid.md`,
  `docs/specs/0012-catalog-state-robustness.md`,
  `docs/specs/0017-catalog-publication-performance.md`,
  `docs/specs/0018-catalog-order-cache-and-scoped-map-removal.md`

## Context

`CatalogStore` keeps media assets in dictionaries keyed by `MediaAssetID`.
Dictionary iteration order is meaningless, while the grid needs a stable order.

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
- 10 Hz publication and availability: ADR 0005
- collection rendering and diffable application: ADR 0006
- the precomputed sort key itself: spec 0017

User sort modes, metadata ordering, and selection of individual media assets are
outside this decision. Scan-time media eligibility is owned by ADR 0002.

## Decision

`CatalogProjection` is the sole sorting owner and **sorts the current ids on every
publication** by comparing each asset's precomputed `sortKey`. There is no order
cache and no membership-validation step; the snapshot exposes keyed assets and no
ordering.

The projection passes the snapshot's **full value map by copy-on-write** as
`CatalogMediaGridState.assetsByID` and the scoped, ordered ids as
`orderedAssetIDs`. The grid renders `orderedAssetIDs` and looks up only the visible
ids in the shared map, so no per-publication scoped copy is materialized.

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

- The projection is simpler: no `cachedOrderedAssetIDs`, no membership validation,
  no scoped-map construction.
- The grid's `assetsByID` is the full snapshot map (shared, not copied). Its
  `orderedAssetIDs` remains the scoped, ordered structure.
- The cross-library equality isolation the scoped map provided is dropped. A real
  detail change in an unselected library now produces one extra publication that
  the grid resolves to a visible-only refresh with no visible change. No-op-scan
  suppression (FND-062) removes the common source of such churn, so this is
  acceptable for the current product.
- Projection diagnostics report sort duration; the cache-hit, membership-change,
  and scoped-build fields are removed.

## Retirement Proof

Removed in the implementing increment: `cachedOrderedAssetIDs` and its validation,
the scoped-map helper, the `assetOrderCacheHit` / `assetOrderSorted` /
`assetMembershipChanged` / `membershipUs` / `scopedBuildUs` diagnostic fields, the
matching `script/catalog-diagnostics.sh` summary lines, and the tests that asserted
cache-hit reuse. FND-043 is rewritten. Git history owns the prior cache decision.

## Living Documentation Impact

- FND-043 rewritten to the sort-every-publication, full-map contract.
- `CatalogProjection` file guide and comments updated.
- `CatalogMediaGridState` comment updated (full map, not scoped).
- `docs/specs/0018-catalog-order-cache-and-scoped-map-removal.md` records the
  increment; spec 0017 introduced the sort key this decision depends on.

## Verification

- Projection tests cover first sort, detail change keeping order, insertion,
  deletion, same-count replacement, availability/scope filtering, and the full-map
  contract.
- `script/verify.sh` supplies the full local gate.
