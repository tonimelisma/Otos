# Spec: Grid Flicker And JPEG Thumbnail Repair

## Change Type

Bug fix with rendering, enrichment-storage, and diagnostics updates.

## Problem Statement

The latest debug run showed the media grid repeatedly blanking and repainting
thumbnails while no scanner-visible filesystem facts changed. The same run also
showed a corrupt static-like persisted thumbnail for
`/Users/example/Pictures/bike_to_farmers_market.mp4`, even though Quick Look
can generate a correct thumbnail for the original video.

The app is a media browser; rhythmic thumbnail disappearance and corrupt stored
thumbnails are product failures, not acceptable background work artifacts.

## User-Facing Goal

Stable visible thumbnails: background enrichment and no-op rescans must not make
already-visible tiles disappear and reappear. Thumbnails generated from 10-bit or
HDR video must render as normal still images instead of static.

## Historical Before-Fix Evidence

- The run captured for this increment had 2,216 lines. It recorded 114 catalog
  window state applications; 105 had `delta=0`.
- The same log recorded 82 `refreshVisible` collection actions and 90 visible
  reload calls, reloading 7,164 visible cells total.
- All 342 scan batches in that run reported `changed=false`, and 40 scan
  completions deleted zero assets.
- Enrichment applied 84 batches. After the user switched to All Media, many
  batches contained only one or two items but still produced full-window,
  zero-delta publications and visible grid refreshes.
- `CatalogProjection` JSONL for the run recorded 135 window publications; 129
  took at least 250 ms, with a max of 782 ms.
- `MediaAssetCollectionView.refreshVisible` currently calls
  `collectionView.reloadItems(at:)` for unchanged ordered IDs.
- `MediaAssetTileView.prepareForReuse()` clears the image layer, title, date, and
  video badge.
- `ThumbnailStore` writes Quick Look's `CGImage` directly as HEIC. The sample
  MP4 is HEVC Main 10, 10-bit BT.2020/HLG. Quick Look's command-line thumbnail is
  correct; Otos's persisted HEIC decodes as static.
- ADR 0006, ADR 0009, spec 0022, and requirements currently describe visible
  reload and HEIC thumbnails as current behavior.

## Captured User Guidance

The user explicitly directed this increment to:

- Fix the grid flicker.
- Research and choose the correct item-replacement behavior rather than guessing.
- Fix the corrupt thumbnail path.
- Use JPEG thumbnails as the selected thumbnail alternative.
- Add relevant instrumentation, especially in Projection and the surrounding grid
  and thumbnail paths.
- Do not add a migration or re-enrichment policy for existing thumbnail files.
- Manually delete old thumbnails during the increment instead.
- Remove transient `Checking`, `Scanning`, and `Unavailable` status text from
  sidebar library rows.
- Carry the increment through Definition of Done.

This guidance is specific enough to record directly; no separate verification
round is needed before implementation.

## In Scope

- Same-identity grid detail updates reconfigure existing visible collection
  items in place instead of asking AppKit to reload/recycle them.
- Sidebar library rows render folder icon plus library display name only; they do
  not render transient availability or scan-activity subtitles.
- Structural identity changes continue to use one diffable snapshot apply.
- Projection diagnostics include enough scalar detail to distinguish changed
  identity, changed visible details, offscreen-only enrichment churn, and equal
  state suppression.
- UI telemetry records visible in-place refreshes, structural applies, tile reuse
  clears, thumbnail load starts/completions, and thumbnail apply/drop outcomes.
- Thumbnail storage switches from HEIC to JPEG.
- `ThumbnailStore` writes atomically and remains the only owner of thumbnail
  naming, loading, and deletion.
- Existing generated thumbnail files in Application Support are manually deleted.
- Requirements, ADRs, specs, onboarding, and file guides are updated to current
  behavior.

## Out Of Scope

