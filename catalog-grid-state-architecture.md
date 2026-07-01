# Catalog Grid State Architecture

Status: non-authoritative planning note, superseded by
`docs/adr/0010-store-owned-query-catalog-and-identity-grid.md` and
`docs/specs/0025-store-owned-query-catalog-and-identity-grid.md` for the
implemented architecture.

Date: 2026-06-29

This document replaces an earlier multi-option comparison. One design is chosen and
described here: a **Store-owned, SQLite-backed catalog projection** where the UI
holds only ordered asset identities and every per-asset value is faulted on demand.
Research backing the choice lives in
[docs/research/catalog-storage-and-query-models.md](docs/research/catalog-storage-and-query-models.md)
and [docs/research/media-grid-best-practices.md](docs/research/media-grid-best-practices.md).

## 1. Goal and scale target

Otos is a Lightroom-class media browser. The target is **one media view scaling
toward ~1M items in a single scrollable grid**, where:

- order changes continuously as metadata-driven sort keys (e.g. capture date)
  arrive from background enrichment,
- thumbnails and per-item detail arrive constantly and must paint progressively
  without disturbing the viewport,
- sort, filter, and search over metadata are core product surfaces (now or soon),
- the main thread stays well under the 100 ms hang threshold while all of the above
  happens in the background.

### 1.1 Motivating evidence

The current architecture's failure is measured, not theoretical. In a representative
22,263-item selected scope with background enrichment trickling in, one minute of
durable diagnostics showed:

- 52 projection publications and 24 main-run-loop stalls; worst stall 1,159 ms;
  14 stalls at or above 300 ms,
- projection ~462 ms avg / 865 ms max, of which the full-catalog sort was ~366 ms
  avg / 661 ms max — **per publication**,
- enrichment arrived in tiny batches (≤3 results), each waking a full-catalog sort,
  a full value-map equality, and a broad `@Observable` assignment,
- the selected set was stable (no real inserts/deletes).

The cost is whole-catalog work provoked by tiny detail changes. The current model
holds the full per-asset value map resident, copies it through publication, and
re-sorts and deep-diffs it at 10 Hz. At 22k this already janks; it has no version
that scales to 1M.

## 2. The decision

**The filesystem remains Otos's source of truth for media existence and filesystem
facts. SQLite is the Store-owned, authoritative *catalog/overlay projection* of that
truth — subordinate to the filesystem, which wins and is reconciled to on
disagreement — and it is the single place per-asset detail is read from. The UI
holds only the ordered list of `MediaAssetID`s for the current view; per-asset
detail is faulted on demand by the cell that paints it. Sorting, filtering, and
enrichment-selection are indexed database queries, and every query is issued by the
Store — the one owner of the database.**

In one line: **hold order, fault detail, query the projection for everything that
spans all assets — all behind the Store, all still deferring to the filesystem.**

Source-of-truth hierarchy, explicit because it is a non-negotiable principle:

1. the **filesystem** — what media exists, and its filesystem facts,
2. the **SQLite catalog projection** — the Store's durable, rebuildable overlay
   (facts mirrored from scan, plus enrichment), which defers to the filesystem,
3. the **resident UI state** — only the ordered IDs for the current view, a
   projection of the projection.

This is what shipping media-library apps do (Lightroom, Apple Photos, digiKam all
query the database for sort/filter and never hold a full hand-maintained in-memory
catalog at scale). It also dissolves two natural objections:

- *"The database can't be in memory."* A disk-backed SQLite with WAL, a sized
  `cache_size`, and `mmap` keeps the hot working set in RAM through the page cache;
  indexed reads run at near-memory speed. You keep in-memory speed without a
  duplicate model.
- *"In-memory sort/enrichment-selection was simpler."* Those operations become
  `ORDER BY <indexed column>` and `WHERE <stale predicate> LIMIT n`. Today they are
  O(N) scans of the resident map on every tick; as indexed queries they are simpler
  and cheaper at scale, not harder.

## 3. Why this is the right design, not just a faster one

- **It removes the structural problem, not a symptom.** The resident, published,
  diffed value map is what does not scale. This design deletes it outright rather
  than making it cheaper to diff.
- **It matches the product.** Sort/filter/search over metadata require queryable,
  indexed columns. Once that infrastructure exists, sourcing order and
  enrichment-selection from the same indexes is the simplest whole, and a parallel
  in-memory model becomes redundant second machinery.
- **It preserves single ownership.** All database access stays inside the Store
  (Section 4), satisfying the principle that persistence has exactly one owner and
  the UI never bypasses it.
