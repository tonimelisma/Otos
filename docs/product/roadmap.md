# Otos Roadmap And Idea Notes

This is a non-authoritative grab bag of ideas. It may contain rough ideas, wild
concepts, abandoned options, sequencing sketches, or notes that are never meant to
be implemented. None of its contents are ever a basis for a decision, and it never
guides work. It is consulted only when the user explicitly asks "what else could we
build", and any item is implemented only after the user explicitly approves it.

It is not proof that behavior exists, not a commitment, and not a source of
requirements. Implemented current requirements live only in
`docs/requirements.md`.

When a planned item actually lands, add or update precise current requirements in
`docs/requirements.md` with acceptance examples and evidence.

Earlier vocabulary notes in this file include:

- `Grid`: thumbnail browsing surface.
- `Image`: film strip with one main media item.
- `Compare`: film strip with two chosen media items.

## Non-Authoritative Baseline Ideas

- Otos could start as a single-window app for this idea set.
- Originals remain read-only except for an explicit, opt-in filesystem action such
  as Move to Trash.
- Libraries are recursive user-selected folder roots.
- Library add and remove actions live only in Libraries Settings.
- Sidebar navigation shows `All Media` plus added library sources.
- `All Media` aggregates persisted library roots only.
- Empty state offers Add Library and opens Libraries Settings.
- Temporary opened files are not part of `All Media`.
- Editing, export, and broad output workflows are out of scope.
- Copying or moving media into a user-configured library directory is future
  work, not part of the first browsing foundation.
- Other product ideas may be outside this note or may be added later if the user
  explicitly asks to work on planning.
- Faster visible-tile thumbnails on cloud-synced libraries: raise
  materialization (download) concurrency for viewport-priority enrichment.
  Measured 2026-07-09: one visible RAW took ~50 s of OneDrive download through
  the fixed 4-worker pool; a screenful of unenriched RAWs drains at cloud
  speed. Needs an owner decision on bandwidth/disk tradeoffs.
- Hash-based duplicate detection (ADR 0018) must account for the removable-volume
  digest gap: a `.removableVolume` source is never hashed in place (ADR 0018/0013),
  so its rows have no digest until imported, and import reuse short-circuits for it.
  A future duplicate feature needs the destination digest after import or an
  explicit digest-free rule for card sources.

## Non-Authoritative Idea Sequence

P0/P1 items through Import Into User Libraries are now largely shipped; current truth is in `docs/requirements.md` — the sequence below is retained for historical context and does not guide work.

### P0. Libraries And Sidebar

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

- Grid appears after libraries and filesystem records exist.
- Grid shows placeholder tiles before thumbnails exist.
- Default sort starts as newest-first filesystem date.
- Tile details show filename, best-known date, and media kind.
- No path display is required early.
- Filenames may appear in user-facing UI, while logs continue to avoid raw names
  by default.

### P0. Automatic Library Reconciliation

- On launch, persisted records render immediately.
- Background reconciliation then scans accessible libraries and streams changes
  in coalesced batches.
- When cheap filesystem facts change, all derived facts are marked stale.
- Removed files are removed from Otos records during reconciliation.
- Later running-app filesystem changes use file-level FSEvents where available.
- If macOS reports that precision was lost, Otos reconciles the affected root
  recursively and uses the same subtle source status.

### P1. Lazy Metadata And Thumbnail Enrichment

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

- Image view means film strip with one main media item.
- Film strip mirrors the current Grid result.
- The main media area loads original media asynchronously.
- A placeholder is allowed while original media opens or decodes.
- Original-media loading and rendering are performance-sensitive and require
  instrumentation in the implementing spec.

### P1. Compare View

- Compare view means film strip with two chosen media items.
- Film strip mirrors the current Grid result.
- Compare loads original media asynchronously.
- Placeholders are allowed while original media opens or decodes.
- Original-media loading and rendering are performance-sensitive and require
  instrumentation in the implementing spec.

### P2. Liked, Not Rated, And Disliked

- Liked/Not Rated/Disliked comes after Grid, Image, and Compare and is
  implemented as APP-024.
- The mutually exclusive curation state is persisted in the Otos catalog.
- Hover reveals heart, minus, and X direct controls; media has no curation chrome
  at rest. `P/U/X`, menus, and accessibility actions remain equivalent paths.
- Disliked media remains visible unless a filter hides it; Disliked never means
  delete.
- A default-off preference can advance after a choice.
- Photo > Move to Trash uses Command-Backspace as a separate, explicit,
  recoverable filesystem action.

### P2. Filters

- Filters come after curation.
- The first filter scope is curation state.
- Filters live in a toolbar control.
- Later metadata/date/type filters require separate requirements.

### P2. Temporary Opened Files

- File > Open, Finder open, and drag/drop share one arbitrary-open path.
- The path supports one or more files.
- Opened files appear as an ephemeral `Opened Files` sidebar source.
- Opened files are not durable library membership and are not part of
  `All Media`.

### P2. Import Into User Libraries

- Import is supported only into user-configured library directories.
- Sources may be another folder or another Otos library.
- Copy or move are both supported.
- The destination is never a private app-owned media location.
- Detailed destination rules are deferred to the future import spec.

## Research Grounding

- Adobe's catalog model stores references and app-owned organization/editing
  state while originals remain outside the catalog:
  [Lightroom catalog basics](https://helpx.adobe.com/lightroom-classic/help/lightroom-catalog-basics.html).
- Lightroom's browsing and culling surfaces were useful prior art for these idea
  notes, including the `Grid`, `Image`, and `Compare` terms:
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

- Video playback in loupe — shipped as loupe click-to-play poster→player swap (APP-020).
- Bare-key G/E/C view shortcuts — deferred; ⌘1/2/3 shipped (APP-020).

## Places (ideas beyond ADR 0040)

- Place names from reverse geocoding (`CLGeocoder`), as Photos and Lightroom show.
- Assigning or moving a location as authored overlay — drag onto the map, never a write
  to the file.
- `Nearby` from one photo, and a map of a card or an import batch (a contextual
  command from the grid).
- Satellite imagery as a toggle; a filmstrip under the map.
