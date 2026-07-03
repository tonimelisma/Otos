# Spec: Store-Owned Query Catalog And Identity Grid

## Classification

- Work type: Refactor / performance / architecture
- Current requirement IDs: FND-006, FND-017, FND-023, FND-024, FND-025,
  FND-031, FND-033, FND-034, FND-037, FND-038, FND-041, FND-043, FND-044,
  FND-058, FND-061, FND-062, FND-064, APP-006, APP-010, ENR-001, ENR-002,
  ENR-004, ENR-005, ENR-006, ENR-007, ENR-009, ENR-010
- Future idea or candidate links explicitly requested by the user:
  `docs/research/catalog-storage-and-query-models.md`,
  `docs/research/media-grid-best-practices.md`
- ADRs: ADR 0010

## Implementation Status

Implemented in this increment. The current code has no resident
`CatalogStore.assetsByRootPath`, no `CatalogSnapshot`/`currentSnapshot()` path, no
`CatalogMediaGridState.assetsByID`, and no `metadata_blob`. Store owns indexed
SQLite queries; Projection publishes scoped ordered IDs plus a scalar
detail-refresh generation; the AppKit grid uses that generation to re-read visible
details through a Store-backed `MediaTileDetailReader`. Detail-only Store changes
reuse Projection's last ordered-ID result instead of re-running the order query.
When no assets are visible, Projection asks Store for a separate cataloged count so
empty-state policy can still see rows hidden by unavailable roots.

## Problem

The pre-increment catalog/grid publication path did whole-catalog work for tiny
per-asset changes. `CatalogStore` holds a resident per-asset map,
`currentSnapshot()` rebuilds a full `assetsByID` map, `CatalogProjection` sorts and
compares it, `CatalogWindowViewModel` assigns it through `@Observable` state, and
the AppKit grid retains its own value map.

Runtime evidence from a 22,263-item selected scope showed 52 projection
publications in one minute, 24 active-app main-run-loop stalls, worst stall
1,159 ms, repeated projection times in the hundreds of milliseconds, and tiny
enrichment batches waking full-catalog sort/equality work. The selected set was
stable, so this was not real structural churn.

The target product is a Lightroom-class media browser: one scrollable view moving
toward roughly one million items, with metadata-driven order changes, progressive
thumbnail/detail painting, and future metadata sort/filter/search. The current
resident value model and full-map UI publication do not fit that target.

The pre-implementation repository state was inspected:

- `CatalogStore` uses `DatabaseQueue`, incremental migrations, a resident
  `assetsByRootPath`, `currentSnapshot()`, and resident enrichment scheduling.
- `CatalogStorePersistence` stores enrichment metadata as an opaque
  `metadata_blob`.
- `CatalogProjection` pulls snapshots, sorts `assetsByID`, and publishes
  `CatalogWindowState`.
- `CatalogMediaGridState` carries `orderedAssetIDs` and `assetsByID`.
- `MediaAssetCollectionViewController` uses a diffable data source by ID but
  configures cells from its resident `assetsByID` map.
- `MediaAssetTileView` already loads thumbnail/date off-main with a generation
  guard, which is the right leaf pattern to extend.

## Scope

In scope:

- replace the resident per-asset Store/UI value model with Store-owned indexed
  SQLite queries
- replace `DatabaseQueue` with a production/file `DatabasePool` using WAL and
  tuned page/mmap cache settings
- use a clean schema from zero, with no migration from the current schema
- destructively reset old local catalog/thumbnails in this pre-user app while
  preserving originals
- add queryable metadata columns and `metadata_extra_json` for long-tail metadata
  preservation
- add Store query APIs for ordered IDs, tile detail, enrichment selection, and
  single-asset metadata
- publish identity-plus-generation grid state so detail-only Store invalidations
  reach the visible detail reader
- add a controller-owned `MediaTileDetailReader` with batching, deduplication,
  cancellation, and generation checks
- move enrichment selection to Store queries
- retire resident maps, full snapshots, full-map equality, and in-memory sorts
- update ADRs, requirements, onboarding, file guides, tests, and instrumentation

Out of scope:

- user-facing metadata filter/search UI
- a virtual count/range collection data source
- migration from old catalog schema or generated thumbnails
- multi-window behavior
- changing original files or adding sidecars
- audio-specific media behavior

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user
      verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored unless explicitly
      requested by the user for this task.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is defined.
