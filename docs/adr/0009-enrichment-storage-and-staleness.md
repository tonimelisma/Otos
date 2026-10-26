# ADR 0009: Enrichment Storage And Staleness

## Status

Accepted

## Context

Every cataloged image and video needs two derived products: a thumbnail for the
grid and parsed media metadata (EXIF and similar). Both require reading bytes,
which for the common case — media in cloud-synced folders stored as dataless
`SF_DATALESS` placeholders — forces materialization (a download). ADR 0008 owns
the materialization policy (the detector gate plus the permission to download in
the background); this ADR owns where the derived products live, how the catalog
decides a product is stale, and which owner produces them.

Two load-bearing facts about the architecture constrain the storage choice:

1. The catalog targets large libraries — anything added to hot `MediaAsset`
   detail rows or grid publication costs that much times the visible/query count.
2. `CatalogMediaGridState` is deliberately limited to identities plus a scalar
   detail-refresh generation (ARC-013/ARC-022). Image bytes and large nested
   metadata must never flow through that publication.

Verified facts feeding the decision: `MediaEligibility` already restricts the
catalog to `.image`/`.movie` files, so non-media is never a materialization
target; `FileMaterialization.status(of:)` is ~7 µs/file (measured);
Store-owned indexed enrichment-candidate queries keep scheduling out of UI
publication; Otos does not free downloaded bytes itself, and macOS evicts uploaded,
idle provider files under disk pressure (ADR 0008).

This decision supports requirements ENR-001 through ENR-014.

## MECE Decision Scope

This ADR owns:

- Thumbnails are files on disk; the catalog stores only the relative path. Size,
  format, and generator (256 px long edge, JPEG; for a still, drawn from the
  rendering that also makes its stored preview, ADR 0035; for a video, or a still the
  renderer cannot read, generated from QuickLook with icon fallback rejected — a
  definitive thumbnail-unavailable stamp when no real imagery can be produced). Generated files are staged until Store validates and
  stamps the result. The visible grid may hold a bounded decoded-thumbnail memory
  cache for synchronous repaint, but that cache is rendering state only, never
  catalog truth or durable overlay.
- The full parsed metadata is persisted in `asset_metadata` as queryable scalar
  columns plus `metadata_extra_json`, decoded on demand, and is **never resident**
  in grid publication.
- The only enrichment data fetched with visible `MediaTileDetail` rows: the
  thumbnail path, generated best kind, video duration seconds, and the
  `(size, mtime)` source stamps. The canonical content hash remains outside
  `MediaTileDetail` and grid publication. Generated best date and format remain
  hot query/filter facts but are not tile display facts.
- Disjoint column ownership: the scan writes only fact columns, enrichment writes
  only enrichment columns including the canonical hash and its source signature,
  scan upserts preserve enrichment overlay, and a stale
  in-flight enrichment completion must revalidate the source signature in SQLite
  before it can stamp a row current.
- Staleness is the `(size, mtime)` source signature for metadata products and the
  canonical XXH3-128 hash; a missing, malformed, or signature-mismatched hash is
  stale. mtime-only changes count.
- Timestamp role facts are stored; SQLite's generated `best_capture_unix` value
  supplies Date sort and enrichment priority. Video duration is a hot scalar
  because the tile surface needs it for every visible video; other metadata
  dimensions and details remain cold.
