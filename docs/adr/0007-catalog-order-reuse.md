# ADR 0007: Catalog Order Reuse

- Status: Accepted
- Last updated: 2026-06-21
- Specs: `docs/specs/0011-placeholder-media-grid.md`,
  `docs/specs/0012-catalog-state-robustness.md`

## Context

`CatalogStore` keeps media assets in dictionaries keyed by `MediaAssetID`.
Dictionary iteration order is meaningless, while the grid needs stable ordering
by library display name, root path, and relative path. Detail, selection,
availability, and scan-activity changes often leave membership unchanged, so
re-sorting every projection would repeat work without changing identity order.

Any cache-validity rule must remain correct without duplicating catalog truth or
requiring every Store mutation path to maintain separate invalidation metadata.

## MECE Decision Scope

This ADR owns:

- where catalog identity sorting occurs
- how Projection validates and reuses cached identity order
- how scoped asset values are materialized from that order

It references but does not own:

- SQLite and scan reconciliation: ADR 0002
- UI ownership: ADR 0004
- 10 Hz publication and availability: ADR 0005
- collection rendering and diffable application: ADR 0006

Persistent revisions, user sort modes, media eligibility, metadata ordering,
thumbnail ordering, and selection of individual media assets are outside this
decision.

## Decision

Keep Store's dictionaries as the only runtime catalog truth. `CatalogSnapshot`
exposes keyed assets but no ordering and no invalidation counter.

`CatalogProjection` caches globally ordered `[MediaAssetID]`. Before reuse it
directly validates membership:

1. cached count must equal the snapshot asset count
2. every cached ID must exist in the snapshot map

Those two checks prove set equality because cached IDs are unique. If either
check fails, Projection sorts all current IDs with the established comparator
and replaces the cache. Insertions, deletions, and same-count identity
replacements therefore become ordinary cache misses without Store-side
bookkeeping.

The comparator uses a root-path-to-display-name lookup derived once from the
snapshot's library rows, then root path and relative path as deterministic
tie-breakers. A malformed snapshot whose asset root lacks a library row falls
back to `LibraryRootPath.displayName`; the fallback preserves complete output
without inventing a second identity.

After validating order, Projection filters IDs directly by availability and
sidebar scope. It builds `CatalogMediaGridState.assetsByID` only for IDs in the
selected scope. Changes outside that scope then remain equality-suppressed and
do not force a window-state assignment.

## Alternatives Considered

### Sort Every Projection

Pros:

- no cache state or validation

Cons:

- repeats O(n log n) work for detail, selection, availability, and activity
  changes that do not affect order

Failure mode: frequent scan detail updates waste projection time.

### Maintain A Sorted Array In Store

Pros:

- snapshots can expose ready order

Cons:

- dictionaries and array both answer catalog membership
- UI ordering contaminates persistence/scanning ownership

Failure mode: mutation paths update one representation but not the other.

### Store A Manual Transient Revision

Pros:

- constant-time cache-validity comparison

Cons:

- every membership mutation path must classify and increment correctly
- the counter duplicates a fact already represented by keyed membership

Failure mode: a missed increment silently reuses stale order; defensive identity
validation is still needed, making the counter redundant.

### Persist Ordering Or A Revision

Pros:

- cache can survive launch

Cons:

- adds schema and synchronization for rebuildable derived state

Failure mode: persisted order drifts from catalog truth.

## Consequences

- Store has no order-cache invalidation responsibility.
- Projection remains the sole sorting owner and reuses order on detail-only,
  selection, availability, and activity changes.
- Same-count replacement is detected without special cases.
- Validation is O(n), intentionally simpler and safer than manually maintained
  invalidation metadata.
- Scoped value maps avoid unrelated state churn.
- Diagnostics report cache hit, membership change, sort duration, ordered count,
  and selected-scope count.

## Living Documentation Impact

Requirement FND-042 is retired. Requirement FND-043, Spec 0011, Projection
comments, diagnostics summaries, and tests must describe identity validation,
not a Store-maintained revision. The old ADR filename and every current backlink
to it are removed.

## Verification

- Projection tests cover first sort, detail-only reuse, insertion, deletion,
  same-count replacement, availability/scope filtering, orphan fallback order,
  and scoped-map isolation.
- Store tests contain no structural invalidation bookkeeping.
- Source hygiene rejects the retired revision symbol.
- `script/verify.sh` supplies the full local gate.
