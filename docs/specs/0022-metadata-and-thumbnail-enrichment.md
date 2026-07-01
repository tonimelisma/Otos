# Spec: Metadata And Thumbnail Enrichment

## Classification

Feature. Adds the enrichment subsystem: a thumbnail and parsed metadata for every
cataloged image and video, prioritizing the viewport, eagerly materializing cloud
files in the background, never blocking the UI or a worker, never fabricating
facts. The durable architecture decisions are owned by
[ADR 0009](../adr/0009-enrichment-storage-and-staleness.md); this spec owns the
implementation.

## Problem

The catalog stored only filesystem facts: the grid showed placeholder tiles with a
filename, no thumbnail and no date, and no media metadata existed. Most media lives
in cloud-synced folders as dataless `SF_DATALESS` placeholders, so producing
thumbnails and metadata means reading bytes — which forces a download — without
stalling the UI, without blocking a worker on a multi-second transfer, and without
accidentally materializing a file by faulting on a read.

## Scope

In scope:

- The enrichment data model (SQLite enrichment columns, hot `MediaAsset` detail
  fields, on-demand `AssetMetadata` scalar/detail JSON, the `(size, mtime)`
  staleness signature, the computed `bestCaptureDate`).
- `MediaEnricher` (metadata read + QuickLook thumbnail) and `ThumbnailStore`
  (JPEG thumbnail files).
- `EnrichmentCoordinator`: the cursorless two-pool scheduler.
- The viewport channel (grid → ViewModel → coordinator) and tile rendering of the
  thumbnail and capture date.
- Integration with `CatalogStore` (batched apply, stale-completion rejection,
  rescan merge, thumbnail purge), `CatalogProjection`, and the grid.

Out of scope (named so they are not built): sort/filter by metadata and any grid
reordering (data plus a computed best-date only); a film-strip / single-image /
compare view; editing and import; an in-memory thumbnail cache (none until a
scroll profile demands one); a metadata inspector and exposure fields; Live Photos
and paired-media-as-one-item; the max-zoom "load the original" path (thumbnails
serve up to their native size, beyond which a future increment loads originals).

## Definition Of Ready

- Goal, change type, scope, and non-goals are explicit (above).
- Current repo state inspected at the time of this spec: the catalog was fully
  resident and media-only (`MediaEligibility`). The current implementation after
  ADR 0010 keeps `CatalogMediaGridState` cheap by carrying ordered IDs plus a
  scalar detail-refresh generation; `FileMaterialization` provides the dataless
  gate and non-blocking download helpers (spec 0021); FSEvents drive debounced
  full rescans (spec 0023).
- Observable requirements and acceptance examples identified (ENR-001…ENR-010).
- Ownership, side effects, persistence, cancellation, errors, progress, privacy,
  instrumentation, and verification addressed (below and in ADR 0009).
- Three or more alternatives compared with the simplest correct one selected
  (ADR 0009 Alternatives).
- Retirement list and proof for the placeholder-grid framing (below).

## Captured Requirements For User Verification

Captured from the user across the design discussion and recorded as ENR-001…
ENR-010 in `docs/requirements.md` (Current). Highlights:

- Functional: every cataloged image/video gets a thumbnail and parsed metadata;
  the grid shows the thumbnail and a capture date; eager full-library
  materialization; the viewport is prioritized; the capture date is the best
  available real date and is never fabricated.
- Architecture: thumbnails are files referenced by path (256 px JPEG generated
  from QuickLook);
  the full metadata is on-demand scalar/detail JSON, never in grid publication;
  disjoint scan/enrichment column ownership with preserving scan upserts; `(size, mtime)`
  staleness; stale in-flight completions are rejected before they can stamp newer
  source facts current; a single coordinator actor owning two fixed worker pools
  by cursorless scheduling; a single SQLite claim lease column preventing repeated
  dequeue; enrichment writes batched through `CatalogStore`.