- Otos eagerly materializes the whole media library to enrich it (the enrichment
  application of ADR 0008's permission), accepting the disk growth macOS has not yet
  evicted, and never below the free-space floor (ADR 0027).
- The enrichment ownership split: `EnrichmentCoordinator` owns a bounded claim
  state machine and eight local enrichment workers; `MaterializationCoordinator`
  owns the one bounded physical-transfer scheduler shared by preview, device, and
  background demand. Store owns claim ordering and claims. Connected-source
  priority is applied at candidate/staging selection time, not through a durable
  second queue.

This ADR references, but does not own:

- The cloud materialization detector gate and the permission to download in the
  background, owned by ADR 0008.
- The SQLite catalog schema, Store query surface, and completed-scan
  reconciliation, owned by ADR 0002 and ADR 0010.
- The Projection publication model, owned by ADR 0005, Store-owned query
  architecture owned by ADR 0010, and descriptor/best-value query policy owned
  by ADR 0011.
- The narrow AppKit grid rendering boundary, owned by ADR 0006.
- Removable filesystem volume and MTP camera source identity, detach/forget
  lifecycle, temporary device staging, and All Media exclusion, owned by ADR 0013.

Adjacent decisions requiring separate ADRs or specs:

- A metadata inspector surface and the max-zoom "load the original" path
  (thumbnails serve up to their native size).
- Any durable thumbnail cache beyond the app-owned JPEG files, or any larger
  preview/original-rendering cache.
- Additional metadata indexes only if a future cross-asset feature proves them
  with measured query evidence.

## Decision

1. **Thumbnails are files; the catalog stores the path.** `ThumbnailStore` writes
   a staged 256 px long-edge JPEG under
   `Application Support/<bundleID>/Thumbnails/`, named for a deterministic final
   hash of `(library_root_id, relative_path)` — an opaque storage key, not asset
   identity. `CatalogStore.applyEnrichmentBatch` promotes the staged file to that
   final name only after SQLite source-signature validation passes; stale or
   deleted results discard their staged file and cannot overwrite the previous
   final thumbnail. The final promotion is atomic (replace or move) so a tile
   never reads a half-written file during a re-enrichment overwrite. A still's
   thumbnail and preview come from one `ImageRenderer` development (ADR 0035), and
   the preview is staged, promoted, superseded and purged with the thumbnail. For a
   video, or a still the renderer cannot read, QuickLook
   generates the image from real imagery only (`.thumbnail` /
   `.lowQualityThumbnail`); the generic `.icon` fallback is rejected. A
   generation failure is a definitive thumbnail-unavailable outcome: enrichment
   still stamps the asset (no retry until the file changes) and the grid shows
   a broken-media placeholder. The catalog stores `thumbnail_path` (NULL when
   unavailable). 256 px is a true grid thumbnail;
   the max-zoom path that loads originals is a separate future decision.

   The no-blank grid invariant (APP-015) is owned by `TileContentStore`: it is the
   sole decoded-image owner for the grid, keyed by asset identity and image-
   content key (`thumbnail_path`, source size, and source mtime seconds),
   cost-capped (default 256 MB) with pin-aware LRU image eviction. Visible IDs
   are pinned so a painted thumbnail cannot disappear under budget pressure.
   Unpinned images may be dropped and re-decoded on rebind. The store is never
   persisted, never used to answer catalog truth, and a re-enrichment that
   advances the image key keeps any prior painted image until the newer decode
   lands.

2. **The full metadata is on-demand scalar-plus-JSON, never resident in grid
   publication.** Enrichment writes the parsed `AssetMetadata` into an
   `asset_metadata` companion row. Common query fields are scalar columns; long-tail
   fields are preserved in `metadata_extra_json`. `fetchCatalog` loads roots and
   counts only; visible tile detail reads fetch only thumbnail path, generated best
   kind, duration, and source stamps. Full metadata is loaded only on demand, one
   asset at a time, for future inspector/query surfaces. Holding the full nested
   result inline on `MediaAsset` would ride the Projection publication path and
   cost memory whether fields are nil or not.

   The permanent exception is `duration_seconds`: enrichment writes it both to the
   cold metadata row and to nullable `media_asset.duration_seconds`. The tile uses
   that scalar to show video duration for every visible video. Keeping duration hot
   avoids a per-viewport metadata join while still leaving pixel dimensions,
   frame-rate, codecs, camera fields, locations, and full metadata JSON cold.

3. **Enrichment schema changes remain additive.** Catalog migrations are owned by
   `CatalogStorePersistence`; a future or unrecognized schema refuses to open
   without erasing the database or purging thumbnails. Originals are untouched,
   and supported additive changes preserve existing overlay until ordinary
   signature validation or re-enrichment rebuilds it.

4. **Timestamp role facts and video duration are stored as hot query/display facts.**
   Enrichment writes timestamp role facts (original, QuickTime creation,
   digitized, and GPS) instead of a pre-resolved winner. SQLite's
   `best_capture_unix` generated column ranks those role facts ahead of
   filesystem creation and modification dates, so Date sort and enrichment
   priority read the same best value without keeping full metadata resident. The
   metadata detail row still preserves all date roles, and the generated best date
   remains nil only when nothing is known. Grid tiles do not render this date.
   Enrichment also writes `duration_seconds` into the hot row for videos, using
   NULL for images and duration-less videos. Duration is not part of staleness,
   sorting, or image thumbnail identity; it is only a visible tile badge fact.

5. **Disjoint column ownership; scan upserts preserve overlay.** The scan upsert
   writes only scan fact columns; enrichment writes only `asset_metadata`,
   timestamp role facts, enriched kind/format, `duration_seconds`,
   `thumbnail_path`, the canonical hash, and the `(size, mtime)` stamps. A re-scan never clobbers
   metadata, duration, or the thumbnail within one record. An enrichment
   completion revalidates its source `(size, mtime)` in SQLite before writing and
   before promoting its staged thumbnail; stale overlay may remain visible as the
   best-known data, but stale work cannot mark a changed source current or replace
   the prior thumbnail file.

6. **Staleness is the `(size, mtime)` source signature.** `needsEnrichment` is
   true when the metadata stamps or canonical hash/signature are absent or differ
   from the asset's current `(byteSize, contentModifiedAt-in-seconds)`; it depends only on the signature,
   never on whether products exist, so a definitive-but-empty outcome (unsupported
   file, icon-only thumbnail) still stamps and is not retried. mtime-only changes
   count, because a real edit can leave the size constant. The always-firing scan-
   completion notification (ARC-038 suppresses only the per-batch projection wake,
   not the scan-lifecycle wake) lets the coordinator re-evaluate staleness after
   every rescan. Stamps are stored as integer seconds to avoid floating-point
   epsilon in equality. There is no stored `is_stale` flag.

   A metadata reader fix that changes what existing rows should hold is backfilled
   by an additive migration that clears the stamps of exactly the rows the fix can
   change, so the same predicate claims them again (`v5_heif_orientation_reread`: library
   HEIF rows with no orientation, which MediaMetadata before 0.6.1 could not read from
   `irot`/`imir`). There is no stored reader version: re-reading every row on each
   library release would download the whole cloud library to fix what a few rows hold.

7. **Eager full-library materialization.** Otos submits every dataless media file
   for background materialization after local enrichment drains, accepting the local
   disk growth macOS has not yet evicted. A download that would take the volume below
   the free-space floor is not started: `MaterializationCoordinator` reads capacity
   off the actor for background- and device-priority work, returns
   `insufficientLocalSpace`, and the schedule gives a cloud row's claim back and offers
   it again after `spaceRecheck` (60 s, `time: poll` — macOS reports no free-space
   change at an app-defined threshold). Interactive and command work does not wait for
   the floor. The catalog is already media-only, so non-media is never downloaded.

8. **Separate enrichment and materialization owners.** `EnrichmentCoordinator`
   owns cursorless catalog claims, a bounded 32-identity ready-enrichment window,
   separate materialization demands and in-flight IDs, pending-apply claims,
   readiness retry state, eight local byte-reading workers, the `freshly` handoff,
   and batched writes. Ready capacity, physical-transfer capacity, and SQLite
   claim ownership are independent: a dataless claim becomes a bounded
   materialization demand without occupying a ready slot, and a completed result
   releases ready capacity while retaining its Store claim until apply. It does
   not schedule physical provider transfers. `MaterializationCoordinator` is the
   sole owner of deliberate transfers requested by preview, device staging, or
   enrichment. Readiness admission is routed through an injectable
   `EnrichmentReadinessChecking` boundary; unknown provider status is retried by
   an owned signal rather than treated as ready.

   Producer flow control and physical admission are deliberately separate.
   Enrichment hands off at most 16 requests globally, derived from the physical
   scheduler's 16-slot capacity, and at most two per root, derived from the one
   active background slot plus one look-ahead request. Those are not second
   provider-admission rules: the materializer remains the only actor that decides
   what physically starts. The bounded handoff prevents a 25,000-placeholder
   library from becoming 25,000 suspended tasks, continuations, and claims.

   Materialization priority is interactive, then device, then background. A single
   owned supervisor is the only dispatcher; request registration only mutates
   bounded per-identity state and wakes it. Pending or effectively active
   interactive work prevents new lower-priority dispatch. Same-identity demand
   promotes queued work or joins an in-flight transfer, and effective priority is
   derived from current waiters so cancellation cannot leave a stale barrier.
   Global admission is
   16 transfers and 2 GiB logical bytes with two large videos (at least 256 MiB),
   one slot reserved from background work, and one active background transfer per
   root. Unknown size counts as 4 MiB; an oversized request may run alone.

   Apple's public `startDownloadingUbiquitousItem` API has no priority or reorder
   parameter. Otos cannot promise to reorder an already-issued provider request;
   it stops lower-priority admission and bounds pre-existing same-root contention
   instead of cancelling work the provider may already be performing.

   Enrichment remains cursorless: Store selects and claims eligible rows through
   `enrichmentCandidates(prioritizing:limit:)`. Visible work outranks fallback;
   available connected/removable roots precede fixed roots, then capture date and
   stable path break ties. MTP staging submits device-priority work, with stills
   before videos, then capture date and path. No durable materialization queue or
   status column exists.

   `MaterializationCoordinator` brackets each coalesced physical transfer with one
   Store known-materialization begin/end pair. Only measured regular-file hydration
   event shapes suppress; structural and dropped-event shapes always reconcile.
   The active window covers the 120-second timeout plus measured event lag and the
   existing post-success grace.

   Dataless discovery retains its claim for as long as the materializer waits: a claim
   is a process fact with no expiry, held until its owner releases it or the process
   ends, and loading the catalog clears every claim the last process left. Success
   releases the old claim and returns the
   identity through `freshly` and clears any pacing ledger entry for it. Cancellation
   (an in-flight transfer torn down by something other than shutdown — a per-root
   drain, for example) releases the claim without consuming a retry attempt: it is
   not a signal about the provider's ability to materialize the asset. Ordinary
   background failure retries in-window through a capped exponential schedule
   (`[15, 60, 300, 900]` seconds); once that schedule is exhausted the claim releases
   from the 32-item working window and pacing continues through a small process-local
   ledger (identity → earliest reclaim time, attempt count, and the `sourceSize`
   fragment of its `(size, mtime)` source signature) so a permanently-failing
   population cannot hold claim-window capacity forever the way an unbounded in-window
   retry would. The ledger is consulted when Store re-offers a claim: a candidate whose
   earliest-reclaim time has not arrived is deferred (its claim released back) unless
   its recorded source size no longer matches, which resets pacing immediately. The
   ledger holds no work payload and resets on success, source-signature change, or
   process restart (it is in-memory only). Device staging retries remain capped at
   3 in-window attempts (unbounded for the `insufficientLocalSpace` waiting condition)
   and never enter the ledger, since staged device seeds hold no Store claim.

   Shutdown stops new work, cancels enrichment's materializer waiters promptly, drains
   owned workers, and releases every remaining claim before the materializer itself
   shuts down. Root drain (eject) drops work claimed but not started under the root
   and waits, with no time limit, until the work this coordinator started there has
   finished. A download it handed to the shared materializer counts as running until
   its result comes back, so the drain needs no separate query of the shared
   coordinator, and an unrelated interactive preview request under the same root
   from another consumer never stalls an eject. `FileMaterialization` remains
   the one-URL mechanism: it checks `SF_DATALESS`, requests asynchronously, waits on
   the file's vnode attribute changes without reading bytes, and re-requests once per
   second inside the same timeout because the provider acknowledges nothing.

   Admission diagnostics are aggregate scheduler states. Rejections are counted by
   reason after a full pass and logged only when that state changes, followed by one
   unblocked transition. No candidate is logged again on every wake. Pending or
   effectively active interactive demand that defers device/background work is a
   truthful blocked state, not a silent no-op: it is recorded and reported, and the
   diagnostic does not clear to unblocked while that demand still holds. Enrichment
   writes remain one timed transaction and one detail notification per batch.

9. **Import settlement may reuse a validated source overlay.** After the published
   destination facts and Plan-0060 XXH3-128 digest are available, `CatalogStore`
   may read the source row's current `(size, mtime)` facts, enrichment stamps,
   normalized metadata JSON, and app-owned thumbnail path. Only a source whose
   facts and digest agree is eligible. Metadata and normalized facts are cloned
   into the destination's independent filesystem-path identity; a source thumbnail
   is copied into a separately staged destination thumbnail and promoted through
   the same atomic thumbnail path used by ordinary enrichment. Missing, stale,
   detached, or copy-failed source overlay never blocks import and leaves the
   destination on the ordinary-enrichment path. Source and destination overlay
   lifecycles are independent, and repeated journal recovery is idempotent.

10. **Import publication and enrichment gates are durable safety boundaries.** The
    executor persists a complete `.readyToPublish` record (including the staging
    digest and destination mtime) before exclusive publication, then persists
    `.publishedPendingSettlement` after the rename and before settlement or source
    deletion. Journal update/delete operations fail when they affect zero rows.
    Recovery never trusts a final pathname alone: final-plus-staging and exclusive
    destination races are foreign, while a final-only occupant must match journaled
    size, integer-second mtime, and XXH3 after a live materialization check immediately
    before hashing. Dataless or unknown recovery files retain their journal and use
    the shared `MaterializationCoordinator` for deliberate materialization. Ordinary
    enrichment repeats the same live gate immediately before hash, metadata, and
    thumbnail byte phases. Readiness is never persisted as catalog truth.

11. **The enrichment claim queries pin their partial index with `INDEXED BY`, and
    this is deliberate, measured policy, not an unexamined default.** Both claim
    queries (`EnrichmentClaimGateway.rootEnrichmentClaimQuery`/
    `globalEnrichmentClaimQuery`) name their partial index explicitly rather than
    letting the planner choose freely. Measured 2026-08-03 against a read-only copy
    of the live catalog (28,392 assets): for the single-root
    claim query, the planner already chooses the matching partial index
    unprompted — `INDEXED BY` changes nothing there. For the **global** (multi-root)
    claim query, removing the hint made the planner instead choose the primary-key
    autoindex plus a temporary B-tree sort, measured at **0.337 s** versus **0.005 s**
    with the hint for the same query against 3 roots (~27,000 combined assets) —
    roughly 68× slower. `INDEXED BY` converts that planner *preference* into a hard
    *build-time* dependency (a mismatched predicate fails to prepare rather than
    silently degrading), which is exactly why the v12/v13 migration bodies that
    create these indexes are frozen: the hint's safety only holds if the
    index text a shipped catalog actually has is provably implied by the predicate
    the query builds today.

## Alternatives Considered

### Video duration left only in `asset_metadata`

Keep `duration_seconds` only in the cold metadata companion row and join that row
when fetching visible tile details.

Pros:

- Keeps the hot media row smaller by one nullable scalar.
- Preserves a strict "all metadata is cold" rule.

Cons:

- Adds a metadata join to the visible tile detail path for a permanent video-tile
  surface.
- Makes scrolling need cold metadata table access for every visible video.

Failure modes:

- A future visible-detail query could accidentally pull more cold metadata into
  the grid path.

Rejected for the owner-directed hot duration promotion. Duration is
small, scalar, and needed by every visible video; other metadata remains cold.

### Metadata inline on `MediaAsset` and resident

Store the parsed metadata as fields on `MediaAsset` (or a resident sparse dict)
so any feature can read it without a database hit.

Pros:

- A future metadata sort/filter/inspector reads memory with no decode.
- One representation, no JSON decode.

Cons:

- Rides the Projection background rebuild and deep `==`; at 1M assets the per-tick copy
  and compare cost is large even off-main.
- Inline optionals cost their full slot whether nil or not (~480 B/asset ≈ 480 MB
  at 1M) for data nothing currently reads across assets.

Failure modes:

- The cheap-grid invariant (ADR 0007/ARC-022) erodes; a cold enrichment sweep pegs
  the Projection actor.

Rejected: nothing reads full metadata across all assets today, so it must not be
resident in the grid path. Scalar columns keep likely query fields indexable, and
metadata detail JSON preserves long-tail fields for one-asset-at-a-time reads. If a
cross-asset metadata feature is ever built, that spec adds only the indexes or
resident structure it proves it needs.

### Thumbnails as SQLite BLOBs

Store thumbnail bytes in the catalog row instead of files.

Pros:

- One store; no separate file lifecycle to keep in sync with rows.

Cons:

- Bloats the database and risks thumbnail bytes riding hot detail rows or the
  publication path if a column is ever read broadly.
- Files are simpler to write atomically and to delete on purge.

Failure modes:

- Image bytes leak into the Projection pipeline through a careless column read.

Rejected in favor of files-by-path, which keeps bytes entirely out of the catalog
and the publication.

### HEIC thumbnail files

Write thumbnail files as HEIC.

Pros:

- Compact files.
- Native Image I/O support on macOS.

Cons:

- The observed `bike_to_farmers_market.mp4` failure produced a valid-looking HEIC
  thumbnail that decoded as static after writing a 10-bit/HDR video-derived
  `CGImage` through Image I/O.
- Correctness would require a careful 8-bit sRGB normalization step before every
  encode, keeping the app on the same format path that already failed.

Failure modes:

- Another high-bit-depth, HDR, or unusual color-layout input silently stores a
  corrupt thumbnail.

Rejected in favor of JPEG for the grid thumbnail product.

### PNG thumbnail files

Write thumbnail files as PNG.

Pros:

- Lossless and robust for unusual input bit depth and color.

Cons:

- Larger than needed for 256 px grid thumbnails. The sampled Quick Look PNG for
  the failing MP4 was 182 KB, versus 14 KB for a JPEG quality-85 derivative.

Failure modes:

- The durable overlay directory becomes much larger for no visible grid benefit.

Rejected in favor of JPEG.

### JPEG thumbnail files

Write thumbnail files as JPEG.

Pros:

- Opaque, 8-bit, broadly supported photo/video thumbnail format.
- Avoids the HEIC Main 10/static failure path seen in the latest run.
- Compact enough for durable backed-up overlay; the sampled failing MP4 thumbnail
  was 14 KB at quality 85.

Cons:

- Lossy and not alpha-preserving.

Failure modes:

- Transparent source images flatten to an opaque thumbnail. The current grid
  thumbnail is not an alpha-fidelity product.

Selected for `ThumbnailStore`.

### A maintained work backlog (partition sets or a cursor)

Keep an explicit `extractionPending`/`downloadPending` partition, or a cursor into
the catalog, instead of deriving work each pass.

Pros:

- O(1) "next unit" without scanning the snapshot.

Cons:

- Scale machinery before measurement says it is needed; the derive-it scan is
  sub-millisecond (ARC-037 context). A partition is a second source of truth that
  the coordinator's own batched writes would thrash; a cursor has position gaps and
  own-write feedback.

Failure modes:

- The partition drifts from `needsEnrichment` truth; the cursor re-processes or
  skips after a rescan.

Rejected: cursorless derivation is simpler and correct (ARC-022 precedent for
deriving over maintaining). The current coordinator still derives candidates from
Store truth, but it batches claimed rows into a small actor-local queue after
measurement showed writer-queue pressure from many tiny claim transactions. That
queue is not a maintained catalog partition: if the process exits, Store lease
expiry is the recovery path. Revisit a durable partition only if the cursorless
query itself is measured too costly at a real large library.

## Consequences

- The grid gains thumbnails and video duration badges while publication stays
  identity-plus-generation only; visible tile detail reads fetch only
  `thumbnailPath`, generated best kind, duration, and stamps for visible IDs. Full
  metadata stays out of grid memory.
- The grid can synchronously repaint decoded thumbnails already seen in the current
  process without making decoded image memory a source of truth. The decoded-image
  cache is a fixed count/cost LRU, so entries age out only when those limits are
  exceeded; it does not currently observe OS memory-pressure notifications. After an
  entry ages out, a never-cached path can still show placeholder until a new decode
  succeeds.
- Re-enrichment is self-healing: a fact change makes the stamp mismatch, so the
  asset re-queues with no cancellation logic.
- Local disk grows as the library materializes until macOS evicts uploaded, idle
  files, and never below the free-space floor; this is an accepted, deliberate cost of
  complete coverage, not a leak.
- A future metadata-driven feature (sort, filter, inspector) must use the scalar
  columns/detail JSON on demand or propose its own measured index/resident structure
  in a new spec; it cannot assume metadata is resident in the grid path.
- Thumbnail files are owned overlay: they are deleted when their row is purged by
  proven deletion or explicit library removal (ADR 0008 lifecycle).
- Orphan hidden staged thumbnail temp files are also deleted at app-owned
  thumbnail-store startup, limited to the Application Support thumbnail directory.
  Originals and user media folders are never touched by that cleanup.
- Existing generated thumbnails from an older private format may be deleted
  manually during a development increment; the app does not carry a compatibility
  loader or migration path for generated thumbnail overlay.
- Stalled provider materialization requests are retried every second within the
  same timeout and attributed in diagnostics, but Otos still cannot guarantee a
  third-party provider will materialize a file before the timeout.

## Retirement Proof

This ADR adds enrichment storage; it retires the placeholder-grid framing that the
grid shows no derived products. Updated, not deleted: requirements APP-001,
APP-006, APP-009, APP-010 (the grid now renders thumbnails and video badges),
and ARC-034's "bounded" materialization phrasing (eager full-library is now
permitted, owned here). ADR 0008 point 6 is amended to permit eager full-library
materialization and to point here for the enrichment specifics. No schema or type
was removed by ADR 0010's clean schema reset; there is no migration compatibility
path for pre-user enrichment schema changes.

