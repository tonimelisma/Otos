# Otos Architecture Map

The current-state map of the codebase: the one-directional dataflow, who owns what,
and where to make a change. Details of *why* live in `docs/adr/`; *what* the product
does lives in `docs/requirements.md`; file guides in the source explain each file.

## The one idea

The user's filesystem is the source of truth. Everything Otos stores (catalog +
thumbnail/metadata overlay) lives in Application Support and is a subordinate
projection. When they disagree, the filesystem wins. Most overlay is rebuildable
by re-observing the filesystem; import-batch stamps are the first non-rebuildable
overlay fact, so schema changes migrate additively and future/unrecognized
schemas refuse to open instead of erasing.

## One-directional dataflow

```
  filesystem + removable/camera source monitors  (the truth)
        │  read-only scan / device observation
        ▼
  CatalogStore (actor)  ── the only owner of SQLite catalog truth + query APIs
        │  cheap "something changed" signal + ordered-ID / detail queries
        ├───────────────▶ EnrichmentCoordinator (actor)  ── the one write-side branch:
        │   writes back      asks Store for candidates, produces thumbnails + metadata
        ▼                    (reads bytes, may materialize cloud files), writes to Store
  CatalogProjection (actor)  ── truth → UI-ready CatalogWindowState (off MainActor)
        │  coalesced ~1s for background changes, immediate for user query intents
        ▼
  CatalogWindowViewModel (@MainActor)  ── the SwiftUI bridge; assigns @Observable state
        │
        ▼
  SwiftUI views  →  grid / loupe(+filmstrip) detail (mode-switched)
                     MediaGridBridgeView (AppKit NSCollectionView; .grid or .strip)
                     PreviewImageLoader (actor) — loupe/compare full-size decode
```

Nobody reads "upward": a view never calls the database; the database never knows a
view exists. To answer "where does X happen," find the one layer that owns X.

## Actors and why

| Type | Isolation | Owns | Why an actor |
| --- | --- | --- | --- |
| `CatalogStore` | actor | SQLite, `RootRegistry`/`RootRuntimeState`, `FilesystemReconciler` (pure batch classify into typed dirty scopes), `FilesystemDirtyAccumulator` (per-root file/subtree/root coalesce), `ScanLeaseController` (lease/queue bookkeeping), `CatalogQueryGateway` (read SQL/mapping), `EnrichmentLeaseGateway` (enrichment claim leases + SQL), known-materialization suppression, integrity scheduler, removable-source state, change notifications, all catalog queries | serializes every mutation/query for free; a remove can be processed mid-scan safely (lease re-checked after every await); owned helpers are not second actors |
| `CatalogProjection` | actor | coalesced `CatalogWindowState` publication + all sorting/filtering/hiding/empty-state/scope derivation | keeps derivation off the main thread (that is what would hang the UI) |
| `MediaOperationCoordinator` | actor | greedy import-plan lifecycle per attached removable source, destination mapping, scalar presentation stream, queued Import | serializes per-source dirtiness; filesystem probes run off the actor |
| `MediaImportExecutor` | actor | journaled import for volumes and cameras: staging, exclusive publish, settlement, recovery | serializes one active import; copyfile/camera download off the actor |
| `ReorganizationPlanner` | pure enum | physical-member reservation graph + chain/cycle recipes (no FS writes) | called from tests/coordinator; probes via occupancy map |
| `ReorganizationExecutor` | pure enum + Store journal | component journal, same-volume no-overwrite moves, recovery observations, filesystemComplete handoff | Store owns lease/settlement; executor never catalogs temps |
| `LibraryReorganizationRunner` | actor | plan → journal → execute → settle for one fixed library; returns remap batches | ViewModel confirmation + remap UI |
| `EnrichmentCoordinator` | actor | two worker pools (8 enrich / 16 materialize maxima) + `EnrichmentAdmissionPolicy` (byte/video/viewport/root fairness), in-flight tracking, claim leases, known-materialization begin/end | serializes scheduling state; heavy decode/parse/download runs inside its worker tasks, off the actor |
| `PreviewImageLoader` | actor | loupe/compare full-size decode, dataless materialization gate, per-id coalesce + small LRU | serializes decode/cache state; byte reads off the actor |
| `CatalogWindowViewModel` | `@MainActor` | final SwiftUI state assignment, sidebar selection, grid selection model (`GridSelection`), view mode / loupe focus, owned per-slot pane-request tasks, lossless serial mutation delivery, monitor/task lifetimes, import presentation bridge | touches SwiftUI state; deliberately a thin bridge — heavy work belongs down a layer |

Rule of thumb: the main thread only assigns final UI state and starts work;
everything expensive happens on an actor off the main thread.

## Key subsystems

