# Otos Architecture Map

The current-state map of the codebase: the one-directional dataflow, who owns what,
and where to make a change. Details of *why* live in `docs/adr/`; *what* the product
does lives in `docs/requirements.md`; file guides in the source explain each file.

## The one idea

The user's filesystem is the source of truth. Everything Otos stores (catalog +
thumbnail/metadata overlay) lives in Application Support and is a subordinate,
rebuildable projection. When they disagree, the filesystem wins.

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
  SwiftUI views  →  MediaGridBridgeView (AppKit NSCollectionView, the grid)
```

Nobody reads "upward": a view never calls the database; the database never knows a
view exists. To answer "where does X happen," find the one layer that owns X.

## Actors and why

| Type | Isolation | Owns | Why an actor |
| --- | --- | --- | --- |
| `CatalogStore` | actor | SQLite, root runtime state, scan/enumeration leases, removable-source state, change notifications, all catalog queries | serializes every mutation/query for free; a remove can be processed mid-scan safely (lease re-checked after every await) |
| `CatalogProjection` | actor | coalesced `CatalogWindowState` publication + all sorting/filtering/hiding/empty-state/scope derivation | keeps derivation off the main thread (that is what would hang the UI) |
| `EnrichmentCoordinator` | actor | two worker pools (enrich local / download cloud), in-flight tracking, claim leases | serializes scheduling state; heavy decode/parse/download runs inside its worker tasks, off the actor |
| `CatalogWindowViewModel` | `@MainActor` | final SwiftUI state assignment, sidebar selection, lossless serial mutation delivery, monitor/task lifetimes | touches SwiftUI state; deliberately a thin bridge — heavy work belongs down a layer |

Rule of thumb: the main thread only assigns final UI state and starts work;
everything expensive happens on an actor off the main thread.

## Key subsystems

- **Identity** is typed: `LibraryRootPath` + `MediaRelativePath` = `MediaAssetID`. No
  invented durable IDs; the filesystem path is the identity (ADR 0003/0008).
- **The grid** is the one AppKit boundary (`MediaGridBridgeView` +
  `MediaGrid*`), for cell reuse at tens of thousands of tiles. `MediaGridMutationGate`
  is the single arbiter of structural applies and zoom swaps. Mouse selection is
  model-owned (`GridSelection`; the subclass never calls `super.mouseDown`). Tiles
  never blank a painted same-asset thumbnail (ADR 0006).
- **Sidebar/sources**: `SidebarSelectionPolicy` (pure) decides default/attach
  selection and All-Media visibility; eject is unmount-driven and honest (ADR 0014).
- **Enrichment** reads bytes and may materialize cloud placeholders; the scanner
  reads only filesystem facts and materializes nothing (ADR 0008/0009).
- **Pure policy helpers** carry the testable logic beside effectful actors:
  `CatalogWindowPolicy`, `SidebarSelectionPolicy`, `GridColumnCount`,
  `MediaGridZoomPolicy`, `GridSelection`.

## Where to make a change

| To change… | Touch… |
| --- | --- |
| what the UI shows | `CatalogProjection` (derivation) or `CatalogWindowViewModel` (final assignment) — never a view |
| what is stored | `CatalogStore` + a SQLite migration in `CatalogStorePersistence` + an ADR |
| platform source handling | the ViewModel owns monitor/session lifetimes; the Store owns attach/detach/remap/persistence |
| heavy work (enrichment, future decode/export) | a new actor/service off the main thread that checks `FileMaterialization` before reading bytes, following `EnrichmentCoordinator`'s pattern |
| grid rendering/selection/zoom | the `MediaGrid*`/`MediaGrid*` boundary (ADR 0006) |

Never violate the non-negotiables in `AGENTS.md`: the filesystem is the truth,
originals are read-only, nothing is written into the user's folders, and the main
thread stays free of database/scan/sort/decode work. If answering one question makes
you touch two layers, the boundary is probably wrong — move the responsibility.
