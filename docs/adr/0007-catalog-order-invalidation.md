# ADR 0007: Catalog Order Invalidation

## Status

Accepted.

## Decision Scope

This ADR owns how catalog membership changes invalidate asset ordering, where
sorting occurs, and how projected identity order is reused.

It references but does not own SQLite schema/scanning (ADR 0002), UI ownership
(ADR 0004), 10 Hz publication (ADR 0005), or collection rendering (ADR 0006).
Persistent revisions, user sort modes, eligibility filtering, metadata order,
and thumbnail order are outside this decision.

## Context

Store runtime truth is already keyed, while dictionary iteration order is
undefined. Sidebar changes and file detail updates do not alter global asset
order, so sorting all assets for every projection tick is unnecessary work.
The UI also needs identity order separated from current values to distinguish
structural updates from visible detail refreshes.

## Alternatives

1. Sort every projection: no cache invalidation, but repeats O(n log n) work for
   selection, availability, activity, and detail-only updates.
2. Keep a sorted array as Store truth: makes every mutation maintain two truth
   structures and mixes UI order into catalog ownership.
3. Persist sort positions/revision: adds schema and synchronization for entirely
   rebuildable state.
4. Transient membership revision plus Projection cache: Store signals structural
   invalidation; Projection remains sole ordering owner.

## Decision

Keep Store's nested root/path dictionaries as runtime truth. Add transient
`UInt64 assetStructureRevision` and advance it once when:

- a scan batch inserts one or more new identities
- completed reconciliation removes one or more identities
- removing a library removes one or more identities
- loaded catalog structure replaces current runtime structure

Do not advance it for detail updates, availability, scan activity, empty-library
addition/removal, or shutdown.

`CatalogSnapshot` exposes keyed assets and the revision. `CatalogProjection`
caches the last revision and globally sorted IDs using the established library
display-name, root-path, relative-path comparator. A changed revision rebuilds
the order. An unchanged revision rematerializes current values by cached ID and
filters that order for availability and sidebar scope without sorting.

If cached IDs do not resolve exactly against the snapshot map, Projection logs
an invariant failure and rebuilds instead of publishing incomplete state.

## Why This Is Simplest Correct

One monotonic in-memory counter says exactly whether membership-derived order can
be reused. It adds no durable schema, no second catalog truth, and no generalized
cache framework. The invariant fallback favors correct complete output if Store
revision maintenance is ever wrong.

## Consequences

- Detail changes reach visible tiles without structural collection work.
- Scope and availability changes filter cached order without global re-sorting.
- The revision resets on launch and has no cross-process meaning.
- Store mutation tests must classify structural versus detail-only changes.
- Projection diagnostics expose cache hits, sorts, sort duration, revision, and
  invariant recovery.