- Non-functional: no media I/O, decode, or formatting on the MainActor; the tile
  loads its thumbnail and formats its date off-main and only assigns on Main.

## Architectural Alternatives

The substantive storage and scheduling alternatives (metadata inline-and-resident
vs. on-demand persisted detail; thumbnails as BLOBs vs. files; JPEG vs. HEIC vs. PNG; a maintained
backlog vs. cursorless) are compared in
[ADR 0009](../adr/0009-enrichment-storage-and-staleness.md). The
implementation-level alternatives this spec weighed:

### Alternative A — One pool that gates, downloads, and extracts each unit

A single worker pool where each task checks status, downloads if dataless, then
extracts.

Pros:

- One pool, one code path; no `freshly` hand-off.

Cons:

- A worker blocks on a multi-second (or stalled) download, starving extraction of
  already-local files.

Failure modes:

- The whole pool parks on slow transfers while thousands of local files wait.

Rejected: a worker must never block on a download. Two pools (4 enrich + 4
download) are separate I/O budgets connected by the `freshly` hand-off (selected);
Store's `enrichment_claimed_until` lease is the SQL dequeue gate, not a maintained
coordinator backlog.

### Alternative B — Maintain explicit pending-work partitions

Keep `extractionPending` / `downloadPending` sets updated as facts change.

Pros:

- O(1) next-unit.

Cons:

- A second source of truth the coordinator's own batched writes thrash; scale
  machinery before measurement.

Failure modes:

- The partition drifts from `needsEnrichment` truth after a rescan.

Rejected by ADR 0010: derive work from the resident snapshot via `needsEnrichment`.
The current coordinator asks Store for bounded enrichment candidates instead.

### Alternative C — Per-item cancellation on scroll and staleness

Cancel in-flight enrichment when the item leaves the viewport or goes stale.

Pros:

- Avoids "wasted" work on scrolled-away items.

Cons:

- Eager-everything re-downloads anyway; thumbnails are durable; staleness
  re-queues. Cancellation buys nothing and adds complexity.

Rejected: cancellation only at teardown. Selected.

## Selected Approach

A single `EnrichmentCoordinator` actor (the write-side satellite of the catalog,
mirror of `CatalogProjection`) runs two fixed worker pools over a
`withDiscardingTaskGroup`, woken by a coalescing `bufferingNewest(1)` signal
stream. Work is queried from Store through bounded enrichment-candidate reads; the
coordinator maintains only the runtime state it cannot derive. Materialization
status is checked off-actor at exactly one site — the enrichment pull, immediately
before the read — serving as both router and ADR 0008 safety gate. Results are
applied in batches (one transaction, one notification) by `CatalogStore`. The
products are a 256 px JPEG thumbnail file and on-demand metadata scalar/detail
rows; only the thumbnail path, a resolved capture date, and the `(size, mtime)`
stamps are fetched with hot asset detail rows. The tile loads its thumbnail and
formats its date off-main. See ADR 0009 for why each choice is the simplest
correct one.

## Interfaces, Ownership, And Data Flow

Modules (isolation — owns):

- `CatalogStore` (actor, extended) — the `v3` schema; `applyEnrichmentBatch` (one
  transaction, per-row existence and source-signature revalidation, one
  notification); the rescan merge (`mergingFacts`); thumbnail delete when rows are
  purged by proven deletion or explicit library removal; on-demand `metadataBlob`
  decode; the `nonisolated thumbnailDirectory`.
- `MediaAsset` (nonisolated value, extended) — the cheap hot detail fields
  (`thumbnailPath`, `captureDate`, `enrichedSourceSize`,
  `enrichedSourceMTimeSeconds`), `needsEnrichment`, `bestCaptureDate`,
  `mergingFacts`, `applyingEnrichment`.
- `AssetMetadata` (nonisolated value, new) — the full `MediaMetadataResult`
  mapped to Otos types and persisted on demand, never in grid publication.