- **Identity** is typed: `LibraryRootPath` + `MediaRelativePath` = `MediaAssetID`. No
  invented durable IDs; the filesystem path is the identity (ADR 0003/0008). Each
  identity value carries a derived FNV-1a `fingerprint` for cheap Hashable /
  diffable hashing only — never persisted, never a second identity.
- **The grid** is the one AppKit boundary (`MediaGridBridgeView` +
  `MediaGrid*`), for cell reuse at tens of thousands of tiles. `MediaGridMutationGate`
  is the single arbiter of structural applies and zoom swaps. Mouse selection is
  model-owned (`GridSelection` lives in `CatalogWindowViewModel`; the AppKit controller
  renders it and the subclass never calls `super.mouseDown`). AppKit surfaces never
  write selection truth; the model flows one way, ViewModel → renderer, and
  `selectionIndexPaths` is render output. Paint truth lives in
  `TileContentStore` (sole decoded-image owner; visible IDs pinned; cost-bounded);
  tiles never blank a painted same-asset thumbnail (ADR 0006).
- **Sidebar/sources**: `SidebarSelectionPolicy` (pure) decides default/attach
  selection and All-Media visibility; eject is unmount-driven and honest (ADR 0014).
- **Enrichment** reads bytes and may materialize cloud placeholders; the scanner
  reads only filesystem facts and materializes nothing (ADR 0008/0009).
- **Companions** (`.xmp` / `.srt`) live in `media_companion`, paired by directory
  stem during scan/FSEvents/camera inventory. They never enter media queries or
  enrichment. `ImportPreferences` owns persisted import policy keys (Settings
  Import tab).
- **Import planning**: `MediaTransferPlanner` is pure; occupancy via
  `FilesystemNamespaceSemantics`, equality via `ContentEqualityChecker`. Store
  tracks two per-root revisions: `planRevision` (general, reorg-polled, bumps on
  no-op rescans too) and `occupancyRevision` (advances only on real media-namespace
  changes). Import-plan staleness and the `RootPlanningChange` stream key on
  `occupancyRevision`, so enrichment/no-op-rescan churn on a cloud destination does
  not livelock planning. Store builds `ImportPlanningSnapshot`;
  `MediaOperationCoordinator` greedily plans attached removable sources and
  publishes scalar footer presentation. Removable filesystem
  volumes and MTP cameras execute through `MediaImportExecutor` (journal +
  copyfile/camera download + exclusive publish + settlement); blocked entries
  withhold cleanup and auto-eject. Imports
  sidebar scopes via `import_batch_unix_ms`. Plan details use
  `ImportPlanDetailReader` (no full plan map on `CatalogWindowState`).
- **Library reorganization**: `ReorganizationPlanner` builds physical-member
  recipes; `ReorganizationExecutor` + normalized `active_reorganization_*` journals
  mutate under a typed root lease; `LibraryReorganizationRunner` is the confirmed
  UI path; ViewModel/`TileContentStore` apply `CatalogIdentityRemapBatch` atomically.
- **Pure policy helpers** carry the testable logic beside effectful actors:
  `CatalogWindowPolicy`, `SidebarSelectionPolicy`, `GridColumnCount`,
  `MediaGridZoomPolicy`, `GridSelection`, `MediaCompanionPairing`.

## Where to make a change

| To change… | Touch… |
| --- | --- |
| what the UI shows | `CatalogProjection` (derivation) or `CatalogWindowViewModel` (final assignment) — never a view |
| what is stored | `CatalogStore` + a SQLite migration in `CatalogStorePersistence` + an ADR |
| platform source handling | the ViewModel owns monitor/session lifetimes; the Store owns attach/detach/remap/persistence |
| import plan lifecycle / footer | `MediaOperationCoordinator` + ViewModel media-ops intents; views stay passive |
| library reorganization | `LibraryReorganizationRunner` + ViewModel confirmation/remap; planner/executor stay off MainActor |
| heavy work (enrichment, future decode/export) | a new actor/service off the main thread that checks `FileMaterialization` before reading bytes, following `EnrichmentCoordinator`'s pattern |
| grid rendering/selection/zoom | the `MediaGrid*` boundary (ADR 0006); selection *model* intents live on `CatalogWindowViewModel` |
| loupe / preview decode | `LoupeView` + `PreviewImageLoader` (ADR 0016); mode intents on `CatalogWindowViewModel` |
| compare pair | `ComparePairPolicy` + `CompareView`; pair is capped selection |

Never violate the non-negotiables in `AGENTS.md`: the filesystem is the truth,
originals are read-only, nothing is written into the user's folders, and the main
thread stays free of database/scan/sort/decode work. If answering one question makes
you touch two layers, the boundary is probably wrong — move the responsibility.
