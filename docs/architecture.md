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

## Targets

```
Otos.xcodeproj
├── OtosKit       (framework)          — everything below (Models/Services/Stores/
│                                         Support/Views/ViewModels); links
│                                         GRDB, MediaMetadata; OtosApp is its one
│                                         public type
├── Otos          (app)                — main.swift + Assets.xcassets only; links
│                                         and embeds OtosKit
└── OtosTests     (unhosted bundle)    — links OtosKit directly, no TEST_HOST
```

No source or test file lives in a directory that names its target; `Otos/` and
`OtosTests/` are unchanged on disk (ADR 0023). Target membership is Xcode
project-file state, not filesystem layout — "where to make a change" below
still answers in terms of what a type does, not which of these four targets
compiles it.

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
        │  coalesced ~1s for background changes, immediate for user query intents;
        │  at publication hands on every part equal to the last one's as that one's own
        │  (`sharingUnchanged`: the grid's `CatalogGridContent`, map, groups, People…)
        │  ◀── DuplicatesProjection, PeopleAssignment (actors): duplicate groups and People,
        │      each its own loop, asked after a catalog change; never awaited by a window pass
        ▼
  CatalogWindowViewModel (@MainActor)  ── the SwiftUI bridge; assigns @Observable state
        │  apply costs in what changed: content identity says the grid moved, its index
        │  answers selection/focus lookups (ADR 0004); `windowTitle` titles every scope;
        │  nothing on a pane the user has left acts until its scope publishes (`showsSelectedScope`)
        │  owns loupeVideoState (single owner); VideoPreviewLoader (@MainActor factory) checks SF_DATALESS + interactive demand and creates AVPlayer
        ▼
  SwiftUI views  →  grid / loupe(+filmstrip) detail (mode-switched), or the Places map
                     when the scope is `.places` (ADR 0040: the ViewModel's cluster lane
                     turns `CatalogWindowState.map` + the reported viewport into stacks),
                     or On This Day's year cards and its story player when the scope is
                     `.onThisDay` (ADR 0049: the player is the loupe's pane, driven by
                     `CatalogWindowViewModelStory`)
                     MediaGridBridgeView (AppKit NSCollectionView; .grid or .strip)
                     PreviewImageLoader (actor) — full-size decode off MainActor; submits interactive demand
                     LoupeVideoPlayerView (NSViewRepresentable AVPlayerView) — inline controls; player owned by ViewModel

  curation / Move to Trash intents
        │
        ▼
  CatalogWindowViewModel ── typed serial intent ──▶ CatalogStore
        │                                             │
        │                                             └─ one SQLite overlay transaction / exact-path reconciliation
        ▼
  CatalogStore (pending_trash_batch_unix_ms, hidden) ──▶ MediaTrashCoordinator (durable queue)
        ├─ dataless member ──▶ MaterializationCoordinator (command), no lease held
        └─ all local ── per-root namespace lease ──▶ FileManager.trashItem
```

Nobody reads "upward": a view never calls the database; the database never knows a
view exists. To answer "where does X happen," find the one layer that owns X.

## Actors and why

| Type | Isolation | Owns | Why an actor |
| --- | --- | --- | --- |
| `CatalogStore` | actor | SQLite (a shared four-reader pool, and two read-only readers kept for the visible tiles' details, `interactiveReader`, ADR 0002), atomic import/reorganization journal transitions and catalog settlement, `RootRegistry`/`RootRuntimeState`, per-root namespace mutation epochs, filesystem/reorganization lease arbitration, scan reconciliation, planning revisions, removable-source state, change notifications (`.changed(CatalogChangedFacts)` naming the kinds of fact a write touched, `.assetsAdded` for a batch that only inserted rows, which the owners of derived facts do not read, but for People's unchecked tally), the catalog load with its maintenance writes each through a partial index and its per-step timings on `op=catalog.start phase=finish`, the WAL's bound after every bulk write (ADR 0002), all catalog queries | serializes catalog truth and every transaction that must agree with it; an older scan may upsert observed facts but its captured epoch cannot authorize missing-row or companion deletion |
| `MediaTrashCoordinator` | actor | lossless serial system-Trash commands, catalog-proven physical-member ordering, and per-root namespace-mutation lease ownership | companions must precede primaries, partial filesystem success must remain truthful, and destructive work must never run on the MainActor or through a permanent-delete path |
| `CatalogProjection` | actor | one doorbell-driven publication loop with `requested`/`covered` revision counters (a request is never cleared by finishing work; a failed read publishes nothing) → `CatalogWindowState` + all sorting/filtering/hiding/empty-state/scope derivation; each Store change names the kinds of fact it touched (`CatalogChangedFacts`) and a pass repeats the order read, the filter-options read, the stack candidates' read, the stack collapse or a shown search's match only when a kind it depends on moved, the search also keyed by `PhotoSearchIndex.revision` (`CatalogProjectionReads`, ARC-018); the filter's options are read after the window publishes, never before it; an intent the work in flight does not answer cancels that unpublished work (`supersede()`, ADR 0005), a store change never does; the People gallery reads nothing but its libraries' state | keeps derivation off the main thread (that is what would hang the UI) |
| `DuplicatesProjection` | actor | the duplicate groups (ADR 0042): one doorbell-driven loop with `requested`/`covered` counters, asked for a build by `CatalogProjection` after a publication that took up a change of a kind the groups are built from (`DuplicatesProjection.inputs`), never `.assetsAdded`; reads through the Store, proposes same-photo pairs from column facts, reads renders and record facts only for those stills, compares off the actor (`@concurrent`), and yields groups that changed for `CatalogProjection` to merge | the groups are a whole-catalog fact: a window pass never waits for a build, and a scope, filter or sort change never starts one |
| `PeopleAssignment` | actor | People (ADR 0047): the same loop shape as `DuplicatesProjection`, asked after a publication that took up a change of a kind it reads (`PeopleAssignment.inputs`), and asked alone for its unchecked tally (`requestTally`, a count read republished with the last state) after `.assetsAdded`; reads `CatalogStore.peopleSnapshot` in one transaction, assigns every face with `FaceAssignmentPolicy` off the actor (`@concurrent`), writes what changed through `CatalogStore.applyAssignment` (a guess only where the face is still Otos's), and when nothing changed publishes the gallery from `PeopleStateBuilder`, keeping a `FaceRanker` to answer which people the targets' faces could be | People is a whole-catalog fact: a window pass never waits for a pass; assignment settles on its own output |
| `MediaOperationCoordinator` | actor | greedy import-plan lifecycle per attached removable source, per-source (path-keyed) destination memory — `destinationBySource`, the one record of a source's destination, loaded at init and changed only by `setDestination` — read back on every new attachment and defaulting to the first available library on first sight (ARC-047; no device-identity or last-used heuristic) and published to Settings through the ordered newest-wins `destinationsStream()`, one `SourceSession` per source held in the synchronous `ImportSessionMachine` (typed `AttachmentGeneration`/`BuildGeneration`; every build, execution and refresh result is an event the machine checks against its identity; a proven plan carries the library and run it was built for, and a running import carries its destination, progress and batch proof, so claims and settlement never read a destination that moved; a plan request is a `planRequested`/`planCovered` counter pair no completion clears), `ImportSourceReadiness` plus settled naming facts gating a source's plan to Ready only once its own live scan/enumeration and enrichment signature have settled, ImportPlanBuilder and ImportExecuting boundaries, derived ledger claims from `Ready`/`Executing` phases, per-source session preference overrides discarded on detach, the one `makePresentation` writer every publish path funnels through (no second call site synthesizes a presentation), scalar presentation stream, queued Import, and one-executor-per-source ownership — a run's outcome (completion, stop, failure) is recorded beside the session and survives the rebuild that follows settlement; `phase` says only what the session is doing now (APP-029) | the actor is a thin shell: it reads the Store, runs build and execution tasks, and sends their results to the machine, whose `handle(_:)` is the only writer of session state; refreshes run through one doorbell-woken consumer so two snapshots never apply out of order; plan building is an owned per-source child task never awaited from the planning-change consumer, so a long build cannot make the coordinator deaf to an attaching card; namespace enumeration and the planning pass run off the actor; ledger conflict-check and registration happen in one synchronous on-actor region against the current ledger, and a losing build re-plans rather than evicting; destination-driven replans and enrichment naming bumps are coalesced into one rebuild per dirty source afterwards |
| `MediaImportExecutor` | actor | one run's import filesystem lifecycle for volumes and cameras: journaled staging (primary and companions), 8 bounded entry workers admitted per entry against the 5 GB disk floor through the run's `FreeSpaceLedger` (ADR 0027 — no run-level free-space check; a floor stop or an `ENOSPC` write settles the run as `.stopped(.diskFloor)`), exclusive publish, and manifest-driven source erase as the run's only card deletion (never after a floor stop); `MediaImportRecovery` settles or cleans earlier processes' journals once at coordinator start, with ownership proof | owns monotonic aggregate progress while independent workers suspend; Store serializes durable journal prerequisites, zero-row failures, and atomic settlement; `EraseManifest` is planned before execution and published outcomes gate copy candidates; `SourceEraser` is the one implementation of source deletion, refuses fixed libraries, and runs under a source namespace lease held for the erase sweep only — a busy or unregistered root yields an incomplete erase, never a failed import |
| `ReorganizationPlanner` | pure enum | applies `ImportNaming` to a library in place: per-bundle names and suffixes against one read `DestinationNamespace`, then key-based rename order with temporary hops for cycles (no FS writes) | the runner enumerates `destinationFolders(for:)` once and plans in one pass |
| `ReorganizationExecutor` | pure enum + Store journal | directory prerequisites, same-volume no-overwrite moves, recovery observations, component rollback, filesystemComplete handoff | owns filesystem mechanics; Store owns durable transitions and never catalogs temps |
| `LibraryReorganizationRunner` | actor | plan → journal → execute → settle (or roll back) for one fixed library at a confirmed revision, plus startup journal recovery that resumes or rolls back every component | owns the use-case sequence while Store owns lease arbitration and transactions |
| `EnrichmentCoordinator` | actor | separate ready-enrichment claims, pending-apply claims, eight-worker local enrichment admission, bounded shared-materializer handoff, `freshly` handoff, batched writes, and one `EnrichmentSchedule` value — materialization demands and their in-flight state, the bounded pacing-only retry ledger, readiness rechecks, the catalog-write retry — whose waits wake the loop through one deadline | readiness admission probes through `EnrichmentReadinessChecking`; ready capacity, transfer capacity, and SQLite-lease ownership are independent; decode/parse and materializer awaits run in owned workers off the actor |
| `MaterializationCoordinator` | actor | bounded consumer-fed interactive/device/background queues, per-id waiter coalescing and effective priority, 16-transfer admission, the `FreeSpaceFloor` check before every background/device dispatch (capacity read off the actor), four-background-per-root fairness, known-materialization suppression, per-root `providerUnavailable` circuit breaker (2 consecutive ETIMEDOUT at device/background → 60s `providerBreakerOpen` suppression, never for interactive), truthful blocked/unblocked admission diagnostics during effective interactive demand; `locality(of:)` (local/fetchable/unreachable, by root kind) and `ensureLocal`, which every fetching byte reader asks | gives every deliberate provider request one scheduling and lifecycle owner; its supervisor is the only dispatcher |
| `PreviewImageLoader` | actor | loupe/compare decode: the stored preview short of full resolution (no byte read), else the original — RAW through `ImageRenderer.interactive` — behind a live byte-read gate, per-id decode coalesce + small LRU | serializes decode/cache state off MainActor and delegates interactive materialization |
| `ImageRenderer` | final class, two lanes, each a serial RAW `OperationQueue` and an Image I/O one (4 wide on `background`) | develops a still once, from its original read whole in one timed read (`StillSource`) — RAW via `CIRAWFilter` at RAW9/RAW8, others via Image I/O — into an 8-bit Display P3 bitmap, logging queue wait, read and develop apart (`render.still`); `background` lane for enrichment (preview + thumbnail), `interactive` for the loupe | rendering is blocking CPU/GPU work, so it leaves every actor on a named queue (ADR 0032 rule 6); two lanes bound RAW memory to two developments and keep enrichment from queuing ahead of the photo on screen (ADR 0035) |
| `LiveEditRenderer` | actor on its own `DispatchSerialQueue` executor | the photo being edited, kept open (`CIRAWFilter` or decoded image) with one intermediate-caching `CIContext`; renders the draft at preview size per control change and the saved recipe's staged preview + thumbnail, reports the open photo's facts (RAW, as-shot white balance), and answers white balance picks (ADR 0036) | development is blocking CPU/GPU work that must leave the MainActor by a named mechanism (ADR 0032 rule 6), and its non-`Sendable` filter state must never leave one owner |
| `EditAnalyzer` | actor, one per window, models loaded on first use off the MainActor | FocalNet (`AutoCropModel`) and GeoCalib's network plus its Swift solver (`AutoLevelModel`, `PerspectiveFieldSolver`), Core ML on the CPU; read by the edit analysis lane for Auto crop and Auto straighten (ADR 0045) | loading reads 79 MB and every prediction blocks, so both stay off the MainActor; one owner per window keeps model state out of ambient globals |
| `FaceAnalyzer` | actor on its own serial queue, one per window model, shared by `PreviewFaceReader` and the enricher, model loaded on first use | Vision face landmarks and capture quality (revision 3), the admission rules (among them Vision's image classifier seeing a person around the face), the five-point alignment (`FaceAlignment`), the opaque 112 px crop and AdaFace IR-101 (`FaceEmbeddingModel`, 8-bit, CPU) for every still's stored preview and a library video's sampled frames (ADR 0047) | every step blocks and the model is 66 MB, so it leaves the shared pool by its own queue (ADR 0032 rule 6) and the model never leaves it |
| `PreviewFaceReader` | actor, one loop woken by the Store's change notifications and its retry wake (`PreviewFaceRetries`) | every still's faces, in a library or an Immich account, read from its stored preview (never the original) with `FaceAnalyzer` and carried back through the preview's edit onto the upright photo, stamped with the preview's source stamp, written only while that preview is current (ADR 0047, ENR-026) | the read and the analysis are slow and must not hold the Store; faces are not an enrichment product, so no original is downloaded for them; one owner per product, as `RenderSignatureRefresher` is for signatures |
| `PlaceNameReader` | actor, one loop woken by the Store's change notifications | names each map cell holding a located item once per language (`PlaceNameLanguage`; the catalog keeps one language's names) through Apple Maps, from the cell's center (`PlaceCell`), stored in `place_cell` for the Places filter; stores only answers, and waits out any failed naming (`time: backoff`) before asking again (ADR 0051) | never sends a photo's own coordinate; nothing it stores is media |
| `PhotoSearchIndex` | actor, one per window, with `SearchImageEmbedder` and `SearchQueryEncoder` each on its own serial queue | keyword search (ADR 0048): one doorbell loop that reconciles memory with the catalog's current `search_embedding` and `search_text` rows (ids first, only missing rows decoded, text kept folded) and embeds every asset whose stored thumbnail has none, newest first, paging past what it cannot read; then reads owed previews for text through `SearchTextReader` (its own serial queue), which stops reading for the rest of the process once Vision's reader is lost to it (`SearchTextReading.losesTheProcess`); every current embedding in one in-memory matrix; `matches(_:among:)` scores a query's encoding against the scope's assets and keeps what `SearchCutoff` keeps against the scope's best. `CatalogProjection` hands it the encoding and the scope; its `changes` stream asks for a publication while a search is shown |
| `PhotoDescriptionWriter` | actor, one loop woken by the Store's change notifications and its retry wake | every still's description (ADR 0053), from its stored preview at 1,024 px and `PhotoDescriptionPrompt`'s facts (who each face is and their age, when, where, text, labels), through `PhotoDescriber.live` on `SystemLanguageModel.default`, one request at a time, newest first; stored in `photo_description` with a source over the catalog's own facts, so any change owes a new one; `changes()` rings the Info pane and `AnniversaryTitleWriter` | the model call is seconds of work Otos does not control, so it runs on its own loop off every other owner; nothing that writes a fact the description reads knows descriptions exist |
| `AnniversaryTitleWriter` | actor, one loop woken by the window's newest-wins request and the description writer's announcements | On This Day's titles (ADR 0053): one text-only request per shown anniversary whose descriptions changed, kept in memory, published whole for `CatalogWindowViewModel.anniversaryTitles` | the projection never waits on the model; the window only hands over what it shows and assigns what is published |
| `SearchQueryReader` | actor, owned by `PhotoSearchIndex` (`queries`) | reading the query shown (ADR 0048): one doorbell loop, newest query next, a reading in flight never cancelled, through `SearchQueryEncoder` (recognition, Translation, Maps, text tower); `status(for:)` answers the projection at once — reading (until the reading reports it ended, no deadline), read, or failed (retried on a `time: backoff`); the projection publishes that as `CatalogWindowState.searchPhase`, republishing the last state marked as searching while a query is read — and `readings()` rings it when a status changes | Translation and Maps can stall; the window's one publication loop must never wait on them | SigLIP 2's towers (94 + 87 MB, token table memory-mapped) and every prediction block, so they stay off the MainActor; one owner keeps embeddings, memory and answers in agreement |
| `ImmichAccounts` | actor, one per process | every Immich account's session (Keychain), `ImmichCatalogSync` loop and status (what the server last answered — connecting/online/offline/signed out — whether a pass is syncing, and the last finished pass, kept in `library_root.last_synced_at`; learned from pass reports), the poll/backoff timer between passes, add (version check + login) and forget (logout + Keychain delete) | the one owner of account sessions so the sync, Settings and removal never disagree about one; network work leaves the main actor; statuses reach the window newest-wins |
| `ImmichCatalogSync` | actor, one per account | the account root's catalog from its server's sync stream: batches applied under a listing lease and acknowledged after the Store's commit; trash hidden by source, deletions and locked purged, reset resynced in full; then each library the server mirrors learned (`immich_mirror`, one `originalPath` read confirmed by the asset's path checksum) and its external assets given their files' digests (`MirrorGateway.pair`, which a library file's digest write also runs, ADR 0054); then the server's preview for every row owed source images, drawn into Otos's preview and thumbnail (`origin: .source`) under the floor | a pass's state is local to it; the doorbell (newest-wins) keeps passes from overlapping |
| `CameraCatalogSync` | `@MainActor` final class, one per attached camera | the camera root's catalog while connected: a pass at attach and one per add/remove report after the catalog is complete (newest-wins doorbell), each under its own enumeration lease; stages and thumbnails only items no earlier pass saw | the camera (`CameraCatalogSource`) is a `@MainActor` hardware boundary; Store owns the rows and the stable-list deletion proof |
| `VideoPreviewLoader` | `@MainActor` final class | loupe video stateless factory: `ensureLocal` at interactive priority, live `SF_DATALESS` re-check, AVPlayer creation, synchronous cleanup | player is `@MainActor` UI object (AVFoundation 27); single owner is ViewModel's `loupeVideoState`, loader holds no `currentState` — no duplication, no unsafe |

Import attachment lifecycle: `CatalogStore` assigns a process-local generation when a
removable root is attached. `MediaOperationCoordinator` carries that generation through
the live session and presentation, owns the actual execution task, and transfers an
executing task to a batch-keyed drain when the source disappears. A presentation
exists only for a live attachment: on detach the session's outcome is logged
(`op=import.outcome phase=settled`) and discarded, because the import bar is drawn only
on the card's own row. A reattached card at the same path starts a fresh session and
cannot inherit the previous run's outcome.
| `CatalogWindowViewModel` | `@MainActor` | final SwiftUI state assignment, sidebar selection, grid selection model (`GridSelection`), view mode / loupe focus (`loupeVideoState` single owner), the Places map's viewport, camera requests and cluster lane (ADR 0040), `today` and the On This Day story (`StoryPlayback`, its hold and video-end waits; ADR 0049), owned per-slot pane-request tasks, lossless serial delivery of catalog mutations, import intents and trash undo/redo/prompt answers (one stream and one consumer each, so the user's order is the delivery order), monitor/task lifetimes, import presentation bridge | touches SwiftUI state; deliberately a thin bridge — heavy work belongs down a layer; `await` materialize suspends without blocking main thread |

Rule of thumb: the main thread only assigns final UI state and starts work;
everything expensive happens on an actor off the main thread.

## Key subsystems

- **Identity** is typed: `LibraryRootPath` + `MediaRelativePath` = `MediaAssetID`. No
  invented durable IDs; the filesystem path is the identity (ADR 0003/0008). Each
  identity value carries a derived FNV-1a `fingerprint` for cheap Hashable hashing
  only — never persisted, never a second identity.
- **Query scope** is resolved once. `RootRegistry.scopePredicate` turns a
  `SidebarSelection` into one `CatalogScopePredicate` (root IDs plus an optional
  import-batch stamp), and every scoped read — ordered IDs, cataloged count, visible
  count, filter options — consumes that value rather than bare root IDs. Filter options
  read the scope of the shown sidebar row (`SidebarSelection.sidebarRow`), whose filter a
  leaf keeps, so a leaf is offered its row's choices. An Imports
  row narrows by root *and* by batch; holding both dimensions in one value is what
  stops a read from honoring one and forgetting the other.
- **The grid** is the one AppKit boundary (`MediaGridBridgeView` +
  `MediaGrid*`), for cell reuse at tens of thousands of tiles. `MediaGridMutationGate`
  is the single arbiter of structural applies and zoom swaps; inside its in-flight slot
  a structural apply builds the next `MediaGridStructure` (ordered identities, day
  sections as contiguous ranges, identity lookups through the publication's
  `CatalogGridContent` index) off the main actor
  (`buildStructure`) and hands it to AppKit on the main actor (`commitStructure`): `reloadData`
  for query and large membership changes, `performBatchUpdates` with the derived
  `MediaGridBatchUpdates` otherwise. The controller is the collection view's plain
  `NSCollectionViewDataSource` over that one value, which the layout, day bar, headers,
  selection, drag, prefetch, zoom and scroll anchoring also read. The grid's layout is
  Otos's own `MediaGridLayout`, arithmetic over the section counts
  (`MediaGridLayoutGeometry`: one pass at `prepare()`, a rect query by binary search),
  so an apply's layout cost is the sections' count, not a per-section solve; the
  filmstrip keeps a one-section compositional layout. Pointer hover has the
  same single-owner shape as mouse selection: `MediaGridCollectionView` answers only
  the geometry question (which item is under the cursor) through one grid-wide
  tracking area, and the bridge owns what hover means, assigning the curation control
  to at most one tile. Per-tile tracking areas cannot work here — scrolling moves
  tiles under a stationary cursor without producing the matching `mouseExited` — so
  the bridge recomputes on every scroll tick and after every structural apply, and
  re-asserts hover on every tile render. That last assertion is what keeps the
  control steady: a tile clears its own control when its content resets, and both
  change guards (asset identity in the bridge, index path in the collection view)
  correctly suppress a repair while the pointer holds on one thumbnail, so the
  owner has to state its answer on every pass rather than only when it changes.
  Scroll-driven recomputation therefore reports the index path unconditionally and
  dedups on asset identity, since a reorder can leave the same index path holding a
  different asset.
  "What is visible" likewise falls back to the layout when AppKit has attached no
  items yet, so an apply into a grid at rest still requests tile detail. Mouse
  selection is
  model-owned (`GridSelection` lives in `CatalogWindowViewModel`; the AppKit controller
  renders it and the subclass never calls `super.mouseDown`). AppKit surfaces never
  write selection truth; the model flows one way, ViewModel → renderer, and
  `selectionIndexPaths` is render output. Paint truth lives in
  `TileContentStore` (sole decoded-image owner, ViewModel-owned and shared by grid, strip, and panes; visible IDs pinned; cost-bounded);
  tiles never blank a painted same-asset thumbnail (ADR 0006). A day is named twice by one label
  (`MediaGridDayLabel.swift`): in flow at the head of its run, and by
  `MediaGridDayBarView`, a controller-owned bar at the grid's top edge. Headers are
  never pinned; `MediaGridDayBarPolicy` (pure) decides which day the bar names. `GridPostLayoutWorkQueue`
  owns keyed focus-scroll and visible-detail/preheat work that must wait for a real
  collection-view layout; it coalesces deferred work and performs the one next-turn retry.
- **Sidebar/sources**: `SidebarSelectionPolicy` (pure) decides default/attach
  selection and All-Media visibility; eject is unmount-driven and honest (ADR 0014).
  An import moves the selection from the card's row to its batch once, when the
  applied window state first carries the batch's row (`followRunsIntoTheirBatches`,
  run on every presentation and every state apply), and a selected removable
  row that stops existing resolves to the policy default. `barOwnsStatus` places the import bar on
  the card's row only, and decides which sidebar row carries the progress indicator
  when the bar is off screen.
- **Materialization** has one path: preview submits interactive demand and enrichment
  submits device/background demand to `MaterializationCoordinator`, which calls the
  one-URL `FileMaterialization` mechanism. The coordinator owns the bounded physical
  scheduler plus a per-root `providerUnavailable` breaker (two consecutive `ETIMEDOUT` probes → 60s `providerBreakerOpen` suppression, preventing a dead-provider storm from holding `backgroundPerRootCap=1` 32×2s); `FileMaterialization` owns the one-URL `SF_DATALESS` gate and `k=2` short-circuit. Enrichment owns a separate bounded producer window (32 claims, at most 16 handed off globally and two per root). Scanning never materializes (ADR 0008/0009).
- **Scan lanes and source presence**: a filesystem scan holds a lease in its lane —
  one lane shared by the fixed libraries, one per card (`ScanLeaseController.ScanLane`)
  — so a card is read the moment it attaches. A card's or camera's retained rows are
  marked `awaiting_presence` on attach and leave that state only as its read observes
  each file; the scope clause, import planning and enrichment claims skip marked rows,
  detach and launch clear the mark, and an erase removes each file's row with its
  journal entry (ADR 0013, ADR 0026).
- **Scan freshness and import settlement**: each active scan captures the root's
  namespace-mutation epoch. Independent import, reorganization, and filesystem-event
  mutations advance the epoch and retain typed dirty scopes; a stale scan can still
  upsert facts but defers destructive missing-row reconciliation. A single-file
  reconcile observes its path once through `CatalogScanner.observeFile` and checks the
  epoch and the namespace lease right before its write; a stale one re-queues its
  dirt. One reconcile loop per Store, woken by a revision-counted doorbell, is the only
  drainer of dirt, and every dirt insertion requests a pass. Each product — metadata,
  rendering (thumbnail and preview), digest — has its own `(size, mtime)` stamp (ADR
  0009), and a claim's `EnrichmentScope` is the set of its row's stale products, made
  from one read. A card is claimed for metadata first, with a provisional QuickLook
  thumbnail, which is all import readiness waits on, then for its renderings and
  digests. Import settlement takes each product from the source when its stamp names the
  copied bytes, or — for a missing rendering — the source's thumbnail as a provisional
  one; it never renders. A copy that settles owing a product is the first row the next
  background claim offers (`localBytesAwaitingProducts`), while its bytes are local. Source
  and destination overlay lifecycles remain independent. While an import copies from a
  card, the Store stops offering the card to enrichment
  (`beginImportSourceRead`/`endImportSourceRead`, bracketed by
  `MediaOperationCoordinator` around each run).
- **Import publication recovery**: a completed staging hash is durably recorded with
  `.readyToPublish` before exclusive publication, and the published final is durably
  recorded as `.publishedPendingSettlement` before settlement or source deletion.
  Recovery treats final-plus-staging and exclusive destination races as foreign;
  final-only occupants require journaled size, integer-second mtime, and SHA-1 proof,
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
  three per-root revisions: `planRevision` (general, bumps on no-op rescans too),
  `namespaceRevision` (which paths the root occupies — real media-namespace changes
  only), and `namingRevision` (what Otos would call the root's assets — an
  enrichment write that changes `capture_wall_compact`). The two consumers read them
  differently and by different mechanisms: reorganization **pulls** `planRevision`
  on demand (`LibraryReorganizationRunner`), while import planning is **pushed** the
  `RootPlanningChange` stream — whose only subscriber is `MediaOperationCoordinator`
  — and applies it *by role*. A root's namespace invalidates a plan reading it as
  source or destination; its naming invalidates a plan reading it as source only,
  because the source capture wall names the copy while a destination's overlay
  renames nothing on disk. That role split is why enrichment churn on a cloud
  destination does not livelock planning (ARC-046). Store builds
  `ImportPlanningSnapshot` from filesystem facts and live revisions; planner decisions do not read hashes, provenance, or
  catalog membership. `MediaOperationCoordinator` greedily plans attached removable sources and
  applies volume-aware `FilesystemNameKey` equality to every destination namespace
  and reservation claim, publishes scalar footer presentation through the one `makePresentation` writer
  every phase transition and progress tick funnels through — no call site
  synthesizes its own presentation value, which is what keeps a stray publish from
  ever showing zero progress or a stale destination mid-run (ADR 0024). A source's plan is offered as Ready, and Import becomes enabled, only
  once `ImportSourceReadiness` proves the source's own live scan/enumeration has
  settled to idle — never while it is still scanning/enumerating or unreachable —
  and once every date-dependent naming fact is settled by the enrichment signature;
  never as a provably-empty card until the current plan is guaranteed to reflect
  settled occupancy, and never from a plan whose build began while the source was
  still being read (ADR 0024; ADR 0026). Several sources may hold a
  ready plan into one
  destination at once: planning stays parallel and each source reads the namespace
  independently, while a coordinator-owned reservation ledger keeps their claimed names
  disjoint and a `skippedForeign` count reports any name still lost to a foreign writer
  (ADR 0021). Removable filesystem
  volumes and MTP cameras execute through `MediaImportExecutor` (journaled staging +
  copyfile/camera download + exclusive publish), after `MediaImportRecovery` has
  settled earlier processes' journals once at coordinator start; Store accepts
  semantic journal transitions and settles the catalog atomically. Blocked entries
  withhold cleanup and auto-eject. Imports
  sidebar scopes via `import_batch_unix_ms`. The grid is the plan view.
- **Library reorganization**: `ReorganizationPlanner` builds physical-member
  recipes; `ReorganizationExecutor` owns directory/move mechanics;
  `LibraryReorganizationRunner` owns execution and recovery sequencing; the view model
  runs its recovery once after the Store starts, and the Store never calls up into it.
  From load, the Store holds every journaled root under the reorganization lease that
  recovery adopts. Store owns the typed root lease, durable `active_reorganization_*` transitions, and atomic
  catalog remap, which records a `pending_identity_remap` batch in the same
  transaction. Batches reach the window inside `CatalogWindowState` (read with the
  ordered IDs); `CatalogWindowViewModel.applyState` carries selection, focus and
  `TileContentStore` across each one before comparing orders, then acknowledges it.
- **Curation**: `CatalogWindowViewModelCuration.swift` is the single target resolver
  and lossless serial choice-command owner. `CatalogStore.setMediaChoice` is the one
  transaction; `MediaFilter.choices` is a query descriptor dimension, not selection
  or a second ViewModel truth. `MediaChoice` stays in tile/pane detail values so Grid,
  filmstrip, Loupe, and Compare render the same persisted overlay. The pointer
  control is two toggles rather than three targets: `MediaChoiceToggle` owns both
  the outline/filled symbol pair and the single "pressing the carried act clears it
  to Not Rated" resolution, so the AppKit tile and the SwiftUI Loupe/Compare control
  stay two renderers of one intent. Neutral keeps its keyboard, menu, and VoiceOver
  paths.
- **Move to Trash**: `CatalogWindowViewModelTrash.swift` resolves the current browser
  target and owns stale-navigation checks; `MediaTrashCoordinator` owns the durable
  queue of pending items (resume on launch, downloads without the lease, retry,
  free-space floor, delete-immediately decisions) and reports to `TrashStatusBar`; `CatalogStore` supplies catalog-proven companions and
  reconciles only successful paths. The shared typed namespace-mutation lease excludes
  import publication and reorganization on one root.
- **Library removal**: Settings ▸ Libraries' Remove and ▸ Removable Media's Forget
  both reach `CatalogStore.removeLibrary`, which removes a free root under a
  `.libraryRemoval` lease, or records the request when another owner holds it and
  reports that owner (the Settings alert, DES-091); the holder's lease release hands the
  root to a removal lease synchronously and the reconcile loop runs the removal.
- **Pure policy helpers** carry the testable logic beside effectful actors:
  `CatalogWindowPolicy`, `SidebarSelectionPolicy`, `GridColumnCount`,
  `MediaGridZoomPolicy`, `MediaGridStructure` / `MediaGridBatchUpdates`, `GridSelection`,
  `MediaCompanionPairing`.

## Where to make a change

| To change… | Touch… |
| --- | --- |
| what the UI shows | `CatalogProjection` (derivation) or `CatalogWindowViewModel` (final assignment) — never a view |
| what is stored | `CatalogStore` + a SQLite migration in `CatalogStorePersistence` + an ADR |
| which files are one photo (RAW+JPEG pairs) / how a stack collapses | `PhotoStackRule` over candidates `PhotoStackSQL` reads with the order (every candidate of the scope's roots, held across passes, or for a keyed scope only the stacks of the rows its order read found, `PhotoStackSQL.Span`); `PhotoStackCollapse` in the projection after search, re-run on the published uncollapsed order without a query when only the expanded stacks change; expansion and Make Key Photo in `CatalogWindowViewModelStacks` (ADR 0052) |
| platform source handling | the ViewModel owns monitor/session lifetimes; the Store owns attach/detach/remap/persistence |
| what a kind of root is or may do | `LibraryRootKind`'s capabilities (one exhaustive `switch` each; never compare kinds at a call site) and `StagingContainer` for kinds that stage originals (ADR 0046 §3) |
| an Immich account's root | `CatalogStore.addImmichAccount` (identity `immich:<server>#<user>`, staging under the build's `RemoteStaging` (`StagingContainers`, re-derived at every load in `normalizedLoadedRoot`), `remote_base_url`); rows through the kind-neutral listing API (`beginSourceListing` …), a full resync completing through `completeSourceResync`; available at launch from its stored listing (`availabilityAtLaunch`), claimed by enrichment for metadata and a video's faces only while its server answers (`RootRuntimeState.isSourceAnswering`, `RemoteRangeAccess`) (ADR 0046) |
| import plan lifecycle / footer | `MediaOperationCoordinator` + ViewModel media-ops intents; views stay passive |
| content hash production/persistence | `ContentHasher` stays inside `MediaEnricher` and `MediaImportExecutor`; enrichment hashes only byte-local roots (`.removableVolume` is gated off, ADR 0018/0013); `CatalogStore` validates source signatures and owns atomic overlay/journal settlement, including each imported copy's product origins (`reused`/`provisional`/`owed`) |
| library reorganization | `LibraryReorganizationRunner` + ViewModel confirmation/remap; planner/executor stay off MainActor |
| heavy byte-reading work | keep decoding/parsing in its consumer, check live `FileMaterialization` status, and submit deliberate downloads to `MaterializationCoordinator` |
| grid rendering/selection/zoom | the `MediaGrid*` boundary (ADR 0006); selection *model* intents live on `CatalogWindowViewModel` |
| loupe zoom | `LoupeZoomPolicy` (pure targets) + `LoupeZoomView` (`NSScrollView` magnification, reports/commands) + `CatalogWindowViewModelLoupeZoom` (intents, full-resolution request); View ▸ Zoom In/Out dispatch by mode (APP-040) |
| inspector (Info / Edit) | `CatalogWindowViewModelInspector` (`inspectorPane`, the one owner; `toggleInspector` / `setInspectorPane`; Info refreshed by every target writer through `refreshOpenWithMenu`: `refreshPhotoInfo` reads the asset row, metadata record, `CatalogStore.photoInfoOverlay`, tile detail and `MaterializationCoordinator.locality` together and `PhotoInfo.make` writes every string; In This Photo's confident labels and certain text from the overlay, the labels named by `SceneLabelNames` (actor, `Resources/SceneLabelNames.tsv`), a label button calling `setSearchText`; the place name from `PlaceNameLookup.mapKit`, never stored) + `InfoPaneView` + `EditPanelView` in `ContentView`'s `.inspector` (APP-041, ADR 0036, ADR 0050) |
| loupe / preview decode | `LoupeView` + `PreviewImageLoader`/`VideoPreviewLoader` + `LoupeVideoPlayerView` (`AVPlayerView` inline) (ADR 0016; stored previews and the renderer, ADR 0035); mode intents on `CatalogWindowViewModel` |
| loupe video (click-to-play) | `VideoPreviewLoader` + `LoupeVideoPlayerView` + `LoupeView` poster/AVPlayer swap; compare stays poster-only |
| compare pair | `ComparePairPolicy` + `CompareView`; pair is capped selection |
| the Places map / an area or a stack under it | scope: `SidebarSelection.places` / `.mapArea` (the viewport's box from `MapClusterPolicy.area`) / `.mapStack` (one stack's members) resolved by `RootRegistry.scopePredicate` into `CatalogScopePredicate.LocationConstraint` (the join reads coordinates with the order) or `ContentConstraint.members` (one JSON argument); content: `CatalogWindowPolicy.mapState` → `CatalogWindowState.map`; stacks: `MapClusterPolicy` (pure) run by `CatalogWindowViewModelMap` (revision-counted lane, `@concurrent`); view modes on the map: `setViewMode` → `openVisibleMapArea`; a stack's click → `zoomIntoMapCluster`, its double-click → `openMapCluster` (the map has no selection); view: `PlacesMapView` (passive; owns only the map's camera, reports `MapViewport`) (ADR 0040) |
| the day an item is on / timeline order | `CatalogSchema.bestCaptureLocalSQL` (`best_capture_local`: the capture wall read as UTC, else the absolute time in whole seconds plus `assumed_utc_offset_seconds`), the offset written by the scan upsert and `writeMetadataProjection` through `CaptureLocalTime.assumedUTCOffset`; Swift reads it as `CaptureLocalTime` (day, `presentationDate`, `formatted`) — grid day buckets, On This Day ranges, search date spans, People birthdays and Info all read this one value (ADR 0039) |
| On This Day and its story | scope: `SidebarSelection.onThisDay(CalendarDay)` resolved by `RootRegistry.scopePredicate` into `CatalogScopePredicate.DateConstraint`, turned inside the read into one `strftime` predicate on local capture time by `AnniversaryMatch` (the day in earlier years, else in earlier months, decided by an `EXISTS` before the filter; ADR 0039); order fixed by `SidebarSelection.fixedSort` / `CatalogQueryDescriptor.effectiveSort`; anniversaries: `OnThisDayAnniversaryPolicy` → `CatalogWindowPolicy.onThisDayState` → `CatalogWindowState.onThisDay`; today: `CatalogWindowViewModelStory` (platform day and zone reports through one doorbell); story: `StoryPlaybackPolicy` (pure) applied by `CatalogWindowViewModelStory` over the loupe's pane and video; views `OnThisDayView` (cards) and `StoryPlayerView` (player), strings in `OnThisDayPresentation` (ADR 0049, `docs/design/on-this-day.md`) |
| a still's description and On This Day's titles | `PhotoDescriptionWriter` + `PhotoDescriber` + `PhotoDescriptionPrompt` (what the model is told) + `PhotoDescriptionStorage` (source, readiness, candidate SQL) + `CatalogStore.photoDescriptionCandidates` / `applyPhotoDescriptions` / `currentPhotoDescriptions`; the Info pane through `PhotoInfoOverlay.photoDescription` and `startReadingsRefresh`; titles through `AnniversaryTitleWriter` and `startAnniversaryTitles` (ADR 0053, ENR-032, APP-077, APP-078) |
| Duplicates / a group under it | scope: `SidebarSelection.duplicates` / `.duplicateGroup` resolved by `RootRegistry.scopePredicate` into `CatalogScopePredicate.ContentConstraint`; content: `DuplicatesProjection` (own actor and loop, asked for a build after a publication that took up a catalog change): `CatalogStore.duplicateCopies` (within each library or across them, by the Store's one `duplicatesReach`, which the scopes use too and the view model hands over from Settings on its mutation stream) → `DuplicateGroupPolicy`, then `samePhotoCandidates` → `SamePhotoPolicy` pairs → `samePhotoDetails` for those stills only → groups (pure, `@concurrent`) → merged by `CatalogProjection` into `CatalogWindowState.duplicates` (nil until first built); the list's order and sections: `DuplicatesLayout` on `CatalogDuplicatesState`, built with the groups (what only a click decides, files of one photo, exact copies in a `DuplicateFolderBucket` per folder set); what each group keeps: `DuplicateResolution` (pure: the click, else the folder set's rule for exact copies, else the default — keep, move, carries, reason); clicks, folder rules and the receipt: `DuplicatesSession` in `CatalogWindowViewModelDuplicates`; the act: `moveMediaToTrash`; Keep All and Review Again: `duplicate_kept_pair`, one intent stream; words: `DuplicatesPresentation` (pure: the section and folder headers, each group's date and reason, each copy's Keep/Trash as a photo or a name, the bar's lines); view: `DuplicatesView` (passive) (ADR 0042, `docs/design/duplicates.md`) |
| reopening where the user left off | `BrowserPlace` (versioned preference value) + `CatalogWindowViewModelBrowserPlace` (load at init, restore once after the first matching result, save at quit) (ADR 0031) |
| curation choice/filter | `MediaChoice` + `CatalogStore.setMediaChoices` (one transaction, reports priors) + `MediaFilter`/`CatalogQueryGateway`; ViewModel owns intents and the curation `UndoManager` (APP-039), views remain passive |
| handing photos to other apps (copy, drag, share, open) | `HandOffPreparer` (what each photo hands over; prepared files in Application Support's `HandOff`, cleared each launch; `HandOffPromise` for drags) + `CatalogWindowViewModelHandOff` (one ordered lane, progress, Cancel) + `ProgressStatusBar`; files written by `MediaFileWriter` (ADR 0037) |
| what faces a still has | `CatalogStore.previewFaceCandidates` names the stills owed them (`PreviewFaceSQL`: the faces stamp does not name the stored preview's source, and the preview's edit is known, read from the partial index `idx_media_asset_still_owes_faces`, ENR-026); `PreviewFaceReader` decodes each preview, `FaceAnalyzer` reads it, `PreviewFaceReader.upright` carries each face back through the edit (`EditGeometry`); `CatalogStore.applyPreviewFaces`'s `writeFaces` replaces the asset's rows in `face` with the faces stamp; `CatalogStore.faces(of:)` reads them back (ADR 0047) |
| what faces a video has | a library video owes them under `EnrichmentClaim.library` (`EnrichmentClaimGateway.videoFacesStalenessSQLPredicate`); an Immich account's video under `EnrichmentClaim.account`; `MediaEnricher` hands `VideoFaceReader` the local file, or for an account's video a `RemoteVideoAsset` whose resource loader reads each range AVFoundation asks for with the account's `RemoteRangeReader`; the reader decodes six frames with `FaceAnalyzer`, keeps one face per person and stages their frames (a failed read is `EnrichmentOutcome.facesUnread`: the other products are written, the row is paced, and a missing model holds every video's faces in `EnrichmentSchedule`; a video AVFoundation says it cannot decode, `VideoFaceReader.isUndecodable`, is stamped with no faces and `undecodable_by` naming `VideoFaceReader.decoderIdentity`, released at launch once that decoder changes); `CatalogStorePersistence.writeEnrichmentOverlay` writes them through `writeFaces` with each face's `frame_index` and sets `face_frames_path`, which the derived-image lifecycle deletes and renames (ADR 0047, ENR-031) |
| who is in a photo | the user's acts: one `PeopleAct` each, applied by `CatalogStore.perform` in one transaction (the hard rules are refused there) and undone by the `PeopleRestore` it returns, carried across a re-read by `FaceCarryOver` in `writeFaces`; Otos's guesses: `FaceAssignmentPolicy` (pure) over `CatalogStore.peopleSnapshot()`, written by `PeopleAssignment` through `CatalogStore.applyAssignment` (ADR 0047, ENR-024, ENR-025) |
| what People shows | `PeopleAssignment` (actor, own loop, asked by `CatalogProjection` after a publication that took up a catalog change, never awaited) builds `CatalogPeopleState` (the gallery and each photo's faces) through `PeopleStateBuilder` (pure) onto `CatalogWindowState.people`; a person's photos are the leaf `SidebarSelection.person` (`ContentConstraint.person`, SQL in `CatalogQueryGateway`), the People filter (`MediaFilter.people`) narrows to photos with every person checked, the likeness sort reads `face.likeness`; `CatalogWindowViewModelPeople` owns the gallery selection, the sheet and merge question, Back to People, the targets' face candidates (`CatalogProjection.faceCandidates`), the intents and their ordered stream and undo, and which person the window shows and filters (`reconcileShownPeople`, holding a person an unanswered merge or redo of one takes away until the store's answer, `PendingPeopleActs`); the photo menus' face groups are built in `CatalogWindowViewModelMediaItemMenu`; `CatalogPeopleState` carries what every People surface reads derived at its build (the visible and hidden people, the names the sheet suggests, each person's index and, per person, the sheet's newest faces), and the hard rules are functions over it; `PeopleView`, `PersonSheetView`, `FaceTileView` and the Info pane's People section are passive (APP-072): a gallery cell is equal to the one it replaces while its person and selection are, and asks for its `PersonMenu` only as its context menu or VoiceOver opens it |
| keyword search: what a query says | `SearchQueryEncoder` (people by name before translation, your languages as recognition hints, Translation, `SearchGlossary` for a language Translation lacks (`Resources/SearchGlossary-<code>.tsv`), `SearchQueryParser` for dates, `SearchPlaces` for places) → `SearchFacts` answered by `CatalogStore.searchFactMatches`; scene labels by `SearchSceneLabels` with the thumbnail's embedding, named by `SearchLabelVocabulary`, applied by `SearchLabelGate`; text by `SearchTextReader` into `search_text` (each line with its confidence), kept folded by `PhotoSearchIndex` (`SearchTextReading.folded`) and matched by `SearchTextQuery` (ADR 0048) |
| keyword search | the field: `ContentView`'s `.searchable` + `CatalogWindowViewModel.setSearchText` / `orderSearchByRelevance` / `focusSearch` (Edit ▸ Find) into `CatalogQueryDescriptor.search`; the answer: `PhotoSearchIndex.matches` (query: `SearchQueryReader` → `SearchQueryEncoder` → `SearchTextTokenizer` → `SearchTextModel`; cut: `SearchCutoff`), applied by `CatalogProjection.applySearch` through `CatalogWindowPolicy.searched`; embeddings: `SearchImageEmbedder` from stored thumbnails into `search_embedding` (`SearchEmbeddingStorage`, `CatalogStore.searchEmbeddingCandidates` / `applySearchEmbeddings`) (ADR 0048, `docs/design/search.md`) |
| re-reading metadata after a MediaMetadata parser fix | `MetadataRefresher` (once per launch: library rows whose `asset_metadata.extraction_revision` is older, from local bytes only) + `CatalogStore.metadataRefreshCandidates` / `applyMetadataRefresh` (signature-guarded write through `writeMetadataProjection`, the same writer enrichment uses) (ADR 0039) |
| which files are one Live Photo | `LivePhotoSQL` in `CatalogQueryGateway` (the one pair rule: same root, folder and `content_identifier`, exactly one still and one movie), applied in the shared scope clause, `fetchLivePhotoMotions` (Trash members, loupe) and planning's `livePhotoStillPath` (naming bundles) (ADR 0041) |
| exporting photos to a folder (File ▸ Export…) | `MediaExporter` (one item: download under the floor, write in the system scratch folder, publish with `_001` naming through `ExclusivePublication`) + `MediaFileWriter` + `CatalogWindowViewModelExport` (sheet state, remembered `ExportSettings`, one ordered job lane, report) + `ExportSheetView` + `ProgressStatusBar` (ADR 0038) |
| editing a photo | `EditRecipe` (values, Codable) + `EditSection`/`EditControl` (panel order, per-photo slider ranges from `EditPhotoFacts`) + `CatalogWindowViewModelEdit` (target, draft, live-render and save lanes, undo) + `LiveEditRenderer` + `CatalogStore.setEditRecipe` / `applyRenderedEditProducts` (revision-guarded) + `EditPanelView` (passive inspector); Auto crop and Auto straighten read on the analysis lane by `EditAnalyzer` (ADR 0045); geometry in `EditGeometry`, the crop tool in `CatalogWindowViewModelCrop` + `CropEditorView`; Show Original, Revert to Original and the keyboard's selected adjustment in `CatalogWindowViewModelEditCommands`; the histogram counted by `EditHistogram` on the live-render lane and drawn by `EditHistogramView`; bare menu keys forwarded by `BareMenuKey`; enrichment renders with the recipe as the fallback (ADR 0036) |
| drag out of the grid / filmstrip | `MediaGridDragPolicy` (pure rules) + `MediaGridCollectionView` (drag detection, deferred plain click) + `MediaGridViewController.beginDrag` + `MediaGridDragSource`; file URLs only (ADR 0028) |
| media context menus | `MediaItemMenuModel` (pure, ordered) + `CatalogWindowViewModelMediaItemMenu` (builds the model at open time, maps commands onto the menu-bar intents) + `MediaItemContextMenu` (the one `NSMenu` renderer; `ContextMenuHost` overlays it on SwiftUI panes) + `MediaGridCollectionView.menu(for:)` |
| share the current items | `CatalogWindowViewModelShare` (File ▸ Share… intent) + `SharePickerPresenter` (owns the AppKit picker while shown) + the toolbar `ShareLink` in `ContentView`; one target list `currentTargetFileURLs`, URLs only (ADR 0012) |
| open in another app / Open With | `CatalogWindowViewModelOpenWith` (intents, off-main menu build) + `OpenWithMenuModel` (pure) + `WorkspaceOpening` (the one LaunchServices seam); URLs only, no bytes (ADR 0012) |
| recoverable deletion | `CatalogWindowViewModelTrash` + `MediaTrashCoordinator` + Store namespace lease/reconciliation; never use a view or permanent-delete API |

Never violate the non-negotiables in `AGENTS.md`: the filesystem is the truth,
originals are read-only, nothing is written into the user's folders, and the main
thread stays free of database/scan/sort/decode work. If answering one question makes
you touch two layers, the boundary is probably wrong — move the responsibility.
