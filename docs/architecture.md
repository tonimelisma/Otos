# Otos Architecture Map

The current-state map of the codebase: the one-directional dataflow, who owns what,
and where to make a change. Details of *why* live in `docs/adr/`; *what* the product
does lives in `docs/requirements.md`; file guides in the source explain each file.

## The one idea

The user's filesystem is the source of truth. Everything Otos stores (catalog +
thumbnail/metadata/hash overlay) lives in Application Support and is a subordinate
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
        ├───────────────▶ EnrichmentCoordinator (actor)  ── bounded claim/enrichment branch
        │   writes back      asks Store for candidates; bounded handoff joins preview at:
        │                    MaterializationCoordinator (actor) ── bounded priority/coalescing/suppression
        │                                      ▼
        │                            FileMaterialization (one-URL mechanism)
  CatalogProjection (actor)  ── truth → UI-ready CatalogWindowState (off MainActor)
        │  coalesced ~1s for background changes, immediate for user query intents
        ▼
  CatalogWindowViewModel (@MainActor)  ── the SwiftUI bridge; assigns @Observable state
        │  owns loupeVideoState (single owner); VideoPreviewLoader (@MainActor factory) checks SF_DATALESS + interactive demand and creates AVPlayer
        ▼
  SwiftUI views  →  grid / loupe(+filmstrip) detail (mode-switched)
                     MediaGridBridgeView (AppKit NSCollectionView; .grid or .strip)
                     PreviewImageLoader (actor) — full-size decode off MainActor; submits interactive demand
                     LoupeVideoPlayerView (NSViewRepresentable AVPlayerView) — inline controls; player owned by ViewModel
