# Spec: Thumbnail Tile Redesign

## Classification

Feature with a persistence/schema update and rendering refactor.

Current requirement IDs changed: APP-006, APP-009, APP-010, ENR-002,
ENR-003, ENR-005, ENR-010.

ADR changed: `docs/adr/0009-enrichment-storage-and-staleness.md`.

## Problem Statement And User-Facing Goal

Before this increment, the media grid tile still looked like a placeholder: every
cell was a full square block, video used a blue tint plus a `video.fill` marker,
and filename/date labels sat in the square cell rather than on the thumbnail
itself. That framing competed with the media and made portrait and landscape
assets feel equally boxed.

The implemented goal is for the thumbnail, at its native aspect ratio, to be the
visible tile face inside the existing six-column square cell. Filename, relative
date, and video duration live as overlays inside that face. The unused part of the
square cell remains plain window background, not letterbox chrome.

## Scope

In scope:

- Keep the existing six-column square compositional layout, 4 pt item insets, and
  12 pt section insets.
- Draw an aspect-fit content rect for the thumbnail or an all-square neutral
  placeholder while no image is loaded.
- Overlay the filename and optional relative capture date at the top-left of the
  visible thumbnail/placeholder on a dark scrim.
- Overlay videos only at bottom-right, using duration text when parsed or a film
  symbol while duration is still unknown.
- Promote video `duration_seconds` from the cold metadata row into the hot
  `media_asset` row because every visible video tile needs it.
- Add a small in-repo relative date helper for the exact product cascade.
- Keep thumbnail size at the current 256 px long edge. The plan's optional 512 px
  bump required an explicit owner yes; no such yes was given.
- Update requirements, ADR 0009, onboarding, index, and affected historical specs
  so current documentation matches behavior.

Out of scope:

- Any change to the collection layout, number of columns, gutters, structural
  apply gate, visible-detail read path, selection semantics, clipboard behavior,
  or enrichment scheduling.
- Promoting image/video pixel dimensions to the hot row.
- Loading original files for higher-resolution tile rendering.
- A thumbnail cache, prefetcher, generalized rendering pipeline, SwiftUI hosting
  cells, or custom tiler.
- Localizing the English literals `Today`, `Yesterday`, and `Last`.
- Any user-original write, sidecar, import/export, preview, zoom, drag, or edit
  behavior.

## Repo State Inspected Before Implementation

- `Otos/Views/MediaAssetCollectionView.swift` already owns the six-column square
  AppKit layout and visible-detail faulting. It does not need layout changes.
- `Otos/Views/MediaAssetTileView.swift` owned one reusable AppKit tile. Before
  this increment it drew the whole square as a gray or blue-tinted backing,
  aspect-fit an image view over the square, and placed filename/date/video icon
  directly in square-cell coordinates.
- `MediaAssetTilePresentation` already contains pure display policy for video
  classification, fallback title, capture-date text, thumbnail content identity,
  and thumbnail load.
- `ThumbnailStore` persists 256 px long-edge JPEGs. A decoded thumbnail's
  `CGImage.width`/`height` gives the display aspect; no metadata dimensions are
  needed for layout.
- `AssetMetadata.durationSeconds` is parsed and persisted in `asset_metadata`, but
  `MediaAsset` and the visible detail query do not carry duration.
- `CatalogStorePersistence.databaseNeedsCleanSchemaReset` intentionally treats an
  incompatible pre-user schema as a clean rebuild and purges app-owned thumbnails.

## Captured Requirements For User Verification

The owner supplied `PLAN.md` and then explicitly requested "implement PLAN.md
until it's fully done. don't stop after the first increment." That guidance is
specific enough to record directly and proceed without another review stop.

Functional requirements:

- A grid tile's visible face shall be the loaded thumbnail's native aspect-fit
  rect inside the square cell. When no thumbnail has loaded yet, the visible face
  shall be a full-square neutral placeholder.
- The top-left overlay shall contain two stacked lines: filename, then relative
  capture date. The date line is omitted when no date is known.
- Relative capture-date text shall use this cascade: `Today`, `Yesterday`,
  `Last <weekday>` for dates two through six days ago, month/day for same-year
  dates, and month/day/year for other years. Future dates use absolute forms.
- Images shall have no video differentiator overlay.
- Videos shall have a bottom-right badge. The badge shows `m:ss` or `h:mm:ss`
  duration when parsed and a film symbol when duration is not yet known.
- The selection ring shall hug the visible thumbnail or placeholder face rather
  than the full square cell.

Architecture requirements:

- `duration_seconds` shall be a nullable hot `media_asset` enrichment column and
  a nullable `MediaAsset.durationSeconds` value. It remains nil for images and
  duration-less videos.
- `asset_metadata.duration_seconds` shall remain the cold complete metadata
  record. This increment does not create a split writer; enrichment writes both
  duration columns from the same result.