- [x] A repository-wide stale-document audit is defined for affected ADRs, specs,
      requirements, process docs, onboarding walkthrough, indexes, templates,
      scripts, and backlinks.
- [x] A code-comment accuracy audit is defined for affected architecture,
      concurrency, persistence, diagnostics, and AppKit boundaries.
- [x] Performance/jank evidence is defined.
- [x] Open questions are answered or out of scope.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| CQ-001 | Architecture | The filesystem remains the source of truth; SQLite is a subordinate Store-owned catalog/overlay projection. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-002 | Architecture | The UI shall hold ordered asset identities plus a scalar detail-refresh generation only; per-asset values shall not flow through Projection, ViewModel, or grid state. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-003 | Architecture | Every SQL/GRDB/database operation shall be owned by `CatalogStore`; row IDs and GRDB types shall not cross Store boundaries. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-004 | Architecture | There is no migration from the current catalog schema; old local catalog/thumbnails are destructively reset because there are no active users. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-005 | Privacy | Destructive reset shall never touch originals in user media folders. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-006 | Functional | Thumbnails discarded by reset shall be regenerated by enrichment. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-007 | Architecture | Metadata needed for sort/filter/search shall be stored in queryable columns; long-tail metadata shall be preserved in `metadata_extra_json` unless promoted later. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-008 | Non-functional | Detail reads shall be bounded to visible/current grid work through a controller-owned detail reader with batching, deduplication, cancellation, and stale-result rejection. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-009 | Non-functional | Resident ordered IDs are accepted for the target scale; a virtual/range grid is an evidence-triggered future escape hatch. | Current | This spec, ADR 0010, `docs/requirements.md` |
| CQ-010 | Tooling | Runtime evidence shall prove no repeated active-app stalls during detail-only enrichment on a production-size library. | Current | This spec, ADR 0010, `docs/requirements.md` |

## Architectural Alternatives

### Alternative A: Patch The Resident Map With Detail Streams

Pros:

- smallest code diff
- likely reduces immediate thumbnail/detail churn
- no persistence redesign

Cons:

- keeps duplicate resident per-asset data
- keeps future metadata sort/filter/search bolted onto a separate path
- keeps enrichment selection as a resident-map scan

Failure modes:

- classification mistakes leave visible cells stale
- resident-map memory and sort cost remain long-term bottlenecks

### Alternative B: Resident Ordered IDs And Windowed Detail

Pros:

- removes full value maps from UI publication
- aligns grid structure with stable identifiers
- preserves current persistence mostly intact

Cons:

- still retains resident Store values
- still duplicates SQLite truth in memory
- metadata query features still require later database-query architecture

Failure modes:

- in-memory ordering/enrichment scans continue to scale poorly
- eventual database transition repeats work

### Alternative C: Store-Owned Indexed SQLite Queries And Identity Grid

Pros:

- deletes the resident per-asset value model
- makes order, metadata query, and enrichment selection one indexed Store-owned
  read model
- preserves filesystem truth while making SQLite the rebuildable query projection
- aligns with large media-library app patterns
- removes full-map UI publication and full-map equality

Cons:

- largest refactor
- requires schema/index/query-plan discipline
- requires concurrent reads and detail-reader backpressure
- full ordered ID snapshots still require measured validation at target scale

Failure modes:

- missing indexes cause full scans
- reader bugs create stale cell painting or thundering-herd reads
- destructive reset accidentally touches originals
- SQLite/page-cache tuning is insufficient at extreme scale

## Selected Approach

Select Alternative C.

The chosen architecture is the simplest correct design for the stated product:
Store-owned indexed SQLite queries for catalog-wide questions; identity-plus-generation UI
publication; bounded detail faulting for visible cells; no resident per-asset
value map; and no migration from current local catalog state.

This is right for the product because future metadata sort/filter/search and
current enrichment selection both need queryable indexed catalog data. Keeping a
parallel resident catalog model would be duplicate machinery.

## Interfaces, Ownership, And Data Flow

### CatalogStore

`CatalogStore` owns:

- the GRDB `DatabasePool` for file-backed locations
- all SQL and GRDB values
- schema creation and destructive reset policy
- scan/enrichment writes
- Store query APIs
- identity-carrying `CatalogChange` notifications

Sketch:

```swift
actor CatalogStore {
    func orderedAssetIDs(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID]
    func catalogedAssetCount(for selection: SidebarSelection) async throws -> Int
    func mediaAssets(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaAsset]
    func enrichmentCandidates(
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> [MediaAsset]
    func metadata(for id: MediaAssetID) async throws -> AssetMetadata?
}
```

### CatalogProjection

Projection owns:

- selected scope and active sort policy
- availability filtering semantics
- title and empty-state derivation
- removed-library fallback
- generation assignment for structural publications
- Store change subscription registration before the coalesced publication loop
  relies on invalidations

Projection does not own SQL, sort execution, or per-asset values.

### CatalogWindowViewModel

ViewModel owns:

- final MainActor UI state assignment
- intent streams
- viewport forwarding
- forwarding the detail-reader capability to the grid

It holds no catalog values.

### AppKit Grid And Cell

Grid owns:

- the diffable data source over `MediaAssetID`
- visible-set derivation from AppKit
- generation-driven visible detail requery
- controller-owned `MediaTileDetailReader`
- batched/deduped/cancellable detail reads

Cell owns:

- current represented identity
- cell generation
- off-main thumbnail/detail load result application guarded by identity and
  generation

### Persistence Effects

Use a clean schema from zero. Old local catalog and thumbnail state are
discarded/reset. Originals are never touched.

## Retirement Proof

Retire:

- `DatabaseQueue` production/file assumption
- incremental v1/v2/v3 schema path
- `metadata_blob` and binary-plist metadata encoding/decoding
- `CatalogStore.assetsByRootPath`
- `CatalogStore.currentSnapshot()` and `makeSnapshot()`
- `CatalogSnapshot.assetsByID`
- `CatalogProjection.sortAssetIDs`
- snapshot/value-map `CatalogWindowState` build path
- `CatalogProjectionChangeSummary` full-map equality
- `CatalogMediaGridState.assetsByID`
- `MediaAssetCollectionViewController.assetsByID`
- asset-value `MediaAssetCollectionItem.configure`
- `EnrichmentCoordinator.latestSnapshot` and resident-map work selection
- tests asserting current value-map publication as current behavior
- docs/comments claiming current value-map publication, blob metadata, or
  in-memory ordering as current after retirement

## Implementation Phases

Each phase is independently shippable and must pass `script/verify.sh`.

### Phase 0: DB Engine And Clean Reset

- Use `DatabasePool` for production/file-backed locations with WAL and page/mmap
  cache configuration.
- Keep `.inMemory` tests on `DatabaseQueue` if required by GRDB.
- Collapse schema creation to one clean current schema path with no old-schema
  awareness.
- Add debug/pre-user destructive reset when schema changes.
- Clear thumbnail directory when catalog reset discards thumbnail references.
- Tests: old/stale catalog state is discarded, originals untouched, thumbnails
  regenerated later, concurrent read during write is coherent.

### Phase 1: Clean Queryable Schema

- Define `library_root`, `media_asset`, `asset_metadata`, and indexes.
- Store `sort_key` at write time.
- Store scalar metadata columns and `metadata_extra_json`.
- Remove `metadata_blob` and binary-plist metadata paths.
- Tests: ordering matches `MediaSortKey`, query plans use indexes, row IDs do not
  leak, scan/enrichment write the new schema.

### Phase 2: Store Query Surface

- Add `orderedAssetIDs`, `mediaAssets`, `enrichmentCandidates`, and `metadata`.
- Keep Store notifications cheap; Projection registers the notification stream
  before publication work and turns Store invalidations into the grid
  detail-refresh generation.
- Tests: query outputs match existing Projection semantics for scope,
  availability, order, tile detail, enrichment staleness, and metadata reads.

### Phase 3: Identity Publication And Reader-Backed Faulting

- Projection publishes ordered IDs + chrome + detail-refresh generation.
- Projection retains its owner for the lifetime of active subscribers and tests
  prove detail-only Store writes after startup publish a newer generation.
- ViewModel forwards detail-reader capability to grid.
- Grid drops `assetsByID`, applies ID snapshots, re-queries visible details when
  the generation changes, and owns the reader.
