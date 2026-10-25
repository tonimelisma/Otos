# ADR 0035: Stills are rendered once and kept as a thumbnail and a preview

- Status: Accepted
- Last updated: 2026-10-25

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
  for the loupe. At most two RAW developments, 160–340 MB each, are in memory at once,
  and enrichment never queues in front of the photo on screen.
- **Two stored products per still,** made from one rendering during enrichment, while
  the original's bytes are local:
  - a 2560 px preview, 8-bit Display P3 HEIC, in `media_asset.preview_path`;
  - the 256 px grid thumbnail, drawn from that rendering.

  Videos keep their Quick Look thumbnail and get no preview. If the renderer cannot
  read a still, its thumbnail falls back to Quick Look and it gets no preview. Both
  files live in the existing derived-image directory and follow the thumbnail's whole
  lifecycle: staged, promoted only after the row validates, superseded files deleted,
  purged with the row, moved when a root's path changes, and copied by import reuse.
- **The loupe opens from the preview.** Every request short of full resolution decodes
  the stored preview without touching the original, cloud-only or not. The original's
  oriented size comes from the catalog's stored metadata, joined into `MediaTileDetail`.
  Zooming to full resolution renders the original: a RAW through the interactive
  renderer, downloading it first if needed; any other still through Image I/O, as
  before. A RAW with no preview yet is developed on demand, never shown as its embedded
  JPEG.
- **Backfill.** The additive migration `v3_media_asset_preview_path` clears the
  enrichment stamps of library stills, so the unchanged staleness predicate claims
  them again and enrichment renders both products, downloading cloud-only originals
  under the free-space floor (ENR-008). Card and camera rows are left stamped.
- **Import reuse** copies the preview with the thumbnail. A still whose source row has
  no preview (a camera row, enriched from byte ranges) is a reuse miss, so the library
  copy is enriched from its own bytes and gains one.
- **No re-render on OS updates.** A macOS update that changes RAW9's output does not
  re-render, because re-rendering means re-downloading the library. Products follow the
  file's `(size, mtime)` and, from the editing increments on, the edit recipe.

## Consequences

- Grid and loupe show the same rendering. Every RAW changes from the camera's look to
  RAW9's as enrichment reaches it; a newer thumbnail of the same asset replacing the
  painted one keeps the no-blank rule (APP-015).
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