## Living Documentation Impact

- `docs/adr/0008-...md` — point 6 and the MECE cloud-materialization bullet amended
  to permit eager full-library materialization and reference this ADR.
- `AGENTS.md` — the cloud-materialization baseline paragraph amended the same way.
- `docs/requirements.md` — add ENR-001…ENR-010 (Current); update APP-001, APP-006,
  APP-009, APP-010, and ARC-034.
-  — the enrichment
  implementation spec this ADR is the decision record for.
-  — changes the thumbnail
  private file format to JPEG and documents manual old-thumbnail deletion.
  one-second provider re-request cadence and durable result attribution fields.
- `docs/index.md` — register this ADR.
- `docs/architecture.md` — add the enrichment data flow and the coordinator's role.
- `ENRICHMENT-IMPLEMENTATION-PLAN.md` — deleted (its decisions now live here and
  in requirements).

## Capture Timestamps: One Stored Truth, Two Projections

`AssetMetadata.timestamps` — the `CaptureTimestampRecord` array persisted in
`metadata_extra_json` — is the single stored capture-timestamp truth. Every date
column is a *projection* of it, derived where it is written:

- `CaptureWallClock.select(from:)` → `capture_wall_compact` / `capture_wall_precision`,
  the naming fact (ENR-012). Selects local-authority records only.
