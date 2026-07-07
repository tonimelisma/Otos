# Spec 0044: Thumbnail Label Removal And Badge Centering

## Classification

Bug fix plus refactor.

## Problem Statement And User-Facing Goal

The video-duration badge is intentionally tight and anchored to the thumbnail's
bottom-right corner, but the duration text can clip on the right edge because the
badge applies only one horizontal padding amount. At the same time, thumbnails
should no longer show filename or relative date overlays. Removing those labels
must remove their tile-specific plumbing instead of merely hiding the views.

The user-facing goal is a cleaner thumbnail grid: image/video content remains the
primary signal, video tiles keep only a compact bottom-right duration or film
badge, the dark badge stays right-aligned to the thumbnail edge, and duration
text is centered inside the darkened area.

## Scope

In scope:

- Keep six square columns and the aspect-fit thumbnail face unchanged.
- Remove filename and relative date from thumbnail tiles.
- Remove filename/date tile subviews, formatters, text-scrim geometry, tests, and
  source-hygiene expectations.
- Narrow visible tile detail reads so the collection tile path receives only
  thumbnail path, best kind, duration, and thumbnail source stamps.
- Keep catalog filename, filesystem dates, and generated best-date facts for
  File Name sort, Best Date sort, scan freshness, and enrichment priority.
- Keep the video badge bottom-right aligned with no outer inset.
- Add symmetric 5 pt horizontal padding inside duration badges and center the
  duration text inside that padded badge.
- Update current requirements, ADRs, onboarding, and stale spec notes.

Out of scope:

- Removing File Name sort or Best Date sort.
- Removing catalog columns for `name`, `name_sort_key`, filesystem dates,
  timestamp role facts, or `best_capture_unix`.
- Changing thumbnail generation, decoded cache policy, grid column count,
  selection behavior, or enrichment scheduling.
- Adding an inspector, preview, zoom, or alternate label surface.

## Current Repo State

Inspection found the thumbnail label path in `MediaAssetTileView`:
`textScrim`, `titleField`, `dateField`, `configureOverlayText`,
`layoutTextScrim`, and accessibility label assembly all consume filename/date
facts. `MediaAssetTilePresentation` owns `title`, `captureDateText`, and
`MediaAssetTileTextScrimFrames`. `MediaTileDetailReader` and
`MediaTileDetailCache` currently traffic full `MediaAsset` rows, which carries
`name` and `bestCaptureDate` to the tile boundary.

The badge crop is in `layoutVideoBadge`: the badge width is
`ceil(durationField.intrinsicContentSize.width) + scrimPaddingX`, while the text
field starts at that padding and receives the full remaining width. That leaves
no right inset. The text field is right-aligned and clipped, and the badge masks
to bounds, so edge antialiasing can be shaved.

Current docs also describe filename/date tile overlays in requirements,
onboarding, ADR 0006, ADR 0009, and specs 0022, 0037, and 0038.

## Captured Requirements For Verification

Functional:

- Grid thumbnails shall not render filename or relative date text.
- Video tiles shall keep a bottom-right dark badge, showing duration when known
  and a film symbol while duration is unknown.
- The video badge darkened area shall remain right-aligned to the thumbnail face.
- Duration text shall be centered inside the darkened badge area.

Architecture:

- Visible tile detail shall use a tile-specific value that omits filename and
  capture-date facts.
- Catalog filename/date facts shall remain available to non-tile owners that use
  them for sorting, scan freshness, or enrichment priority.
- Tile image identity shall remain thumbnail path plus source size and mtime
  stamp; duration changes shall not restart image loading.

Non-functional:

- The change shall not add media I/O, thumbnail decoding, SQLite work, or sorting
  to the MainActor.
- The no-blank same-asset thumbnail invariant remains unchanged.

Process:

- Stale documentation and source-hygiene tests shall be updated so the removed
  filename/date tile plumbing cannot silently return.

These requirements are explicit from the user's messages, so no additional
verification prompt is needed before implementation.

## Linked Requirement IDs

- FND-062 and FND-064 stay current but no longer cite tile date visibility.
- APP-006 changes the grid tile anatomy.
- ENR-002 changes the tile overlay contract.
- ENR-003 changes from tile date display to generated best-date catalog policy.
- ENR-005 changes the visible tile detail read shape.
- ENR-010 changes the synchronous tile formatting scope.

No future requirement candidates are introduced.

## Architectural Alternatives

Alternative A: keep full `MediaAsset` detail rows and hide the labels.

- Pros: smallest code diff.
- Cons: leaves filename/date data at the tile boundary, contrary to the user's
  "no plumbing or wiring" direction.
- Failure modes: future tile code can accidentally re-render filename/date from
  still-present values; source-hygiene tests would need to police more surface.

Alternative B: delete filename/date fields from catalog and persistence.

