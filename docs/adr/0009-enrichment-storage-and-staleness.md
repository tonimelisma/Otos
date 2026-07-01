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

This decision supports requirements ENR-001 through ENR-010.

## MECE Decision Scope

This ADR owns:

- Thumbnails are files on disk; the catalog stores only the relative path. Size,
  format, and generator (256 px long edge, JPEG generated from QuickLook with
  icon fallback accepted). No in-memory thumbnail cache.
- The full parsed metadata is persisted in `asset_metadata` as queryable scalar
  columns plus `metadata_extra_json`, decoded on demand, and is **never resident**
  in grid publication.
- The only enrichment data fetched with hot `MediaAsset` detail rows: the thumbnail
  path, a resolved capture date, and the `(size, mtime)` source stamps.
- Disjoint column ownership: the scan writes only fact columns, enrichment writes
  only enrichment columns, scan upserts preserve enrichment overlay, and a stale
  in-flight enrichment completion must revalidate the source signature in SQLite
  before it can stamp a row current.
- Staleness is the `(size, mtime)` source signature; `needsEnrichment` derives
  from it. mtime-only changes count.
- The resolved `captureDate` is stored; `bestCaptureDate` is computed at display
  as `captureDate ?? createdAt ?? contentModifiedAt`.
- Otos eagerly materializes the whole media library to enrich it (the enrichment
  application of ADR 0008's permission), accepting the unreclaimable disk growth.
- The enrichment ownership split: a single `EnrichmentCoordinator` actor running
  two fixed worker pools (4 enrich + 4 download) by cursorless scheduling.

This ADR references, but does not own:

- The cloud materialization detector gate and the permission to download in the
  background, owned by ADR 0008.
- The SQLite catalog schema, Store query surface, and completed-scan
  reconciliation, owned by ADR 0002 and ADR 0010.
- The 10 Hz projection/publication model, owned by ADR 0005, and Store-owned
  sort-key ordering, owned by ADR 0007 and ADR 0010.
- The narrow AppKit grid rendering boundary, owned by ADR 0006.

Adjacent decisions requiring separate ADRs or specs:

- Sorting or filtering by metadata, a metadata inspector surface, and the
  max-zoom "load the original" path (thumbnails serve up to their native size).
- An in-memory thumbnail cache, if a measured scroll profile ever demands one.
- Additional metadata indexes only if a cross-asset feature (metadata sort/filter)
  is ever built.

## Decision

1. **Thumbnails are files; the catalog stores the path.** `ThumbnailStore` writes
   a 256 px long-edge JPEG under `Application Support/<bundleID>/Thumbnails/`,
   named from a hash of `(library_root_id, relative_path)` — an opaque storage
   key, not asset identity. Writes are atomic (temp file, then `rename`) so a tile
   never reads a half-written file during a re-enrichment overwrite. QuickLook
   generates the image and its icon fallback is accepted (a generic tile beats
   none). The catalog stores `thumbnail_path`; there is no in-memory thumbnail
   cache. 256 px is a true grid thumbnail; the max-zoom path that loads originals
   is a separate future decision.

2. **The full metadata is on-demand scalar-plus-JSON, never resident in grid
   publication.** Enrichment writes the parsed `AssetMetadata` into an
   `asset_metadata` companion row. Common query fields are scalar columns; long-tail
   fields are preserved in `metadata_extra_json`. `fetchCatalog` loads roots and
   counts only; tile detail reads fetch only hot media columns. Full metadata is
   loaded only on demand, one asset at a time, for future inspector/query surfaces.
   Holding the full nested result inline on `MediaAsset` would ride the Projection
   publication path and cost memory whether fields are nil or not.

3. **There is no migration policy for pre-user metadata shape changes.** This app
   has no active users; incompatible local catalog state is destructively reset by
   the clean schema policy in ADR 0010. Originals are untouched, and metadata is
   rebuilt by re-enrichment.

4. **One resolved capture date is stored; the best date is computed at display.**
   Enrichment resolves `capture_date_unix` from the metadata date priority chain
   (original → quickTime creation → digitized → gps). `bestCaptureDate` is computed
   as `captureDate ?? createdAt ?? contentModifiedAt`, so the grid shows a date
   without the full metadata resident, the filesystem fallback cannot drift, and it
   upgrades automatically as enrichment lands. The metadata detail row preserves
   all date roles, so a future policy can re-resolve without re-reading files. The
   date is shown as a plain date and is never fabricated (MED-002):
   `bestCaptureDate` is nil only when nothing is known.

5. **Disjoint column ownership; scan upserts preserve overlay.** The scan upsert
   writes only fact columns; enrichment writes only `asset_metadata`,
   `capture_date_unix`, `thumbnail_path`, and the `(size, mtime)` stamps. A re-scan
   never clobbers metadata or the thumbnail within one record. An enrichment
   completion revalidates its source `(size, mtime)` in SQLite before writing; stale
   overlay may remain visible as the best-known data, but stale work cannot mark a
   changed source current.

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
   budgets (neither is CPU-bound). Scheduling is cursorless: the next units are
   queried from Store through `enrichmentCandidates(prioritizing:limit:)`, and Store
   atomically claims returned rows with one nullable `enrichment_claimed_until`
   column and `UPDATE ... RETURNING`. The coordinator maintains no backlog — only
   the runtime state it cannot derive (viewport, in-flight guards, the just-
   downloaded `freshly` LIFO hand-off, the discovered-dataless set, the pending-
   apply buffer, and one `eagerMode` latch). Those process-local sets prevent
   duplicate scheduling inside this coordinator; the SQLite lease is the SQL query
   gate that prevents repeated dequeue of already-owned rows.

   Claim transitions are explicit. Completed results keep their claim until
   `applyEnrichmentBatch` attempts the write; after that attempt, successful and
   stale-dropped results release the claim. Transient enrichment releases the claim
   so it can retry. Dataless discovery refreshes the claim while the coordinator owns
   download state. Successful or failed materialization releases the claim before
   the ID is rediscovered or handed back through `freshly`; persistent write failure
   leaves the ordinary lease expiry/backoff to avoid a tight retry loop.

   Materialization status is checked live at exactly one site — the enrichment pull,
   immediately before the read — which is both the router (materialized → enrich;
   dataless → download) and the ADR 0008 safety gate; it is never persisted.
   Enrichment writes are batched (one transaction, one detail-only notification per
   batch) because a per-asset transaction and per-asset notification would crawl and
   re-sort the catalog on every completion. Cancellation is teardown-only: eager-
   everything re-downloads anyway, thumbnails are durable, and staleness re-queues,
   so per-unit cancel buys nothing.

## Alternatives Considered

### Metadata inline on `MediaAsset` and resident

Store the parsed metadata as fields on `MediaAsset` (or a resident sparse dict)
so any feature can read it without a database hit.

Pros:

- A future metadata sort/filter/inspector reads memory with no decode.
- One representation, no JSON decode.

Cons:

- Rides the Projection 10 Hz rebuild and deep `==`; at 1M assets the per-tick copy
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

- Image bytes leak into the 10 Hz pipeline through a careless column read.

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
deriving over maintaining). The one expensive case — the full sweep to prove "no
materialized work left" before the latch — is hoisted off the coordinator actor.
Revisit a maintained partition only if the cursorless scan is measured too costly
at a real large library.

