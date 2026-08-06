# ADR 0010: Store-Owned Query Catalog And Identity Grid

## Status

Accepted

## Context

Before this decision, Otos kept a resident per-asset catalog map in `CatalogStore`, rebuilt
that map into `CatalogSnapshot.assetsByID`, sorted it in `CatalogProjection`, passed
the full value map through `CatalogWindowState`, and gave the grid an
`assetsByID` detail map. A production-size run around a 22,263-item selected scope
showed repeated projection publications, full-catalog sort/equality work, and
active-app main-run-loop stalls, including stalls above one second, while
enrichment arrived in tiny batches.

The current model treats small per-item detail changes as whole-catalog
publication work. It also cannot satisfy the target product shape: one
Lightroom-class media view scaling toward roughly one million items, with
metadata-driven sort/filter/search and progressive thumbnail/detail painting.

The filesystem remains Otos's source of truth for media existence and filesystem
facts. The catalog is a subordinate, rebuildable overlay projection under
Application Support. There are no active users of this pre-release app, so this
decision does not need an on-disk migration path from the current schema: the
catalog and thumbnail state may be destructively reset and rebuilt from the
filesystem and enrichment.

This decision supports current and candidate requirements around filesystem
truth, single-window ownership, passive SwiftUI composition, Store-owned
persistence, AppKit collection rendering, off-main media work, and jank
diagnostics.

## MECE Decision Scope

This ADR owns:

- the catalog read model for grid-scale data
- the persistence/query owner boundary
- the decision to use Store-owned indexed SQLite queries for ordering, detail
  reads, enrichment selection, and future metadata query surfaces
- the decision to remove resident per-asset values from Store, Projection,
  ViewModel, and grid publication paths
- the decision that the grid holds ordered `MediaAssetID`s and faults detail by ID
  through a narrow reader
- the destructive clean-schema/reset policy for this pre-user catalog redesign

This ADR references but does not own:

- the filesystem source-of-truth and overlay lifecycle rules in ADR 0008
- library root selection/access policy in ADR 0003
- thumbnail byte storage and staleness signature policy in ADR 0009
- main-window ownership and task lifetime rules in ADRs 0004 and 0005
- exact UI layout details in ADR 0006

Adjacent decisions requiring specs or ADR updates:

- the concrete schema and clean reset implementation
- the exact Store query API names and GRDB implementation
- the controller-owned detail reader implementation
- any future virtual/range data-source design if resident ordered IDs are measured
  insufficient
- any future user-facing metadata filter/search feature

## Decision

Use a Store-owned, SQLite-backed catalog projection with an identity-plus-generation grid.

The filesystem remains the source of truth. `CatalogStore` owns SQLite and every
query. SQLite stores the complete queryable catalog projection: filesystem facts
mirrored from scans, enrichment overlay, persisted sort keys, and queryable
metadata columns. No UI, Projection, ViewModel, grid, or cell code may touch SQL,
GRDB types, SQLite row IDs, or database handles.

`CatalogProjection` owns presentation policy: selected scope, active sort mode,
availability hiding, title, empty state, removed-library fallback, and a scalar
detail-refresh generation. It calls Store query APIs for ordered IDs when a
structural change or scope change can affect membership/order, then publishes chrome
plus `CatalogMediaGridState`: ordered visible identities and the generation only,
never per-asset values. If that visible scope is empty, Projection may ask Store for
separate counts over the same scope, so it can distinguish "nothing exists" from
"cataloged media is hidden because roots are unavailable" and from "an active filter
excluded everything."

A scope is not merely a set of roots — an Imports row also narrows by
`import_batch_unix_ms`. `RootRegistry` therefore resolves each `SidebarSelection`
into exactly one `CatalogScopePredicate`, and every scoped read (ordered IDs, both
counts, filter options) consumes that value. Passing bare root IDs per query is
rejected: it let ordering apply batch membership while the counts and filter options
silently did not, so a batch whose rows an active filter excluded reported itself as
an empty library and withheld the Clear Filters affordance.

Detail-only Store changes reuse the last ordered-ID result and advance
only the detail-refresh generation. Projection registers Store change notifications
before relying on the coalesced publication loop so detail-only Store writes cannot
be missed between startup and the first visible publication.

The UI holds only ordered `MediaAssetID`s for the current scope and sort. The grid
uses a diffable data source keyed by `MediaAssetID`. `MediaAssetID` (and its path
components) hash through a derived process-independent FNV-1a fingerprint so
23k-item snapshot builds and Set membership stay cheap; equality still falls back
to full path-string comparison on fingerprint collision, and Codable/persistence
remain the raw path strings only. The scalar generation is not
catalog truth; it is only an invalidation counter that lets Store detail-only
changes reach the visible detail reader even when ordered IDs are unchanged. The
AppKit grid controller owns viewport and reuse. Cells paint one asset and request
detail through a controller-owned `MediaTileDetailReader` that batches, deduplicates,
cancels, and generation-checks detail reads. Thumbnails remain file-backed and are
loaded off the main actor.

Enrichment selection moves from a resident map scan to a Store claim query:
`enrichmentCandidates(prioritizing:limit:)`.