- `EnrichmentCoordinator` (actor, new) — the cursorless scheduler, the two pools,
  the transient state, the batched-apply buffer.
- `MediaEnricher` (nonisolated value, new) — one async unit:
  `MediaMetadataReader.read` plus a QuickLook 256 px JPEG thumbnail →
  `EnrichmentOutcome`;
  injectable like `CatalogScanner`.
- `ThumbnailStore` (nonisolated enum, new) — the thumbnails directory, naming,
  atomic write, load, delete.
- `FileMaterialization` (nonisolated, existing) — the dataless gate and the
  non-blocking download.
- `CatalogWindowViewModel` (@MainActor, extended) — owns the coordinator's
  lifetime, the newest-value `viewportChanged` intent lane, and `startEnrichment`.
- The grid bridge and tile (@MainActor, extended) — report visible identities;
  load the thumbnail off-main keyed on content; show the filename and best date.

Data flow:

```
scan / FSEvents → Store notifies → Coordinator queries Store candidates → dispatch
  enrich slot: status .materialized → MediaEnricher (read + QuickLook)
       → pendingApply buffer → store.applyEnrichmentBatch (merge cheap fields,
         stamp, one notification)
  enrich slot: status .notMaterialized → datalessPending → download pool
  download slot: materialize → freshly (LIFO) → signal → enrich slot pulls it
Projection republishes (thumbnailPath / captureDate now set; cheap)
  → grid refreshVisible → existing visible tiles reconfigure in place
    → tile: if content key changed, ThumbnailStore.load off-main
    → image + best-date assigned on Main
asset row purged (proven deletion or library removal) → ThumbnailStore.delete
```

Only ordered IDs plus a scalar detail-refresh generation flow through the 10 Hz
grid publication — no bytes and no full metadata. Hot tile details are faulted by
visible ID, and full metadata lives in `asset_metadata` scalar columns plus
`metadata_extra_json` for on-demand reads.

Concurrency and cancellation: the coordinator owns one supervising task (started
by the ViewModel), captured weakly; `MediaEnricher`/`ThumbnailStore` run inside the
child tasks (off-actor); only `finish*`/dispatch and the batched apply run on the
actor; the tile's load runs in a detached task and assigns on Main under a
generation token. Cancellation is teardown-only: the ViewModel cancels the
supervisor and shuts the coordinator down, cancelling the group.

Implementation sequence (each landed and verified on its own):