- **It is the evidenced approach at scale** (see the storage research note).

The honest cost: it is storage-latency sensitive (benign on the SSDs every target
ships), it depends on declared indexes, and it needs a concurrent read path. These
are the costs every reference app pays.

## 4. Ownership and boundaries

This is the core of the design. Each layer owns one thing and never reaches across.

- **CatalogStore (actor) — the single owner of the database and of every query.**
  Owns the GRDB connection pool, all reads and writes, scan/enrichment mutation
  ordering, and change classification. Exposes a query surface (Section 8). It is
  the only code that touches SQL, GRDB types, or row IDs. It holds **no** resident
  per-asset value map.
- **CatalogProjection (actor) — owns presentation policy, not data.** Owns the
  selected scope, the active sort mode, the removed-library fallback, the window
  title, and the empty-state meaning. It **calls** Store query APIs (e.g.
  `orderedAssetIDs(scope:sort:)`) passing only domain policy types; it issues no
  SQL, holds no catalog values, and builds no value map. It publishes ordered IDs +
  chrome + a changed-ID signal.
- **CatalogWindowViewModel (MainActor) — owns UI delivery.** Assigns chrome +
  ordered IDs to SwiftUI; forwards the changed-ID signal and the detail-reader
  capability to the grid; owns the async lanes (selection, mutation, viewport).
  Holds no catalog data.
- **The AppKit grid controller — owns the viewport, structure, and the detail
  reader.** A diffable data source over ordered `MediaAssetID`s; owns cell reuse,
  the visible set, the changed-ID-to-visible-cell reconfiguration, and a
  `MediaTileDetailReader` that batches/dedups/cancels detail reads (Section 11).
  Holds no value map.
- **The cell — paints one asset.** Its lifecycle event is "I now represent ID X";
  it requests detail through the controller's reader, never the Store directly, and
  applies the result behind a generation guard. Holds only its own current detail.
- **EnrichmentCoordinator (actor) — owns enrichment scheduling.** Asks the Store
  which assets need enrichment (prioritized by viewport), runs the work off-actor,
  writes results back through the Store. Holds no resident catalog snapshot.

The decisive rule that answers "doesn't ordering then go straight to SQLite?":
**no — ordering executes inside the Store behind a method; Projection owns the sort
*choice*, the Store owns the sort *execution*.** Nothing except the Store ever
touches the database, a GRDB type, SQL, or a row ID. Today Projection receives the
whole value map and sorts it, which is itself a mild ownership smell; in this design
Projection never sees catalog values at all. Ownership is preserved and clarified,
not relocated.

## 5. Persistence: the clean SQLite schema

SQLite holds the complete, queryable, columnar catalog projection. It remains
subordinate to the filesystem (Section 2): scan mirrors filesystem facts into it and
reconciles deletions; enrichment adds overlay. **No opaque metadata blob** — an
opaque blob cannot be sorted, filtered, or indexed, which defeats the product.
Thumbnail *bytes* remain files in `ThumbnailStore`, keyed by name (correct;
unchanged).

There is **no migration**. Otos has zero users and the catalog is a rebuildable
projection of the filesystem, so a schema change resets and rebuilds (re-scan facts,
re-enrich metadata/thumbnails) rather than migrating. The schema is defined clean,
from zero (Section 14, Phases 0–1).

- **`media_asset` (hot row):** identity (`library_root_id`, `relative_path`),
  filesystem facts (name, content type, byte size, created/modified), the
  enrichment staleness stamps, `thumbnail_path`, `capture_date`, and a persisted,
  indexed **`sort_key`** (the natural-order key currently computed by `MediaSortKey`,
  moved to write time). This narrow row serves ordering, enrichment-selection, and
  the grid tile.
- **`asset_metadata` (1:1 cold companion):** the extended **scalar** metadata the
  inspector and metadata filters use — dimensions, camera make/model, lens, ISO,
  f-number, focal length, orientation, a single capture timestamp, a single GPS
  point, rating — as typed, indexable columns (these are one-per-asset, so they are
  columns, not child tables); plus a **`metadata_extra_json`** column that preserves
  the full extracted payload so nothing enrichment found is lost and any field can
  be promoted to an indexed column later without re-enrichment. This row is loaded
  only by the inspector or a metadata-filter query — never by the grid tile.
- **Child tables** only for genuinely *multi-valued* metadata (keywords, faces,
  multi-point tracks), added when those features ship.
- **Indexes:** on every sort column (`sort_key`, `capture_date`), a partial index
  for the needs-enrichment predicate, and a column index per metadata facet as
  filters ship.