Catalog schema advances are additive GRDB migrations. Destructive schema reset
(`eraseDatabaseOnSchemaChange` and the former clean-reset erase path) is retired
because import history and other non-rebuildable overlay must survive app upgrades.
A database whose applied migration identifiers include ones this app does not know,
or whose user tables exist without any known migration identifiers, refuses to open:
no roots load, no scans run, and nothing is written to the catalog file. The window
surfaces a typed "catalog was written by a newer Otos" / incompatible empty state.
An explicit user-confirmed Rebuild Catalog operation is reserved for a later
requirement and is never used as silent migration behavior.

## Alternatives Considered

### Alternative A: Patch The Current Resident Map With Detail Streams

Pros:

- smallest implementation diff
- directly reduces detail-only UI churn
- no persistence redesign

Cons:

- keeps a duplicate resident per-asset model
- keeps value-map memory and lifetime complexity
- does not make metadata sort/filter/search a natural indexed query surface
- leaves enrichment selection as an in-memory scan

Failure modes:

- detail-patch classification bugs leave visible cells stale
- structural work still grows with resident catalog size
- future metadata features force a later, larger redesign

### Alternative B: Resident Ordered IDs And Windowed Detail, With Store Still Resident

Pros:

- removes full value maps from UI publication
- matches collection-view identity best practices
- simpler than a fully database-backed read model

Cons:

- still needs a resident Store value model for ordering/enrichment selection
- still duplicates catalog truth between memory and SQLite
- metadata sort/filter/search still needs a separate database query design

Failure modes:

- in-memory ordering/enrichment scans remain the long-term bottleneck
- the eventual database-query transition repeats much of the work

### Alternative C: Store-Owned Indexed SQLite Queries And Identity Grid

Pros:

- removes the resident per-asset value model
- makes sort/filter/search and enrichment selection indexed Store queries
- uses separate root-local and global indexes for library-scoped and all-media
  ordering/enrichment reads
- keeps persistence/query ownership singular
- aligns with large media-library application patterns
- solves the measured value-map publication failure and the target-scale model

Cons:

- larger refactor across persistence, Store, Projection, ViewModel, grid, tile, and
  enrichment
- query/index correctness becomes critical
- concurrent read path and detail-reader backpressure must be implemented
- resident ordered ID list at one million items still needs runtime proof

Failure modes:

- missing indexes cause full scans
- mismatched partial-index predicates cause SQLite to ignore the stale-enrichment
  indexes
- stale async detail paints reused cells unless generation checks are correct
- SQLite/page-cache tuning is insufficient at extreme scale
- destructive reset accidentally touches originals unless explicitly tested

## Consequences

This decision makes Store query APIs the only way to read catalog data. It removes
the resident map and full-value publication path. Current implementation and docs
must keep persistence, publication, grid rendering, ordering, enrichment storage,
and onboarding aligned with that boundary. Query behavior, stale-result handling,
and production-size performance evidence are part of the DoD for increments that
change this path.

It also intentionally avoids migration complexity. Local pre-release catalog state
is disposable; originals remain untouched.

The implementing schema uses root-local and global covering indexes for ordered
identity reads and equivalent partial indexes for stale enrichment candidates.
Query-plan tests are part of the regression suite because the whole architecture
depends on SQLite streaming those reads instead of doing temporary sort work.

## Retirement Proof

The implementation removes or proves unreachable:

- `CatalogStore.assetsByRootPath`
- `CatalogStore.currentSnapshot()` and `makeSnapshot()`
- `CatalogSnapshot.assetsByID`
- `CatalogProjection.sortAssetIDs` and snapshot-based `buildWindowState`
- `CatalogProjectionChangeSummary` full-map equality
- `CatalogMediaGridState.assetsByID`
- `MediaGridViewController.assetsByID`
- asset-value-based tile configuration
- resident-map enrichment scheduling
- `metadata_blob`, `encodeMetadata`, `decodeMetadata`, and blob-specific tests
- incremental v1/v2/v3 migration assumptions
- public paths where row IDs, GRDB types, SQL, or DB handles cross Store boundary

## Living Documentation Impact

Updated by the implementing increment:

- `docs/requirements.md`
- ADRs 0002, 0004, 0005, 0006, 0007, and 0009
- `docs/index.md`
- specs 0017, 0018, 0022, and 0024 if they retain current-state claims that are
  superseded
- file guides in `CatalogModels.swift`, `CatalogStore.swift`,
  `CatalogStorePersistence.swift`, `CatalogProjection.swift`,
  `CatalogWindowViewModel.swift`, `MediaGridBridge.swift`,
  `MediaAssetTileView.swift`, and `EnrichmentCoordinator.swift`

Planning documents may remain non-authoritative, but must not be cited as current
implementation.

## Reversal Plan

If Store-owned SQLite queries fail at measured target scale, first verify indexes,
WAL/page-cache settings, query plans, and detail-reader batching. If the resident
ordered ID list or diffable snapshots are the bottleneck, evolve to a virtual
count/range data source where Store returns ID windows by range. If SQLite itself
is the bottleneck for a very large query-heavy catalog, evaluate a stronger
database engine with evidence.