- The visible-detail query shall fetch duration with the other hot row fields.
- Scan upserts shall preserve duration exactly as they preserve thumbnails,
  timestamp role facts, kind/format, and staleness stamps.
- The schema change shall use the Store-owned clean reset path instead of an additive
  ALTER migration, so previously enriched rows are rescanned and re-enriched
  rather than keeping duration nil indefinitely.

Non-functional and regression requirements:

- Thumbnail reads and decodes stay off the MainActor; tile configuration only
  computes small scalar strings and frames.
- `imageContentKey` must not include capture date or duration. Date/duration text
  updates must not clear and reload an unchanged thumbnail.
- Overlay layout must clamp inside the content rect. In extremely small or
  panoramic rects, the video badge hides before the date line; the filename
  survives longest.
- The implementation shall include focused pure-policy tests, Store persistence
  tests, schema reset coverage, and full `script/verify.sh` evidence.

## Architecture Alternatives

### Duration Storage

Alternative A: hot `media_asset.duration_seconds` column, selected.

Pros:

- One visible-detail query has everything needed for every visible video tile.
- Avoids a per-viewport join on the hot scroll path.
- Owner explicitly chose hot duration promotion.

Cons:

- Adds one nullable scalar to the hot row and forces a clean schema reset.

Failure modes:

- If scan upserts replaced rather than preserved enrichment overlay, duration
  would be lost. Existing disjoint writer tests are extended to cover it.

Alternative B: join `asset_metadata` when fetching visible details.

Pros:

- Avoids a new hot column.
- Keeps all duration state only in the cold metadata table.

Cons:

- Adds join work to every visible tile detail read for a permanent tile surface.
- Couples grid scrolling to the cold metadata table.

Failure modes:

- A future detail read could accidentally expand into more cold metadata.

Alternative C: keep a projection- or grid-resident duration cache.

Pros:

- Can avoid schema changes.

Cons:

- Creates a second source of truth for an enrichment fact.
- Adds cache invalidation where a nullable persisted scalar is sufficient.

Failure modes:

- Duration can drift from Store truth after re-enrichment, reset, or root removal.

### Relative Date Formatting

Alternative A: small in-repo helper, selected.

Pros:

- Exactly matches the required cascade.
- Pure, deterministic, and testable with injected `now` and `Calendar`.
- Avoids a dependency for roughly one small policy helper.

Cons:

- The words `Today`, `Yesterday`, and `Last` are English literals.

Failure modes:

- On-screen tiles can retain yesterday's text across midnight until the next
  reconfigure. That bounded staleness is accepted.

Alternative B: `RelativeDateTimeFormatter` or `DateFormatter` relative dates.

Pros:

- Native Foundation APIs.

Cons:

- Foundation does not provide the exact cascade: weekday names for two through
  six days ago plus absolute fallback.

Failure modes:

- The tile could say "2 days ago" or jump to absolute dates, contrary to product
  requirements.

Alternative C: third-party date helper.

Pros:

- More date utilities are available if future needs grow.

Cons:

- Adds a dependency without proving it is the best architecture.
- Still does not remove the need for product-specific policy.

Failure modes:

- A broad dependency becomes product infrastructure for a tiny formatting rule.

### Tile Rendering

Alternative A: keep one AppKit reusable tile with subviews, selected.

Pros:

- Preserves the current narrow AppKit grid boundary and reuse lifecycle.
- Keeps frame math local, direct, and testable through pure rect policy.
- Avoids per-tile SwiftUI hosting and custom drawing complexity.

Cons:

- AppKit frame layout remains imperative.

Failure modes:

- Bad reuse cleanup could leave stale overlay text or badges. Existing generation
  guards and reuse tests cover the behavior class.

Alternative B: custom `draw(_:)` tile.

Pros:

- Fewer subviews.

Cons:

- Manual text/icon drawing makes truncation, accessibility, and dynamic layout
  more fragile.

Failure modes:

- Text or badges can clip/overlap without AppKit text-field behavior.

Alternative C: per-tile SwiftUI hosting.

Pros:

- Declarative overlay composition.

Cons:

- Reintroduces high-cardinality SwiftUI hosting into the grid surface that ADR
  0006 intentionally moved to AppKit after measured table/grid jank.

Failure modes:

- Large-library scrolling or repeated updates can rebuild too much view graph.

## Selected Approach

Keep the existing `NSCollectionView` layout and reusable AppKit tile. Add
`duration_seconds` to the hot `media_asset` enrichment column group and carry it
through `StoredAsset` into `MediaAsset`. Add `RelativeDateText` as a pure helper.
Extend `MediaAssetTilePresentation` with duration-badge and content-rect policy.
Refactor `MediaAssetTileView` so a transparent cell contains one visible
`contentView` whose frame is the aspect-fit image rect or full-square placeholder.
The thumbnail, top-left text scrim, video badge, and selection ring all live
inside that content view.

