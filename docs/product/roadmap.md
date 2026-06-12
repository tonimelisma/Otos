# Otos Product Roadmap

This roadmap is the canonical product plan for Otos' first library, browsing,
enrichment, and curation milestones. Otos overlays an app-owned catalog on top
of user-owned media that remains in user-configured folders.

The accepted view vocabulary is:

- `Grid`: thumbnail browsing surface.
- `Image`: film strip with one main media item.
- `Compare`: film strip with two chosen media items.

## Product Baseline

- Otos is a single-window app for this roadmap.
- Originals remain read-only.
- Libraries are recursive user-selected folder roots.
- Library add and remove actions live only in Libraries Settings.
- Sidebar navigation shows `All Media` plus added library sources.
- `All Media` aggregates persisted library roots only.
- Empty state offers Add Library and opens Libraries Settings.
- Temporary opened files are not part of `All Media`.
- Editing, export, and broad output workflows are out of scope.
- Copying or moving media into a user-configured library directory is future
  work, not part of the first browsing foundation.
- Proposed extra product ideas are intentionally outside this roadmap until
  explicitly accepted.

## Priority Roadmap

### P0. Libraries And Sidebar

Requirement IDs: `SRC-001`, `SRC-002`, `SRC-003`, `SRC-004`, `CAT-001`,
`UI-001`.

- Add Libraries Settings as the only place to add or remove library roots.
- Add Library uses a native folder picker and creates a recursive library root.
- Duplicate libraries show an error.
- Overlapping library roots are prevented.
- Packages are skipped during recursive scan.
- Symlinks and aliases are not followed.
- Removing a library requires confirmation and deletes Otos records and
  enrichments for that library; originals remain untouched.
- Sidebar is navigation-only and shows `All Media` plus added libraries.

### P0. Fast First Browse

Requirement IDs: `SCN-001`, `SCN-002`, `CAT-002`.

- First scan persists library roots and filesystem-only media records.
- Filesystem-only facts are limited to deterministic URL, resource, or
  filesystem facts: source-relative identity, file-vs-directory/package/symlink
  classification, type identifier, size/allocation, filesystem dates, and file
  resource identifier when available.
- First scan does not read dimensions, duration, EXIF/IPTC, embedded capture
  date, thumbnails, or checksums.
- Scan work runs in the background.
- UI-visible changes are streamed in coalesced batches.
- Sidebar/source status is subtle: scanning, reconciling, idle, or failed.
- There is no user-facing scan cancel control.

### P0. Grid With Placeholders

Requirement IDs: `UI-002`, `UI-003`.

- Grid appears after libraries and filesystem records exist.
- Grid shows placeholder tiles before thumbnails exist.
- Default sort starts as newest-first filesystem date.
- Tile details show filename, best-known date, and media kind.
- No path display is required early.
- Filenames may appear in user-facing UI, while logs continue to avoid raw names
  by default.

### P0. Automatic Library Reconciliation

Requirement IDs: `REC-001`, `REC-002`, `REC-003`.

- On launch, persisted records render immediately.
- Background reconciliation then scans accessible libraries and streams changes
  in coalesced batches.
- When cheap filesystem facts change, all derived facts are marked stale.
- Removed files are removed from Otos records during reconciliation.
- Later running-app filesystem changes use file-level FSEvents where available.
- If macOS reports that precision was lost, Otos reconciles the affected root
  recursively and uses the same subtle source status.

### P1. Lazy Metadata And Thumbnail Enrichment

Requirement IDs: `ENR-001`, `ENR-002`, `THM-001`, `PERF-001`.

- Apple-common media is in scope.
- RAW is first-class media.
- Live Photos become a single media item when pairing is known.
- Sidecars are acknowledged as later work and are not part of first discovery
  behavior.
- Metadata enrichment is read-only and broad EXIF/IPTC, including GPS/location
  when present.
- Unknown metadata remains explicitly unknown.
- Best-known capture date is used for display while provenance is stored but not
  surfaced early.
- Metadata enrichment and thumbnail generation prioritize the current visible
  and chosen media first, then continue in the background.
- Thumbnail enrichment generates the shared thumbnail representation used by
  Grid and film strip.
- No separate display-preview tier is required.
- Later metadata enrichment may improve best-known dates and apply coalesced
  reordering while preserving current choice state.

### P1. Image View

Requirement IDs: `VIEW-001`, `PERF-002`.

- Image view means film strip with one main media item.
- Film strip mirrors the current Grid result.
- The main media area loads original media asynchronously.
- A placeholder is allowed while original media opens or decodes.
- Original-media loading and rendering are performance-sensitive and require
  instrumentation in the implementing spec.

### P1. Compare View

Requirement IDs: `VIEW-002`, `PERF-002`.

- Compare view means film strip with two chosen media items.
- Film strip mirrors the current Grid result.
- Compare loads original media asynchronously.
- Placeholders are allowed while original media opens or decodes.
- Original-media loading and rendering are performance-sensitive and require
  instrumentation in the implementing spec.

### P2. Pick, Reject, And Unpick

Requirement IDs: `CUR-001`.

- Pick/Reject/Unpick comes after Grid, Image, and Compare.
- The curation state is persisted in the Otos catalog.
- Rejected media remains visible unless a filter hides it.

### P2. Filters

Requirement IDs: `FIL-001`.

- Filters come after curation.
- The first filter scope is curation state.
- Filters live in a toolbar control.
- Later metadata/date/type filters require separate requirements.

### P2. Temporary Opened Files

Requirement IDs: `OPEN-001`.

- File > Open, Finder open, and drag/drop share one arbitrary-open path.
- The path supports one or more files.
- Opened files appear as an ephemeral `Opened Files` sidebar source.
- Opened files are not durable library membership and are not part of
  `All Media`.

### P2. Import Into User Libraries

Requirement IDs: `IMP-001`.

- Import is supported only into user-configured library directories.
- Sources may be another folder or another Otos library.
- Copy or move are both supported.
- The destination is never a private app-owned media location.
- Detailed destination rules are deferred to the future import spec.

## Research Grounding

- Adobe's catalog model stores references and app-owned organization/editing
  state while originals remain outside the catalog:
  [Lightroom catalog basics](https://helpx.adobe.com/lightroom-classic/help/lightroom-catalog-basics.html).
- Lightroom's browsing and culling surfaces are useful prior art, but Otos uses
  only the accepted `Grid`, `Image`, and `Compare` vocabulary:
  [view photos](https://helpx.adobe.com/my_ms/lightroom-classic/help/view-photos.html),
  [flag and rate photos](https://helpx.adobe.com/lightroom-classic/help/flag-label-rate-photos.html).
- Lightroom's missing-file workflow is useful contrast for Otos' automatic
  library reconciliation:
  [locate missing photos](https://helpx.adobe.com/lightroom-classic/help/locate-missing-photos.html).
- macOS File System Events support hierarchy monitoring and file-level events,
  with explicit affected-root reconciliation when event precision is lost:
  [File System Events](https://developer.apple.com/documentation/coreservices/file_system_events),
  [file-level events flag](https://developer.apple.com/documentation/coreservices/1455376-fseventstreamcreateflags/kfseventstreamcreateflagfileevents),
  [must-rescan flag](https://developer.apple.com/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagmustscansubdirs).
- Apple responsiveness guidance requires background work, coalesced UI updates,
  stable identity, and instrumentation for high-volume Grid and media-rendering
  paths:
  [improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness),
  [user interface responsiveness](https://developer.apple.com/documentation/xcode/understanding-user-interface-responsiveness),
  [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