- `BestCaptureInstants.from(_:)` → `ts_original_unix`, `ts_quicktime_creation_unix`,
  `ts_digitized_unix`, `ts_gps_unix`, which the `best_capture_unix` generated
  column coalesces for ordering (ENR-003).

`EnrichmentResult` previously carried a second copy of those four instants as
`EnrichmentTimestampFacts`, and `ReusableEnrichmentOverlay` carried them again
alongside the same records. Production could not diverge — both halves derived
from one upstream `CaptureTimestamps` — but nothing *kept* them in agreement, and
any constructed value was free to contradict itself. Fixtures did: one asserted
best-date ordering from an absolute fact while its records said the asset had no
timestamps at all, and another paired a record with `instant: nil` against a fact
claiming a specific instant. Both states are unreachable through the enricher.

Roles are named by `CaptureTimestampRole`, shared by the producer and both
projections. `CaptureTimestampRecord.role` stays a `String` so persisted JSON can
decode a role this build does not know rather than failing.

Import overlay reuse clones the records and re-derives both projections at the
destination, rather than copying the source row's already-projected columns.
`fetchReusableEnrichmentOverlay` already required `metadata_extra_json` to be
present, and ENR-012's own migration already backfills the capture wall from that
JSON, so deriving the ordering columns from the same place is the existing
storage contract rather than a new dependency.

## Reversal Plan

If metadata must become resident (a cross-asset metadata feature ships), add a
resident sparse structure or additional SQL indexes in a new spec and keep the
detail JSON as long-tail preservation. If eager full-library
materialization proves unacceptable (disk pressure), narrow point 6 back to on-
demand-plus-viewport materialization — the coordinator's `eagerMode` latch is the
single switch that governs the background fill. If candidate queries are measured
too costly at scale, introduce a maintained partition behind the same Store query
boundary without changing the storage
model.
