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
   detail-refresh generation (FND-031/FND-043). Image bytes and large nested
   metadata must never flow through that publication.

Verified facts feeding the decision: `MediaEligibility` already restricts the
catalog to `.image`/`.movie` files, so non-media is never a materialization
target; `FileMaterialization.status(of:)` is ~7 µs/file (spec 0021);
Store-owned indexed enrichment-candidate queries keep scheduling out of UI
publication; a consumer app cannot reclaim another provider's downloaded bytes
(spec 0021).

This decision supports requirements ENR-001 through ENR-011.

## MECE Decision Scope

This ADR owns:

- Thumbnails are files on disk; the catalog stores only the relative path. Size,
  format, and generator (256 px long edge, JPEG generated from QuickLook with
  icon fallback rejected — a definitive thumbnail-unavailable stamp when no real
  imagery can be produced). Generated files are staged until Store validates and
  stamps the result. The visible grid may hold a bounded decoded-thumbnail memory
  cache for synchronous repaint, but that cache is rendering state only, never
  catalog truth or durable overlay.
- The full parsed metadata is persisted in `asset_metadata` as queryable scalar
  columns plus `metadata_extra_json`, decoded on demand, and is **never resident**
  in grid publication.
- The only enrichment data fetched with visible `MediaTileDetail` rows: the
  thumbnail path, generated best kind, video duration seconds, and the
  `(size, mtime)` source stamps. Generated best date and format remain hot
  query/filter facts but are not tile display facts.
- Disjoint column ownership: the scan writes only fact columns, enrichment writes
  only enrichment columns, scan upserts preserve enrichment overlay, and a stale
  in-flight enrichment completion must revalidate the source signature in SQLite
  before it can stamp a row current.
- Staleness is the `(size, mtime)` source signature; `needsEnrichment` derives
  from it. mtime-only changes count.
- Timestamp role facts are stored; SQLite's generated `best_capture_unix` value
  supplies Date sort and enrichment priority. Video duration is a hot scalar
  because the tile surface needs it for every visible video; other metadata
  dimensions and details remain cold.