- No database migration.
- No catalog migration from old `.heic` paths to `.jpg` paths.
- No preserved compatibility loader for old thumbnails.
- No explicit re-enrichment scheduler or user-facing rebuild command.
- No in-memory thumbnail cache.
- No projection cache, maintained dirty partition, or backlog structure.
- No preview, zoom, selection, import/export, or editing behavior.
- No changes to user originals.

## Requirements

### Functional

- A same-identity enrichment or fact-detail update must not make visible
  thumbnails disappear. Existing visible items are reconfigured in place.
- A structural grid update may recycle cells because item identity/order really
  changed.
- A thumbnail generated for the sample 10-bit/HDR MP4 must be a normal JPEG image
  rather than a static-like HEIC.
- Existing old thumbnails are discarded manually; the app does not attempt to
  load or migrate them.

### Non-Functional

- Same-identity refresh must remain viewport-bounded and MainActor work must stay
  below Apple's 100 ms hang threshold.
- Projection diagnostics must explain why a publication happened and which
  portions of the grid could be affected.
- UI high-frequency telemetry stays in Logger/signposts, not JSONL.
- Durable JSONL remains bounded to Projection summaries, coarse Store/enrichment
  events, failures, and detected stalls.

### Architecture

- `CatalogStore` remains the catalog truth owner; no UI-layer cache becomes a
  source of truth.
- `CatalogProjection` still owns sorting, availability filtering, selected-scope
  derivation, and coalesced publication.
- `MediaAssetCollectionView` remains the narrow AppKit boundary.
- `MediaAssetTilePresentation.contentKey` remains the tile's guard for whether
  image/date work must reload.
- `ThumbnailStore` owns the private thumbnail file format and extension.

### Privacy

- Thumbnail cleanup touches only Otos-owned Application Support overlay files.
- Originals in user media folders are not written, moved, renamed, or deleted.
- Diagnostics may include developer-local media paths and filenames, but no media
  bytes, thumbnails, metadata blobs, secrets, or unbounded payloads.

## Architectural Alternatives

### A. Keep `reloadItems(at:)` For Detail Changes

Pros:

- Smallest source change.
- Matches the current file guide and tests.

Cons:

- Invokes AppKit's reuse lifecycle for items whose identity did not change.
- `prepareForReuse()` clears images, causing exactly the visible blink observed.
- Hides the distinction between structural and detail changes.

Failure modes:

- Every enrichment batch can blank the viewport, including offscreen-only
  enrichment that happens to trigger a detail refresh.

Rejected because the failure is already observed.

### B. Use Diffable Snapshot Reload/Reconfigure APIs

Pros:

- Keeps item updates inside the diffable-data-source vocabulary.
- Mirrors Apple's modern guidance for reconfiguring rather than replacing cells.

Cons:

- AppKit's available API surface is not the same as UIKit's
  `reconfigureItems(at:)` convenience in the current target path.
- Snapshot reload APIs still express reload semantics rather than direct
  same-view reconfiguration.

Failure modes:

- Accidentally continues to trigger item reuse or broad diffable work for
  detail-only changes.

Rejected for this increment. The desired behavior is direct and viewport-bounded
with the AppKit APIs already in use.

### C. Reconfigure Existing Visible Items In Place

Pros:

- Makes the structural/detail split explicit.
- Uses existing visible index paths and item lookup to update only on-screen
  views.
- Preserves the tile instance and therefore does not call `prepareForReuse()`.
- Lets `MediaAssetTilePresentation.contentKey` suppress redundant thumbnail/date
  work on unchanged content.

Cons:

- Requires a small imperative loop in the AppKit bridge.
- Needs direct instrumentation to verify visible reconfiguration does not clear
  images.

Failure modes:

- If a visible item cannot be found for an index path during AppKit layout churn,
  that item is skipped until AppKit next asks for configuration.

Selected. This is the smallest correct fix for the observed flicker.

### D. Keep HEIC But Normalize To 8-bit sRGB First

Pros:

- Keeps the existing compact format and `.heic` documentation.
- Could fix 10-bit/HDR input if the bitmap normalization is complete.

Cons:

- Still depends on HEIC encode/decode behavior for tiny grid thumbnails.
- Requires careful Core Graphics bitmap/color-space conversion before every write.
- The current failure is in the HEIC path; keeping the format provides less
  confidence than changing it.

Failure modes:

- A missed color/alpha/bit-depth edge case produces another static or
  decoder-warning thumbnail.

Rejected for this increment.

### E. Store PNG Thumbnails

Pros:

- Lossless and robust for high-bit-depth Quick Look output.
- Very simple to reason about.

Cons:

- Local sample Quick Look PNG was 182 KB for a 144x256 thumbnail, much larger than
  JPEG or HEIC.
- Durable overlay size grows substantially at media-library scale.

Failure modes:

- Large thumbnail directories and slower disk traversal/backup for no visible
  grid benefit.

Rejected because grid thumbnails do not need lossless storage.

### F. Store JPEG Thumbnails

Pros:

- Opaque 8-bit photo/video thumbnail format with broad Image I/O support.
- Local sample compressed to 14 KB at quality 0.85 versus 182 KB PNG and 17 KB
  HEIC.
- Avoids the HEIC Main 10/static failure path for 256 px grid images.
- Correct for thumbnails, where exact alpha and lossless pixels are unnecessary.

Cons:

- Lossy.
- Requires updating current docs/tests from HEIC to JPEG.

Failure modes:

- Transparent source images flatten to an opaque background. Current grid tiles
  are opaque image/video thumbnails; transparent-original fidelity is not a grid
  requirement.

Selected.

### G. Add Projection Caches Or Maintained Dirty Sets

Pros:

- Could reduce the 250-782 ms Projection publications observed in the run.

Cons:

- Adds a second structure to keep correct before the simpler observed bug is
  fixed.
- Violates the current measure-before-optimizing preference unless the in-place
  refresh and instrumentation still show Projection as the dominant remaining
  problem.

Failure modes:

- State duplication or stale cache bugs in the UI publication boundary.

Rejected for this increment. Add instrumentation now; decide any Projection
data-structure change from after-fix measurements.

## Selected Approach

1. Replace same-identity `refreshVisible` reload with in-place visible item
   reconfiguration.
2. Keep structural diffable applies for changed identity/order.
3. Add Logger/signpost events around grid receive, structural apply, in-place
   refresh, tile reuse, tile content-key skip/load/apply/drop,
   and thumbnail write/load failures.
4. Add Projection JSONL scalar fields that compare the newly built grid with the
   last published grid: ordered-identity change, visible selected-scope count,
   full asset map equality cost, and whether only detail changed.
5. Change `ThumbnailStore` to write `.jpg` files atomically using Image I/O JPEG
   with a bounded lossy quality setting.
6. Manually delete the existing Application Support thumbnail directory contents.
7. Remove sidebar library status subtitles while preserving the projected
   availability/activity data for projection, grid empty states, diagnostics, and
   Settings.

## Interfaces, Ownership, And Data Flow

- `CatalogStore.applyEnrichmentBatch` still applies validated enrichment and
  notifies on applied rows.
- `CatalogProjection` still builds `CatalogWindowState`, but diagnostics now say
  whether the media-grid identity changed or only details changed relative to the
  last published state.
- `CatalogWindowViewModel` remains unchanged except for consuming the same state
  stream.
- `SidebarView` continues receiving `[CatalogLibraryState]` for identity and
  selection but renders no status subtitle from `availability` or `activity`.
- `MediaAssetCollectionApplyGate` continues to classify same ordered IDs as
  `refreshVisible`.
- `MediaAssetCollectionViewController.refreshVisible` now re-queries visible
  details through the Store-backed detail reader and calls an in-place visible
  reconfigure helper.
- `MediaAssetTileView.configure` still handles title/badge/background and only
  reloads thumbnail/date when `contentKey` changes.
- `ThumbnailStore.relativeName` now returns `.jpg`; `write` encodes JPEG;
  `load` remains extension-agnostic through Image I/O.

## Concurrency And Cancellation

- Grid in-place reconfiguration is MainActor-bound because it touches AppKit
  views.