1. Data model + store write — `v3` migration; `AssetMetadata`; the `MediaAsset`
   fields, `needsEnrichment`, `bestCaptureDate`; `applyEnrichmentBatch`; the rescan
   merge; thumbnail-delete-on-purge. (PR #21)
2. Enricher + thumbnails — the `MediaMetadata` SPM dependency; `ThumbnailStore`;
   `MediaEnricher.live` (map result → `AssetMetadata`; QuickLook 256 px). (PR #22)
3. Coordinator + pools — `EnrichmentCoordinator` with an injectable enricher and
   materializer; the full enrich → download → `freshly` → re-enrich pipeline.
   (PR #23)
4. Viewport channel + tile — the coordinator started by the ViewModel; the
   newest-value viewport feed; the tile renders the thumbnail and capture date
   off-main. (PR #24)
5. Documentation finalization — this spec, ADR 0009, the ENR requirements, the
   ADR 0008 and AGENTS.md amendments, index and onboarding, and retiring the
   temporary plan. (this increment)

## Retirement Proof

- Placeholder-grid framing: APP-001 (no thumbnail/metadata claim), APP-006
  (placeholder grid), APP-009 and APP-010 (placeholder tiles) updated to current —
  the grid now renders thumbnails and a capture date. No requirement is retired
  outright; they are amended.
- FND-057's "bounded" materialization phrasing updated: eager full-library is now
  permitted (ADR 0009).
- `ENRICHMENT-IMPLEMENTATION-PLAN.md` (temporary, repo root) deleted; its decisions
  now live in ADR 0009, this spec, and `docs/requirements.md`.
- No type, column, fixture, accessibility identifier, or construction path is
  removed; the `v3` migration only adds columns.

## Living Documentation And Comment Audit

- New: `docs/adr/0009-...md`, `docs/specs/0022-...md`.
- Amended: `docs/adr/0008-...md` (point 6, MECE bullets), `AGENTS.md` (cloud
  materialization baseline), `docs/requirements.md` (ENR-001…ENR-010; APP-001/006/
  009/010; FND-057), `docs/index.md` (register ADR 0009 + spec 0022),
  `docs/onboarding.md` (enrichment data flow and the coordinator's role).
- Deleted: `ENRICHMENT-IMPLEMENTATION-PLAN.md`.
- Code-comment audit: the file guides on `EnrichmentCoordinator`, `MediaEnricher`,
  `ThumbnailStore`, `MediaAssetTileView`, and the extended `CatalogStore` /
  `CatalogModels` / `CatalogWindowViewModel` describe the current mechanics and the
  reasons for actor isolation, the off-actor reads, the batched apply, and the
  off-main tile load — no syntax narration or retired behavior.

## Instrumentation And Performance

- `OtosLog.metadata` / `OtosLog.thumbnails` and the diagnostics facade record
  coordinator batch flushes (`catalog.enrichment.coordinator`, phase `flush`),
  thumbnail-generation failures, and bounded thumbnail write/load events (path
  allowed, no metadata payload) at batch and boundary scope — never per-file JSONL,
  never media payloads.
- The grid uses signposts for state receive, structural apply, visible in-place
  reconfiguration, structural reload, and slow-cell setup. The tile's thumbnail
  read/decode and date formatting run off the main actor; Main only assigns,
  keeping the configure path below the slow-cell threshold.
- Performance budgets: MainActor under 100 ms; the full metadata is not resident
  (ADR 0009 §2), and Projection publications carry only ordered IDs plus a scalar
  detail-refresh generation. Measure-before-optimize gates: no thumbnail cache
  until a scroll profile demands one; no maintained work partition until Store
  candidate queries are proven too costly at a real large library.

## Code-Smell Review

- MainActor gravity: avoided — the coordinator and pools are off-main; the tile
  decodes/formats off-main.
- State duplication: avoided — work is derived from `needsEnrichment`, not a second
  backlog; staleness is the `(size, mtime)` signature, not a stored flag.
- Unsafe concurrency escape: none. The tile-image ferry is an ordinary `Sendable`
  value because `CGImage` is immutable and Sendable in the current SDK.
- Otherwise none observed.

## Acceptance Criteria

The ENR-001…ENR-010 acceptance examples in `docs/requirements.md`, plus: a rescan
that changes only mtime makes `needsEnrichment` true and the asset re-enriches
after the scan-completion wake; a stale completion whose `(size, mtime)` no longer
matches the current source facts leaves old best-known overlay visible but does not
stamp the row current; a definitive-but-empty outcome stamps and is not retried;
the full enrich → download → re-enrich pipeline brings every asset to enriched;
removing a library purges its thumbnail files; the tile shows the thumbnail when
the path is set and the best date with the filesystem fallback; same-identity
enrichment refreshes reconfigure visible items in place instead of entering AppKit
reuse.

## Verification

- `script/verify.sh` (Xcode 27 beta) green at each increment: SwiftLint 0
  violations, BUILD SUCCEEDED, TEST SUCCEEDED.
- Tests at the narrowest boundary with an `.inMemory` `CatalogStore` and an
  injectable `MediaEnricher`: `CatalogStoreEnrichmentTests`, `MediaEnricherTests`
  (committed fixtures), `EnrichmentCoordinatorTests`, the `CatalogWindowViewModel`
  enrichment-wiring test, and `MediaAssetTilePresentation` tests.
- POC-validated-only (no CI test): the live cloud materialization download (spec
  0016 / 0021 precedent).