- Cell requests detail through reader and applies guarded results.
- Tests: visible detail change reconfigures one cell, offscreen detail change
  does no cell work, reorder moves/refaults, stale generation drops, fast-scroll
  requests batch/dedupe/cancel.

### Phase 4: Query-Based Enrichment Selection

- EnrichmentCoordinator uses `enrichmentCandidates(prioritizing:limit:)`; Store
  claims returned rows with `enrichment_claimed_until` instead of accepting a large
  SQL exclusion list.
- Retire `latestSnapshot`, `snapshotDirty`, and resident-map work scans.
- Tests: viewport prioritization, stale/in-flight/pending/dataless semantics,
  re-wake after validated stale drops.

### Phase 5: Retire Resident Values

- Remove Store resident per-asset values.
- Classify scan/enrichment changes through SQL-backed facts.
- Remove `currentSnapshot()` and resident merge paths.
- Tests: scan no-op publishes nothing; detail-only enrichment advances the grid
  detail-refresh generation without re-running the order query; insert and delete
  report correctly; stale enrichment writes remain guarded by SQL.

### Phase 6: Scale Validation And Tuning

- Run production-size and synthetic large-library scenarios.
- Record ordered-ID query latency, reader latency, reader-pool wait,
  main-run-loop stalls, and diffable apply spans.
- Add tuning only if measurements require it.

## Living Documentation And Comment Audit

Update:

- `docs/requirements.md`
- `docs/index.md`
- ADRs 0002, 0004, 0005, 0006, 0007, 0009, and ADR 0010 status
- `docs/onboarding.md`
- specs 0017, 0018, 0022, and 0024 where they retain current-state claims
- file guides in `CatalogModels.swift`, `CatalogStore.swift`,
  `CatalogStorePersistence.swift`, `CatalogProjection.swift`,
  `CatalogWindowViewModel.swift`, `MediaAssetCollectionView.swift`,
  `MediaAssetTileView.swift`, and `EnrichmentCoordinator.swift`

Remove comments that describe retired value-map publication, blob metadata, or
resident Store ordering as current.

## Instrumentation And Performance

Required durable JSONL:

- `catalog.store.change`: changed/inserted/deleted/sort-affecting counts,
  library-change Boolean
- `catalog.store.query.order`: scope, root count, count, ms
- `catalog.store.query.tileDetail`: request count, result count, ms
- `catalog.store.query.enrichment`: returned count, ms
- `catalog.projection.window`: scope, count, detail-refresh generation, query ms,
  equality ms, total ms, and state-change flags
- `ui.mainRunLoop.stall`: latest publication kind and generation

Required unified logs/signposts:

- ordering query span
- tile-detail reader batch/request/apply/drop/cancel
- thumbnail load/apply/drop
- visible detail requery and reconfigure count
- diffable structural apply span
- slow cell configuration

Performance gates:

- no repeated active-app stalls during detail-only enrichment
- detail-only changes do not sort full maps or compare full maps
- visible detail request-to-apply latency is measured
- production-size run evidence is captured
- large synthetic evidence is captured before declaring the target scale satisfied

## Code-Smell Review

Risks and mitigation:

- MainActor gravity: DB queries and media work stay off-main; grid only applies
  visible results.
- SwiftUI body work: SwiftUI receives chrome and IDs only; no sorting/filtering
  in views.
- State duplication: no resident per-asset Store map after Phase 5.
- AppKit bridge sprawl: the AppKit bridge owns only viewport, reuse, diffable
  structure, and detail-reader backpressure.
- Unsafe concurrency escape: detail reads are keyed, cancellable, and
  generation-guarded.
- Stringly typed domain facts: Store APIs use typed `MediaAssetID`,
  `SidebarSelection`, and `MediaSortMode`.
- Diagnostic payload sprawl: high-frequency per-cell events stay in unified
  logs/signposts; JSONL records bounded scalar summaries.

## Implementation Evidence

Focused verification added a storage-level query-plan test proving the current
ordered-ID and enrichment-candidate SQL streams from root-local or global covering
indexes without `TEMP B-TREE` sorts:

- `idx_media_asset_order_root`
- `idx_media_asset_order_global`
- `idx_media_asset_needs_enrichment_root`
- `idx_media_asset_needs_enrichment_global`

Production-size evidence was captured after deleting only app-owned state:

- deleted `~/Library/Application Support/net.melisma.Otos/Catalog`
- deleted `~/Library/Application Support/net.melisma.Otos/Thumbnails`
- deleted session diagnostics under
  `~/Library/Application Support/net.melisma.Otos/Diagnostics/`
- preserved originals in the tracked library roots

The fresh run used two OneDrive-backed roots and reached 25,050 cataloged rows:

- `/Users/example/Library/CloudStorage/OneDrive-Personal/Backup`: 3,308 rows
- `/Users/example/Library/CloudStorage/OneDrive-Personal/Family/Jamien kuvat`:
  21,742 rows

Artifacts:

- build/run log:
  `build/Diagnostics/otos-prod-run-20260630-133412.log`
- unified/signpost log:
  `build/Diagnostics/otos-unified-20260630-133412.log`
- JSONL copy:
  `build/Diagnostics/catalog-diagnostics-20260630-133450.jsonl`
- summary:
  `build/Diagnostics/catalog-diagnostics-20260630-133450.txt`

Summary from `script/catalog-diagnostics.sh check`:

- events: 2,398
- scan finishes: 10, scan errors/issues: 0
- ordered-ID queries: 56, worst query: 74 ms, max count: 25,050
- projection publications: 57, worst total: 86 ms
- tile-detail queries: 704, worst query: 12 ms, max requested/returned: 33/33
- enrichment-candidate queries: 1,364, worst query: 32 ms, max returned: 4
- thumbnails written during the short run: 453
- main-run-loop stalls: 2 startup/window stalls, worst 175 ms; these were not
  correlated with ordered-ID, tile-detail, or enrichment query work

The final SQLite query plans for the production database were:

```sql
SCAN media_asset USING COVERING INDEX idx_media_asset_order_global
SCAN media_asset USING INDEX idx_media_asset_needs_enrichment_global
```

Observed residual behavior: QuickLook/OneDrive thumbnail materialization emitted
filesystem events under the `Backup` root during enrichment. Those events
scheduled repeated root rescans; each rescan observed the same 3,308 rows and
deleted 0 rows. This is not UI flicker or catalog deletion, but it is remaining
background churn to tune if it becomes user-visible or consumes measurable CPU.

## Acceptance Criteria

- Old local catalog state is destructively reset without touching originals.
- Thumbnails discarded by reset regenerate through enrichment.
- Store is the only owner of SQL/GRDB/row IDs.
- UI publication carries ordered IDs plus a scalar detail-refresh generation, not
  a full asset value map.
- Per-asset detail is read through a bounded controller-owned reader.
- Visible detail changes update progressively and do not disturb offscreen or
  unrelated visible cells.
- Metadata sort/filter/search columns are queryable; long-tail metadata is
  preserved in `metadata_extra_json`.
- Enrichment selection uses Store queries, not a resident map scan.
- Full-map sort/equality and `assetsByID` UI publication are retired.
- Query-plan tests prove indexed order/enrichment paths.
- Performance evidence shows no repeated active-app stalls during detail-only
  enrichment on a production-size library.

## Verification

- Local checks: `script/verify.sh`
- Focused tests:
  - destructive reset/original preservation
  - schema/index/query-plan tests
  - Store query output tests
  - Projection identity-publication tests
  - grid reader batching/dedup/cancel/stale-drop tests
  - enrichment query-selection tests
  - source hygiene for no UI/Projection GRDB access
- Performance/log evidence:
  - `script/catalog-diagnostics.sh check`
  - `script/logs.sh Catalog`, `script/logs.sh UI`, `script/logs.sh Performance`
  - `script/profile.sh "Animation Hitches" 10s` if stalls remain
  - `script/profile.sh "Time Profiler" 10s` if query or apply spans remain high
- Stale-document audit:
  - ADRs, specs, requirements, onboarding, index, process references, file guides
- Code-comment accuracy audit:
  - every changed persistence, catalog, projection, view-model, AppKit, tile, and
    enrichment boundary
- CI expectations:
  - local `script/verify.sh` required
  - remote CI recorded unless GitHub reports an explicit billing/quota blocker