```

Nobody reads "upward": a view never calls the database; the database never knows a
view exists. To answer "where does X happen," find the one layer that owns X.

## Actors and why

| Type | Isolation | Owns | Why an actor |
| --- | --- | --- | --- |
| `CatalogStore` | actor | SQLite, atomic import/reorganization journal transitions and catalog settlement, `RootRegistry`/`RootRuntimeState`, per-root namespace mutation epochs, filesystem/reorganization lease arbitration, scan reconciliation, planning revisions, removable-source state, change notifications, all catalog queries | serializes catalog truth and every transaction that must agree with it; an older scan may upsert observed facts but its captured epoch cannot authorize missing-row or companion deletion |
| `CatalogProjection` | actor | coalesced `CatalogWindowState` publication + all sorting/filtering/hiding/empty-state/scope derivation; detail-only enrichment changes (no `best_capture`/`best_kind`/`best_format` change) reuse the last order query instead of re-sorting (plan 0064 Stage 3) | keeps derivation off the main thread (that is what would hang the UI) |
| `MediaOperationCoordinator` | actor | greedy import-plan lifecycle per attached removable source, device-identity destination policy (saved mapping → last-used → first-added available), one actor-owned `SourceSession` per source (typed `AttachmentGeneration`/`BuildGeneration`, six-check stale-completion rejection), ImportPlanBuilder and ImportExecuting boundaries, derived ledger claims from `Ready`/`Executing` phases, per-source session preference overrides discarded on detach, scalar presentation stream, queued Import, and one-executor-per-source ownership | serializes per-source dirtiness/execution; plan building is an owned per-source child task never awaited from the planning-change consumer, so a long build cannot make the coordinator deaf to an attaching card; namespace enumeration and the planning pass run off the actor; ledger conflict-check and registration happen in one synchronous on-actor region against the current ledger, and a losing build re-plans rather than evicting; destination-driven replans are suppressed while any execution targets that destination and coalesced into one rebuild per dirty source afterwards |
| `MediaImportExecutor` | actor | import filesystem lifecycle for volumes and cameras: recovery sequencing, orphan staging cleanup, 8 bounded entry workers, staging, exclusive publish, ownership-proving recovery, and optional source deletion | owns monotonic aggregate progress while independent workers suspend; Store serializes durable journal prerequisites, zero-row failures, and atomic settlement; ambiguous final-only recovery gates hashing through the shared materialization requester |
| `ReorganizationPlanner` | pure enum | physical-member reservation graph + chain/cycle recipes (no FS writes) | called from tests/coordinator; probes via occupancy map |
| `ReorganizationExecutor` | pure enum + Store journal | directory prerequisites, same-volume no-overwrite moves, recovery observations, filesystemComplete handoff | owns filesystem mechanics; Store owns durable transitions and never catalogs temps |
| `LibraryReorganizationRunner` | actor | plan → journal → execute → settle for one fixed library plus startup journal recovery decisions; returns remap batches | owns the use-case sequence while Store owns lease arbitration and transactions |
| `EnrichmentCoordinator` | actor | separate ready-enrichment claims, materialization demands, materialization in-flight IDs, pending-apply claims, readiness retry signals, eight-worker local enrichment admission, bounded shared-materializer handoff, lease refresh, `freshly` handoff, batched writes, and a bounded pacing-only retry ledger | readiness admission probes through `EnrichmentReadinessChecking`; ready capacity, transfer capacity, and SQLite-lease ownership are independent; decode/parse and materializer awaits run in owned workers off the actor |
| `MaterializationCoordinator` | actor | bounded consumer-fed interactive/device/background queues, per-id waiter coalescing and effective priority, 16-transfer admission, one-background-per-root fairness, known-materialization suppression, per-root `providerUnavailable` circuit breaker (2 consecutive ETIMEDOUT at device/background → 60s `providerBreakerOpen` suppression, never for interactive), truthful blocked/unblocked admission diagnostics during effective interactive demand, per-waiter-priority scoping of `activeRequestCount(under:)` so eject drain sees only enrichment-originated demand | gives every deliberate provider request one scheduling and lifecycle owner; its supervisor is the only dispatcher |
| `PreviewImageLoader` | actor | loupe/compare full-size decode, live byte-read gate, per-id decode coalesce + small LRU | serializes decode/cache state off MainActor and delegates interactive materialization |
| `VideoPreviewLoader` | `@MainActor` final class | loupe video stateless factory: live `SF_DATALESS` gate, interactive materialization, AVPlayer creation, synchronous cleanup | player is `@MainActor` UI object (AVFoundation 27); single owner is ViewModel's `loupeVideoState`, loader holds no `currentState` — no duplication, no unsafe |
| `CatalogWindowViewModel` | `@MainActor` | final SwiftUI state assignment, sidebar selection, grid selection model (`GridSelection`), view mode / loupe focus (`loupeVideoState` single owner), owned per-slot pane-request tasks, lossless serial mutation delivery, monitor/task lifetimes, import presentation bridge | touches SwiftUI state; deliberately a thin bridge — heavy work belongs down a layer; `await` materialize suspends without blocking main thread |

Rule of thumb: the main thread only assigns final UI state and starts work;
everything expensive happens on an actor off the main thread.

## Key subsystems

- **Identity** is typed: `LibraryRootPath` + `MediaRelativePath` = `MediaAssetID`. No
  invented durable IDs; the filesystem path is the identity (ADR 0003/0008). Each
  identity value carries a derived FNV-1a `fingerprint` for cheap Hashable /
  diffable hashing only — never persisted, never a second identity.
- **Query scope** is resolved once. `RootRegistry.scopePredicate` turns a
  `SidebarSelection` into one `CatalogScopePredicate` (root IDs plus an optional
  import-batch stamp), and every scoped read — ordered IDs, cataloged count, visible
  count, filter options — consumes that value rather than bare root IDs. An Imports
  row narrows by root *and* by batch; holding both dimensions in one value is what
  stops a read from honoring one and forgetting the other.
- **The grid** is the one AppKit boundary (`MediaGridBridgeView` +
  `MediaGrid*`), for cell reuse at tens of thousands of tiles. `MediaGridMutationGate`
  is the single arbiter of structural applies and zoom swaps. Mouse selection is
  model-owned (`GridSelection` lives in `CatalogWindowViewModel`; the AppKit controller
  renders it and the subclass never calls `super.mouseDown`). AppKit surfaces never
  write selection truth; the model flows one way, ViewModel → renderer, and
  `selectionIndexPaths` is render output. Paint truth lives in
  `TileContentStore` (sole decoded-image owner, ViewModel-owned and shared by grid, strip, and panes; visible IDs pinned; cost-bounded);
  tiles never blank a painted same-asset thumbnail (ADR 0006). `GridPostLayoutWorkQueue`
  owns keyed focus-scroll and visible-detail/preheat work that must wait for a real
  collection-view layout; it coalesces deferred work and performs the one next-turn retry.
- **Sidebar/sources**: `SidebarSelectionPolicy` (pure) decides default/attach
  selection and All-Media visibility; eject is unmount-driven and honest (ADR 0014).
- **Materialization** has one path: preview submits interactive demand and enrichment
  submits device/background demand to `MaterializationCoordinator`, which calls the
  one-URL `FileMaterialization` mechanism. The coordinator owns the bounded physical
  scheduler plus a per-root `providerUnavailable` breaker (two consecutive `ETIMEDOUT` probes → 60s `providerBreakerOpen` suppression, preventing a dead-provider storm from holding `backgroundPerRootCap=1` 32×2s); `FileMaterialization` owns the one-URL `SF_DATALESS` gate and `k=2` short-circuit. Enrichment owns a separate bounded producer window (32 claims, at most 16 handed off globally and two per root). Scanning never materializes (ADR 0008/0009).
- **Scan freshness and import settlement**: each active scan captures the root's
  namespace-mutation epoch. Independent import, reorganization, and filesystem-event
  mutations advance the epoch and retain typed dirty scopes; a stale scan can still
  upsert facts but defers destructive missing-row reconciliation. Import settlement
  validates current source `(size, mtime)` facts plus the Plan-0060 XXH3-128 digest,
  and may clone the source's normalized enrichment overlay while copying an
  independent destination thumbnail. Reuse is available only for sources whose bytes
  are local: a `.removableVolume` source is never hashed in place, so its settlement
  records a typed `removableSourceNotHashed` miss. A reuse miss falls back to ordinary
  enrichment; source and destination overlay lifecycles remain independent.
- **Import publication recovery**: a completed staging hash is durably recorded with
  `.readyToPublish` before exclusive publication, and the published final is durably
  recorded as `.publishedPendingSettlement` before settlement or source deletion.
  Recovery treats final-plus-staging and exclusive destination races as foreign;
  final-only occupants require journaled size, integer-second mtime, and XXH3 proof,
  with a live materialization gate before hashing. The shared
  `MaterializationCoordinator` owns deliberate recovery materialization requests.
- **Enrichment byte gates**: `MediaEnricher` checks live materialization independently
  immediately before hashing, metadata parsing, and thumbnail generation. Earlier
  successful gates never authorize a later phase after provider eviction. Hash
  production is gated on byte locality (ADR 0018): `.removableVolume` sources skip
  hashing entirely, so their enrichment runs the metadata-parse and thumbnail gates
  only.
- **Companions** (`.xmp` / `.srt`) live in `media_companion`, paired by directory
  stem during scan/FSEvents/camera inventory. They never enter media queries or
  enrichment. `ImportPreferences` owns persisted import policy keys (Settings
  Import tab).
- **Import planning**: `MediaTransferPlanner` is pure and single-pass.
  `destinationFolders(for:)` derives the bounded folder set a plan can touch from
  source facts plus policy alone (a suffix retry changes the file name, never the
  folder); `FilesystemNamespaceSemantics.enumerateNamespace` reads exactly those
  folders once into a `DestinationNamespace`; `planImport` then decides every
  candidate from memory. Absence is proven, not assumed — a folder that could not be
  read answers `nil`, and its candidates block rather than reading as free space.
  A selected regular-file candidate is preexisting
  only when live size and the shared expected destination mtime match. Store tracks
  two per-root revisions: `planRevision` (general, reorg-polled, bumps on
  no-op rescans too) and `occupancyRevision` (advances only on real media-namespace
  changes). Import-plan staleness and the `RootPlanningChange` stream key on
  `occupancyRevision`, so enrichment/no-op-rescan churn on a cloud destination does
  not livelock planning. Store builds `ImportPlanningSnapshot` from filesystem
  facts and live occupancy; planner decisions do not read hashes, provenance, or
  catalog membership. `MediaOperationCoordinator` greedily plans attached removable sources and
  publishes scalar footer presentation. Several sources may hold a ready plan into one
  destination at once: planning stays parallel and each source reads the namespace
  independently, while a coordinator-owned reservation ledger keeps their claimed names
  disjoint and a `skippedForeign` count reports any name still lost to a foreign writer
  (ADR 0021). Removable filesystem
  volumes and MTP cameras execute through `MediaImportExecutor` (recovery + orphan
  staging cleanup + copyfile/camera download + exclusive publish); Store accepts
  semantic journal transitions and settles the catalog atomically. Blocked entries
  withhold cleanup and auto-eject. Imports
  sidebar scopes via `import_batch_unix_ms`. The grid is the plan view.
- **Library reorganization**: `ReorganizationPlanner` builds physical-member
  recipes; `ReorganizationExecutor` owns directory/move mechanics;
  `LibraryReorganizationRunner` owns execution and recovery sequencing. Store owns
  the typed root lease, durable `active_reorganization_*` transitions, and atomic
  catalog remap; ViewModel/`TileContentStore` apply each remap batch atomically.
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
| content hash production/persistence | `ContentHasher` stays inside `MediaEnricher` and `MediaImportExecutor`; enrichment hashes only byte-local roots (`.removableVolume` is gated off, ADR 0018/0013); `CatalogStore` validates source signatures and owns atomic overlay/journal settlement, including import overlay reuse diagnostics |
| library reorganization | `LibraryReorganizationRunner` + ViewModel confirmation/remap; planner/executor stay off MainActor |
| heavy byte-reading work | keep decoding/parsing in its consumer, check live `FileMaterialization` status, and submit deliberate downloads to `MaterializationCoordinator` |
| grid rendering/selection/zoom | the `MediaGrid*` boundary (ADR 0006); selection *model* intents live on `CatalogWindowViewModel` |
| loupe / preview decode | `LoupeView` + `PreviewImageLoader`/`VideoPreviewLoader` + `LoupeVideoPlayerView` (`AVPlayerView` inline) (ADR 0016); mode intents on `CatalogWindowViewModel` |
| loupe video (click-to-play) | `VideoPreviewLoader` + `LoupeVideoPlayerView` + `LoupeView` poster/AVPlayer swap; compare stays poster-only |
| compare pair | `ComparePairPolicy` + `CompareView`; pair is capped selection |

Never violate the non-negotiables in `AGENTS.md`: the filesystem is the truth,
originals are read-only, nothing is written into the user's folders, and the main
thread stays free of database/scan/sort/decode work. If answering one question makes
you touch two layers, the boundary is probably wrong — move the responsibility.