## Consequences

- The grid gains thumbnails and a capture date while the 10 Hz publication stays
  identity-plus-generation only; hot detail reads fetch only `thumbnailPath`,
  `captureDate`, and stamps for visible IDs. Full metadata stays out of grid
  memory.
- Re-enrichment is self-healing: a fact change makes the stamp mismatch, so the
  asset re-queues with no cancellation logic.
- Local disk grows as the library materializes and that growth is unreclaimable;
  this is an accepted, deliberate cost of complete coverage, not a leak.
- A future metadata-driven feature (sort, filter, inspector) must use the scalar
  columns/detail JSON on demand or propose its own measured index/resident structure
  in a new spec; it cannot assume metadata is resident in the grid path.
- Thumbnail files are owned overlay: they are deleted when their row is purged by
  proven deletion or explicit library removal (ADR 0008 lifecycle).
- Existing generated thumbnails from an older private format may be deleted
  manually during a development increment; the app does not carry a compatibility
  loader or migration path for generated thumbnail overlay.

## Retirement Proof

This ADR adds enrichment storage; it retires the placeholder-grid framing that the
grid shows no derived products. Updated, not deleted: requirements APP-001,
APP-006, APP-009, APP-010 (the grid now renders thumbnails and a capture date),
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
- `docs/specs/0022-metadata-and-thumbnail-enrichment.md` — the enrichment
  implementation spec this ADR is the decision record for.
- `docs/specs/0024-grid-flicker-and-thumbnail-jpeg.md` — changes the thumbnail
  private file format to JPEG and documents manual old-thumbnail deletion.
- `docs/index.md` — register this ADR and spec 0022.
- `docs/onboarding.md` — add the enrichment data flow and the coordinator's role.
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