- **Engine config:** `DatabasePool` with WAL for concurrent readers alongside the
  single writer; `cache_size`/`mmap_size` sized to keep the hot working set
  resident. (The `.inMemory` test location stays a `DatabaseQueue`; GRDB pools
  require a file/WAL.)

## 6. State: what is resident, what is faulted

The residency rule is singular: **a value is resident only if it is needed to span
all assets at once; everything else is faulted on demand.**

Resident:

- the ordered `[MediaAssetID]` for the current scope (the query result that backs
  the diffable data source — IDs, not values; gives free random access and counts),
- per-root availability (a handful of runtime entries, not persisted).

Faulted on demand from SQLite (page cache keeps it near-memory-speed):

- the tile detail for the visible window (`MediaTileDetail`), via the reader,
- the full metadata for the one selected asset (inspector),
- thumbnail bytes (separate keyed file pipeline).

Per-asset resident state: none. The current `assetsByRootPath` value map and the
`makeSnapshot()` O(N) rebuild are deleted.

## 7. The resident ordered-ID list

This design keeps one resident, all-asset structure: the ordered `[MediaAssetID]`
for the current scope, applied to an `NSDiffableDataSourceSnapshot`. This is the
committed structure for the ~1M target. Holding the full ordered identity list
resident is what gives the grid free random access, exact counts, and structural
diffing, while every per-asset *value* stays out of memory (Section 6). At roughly
150 MB for a million path-based IDs it is an accepted, bounded cost for a heavy
media app.

Should a catalog ever grow far past this target, the known escape hatch is a
count + range-fetch virtual data source (the grid reports an item count and fetches
ID windows by index range from the Store, with no full ID snapshot). It is
explicitly out of scope here and deliberately not designed for; this document
commits to the resident ordered-ID list.

## 8. Store query and notification surface

The Store returns only domain types; no GRDB value, SQL, or row ID crosses this
boundary (enforced by a test, Section 16).

```swift
extension CatalogStore {
    // Ordered identities for a scope+sort, computed by an indexed query.
    func orderedAssetIDs(scope: SidebarSelection, sort: MediaSortMode) async -> CatalogOrderedIDs

    // Detail for the visible/prefetch window only; keyed read, never the whole set.
    func tileDetails(for ids: [MediaAssetID]) async -> [MediaAssetID: MediaTileDetail]

    // Enrichment work selection, prioritizing the current viewport.
    func assetsNeedingEnrichment(prioritizing viewport: [MediaAssetID], limit: Int) async -> [EnrichmentTarget]

    // Full metadata for one asset (inspector).
    func metadata(for id: MediaAssetID) async -> AssetMetadata?
}

// Ordered IDs carry the structural generation they were produced under (Section 11).
nonisolated struct CatalogOrderedIDs: Sendable, Equatable {
    var scope: SidebarSelection
    var sort: MediaSortMode
    var structuralGeneration: Int
    var ids: [MediaAssetID]
}

nonisolated struct MediaTileDetail: Sendable, Equatable {
    var name: String?
    var contentTypeIdentifier: String?
    var bestCaptureDate: Date?
    var thumbnailPath: String?
}
```

Change notification carries identities, not a contentless flag:

```swift
nonisolated struct CatalogChange: Equatable, Sendable {
    var changedIDs: Set<MediaAssetID>     // detail changed in place
    var insertedIDs: Set<MediaAssetID>
    var deletedIDs: Set<MediaAssetID>
    var sortAffectingIDs: Set<MediaAssetID> // changed a column the active sort uses
    var librariesChanged: Bool            // add/remove/availability/activity
}
```

Projection decides from a change whether order/membership moved (republish the
ordered ID list with a new generation) and always forwards the changed-ID set
(repaint visible cells in it). The published grid state is identities only:

```swift
nonisolated struct CatalogMediaGridState: Equatable {
    var scope: SidebarSelection
    var structuralGeneration: Int
    var orderedAssetIDs: [MediaAssetID]
}
```

The cell-detail capability handed to the grid is narrow and Store-backed, never
GRDB:

```swift
nonisolated protocol MediaTileDetailReader: Sendable {
    // Controller-owned implementation batches, dedups, and cancels (Section 11).
    func detail(for id: MediaAssetID) async -> MediaTileDetail?
}
```

## 9. Data flows

**Cold launch → first paint.** Store opens the pool → Projection calls
`orderedAssetIDs` → publishes the ID list + chrome → grid applies the diffable
snapshot → AppKit instantiates the ~visible cells → each cell asks the controller's
reader for its detail; the reader batches the visible window into one `tileDetails`
query and distributes results → cells paint (thumbnail loads in the same task).

