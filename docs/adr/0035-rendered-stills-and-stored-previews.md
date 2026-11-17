# ADR 0035: Stills are rendered once and kept as a thumbnail and a preview

- Status: Accepted
- Last updated: 2026-11-07

## Context

Owner decisions (2026-10-25) require an unedited RAW to show Apple's RAW9 defaults, and
every surface — grid, loupe, compare — to show the edited photo. Until now the grid
showed Quick Look's 256 px thumbnail, which for an ARW is the camera's embedded JPEG
(measured: mean difference 2.25 against the embedded JPEG, 17.9 against a RAW9
render), and the loupe decoded the embedded preview or the original with Image I/O.

The library is about 778 GB on a 494 GB disk, and 92% of its RAWs are cloud-only
(`docs/research/2026-10-25-library-storage-and-previews.md`). Opening a photo whose
original is cloud-only took seconds to over a minute. ADR 0016 had rejected
"enrichment-side pregenerated large previews on disk"; that rejection assumed the
original could be read when the photo opened, which this library disproves.

Measured on 60 downloaded photos: a 2560 px HEIC preview averages 0.37–0.44 MB
(about 6 GB for the library's ~13,900 stills), decodes in 65–128 ms, and a RAW9
render at that size takes about 1.1 s. A full-size render would be 1–5 MB per RAW
and is never shown at full size except when zoomed to 100%.

## Decision

- **One renderer.** `ImageRenderer` develops a RAW with `CIRAWFilter` at the newest
  decoder the file supports (RAW9, else RAW8, else the filter's default). It decodes
  any other still with Image I/O, orientation applied. Output is an 8-bit Display P3
  bitmap, produced on one of two serial lanes: background for enrichment, interactive
  for the loupe. Each lane develops one RAW at a time, so at most two RAW developments,
  160–340 MB each, are in memory at once. Each lane also has its own queue of Image I/O
  decodes, up to four at once on the background lane, admitted by the memory each render
  holds (the pixels its format decodes at and the rendering it makes, `DecodeBudget`) so
  that together they hold no more than four HEIC previews: a 12 MP JPEG decodes whole and
  two run at once. Enrichment stages a still's preview and thumbnail on the lane, inside
  that admission (`docs/research/2026-11-17-first-launch-decodes.md`). Enrichment never queues in front of the
  photo on screen. A RAW's oriented native
  size is read once, when its filter is made (`OpenedRAW`), and every scale factor and
  reported size comes from that value: under RAW9 the filter's `nativeSize` changes once
  a scale factor is set (research 2026-10-26-live-edit-latency).
- **Two stored products per still,** made from one rendering while the original's bytes
  are local, and stamped together as the row's rendering (ADR 0009):
  - a 2560 px preview, 8-bit Display P3 HEIC, in `media_asset.preview_path`;
  - the 256 px grid thumbnail, drawn from that rendering.

  A card's metadata pass, the pass an import waits on, renders nothing: each row gets
  Quick Look's thumbnail — for a RAW, the camera's embedded JPEG — as a provisional,
  unstamped thumbnail. The card's renderings come in its later rendering-and-digest pass.
  A RAW9 development costs about a second, and neither a smaller output, draft mode, a
  shared context nor concurrency makes it cheaper (research 2026-10-31-raw9-speed); the
  card's HEIF decodes took most of its readiness time when they were in the first pass
  (research 2026-10-31-card-readiness-products).

  Videos keep their Quick Look thumbnail and get no preview. If the renderer cannot
  read a still, its thumbnail falls back to Quick Look and it gets no preview. Both
  files live in the existing derived-image directory and follow the thumbnail's whole
  lifecycle: staged, promoted only after the row validates, superseded files deleted,
  purged with the row, moved when a root's path changes, and copied by import reuse.
- **Source-provisional products** (ADR 0046). A source that serves its own derived
  images can supply both products before Otos renders. An Immich account's are drawn
  from Immich's own preview (1440 px on the short edge by default; its size is read from
  each file, never assumed), downloaded after each sync pass: the preview kept at that
  size, the thumbnail drawn from it, through the same staging and promotion as a
  rendering. They are stamped as source products (`source_products_*`), never as the
  rendering, like a card's Quick Look thumbnail, but unlike it they are not a claim on
  enrichment: the row is rendered only when its
  original is local for work that needs its bytes, and that one read writes Otos's
  rendering over them (ADR 0046 §7). Re-downloading 350 GB of originals to replace a
  6 GB set of usable images is the cost this state avoids
  (`docs/research/2026-11-07-immich-derived-assets.md`).
- **The loupe opens from the preview.** Every request short of full resolution decodes
  the stored preview without touching the original, cloud-only or not. The original's
  long edge comes from the catalog's stored metadata, joined into `MediaTileDetail`, and
  sets the loupe's 100 percent; the picture's shape is always the decode's, because the
  catalog can record a HEIF turned by its `irot` property at its stored, unrotated size.
  Zooming to full resolution renders the original: a RAW through the interactive
  renderer, downloading it first if needed; any other still through Image I/O, as
  before. A RAW with no preview yet is developed on demand, never shown as its embedded
  JPEG.
- **Backfill.** The additive migration `v3_media_asset_preview_path` clears the
  enrichment stamps of library stills, so the unchanged staleness predicate claims
  them again and enrichment renders both products, downloading cloud-only originals
  under the free-space floor (ENR-008). Card and camera rows are left stamped.
- **An import never renders.** A source rendering current for the copied bytes is copied
  with its preview; a copy without one — a card row its rendering pass had not reached, a
  camera row — settles with the source's thumbnail as a provisional one and is rendered
  by enrichment straight after, ahead of other background work, while its bytes are local
  (ADR 0009 §9).
- **No re-render on OS updates.** A macOS update that changes RAW9's output does not
  re-render, because re-rendering means re-downloading the library. Products follow the
  file's `(size, mtime)` and, from the editing increments on, the edit recipe.

## Consequences

- In a library, grid and loupe show the same rendering. Every library RAW changes from
  the camera's look to RAW9's as enrichment reaches it. A card shows its RAWs in the
  camera's look until its rendering pass reaches them, with the loupe developing them on
  open; a newer thumbnail of the same asset replacing the painted one keeps the no-blank
  rule (APP-015). An imported copy settles with the card's rendering, or with its
  provisional thumbnail until enrichment renders it.
- An Immich account's photos show Immich's rendering — for a RAW, libvips's, not
  RAW9 — until their original is local; the grid and loupe of a library always show
  Otos's.
- About 6 GB of Application Support for previews, kept for the life of each photo
  (ADR 0008, ADR 0009: no eviction).
- The backfill re-enriches every library still once: on this library, about 209 GB of
  cloud-only originals pass through the disk, under the floor, and macOS evicts them
  again under pressure.
- Supersedes ADR 0016's rejection of stored previews, and ADR 0009's Quick Look
  generator for stills. ADR 0009's reason for rejecting HEIC thumbnails (deep or HDR
  input misencodes) is met by normalizing to 8 bits first.

## Rejected

- **No stored preview, render on open:** 1.0–1.2 s per photo from a local original,
  and a download first for 92% of RAWs.
- **A stored full-size render:** 6–31 GB for the RAWs alone, and nothing displays it
  at full size.
- **JPEG previews:** about twice the size of HEIC.
- **A separate preview directory and store type:** every file mechanic is the
  thumbnail's already; only encoding and extension differ.
- **Rendering a card's stills in its metadata pass:** it made a card of 37 RAWs ready to
  import in 55–70 s instead of 6 s, and no `CIRAWFilter` option or concurrency made the
  development cheaper. Developing only its non-RAW stills there still held a 429-row card
  at 23–58 s against 4–15 s for metadata alone.
- **Rendering an imported copy during the import:** it holds the import on a development
  of about a second per RAW, for a product the import does not need. A copy is rendered
  first after it lands instead, long before a cloud-synced library can upload and evict
  it.