- Pros: absolute removal of those facts.
- Cons: breaks current File Name sort, Best Date sort, scan freshness, and
  enrichment priority requirements.
- Failure modes: schema churn for the wrong owner boundary; product regressions
  outside the thumbnail surface.

Alternative C: introduce `MediaTileDetail` and a Store-backed tile-detail query
that selects only fields the tile needs.

- Pros: removes filename/date from the thumbnail data path while preserving
  current catalog behavior; keeps one Store-owned query path for visible tiles;
  makes tests and source hygiene precise.
- Cons: adds one small value type and one narrow SQL projection.
- Failure modes: the new projection could drift from tile needs unless covered by
  tests and current docs.

## Selected Approach

Use Alternative C. Add `MediaTileDetail` for the grid tile boundary, backed by a
`CatalogStore.mediaTileDetails(for:)` query that selects only identity,
`thumbnail_path`, `best_kind`, `duration_seconds`, and the thumbnail source
stamps. Keep `MediaAsset` and `mediaAssets(for:)` for existing non-tile owners.

Delete the top-left label subviews and presentation helpers. The tile configures
only the video badge and image load. For duration badges, compute width as
`ceil(textWidth) + 5 + 5`, keep the badge frame bottom-right aligned, make the
duration field occupy the padded interior, and center its text.

This is the simplest correct approach because it removes the wrong boundary
without disturbing catalog facts that still have current owners.

## Interfaces, Ownership, Data Flow, And Persistence

- `MediaTileDetail` owns the visible tile's small scalar detail value.
- `CatalogStore.mediaTileDetails(for:)` owns the Store-backed visible tile query.
- `MediaTileDetailReader` owns cancellation/error handling for tile reads.
- `MediaTileDetailCache` keeps sticky visible details by `MediaAssetID`.
- `MediaAssetTilePresentation` owns pure badge geometry, duration formatting,
  image identity, and paint decisions.
- `MediaAssetTileView` owns AppKit view state for the thumbnail face, video
  badge, async load generation guard, selection ring, and accessibility label.

Persistence effects:

- No schema change.
- No catalog fact or overlay column is removed.
- The new visible tile query reads fewer columns than the older full
  `MediaAsset` detail read.

## Concurrency And Actor Ownership

- `CatalogStore` remains the actor owner of SQLite reads.
- `MediaTileDetailReader` is the async bridge from the AppKit controller to the
  Store query.
- `MediaAssetCollectionViewController` remains MainActor AppKit state.
- Thumbnail loads and preheat decoding remain off-main.
- The existing generation and same-identity guards continue rejecting stale
  image-load completions.

## Instrumentation And Profiling Plan

No new instrumentation category is required. Existing unified log/signpost spans
remain in place for visible detail queries, visible item reconfiguration,
preheat, slow cell configuration, tile load start/drop/apply/nil, and paint
invariant defense. The change removes synchronous filename/date formatting from
tile configuration and narrows detail SELECT payload, so it does not add a new
jank risk. Verification should include the existing local `script/verify.sh`;
runtime smoke/profiling is useful but not required unless verification reveals a
rendering or responsiveness regression.

## Test And Acceptance Criteria

- `MediaAssetTilePresentationTests` proves:
  - only video details receive video presentation;
  - duration formatting remains unchanged;
  - badge visibility still hides on small rects;
  - duration badge dark area is right-aligned;
  - duration text frame is centered inside the dark area with symmetric padding;
  - duration changes do not change the image content key.
- `MediaAssetCollectionTests` proves sticky detail caching with `MediaTileDetail`.
- Source-hygiene tests prove `textScrim`, `titleField`, `dateField`, and
  `captureDateText` are absent from the tile/presentation path.
- `script/verify.sh` passes.

## Code-Smell Review

- MainActor gravity: avoided; SQLite and decoding remain off-main.
- State duplication: one new tile projection exists at the Store boundary, not as
  a second source of media truth.
- Stringly typed domain facts: narrowed typed value replaces full `MediaAsset`
  at the tile boundary.
- Test coupling: existing source-hygiene string tests remain intentionally
  narrow for regression protection.
- Diagnostic payload sprawl: no new payloads.

## Stale-Document Audit

Affected current docs: `docs/requirements.md`, `docs/onboarding.md`,
`docs/index.md`, ADR 0006, ADR 0009, spec 0022, spec 0037, and spec 0038.
Process docs, templates, scripts, and planning docs are unaffected. Backlinks are
updated through the requirements evidence and docs index.

## Code-Comment Accuracy Audit

Affected file guides and comments in `MediaAssetTilePresentation`,
`MediaAssetTileView`, `MediaAssetCollectionView`, `CatalogStore`, and
`CatalogStoreScanFreshnessTests` are updated to remove stale filename/date tile
claims. No comment is added for implementation history.