This is the simplest correct architecture: one new scalar because the tile always
needs the fact, one pure date helper because Foundation does not offer the exact
policy, and one local AppKit view refactor inside the existing grid boundary.

## Interfaces, Ownership, Data Flow, And Persistence

- `CatalogStorePersistence` owns the schema addition, required-column reset
  detection, enrichment writes, visible-detail SELECTs, and row decoding.
- `CatalogStore.StoredAsset` and `MediaAsset` carry `durationSeconds`.
- `AssetMetadata` remains the full cold metadata record and still round-trips
  `durationSeconds`.
- `MediaAssetTilePresentation` owns pure display policy:
  `captureDateText`, `videoBadgeText`, `showsVideoBadge`, and `contentRect`.
- `MediaAssetTileView` owns reusable AppKit view state, layout, off-main image
  load generation guards, accessibility label assembly, and selection-ring
  drawing on the visible content face.

Persistence effects:

- The `media_asset` table gains nullable `duration_seconds DOUBLE`.
- `requiredCurrentMediaAssetColumns()` includes `duration_seconds`, so old local
  pre-user catalogs take the Store-owned clean reset path. Originals remain
  untouched; app-owned thumbnails are purged with the discarded schema.
- Scan upserts do not write duration. Enrichment writes duration from
  `result.metadata.durationSeconds`.

## Concurrency, Cancellation, Errors, Privacy, And Instrumentation

- No new actor or long-running task is added.
- The tile's existing detached thumbnail load remains the only byte-read path in
  the tile and is still guarded by a generation token.
- Relative-date and duration string formatting are small synchronous scalar
  operations in configuration.
- `CatalogStore.applyEnrichmentBatch` keeps its existing stale-completion
  validation and error handling.
- Diagnostics remain scalar. No thumbnail bytes, metadata blobs, secrets, or
  unbounded payloads are logged.
- Existing UI signposts still cover tile configure, thumbnail load start/apply/
  drop, visible reconfigure, and structural apply. Runtime smoke evidence will
  use `script/smoke-run.sh` plus unified-log/catalog-diagnostics artifacts.

## Test And Acceptance Criteria

- `RelativeDateTextTests` cover today, yesterday, two-through-six-day weekday
  text, the seven-day absolute boundary, same-year absolute dates, prior-year
  dates, future dates, and Dec/Jan year boundaries under a fixed calendar.
- `MediaAssetCollectionTests` cover relative date text, duration-badge text,
  videos-only badge visibility, content-rect math for landscape/portrait/square/
  unknown images, overlay visibility thresholds, and unchanged image keys across
  date/duration changes.
- `CatalogStoreEnrichmentTests` prove duration round-trips into
  `mediaAssets(for:)`, images remain nil, and scan upserts preserve duration.
- `CatalogStoreThumbnailLifecycleTests` prove an old `media_asset` schema without
  `duration_seconds` triggers the clean reset and purges app-owned thumbnails.
- `script/verify.sh` must pass locally with the Xcode version recorded.
- Smoke verification should exercise seeded-grid startup, scrolling, thumbnails,
  videos with and without duration, undated assets, placeholder-to-thumbnail
  transition, selection ring, and six-column resizing. Any unavailable visual
  case must be recorded with the blocker and remaining risk.

## Stale Document And Code-Comment Audit

Update current docs and comments that describe:

- full-square neutral/video tile chrome,
- `video.fill` plus blue-tint video differentiation,
- plain capture-date formatting,
- hot metadata columns that omit duration,
- selection rings around the full cell rather than the visible face.

Documents audited: ADR 0006, ADR 0009, specs 0011, 0022, 0024, 0031,
requirements, onboarding, and the docs index. Planning docs remain untouched
because the user did not ask to update roadmap/planning material.

Code-comment audit: `MediaAssetTileView`, `MediaAssetCollectionView`,
`CatalogModels`, `CatalogStore`, `CatalogStorePersistence`, and related tests
must describe current mechanics only. Delete or rewrite any comments that explain
retired tile chrome.

## Code-Smell Review

- MainActor gravity: accepted only for AppKit layout and scalar label assignment;
  thumbnail decode remains off-main.
- State duplication: duration is duplicated between hot row and cold metadata row
  by explicit product need; both are written by the same enrichment owner.
- AppKit bridge sprawl: contained to the existing tile and collection boundary.
- Stringly typed facts: duration remains typed as `Double?` seconds; paths and
  asset identities stay typed.
- Diagnostic payload sprawl: no new unbounded diagnostic payloads.
- Test coupling: pure policy tests assert observable formatting and rect results,
  not private subview frames.