**Scroll into a new region.** AppKit instantiates cells for already-resident IDs
(random access is free) → each says "I represent ID X" to the reader → the reader
coalesces the new window into a batched read and cancels reads for IDs that left the
window → cells scrolled away are reused, their pending detail dropped by the
generation guard. No publication.

**Detail change for a *visible* asset, no reorder** (today's jank case). Enrichment
writes asset X → Store emits `changed {X}`, `sortAffecting {}` → Projection sees no
sort-affecting change → forwards `{X}`, no new list → grid: X ∈ visible →
re-request X's detail through the reader → X's cell repaints. One cell. No sort, no
diff, no broad assignment.

**Detail change for an *offscreen* asset.** Same until Projection forwards `{X}` →
grid: X ∉ visible → nothing. When the user scrolls to X later, its cell requests the
now-current detail.

**Metadata-driven reorder** (date sort; a capture date arrives). Store writes X and
emits `changed {X}`, `sortAffecting {X}` → Projection's sort mode is date → it
re-queries `orderedAssetIDs` (new `structuralGeneration`) and publishes the new
list + `{X}` → grid applies the new snapshot (diffable moves X's cell) and
re-requests X's detail. The re-query is an index-ordered scan, not a sort. Coalesce:
re-query only after a write batch reported sort-affecting IDs (Section 11).

**Scope/sort change.** Projection resolves scope/sort policy → re-queries
`orderedAssetIDs` (new generation) → publishes the new list (scroll resets per
existing rules) → cells for the new view request their detail.

**Insert / delete (scan reconcile).** Store mutates rows and reports
inserted/deleted IDs → Projection republishes the list (new generation) with those
IDs → diffable inserts/removes cells.

**Enrichment selection.** Coordinator wakes → `assetsNeedingEnrichment(prioritizing:
viewport, limit:)` → works the batch off-actor → writes back through the Store,
which emits `changed`. Replaces the current full-map resident scan.

## 10. Viewport ownership and flow

There is exactly one owner of "what is visible," and the anti-duplication rule
follows from it.

- **Owner: AppKit.** `indexPathsForVisibleItems()` is the ground truth, available
  synchronously on the main actor. No other layer keeps an authoritative copy.
- **Grid controller (main actor):** reads the visible set from AppKit *on demand*
  to intersect it with an incoming changed-ID signal (`changedIDs ∩ visible`) and to
  drive the reader's window. It does not cache an authoritative copy — it queries the
  owner.
- **EnrichmentCoordinator (its own actor):** is *delivered* the latest visible set
  as a newest-value priority hint and holds it, because it is remote and
  asynchronous and cannot read AppKit synchronously. This stored copy is explicitly
  non-authoritative and staleness-tolerant.
- **Projection and Store know nothing about visibility, deliberately.** Projection
  forwards *all* changed IDs; the visible intersection happens only at the grid, the
  only layer that owns visibility. Pushing the visible set up into Projection/Store
  would be the duplication to avoid.

```text
scroll -> NSCollectionView updates visible cells           (owner: ground truth)
       -> grid controller reads indexPathsForVisibleItems  (the one derivation)
            |- local: changedIDs ∩ visible -> re-request those cells' detail
            |- drive the reader window (batch/cancel)
            '- forward newest visible IDs -> ViewModel -> EnrichmentCoordinator (hint)
```

No layer holds a competing authoritative visible set; the ViewModel stores none; the
coordinator's copy is a labeled non-authoritative hint.

## 11. Concurrency, generations, and backpressure

**Actors and isolation.**

- **Store:** an actor over a GRDB `DatabasePool`. Writes (scan/enrichment) serialize
  through the single writer; reads (ordering, tile detail, metadata) run
  concurrently via WAL so a view read never blocks behind a write.
- **Projection:** keeps its one-in-flight, dirty-coalesced 10 Hz loop. Its published
  value is the ordered ID list + chrome; it never holds catalog values.
- **ViewModel/grid:** MainActor. **Cells:** request detail through the reader.
- **EnrichmentCoordinator:** an actor; heavy work runs in off-actor child tasks.

**The detail reader is baseline backpressure, not an optimization.** The repo
requires async UI intents to define their delivery semantics, and unbounded per-cell
reads during fast scroll are a real thundering-herd cliff. The controller-owned
`MediaTileDetailReader` therefore, from the first implementation:

- coalesces all cell detail requests in a run-loop turn into one batched
  `tileDetails(for: window)` query,
- dedups in-flight requests for the same ID,
- cancels reads for IDs that have left the visible window,
- applies a result to a cell only if the cell still represents that ID.

Prefetch *lookahead* (reading beyond the visible window) is a separate, measured
lever (Phase 6) — deferred, not baseline.

**Generations and stale-result rejection.** Everything detail-bearing is async, so
every async result is validated before it is applied:

- Each ordered-ID publication carries a monotonic `structuralGeneration`, bumped on
  any scope, sort, or membership change.
- An `orderedAssetIDs` re-query result is applied only if the scope+sort it was
  issued under is still current; otherwise dropped and counted.
- A `tileDetails` result is applied to a cell only if the cell still represents that
  `MediaAssetID` (per-cell `loadGeneration`, bumped on configure and on reuse).
- A changed-ID reconfigure is ignored if its structural generation was superseded by
  a newer published list.

**Backpressure rules.**

- One publication in flight; dirty is coalesced and cleared *before* the await so
  input arriving during the query survives for the next tick.
- **Structural dominates detail:** if a scope/sort/membership change is pending,
  publish the new ordered list rather than a detail-only repaint.
- **Changed IDs coalesce by set,** not by queue: the cell reads current truth at
  request time.
- **Viewport hint is newest-value.**
- **Structural commands are lossless and ordered** (library add/remove, scope).
- **Re-sort trigger:** re-query ordered IDs only after a write batch reported
  sort-affecting IDs; coalesce at the 10 Hz cadence; the query is an index scan.

## 12. Thumbnails

Unchanged in principle and already correct: thumbnail bytes live as files in
`ThumbnailStore`, keyed by name, loaded off the main actor by the cell. Under this
design the cell receives `thumbnailPath` in its `MediaTileDetail` (from the reader)
and loads the thumbnail in the same detached task, applying both behind one
generation guard. On a clean-schema reset (Section 14) the thumbnail directory is
cleared with the catalog and regenerated by enrichment.

## 13. What this deletes and what it adds

Deletes:

- the resident `assetsByRootPath` per-asset value map,
- `currentSnapshot()` / `makeSnapshot()` and the O(N) per-tick map rebuild,
- `CatalogMediaGridState.assetsByID` and its flow through publication,
- the full-map equality in Projection (`PublicationChangeSummary`),
- the in-memory sort (`CatalogProjection.sortAssetIDs`) and per-publication ordering,
- the grid controller's `assetsByID`,
- the opaque `metadata_blob` and its encode/decode path,
- the incremental `v1/v2/v3` migrations (replaced by one clean schema; no migration),
- the in-memory enrichment scan over the full resident map,
- `MediaAsset.sortKey` computed at init (moves to a persisted, write-time column).

Adds:

- `DatabasePool` + WAL + a tuned page/mmap cache, with DEBUG reset-on-schema-change,
- a clean schema: indexed `sort_key`, the `asset_metadata` companion (scalar columns
  + `metadata_extra_json`), facet indexes, and child tables only for multi-valued,
- the Store query surface (Section 8) and the identity-carrying `CatalogChange`,
- the controller-owned `MediaTileDetailReader` (batching/dedup/cancellation),
- the enrichment-selection query,
- the structural-generation stale-result rejection (Section 11).

## 14. Implementation plan

Sequencing rules, binding for every phase:

- Each phase lands as its own increment on `main`, passing `script/verify.sh`, and
  is independently shippable — the app works after each.
- No compatibility shims and no migration (repo rule + zero users). Where a no-shim
  switch couples two layers, they land in the same increment (Phase 3).
- Each phase carries a **retirement list** (named symbols deleted), a **proof plan**
  (tests + verification), an **instrumentation** delta, and an **exit gate**.
- Performance-sensitive phases (3, 6) carry trace/log artifacts per
  `docs/process/performance.md`.

### Phase 0 — DB engine and clean-schema reset

- **Goal:** the concurrent-read engine and the reset mechanism, before any read path
  moves onto it.
- **Changes:** production/file `CatalogStore.Location` uses `DatabasePool` (WAL);
  set `cache_size`/`mmap_size`. The `DatabaseMigrator` is collapsed to a single
  clean migration set with **no awareness of any prior schema**; in DEBUG,
  `eraseDatabaseOnSchemaChange = true` so iterating the schema wipes and rebuilds the
  local catalog. On a reset/erase, the thumbnail directory is cleared too (its
  name→file mapping is gone) and regenerated by enrichment.
- **Retirement:** production `DatabaseQueue`; the `v1/v2/v3` incremental migrations.
- **Instrumentation:** reader-pool acquisition spans; WAL checkpoint spans; a log on
  schema-reset.
- **Tests:** reset acceptance criteria (Section 16); concurrent read during a write
  is coherent and never corrupts.
- **Exit gate:** a stale local catalog from a prior schema is discarded and the app
  starts clean; reads run concurrently with a write.

### Phase 1 — Clean schema from zero

- **Goal:** the queryable, orderable schema, created from nothing.
- **Changes:** define `media_asset` (hot row incl. write-time `sort_key`),
  `asset_metadata` (scalar columns + `metadata_extra_json`), and the indexes
  (`sort_key`, `capture_date`, partial needs-enrichment). Child tables are deferred
  to Phase 7. The UI still uses the resident map at this point.
- **Retirement:** `metadata_blob`, `encodeMetadata`/`decodeMetadata`,
  `metadataBlob(...)`; `MediaAsset.sortKey` computed in `init`.
- **Instrumentation:** schema-creation log.
- **Tests:** ordering by `sort_key` matches `MediaSortKey`; row IDs do not leak;
  `EXPLAIN QUERY PLAN` shows ordering and needs-enrichment queries use their indexes.
- **Exit gate:** scan and enrichment write the new schema; no opaque blob exists.

### Phase 2 — Store query surface (additive, behind tests)

- **Goal:** prove the read APIs correct with nothing consuming them yet.
- **Changes:** add `orderedAssetIDs`, `tileDetails`, `assetsNeedingEnrichment`,
  `metadata`; add the identity-carrying `CatalogChange` produced alongside the
  existing notification.
- **Instrumentation:** per-query category, scope, count, ms; dev-only `EXPLAIN QUERY
  PLAN` capture.
- **Tests:** ordering matches `MediaSortKey` and `capture_date`; scope and
  availability filtering match current Projection rules; `tileDetails` returns only
  requested IDs; needs-enrichment returns stale assets, viewport-prioritized;
  `metadata` returns columns or nil.
- **Exit gate:** every query proven correct against fixtures equivalent to current
  Projection output.

### Phase 3 — Identity publication + reader-backed faulting (the core switch)

- **Goal:** the UI runs entirely on ordered IDs + faulted detail. Projection,
  ViewModel, grid, cell, and the reader change together (no shim).
- **Changes:** Projection publishes `CatalogMediaGridState{scope, generation,
  orderedAssetIDs}` + chrome + changed-ID signal, stops pulling/sorting/diffing a
  value map; ViewModel forwards the changed-ID set + the reader capability; the
  controller drops `assetsByID`, owns the `MediaTileDetailReader`
  (batch/dedup/cancel, Section 11), applies new lists, and reconfigures
  `changedIDs ∩ visible`; the cell requests detail through the reader behind its
  generation guard; structural/cell generation rejection per Section 11.
- **Retirement:** `CatalogProjection.sortAssetIDs`, `orderedAssetIDs(for snapshot)`,
  the value-map `buildWindowState`, `PublicationChangeSummary`,
  `CatalogMediaGridState.assetsByID`, the controller's `assetsByID` and the
  `refreshVisible` map swap, the asset-carrying `MediaAssetCollectionItem.configure`.
- **Instrumentation:** publication kind/generation; reader batch size, dedup count,
  cancel count; tile-detail apply/drop; changed-ID visible reconfigure count;
  slow-cell config.
- **Tests:** offscreen change → zero reconfigures; visible change → one; reorder →
  move + re-request; stale generation dropped; cell reuse cancels the request; a
  late recycled-cell result is dropped; fast-scroll batches/cancels rather than
  issuing N reads; scroll preserved/reset per existing rules.
- **Exit gate:** no value map anywhere in the UI path; trace shows reader-batched
  faulting and no full-catalog work on a detail change; production-size run shows no
  repeated active-app stalls during detail-only enrichment.

### Phase 4 — Enrichment selection via query

- **Goal:** the coordinator stops scanning a resident snapshot.
- **Changes:** `EnrichmentCoordinator` uses `assetsNeedingEnrichment(...)` instead of
  `latestSnapshot`/`currentSnapshot()`; viewport prioritization is a query argument.
- **Retirement:** `latestSnapshot`, `snapshotDirty`, the cursorless
  `nextEnrichmentWork` scan over `assetsByID`, `hasEnrichmentWorkRemaining`.
- **Tests:** the query returns the same work set the resident scan would, prioritizes
  viewport, honors in-flight/pending/dataless semantics; a validated stale drop
  re-wakes correctly.
- **Exit gate:** no resident snapshot consumed by enrichment.

### Phase 5 — Retire the resident value map

- **Goal:** the Store holds zero per-asset values.
- **Changes:** the scanner reports inserted/changed/deleted IDs from the
  upsert/reconcile via SQL (`RETURNING` or pre/post set diff) into `CatalogChange`
  instead of comparing against the resident copy; enrichment writes rely on the
  existing SQL source-signature `WHERE` guard for staleness and stop mirroring into
  memory.
- **Retirement:** `assetsByRootPath`, `makeSnapshot()`, `currentSnapshot()`,
  `applyScannedBatchToMemory`'s resident compare, `mergeEnrichmentIntoMemory`,
  `currentlyWritableEnrichments`' resident validation.
- **Tests:** a re-scan observing identical files publishes nothing; a detail-only
  scan change reports `changedIDs`; insert/delete reports correctly; the stale
  enrichment write is still rejected by the SQL guard.
- **Exit gate:** zero resident per-asset values; prior catalog-lifecycle and
  enrichment tests pass against the database paths.

### Phase 6 — Scale validation and tuning

- **Goal:** confirm the design holds at the target scale and tune the knobs.
- **Changes:** size `cache_size`/`mmap_size`; add synthetic 100k and ~1M fixtures;
  coalesce re-sorts only if measurement requires; add prefetch lookahead only if
  measured necessary.
- **Instrumentation:** snapshot apply/diff ms and ID-array memory at production-size,
  100k, and ~1M; re-sort cadence under date-enrichment; per-cell read latency; pool
  read-wait; main-thread stall correlation.
- **Exit gate:** main thread within budget under enrichment-driven re-sorting and
  fast scroll at production-size and ~1M.

### Phase 7 — Metadata filter/search (future, feature-gated)

- Child tables for multi-valued metadata; facet indexes; query predicates;
  promotion of `metadata_extra_json` fields to indexed columns as filters ship. Out
  of scope until approved; listed so the schema and query surface stay
  forward-compatible.

## 15. Failure modes and mitigations

- **Stale async result paints the wrong cell.** Mitigation: structural generation +
  per-cell `loadGeneration`; drop and count stale results (Section 11).
- **Thundering herd of per-cell reads on fast scroll.** Mitigation: the
  controller-owned reader batches per tick, dedups, and cancels obsolete reads — this
  is baseline, not deferred.
- **Missed changed-in-place signal — a visible cell shows stale detail.** The
  changed-ID signal is the *only* in-place repaint trigger. Mitigation: test visible
  and offscreen changed-ID delivery directly; a structural republish re-requests the
  cell anyway.
- **Re-sort churn under metadata sort.** Mitigation: re-query only on reported
  sort-affecting IDs; coalesce at 10 Hz; the query is an index scan.
- **Un-indexed query becomes a full scan.** Mitigation: every sort/filter has an
  index; `EXPLAIN QUERY PLAN` assertions in tests catch a regressed plan.
- **Stale enrichment write after a newer scan.** Mitigation: the SQL
  source-signature `WHERE` guard (preserved from today) rejects it.
- **Scroll jump on a structural change.** Mitigation: preserve/reset per existing
  scope rules; test both.
- **Row-ID or GRDB type leakage across the Store boundary.** Mitigation: keep
  `StoredRoot`/`StoredAsset` and all GRDB types internal; a test/grep asserts none
  crosses the public boundary.
- **SQLite strain at extreme scale.** digiKam's ~100k guidance is the signal to
  revisit the engine; decided only with measurement, never preemptively.

## 16. Test plan

**Destructive-reset acceptance (Phase 0):**

- Given an old local catalog exists, the app starts on the new schema after the old
  catalog state is discarded.
- Given the reset occurs, originals on disk are untouched.
- Given thumbnails are discarded, they regenerate through enrichment.
- Given the DB is recreated, row IDs (and GRDB types) still never escape the Store.

**Unit / integration (narrowest useful boundary):**

- Ordering: `orderedAssetIDs` matches `MediaSortKey` natural order; date sort by
  `capture_date`; scope filtering (All vs library); unknown/unavailable excluded.
- Query plans: ordering and needs-enrichment queries use their indexes
  (`EXPLAIN QUERY PLAN` assertion).
- `tileDetails`: returns only requested IDs, correct fields.
- Enrichment selection: returns stale assets, excludes enriched, prioritizes
  viewport, honors in-flight/pending/dataless semantics.
- `metadata(for:)`: scalar columns + `metadata_extra_json` round-trip; nil when
  absent.
- `CatalogChange` classification: enrichment → `changedIDs` (+ `sortAffectingIDs`
  only under a sort using the changed column); scan no-op → empty; scan detail →
  `changedIDs`; insert/delete → inserted/deleted; library change → `librariesChanged`.
- Projection: publishes ordered IDs only (no value map); `structuralGeneration`
  increments on scope/sort/membership; removed-library fallback; empty-state.
- Reader: coalesces a window into one query; dedups in-flight; cancels reads for IDs
  that left the window; applies only to the still-current cell.
- Stale-result rejection: an `orderedAssetIDs` result under an old scope is dropped;
  a `tileDetails` result for a reused cell is dropped.
- Grid: offscreen changed ID → zero reconfigures; visible changed ID → exactly one;
  reorder → move + re-request.
- Ownership: no UI/Projection code references GRDB, SQL, or row IDs.

**Runtime scenarios (production-size, 100k, and ~1M fixtures):**

- Production-size cold launch to first paint.
- Scroll into an un-enriched region: progressive per-cell fill, no jank.
- Enrichment active while scrolling: viewport-prioritized, no viewport disturbance.
- Scope change small → large library: scroll resets; the new view faults.
- Filesystem-event burst that resolves to no visible change: no publication.
- Dataless-materialization completion while the asset is visible vs offscreen.
- 100k and ~1M: snapshot apply/diff cost, ID-array memory, re-sort cadence,
  per-cell read latency, and main-thread budget all within budget.

## 17. Instrumentation

**Durable JSONL (coarse boundaries, bounded scalars):**

- `catalog.store.change`: changed/inserted/deleted/sort-affecting counts,
  `librariesChanged`.
- `catalog.projection.publish`: kind (structure/detail), scope, count, generation,
  query ms, total ms, stateChanged.
- `catalog.store.query.order`: scope, sort, count, ms, `usedIndex` (dev builds).
- `catalog.store.query.enrichment`: returned, ms.
- `ui.mainRunLoop.stall`: existing scalar fields + latest publication kind and
  generation.

**Unified logs / signposts (hot paths):** ordering query; reader batch
(size/dedup/cancel); tile-detail apply/drop; thumbnail load start/apply/drop;
changed-ID visible reconfigure count; slow cell configuration; reader-pool read-wait;
diffable snapshot apply.

**Rules:** no per-asset JSONL in hot paths; dev-only `EXPLAIN QUERY PLAN` capture;
follow Apple's measure→fix→verify loop with the repo profile scripts.

## 18. Risks and open questions

- Whether prefetch lookahead is needed for per-cell read latency under fast scroll —
  Phase 6 measurement.
- The point at which SQLite itself (not the architecture) limits a very large,
  query-heavy catalog (digiKam's ~100k signal); revisit the engine only with
  evidence.
- Where the table of sort-affecting columns per sort mode is defined and tested.

## 19. Preserved invariants

Filesystem as the source of truth, with the catalog deferring and reconciling to it;
path-based `MediaAssetID` identity; SQLite row IDs and GRDB types private to the
Store; the scan/reconcile pipeline; disjoint scan-vs-enrichment column ownership and
stale-write validation; the overlay lifecycle; exactly one main window; passive
SwiftUI views; AppKit as the narrow high-cardinality rendering boundary; thumbnail
bytes as files; the tile's off-main load with a generation guard.

## 20. Documents to update when this lands

ADRs to revise (not yet — this is design input): 0002 (persistence: clean schema,
columns-not-blob, WAL/pool, no migration), 0004 (ownership: Store query surface,
Projection slimming, the detail reader), 0005 (publication: ordered IDs + changed-ID
signal, no value map), 0006 (grid: reader-backed cell faulting), 0007 (ordering:
indexed query, retire the sort-every-publication / shared-value-map model). Plus
`docs/onboarding.md`, `docs/requirements.md`, and the affected file guides. A
decision-complete spec under `docs/specs/` should precede implementation, with the
phases of Section 14 as its increments.

## 21. References

- Research: [catalog-storage-and-query-models.md](docs/research/catalog-storage-and-query-models.md),
  [media-grid-best-practices.md](docs/research/media-grid-best-practices.md)
- Current code: `Otos/Stores/CatalogStore.swift`,
  `Otos/Stores/CatalogStorePersistence.swift`, `Otos/Services/CatalogProjection.swift`,
  `Otos/ViewModels/CatalogWindowViewModel.swift`, `Otos/Views/MediaAssetCollectionView.swift`,
  `Otos/Views/MediaAssetTileView.swift`, `Otos/Services/EnrichmentCoordinator.swift`
- Current decisions: `docs/adr/0002`, `0004`, `0005`, `0006`, `0007`, `0008`, `0009`;
  `docs/process/performance.md`