- Otos eagerly materializes the whole media library to enrich it (the enrichment
  application of ADR 0008's permission), accepting the unreclaimable disk growth.
- The enrichment ownership split: a single `EnrichmentCoordinator` actor running
  two fixed worker pools (4 enrich + 4 download) by cursorless scheduling, with
  Store-owned claim ordering and process-local lease cleanup. Connected-source
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
   never reads a half-written file during a re-enrichment overwrite. QuickLook
   generates the image from real imagery only (`.thumbnail` /
   `.lowQualityThumbnail`); the generic `.icon` fallback is rejected. A
   generation failure is a definitive thumbnail-unavailable outcome: enrichment
   still stamps the asset (no retry until the file changes) and the grid shows
   a broken-media placeholder. The catalog stores `thumbnail_path` (NULL when
   unavailable). 256 px is a true grid thumbnail;
   the max-zoom path that loads originals is a separate future decision.

   Spec 0038's no-blank grid invariant is owned by `TileContentStore`: it is the
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

3. **There is no migration policy for pre-user metadata shape changes.** This app
   has no active users; incompatible local catalog state is destructively reset by
   the clean schema policy in ADR 0010. Originals are untouched. App-owned
   thumbnails are purged with the reset because their SQLite references were
   discarded, and metadata is rebuilt by re-enrichment.

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
   `thumbnail_path`, and the `(size, mtime)` stamps. A re-scan never clobbers
   metadata, duration, or the thumbnail within one record. An enrichment
   completion revalidates its source `(size, mtime)` in SQLite before writing and
   before promoting its staged thumbnail; stale overlay may remain visible as the
   best-known data, but stale work cannot mark a changed source current or replace
   the prior thumbnail file.

6. **Staleness is the `(size, mtime)` source signature.** `needsEnrichment` is
   true when the stamps are absent or differ from the asset's current
   `(byteSize, contentModifiedAt-in-seconds)`; it depends only on the signature,
   never on whether products exist, so a definitive-but-empty outcome (unsupported
   file, icon-only thumbnail) still stamps and is not retried. mtime-only changes
   count, because a real edit can leave the size constant. The always-firing scan-
   completion notification (FND-062 suppresses only the per-batch projection wake,
   not the scan-lifecycle wake) lets the coordinator re-evaluate staleness after
   every rescan. Stamps are stored as integer seconds to avoid floating-point
   epsilon in equality. There is no stored `is_stale` flag.

7. **Eager full-library materialization.** Otos materializes every dataless media
   file in the background to enrich it, accepting the unreclaimable local disk
   growth as the price of complete coverage. This is the enrichment application of
   ADR 0008's permission to download deliberately and non-blocking; the catalog is
   already media-only, so non-media is never downloaded. What the user is looking
   at materializes immediately; the background fill is governed by a materialized-
   first rule (enrich everything local before eagerly downloading the rest).

8. **One coordinator, two pools, cursorless scheduling, one claim lease.** A single
   `EnrichmentCoordinator` actor owns the scheduling and two fixed worker pools — 4
   enrichment slots and 4 materialization slots — because a worker must never block
   on a multi-second download, so the two are separate I/O-bound concurrency
   budgets (neither is CPU-bound). Non-viewport eager materialization may use at
   most `downloadConcurrency - 1` slots while viewport-dataless work is pending, so
   eager fill cannot block what the user is looking at behind a full download pool.
   Scheduling is cursorless: the next units are
   queried from Store through `enrichmentCandidates(prioritizing:limit:)`, and Store
   selects eligible candidate keys in priority/default order, claims only the rows
   still free with one nullable `enrichment_claimed_until` column, then fetches the
   claimed rows back in selected order. Visible priority always outranks fallback
   and fills past contended rows until the limit or eligible input is exhausted.
   Fallback claim ordering first offers available connected/removable source roots,
   then fixed-library roots; inside each source class, work follows the default
   browser's useful order — newest `best_capture_unix` first, then stable path
   tie-breakers — rather than path `sort_key` order. MTP camera staging seeds use
   the same existing download pool but are ordered still/image items before videos,
   then capture date, then path, so short still downloads do not sit behind video
   transfers from the same device. The coordinator maintains no durable backlog or
   SQL partition, but it does keep one small process-local queue of already claimed
   work so a full sweep does not become one claim transaction per free worker slot.
   The rest of its runtime state is what it cannot derive (viewport, in-flight
   guards, the just-downloaded `freshly` LIFO hand-off, the discovered-dataless set,
   the pending-apply buffer, and one `eagerMode` latch).
   Those process-local sets and queued claims prevent duplicate scheduling inside
   this coordinator; the SQLite lease is the SQL query gate that prevents repeated
   dequeue of already-owned rows across queries.

   Claim transitions are explicit. Completed results keep their claim until
   `applyEnrichmentBatch` attempts the write; after that attempt, successful and
   stale-dropped results release the claim. Transient enrichment releases the claim
   so it can retry. Dataless discovery refreshes the claim while the coordinator owns
   download state. Successful or failed materialization releases the claim before
   the ID is rediscovered or handed back through `freshly`; persistent write failure
   leaves the ordinary lease expiry/backoff to avoid a tight retry loop. Because
   `enrichment_claimed_until` is a process-local scheduler lease, Store startup
   clears abandoned claims from the prior process, and coordinator shutdown releases
   queued, undispatched, in-flight, and pending claims before dropping runtime
   state.

   Materialization status is checked live at exactly one site — the enrichment pull,
   immediately before the read — which is both the router (materialized → enrich;
   dataless → download) and the ADR 0008 safety gate; it is never persisted.
   Download workers issue a non-blocking provider request and then poll status
   without reading bytes. If a file remains dataless, the worker re-issues the
   provider request every second within the same overall timeout so a stalled
   provider request becomes attributable and bounded rather than an invisible
   120-second wait. `FileMaterialization` returns the outcome, re-request count,
   and request-to-completion elapsed time so the coordinator can record durable
   materialization lifecycle evidence.
   Enrichment writes are batched (one transaction, one detail-only notification per
   batch) because a per-asset transaction and per-asset notification would crawl and
   re-sort the catalog on every completion. Cancellation is teardown-only: eager-
   everything re-downloads anyway, thumbnails are durable, and staleness re-queues,
   so per-unit cancel buys nothing.

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

Rejected for the owner-directed hot duration promotion in spec 0037. Duration is
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

- The cheap-grid invariant (ADR 0007/FND-043) erodes; a cold enrichment sweep pegs
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
  sub-millisecond (FND-061 context). A partition is a second source of truth that
  the coordinator's own batched writes would thrash; a cursor has position gaps and
  own-write feedback.

Failure modes:

- The partition drifts from `needsEnrichment` truth; the cursor re-processes or
  skips after a rescan.

Rejected: cursorless derivation is simpler and correct (FND-042/043 precedent for
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
- Local disk grows as the library materializes and that growth is unreclaimable;
  this is an accepted, deliberate cost of complete coverage, not a leak.
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
and FND-057's "bounded" materialization phrasing (eager full-library is now
permitted, owned here). ADR 0008 point 6 is amended to permit eager full-library
materialization and to point here for the enrichment specifics. No schema or type
was removed by ADR 0010's clean schema reset; there is no migration compatibility
path for pre-user enrichment schema changes.

## Living Documentation Impact

- `docs/adr/0008-...md` — point 6 and the MECE cloud-materialization bullet amended
  to permit eager full-library materialization and reference this ADR.
- `AGENTS.md` — the cloud-materialization baseline paragraph amended the same way.
- `docs/requirements.md` — add ENR-001…ENR-010 (Current); update APP-001, APP-006,
  APP-009, APP-010, and FND-057.
-  — the enrichment
  implementation spec this ADR is the decision record for.
-  — changes the thumbnail
  private file format to JPEG and documents manual old-thumbnail deletion.
  one-second provider re-request cadence and durable result attribution fields.
- `docs/index.md` — register this ADR and spec 0022.
-  — add the enrichment data flow and the coordinator's role.
- `ENRICHMENT-IMPLEMENTATION-PLAN.md` — deleted (its decisions now live here, in
  spec 0022, and in requirements).

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