- Thumbnail reads remain off-main in detached tile tasks; the small capture-date
  label formats synchronously during tile configuration.
- Thumbnail generation remains off-main in the enrichment workers.
- No new long-lived tasks are added.
- Existing tile generation guards reject stale thumbnail loads after reuse.

## Persistence Effects

No schema change. `thumbnail_path` continues storing a relative filename. New
paths end in `.jpg`. The app intentionally does not include a migration,
compatibility loader, or permanent re-enrichment policy for old generated
`.heic` thumbnail references. This developer increment performs a one-time local
manual overlay reset for the current Application Support data: delete generated
thumbnail files and clear local enrichment overlay columns so subsequent normal
enrichment writes `.jpg` paths.

## Instrumentation And Profiling Plan

- Use the captured run log and copied JSONL as before-fix evidence.
- Add JSONL Projection fields:
  - `mediaIdentityChanged`
  - `mediaDetailsChanged`
  - `previousSelectedScopeAssetCount`
  - `selectedScopeAssetCount`
  - `stateChanged`
  - existing timing fields retained
- Add UI Logger/signposts:
  - `MediaGridVisibleReconfigure`
  - no direct `reloadItems(at:)` bridge path
  - `MediaTilePrepareForReuse`
  - `MediaTileContentUnchanged`
  - `MediaTileLoadStarted`
  - `MediaTileLoadApplied`
  - `MediaTileLoadDropped`
- Add thumbnail Logger/signposts:
  - thumbnail write start/finish with format and dimensions
  - thumbnail load failure
- Verification uses `script/catalog-diagnostics.sh check`, `script/logs.sh UI`,
  `script/logs.sh Performance`, `script/logs.sh Thumbnails`, and
  `script/profile.sh "Animation Hitches" 10s` if runtime capture is possible.

## Tests And Acceptance

- Existing `MediaAssetCollectionApplyGate` tests continue to prove same IDs choose
  `refreshVisible`.
- Source hygiene proves `refreshVisible` no longer calls `reloadItems(at:)`.
- Source hygiene proves `SidebarView` does not render `Checking`, `Scanning`, or
  `Unavailable` status text.
- Tile presentation tests continue to prove content-key changes for thumbnail
  path, source stamp, and date.
- Thumbnail store tests prove relative names use `.jpg`, writing produces a
  loadable JPEG, and deletion still works.
- Catalog/enrichment tests use `.jpg` representative paths.
- Requirements authority check passes.
- `script/verify.sh` passes locally.
- Runtime evidence shows same-identity updates log visible reconfiguration with
  no direct `reloadItems(at:)` bridge path, and the sample MP4 gets a JPEG
  thumbnail that decodes as a normal image.

## Code-Smell Review

- AppKit bridge sprawl: accepted only inside the existing collection controller.
- MainActor gravity: no sorting, decoding, file I/O, or thumbnail encoding moves
  to MainActor.
- State duplication: no new cache or dirty set is added.
- Diagnostic payload sprawl: logs remain scalar and path-bounded; no thumbnail or
  metadata bytes are logged.
- Test coupling: source-hygiene checks guard the specific regression because the
  failure was a forbidden API call in one boundary; behavior tests cover public
  owner semantics.

## Stale-Document Audit Plan

Update current docs that mention visible reloads, HEIC thumbnails, or sidebar
status text:

- `docs/requirements.md`
- `docs/adr/0006-catalog-grid-rendering.md`
- `docs/adr/0009-enrichment-storage-and-staleness.md`
- `docs/specs/0011-placeholder-media-grid.md`
- `docs/specs/0006-catalog-library-state-snapshot.md`
- `docs/specs/0022-metadata-and-thumbnail-enrichment.md`
- `docs/index.md`
- `docs/onboarding.md`
- affected file guides and comments in `MediaAssetCollectionView`,
  `MediaAssetTileView`, `ThumbnailStore`, `MediaEnricher`, and
  `CatalogProjection`

Planning docs are not consulted or updated because the user did not ask for
roadmap/planning input.
