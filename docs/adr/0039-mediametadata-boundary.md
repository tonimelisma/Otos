# ADR 0039: MediaMetadata is Otos's own library, and owns everything about the bytes

- Status: Accepted
- Last updated: 2026-10-25

## Context

[MediaMetadata](https://github.com/tonimelisma/MediaMetadata) is the byte parser behind
enrichment and camera reads. Otos's owner also owns it, so it can change in any way Otos
needs: a missing fact is a change to the library, not a workaround in Otos. Two failures
showed what goes wrong without a stated boundary:

- **Parsing knowledge drifted into Otos.** Otos re-derived facts the parser knew better:
  - which EXIF orientations turn a picture a quarter;
  - which timestamp role names a file;
  - what kind of media a container family holds;
  - a parallel list of timestamp roles.

  When the library learned HEIF `irot` (0.6.1), Otos needed a hand-written migration
  (`v5_heif_orientation_reread`) to find the rows the fix could change.
- **Re-reading costs bytes.** The library is mostly cloud-only: ~779 GB in library roots,
  ~713 GB of it cloud-only (measured 2026-10-25). Reading a cloud-only file's header
  downloads the whole file.

MediaMetadata 0.7.0 adds what a consumer needs to stop re-deriving:
- `geometry` (stored size, orientation, display size);
- `format.kind`;
- typed timestamp `Role`s and location `Source`s with stable raw values;
- `CaptureTimestamps.wallClockPrecedence`;
- `VideoCodec.identifier`;
- `MediaMetadataReader.extractionRevision`, which rises whenever the same bytes can read
  differently.

## Decision

**What MediaMetadata owns:** every fact read from a file's bytes, and every rule about
what those facts mean. That covers:
- format family and kind;
- orientation semantics and display geometry (`PixelGeometry`, `Orientation.swapsDimensions`);
- the list of timestamp roles and location sources;
- which role names a file (`wallClockPrecedence`) and which orders it (`instantPrecedence`);
- codec identity;
- the extraction revision.

**What Otos owns:**
- persistence and its schema;
- when to pay for bytes (materialization, the free-space floor, never downloading for a
  parser fix);
- the catalog's own projections (`best_capture_unix`, the stored capture wall);
- product policy, such as no audio (MED-004);
- platform decode facts used for rendering (ImageIO's and Core Image's own orientation,
  which describe the decode Otos draws, not the file's metadata).

**Rules:**
- **Never re-derive in Otos a fact or rule the library reports.** A fact Otos needs and the
  library lacks is added to the library, released, and taken by version bump. Otos never
  works around a library gap.
- **Otos stores what the library reports, as reported.** `MediaEnricher.map` copies:
  - `geometry` into orientation and stored size;
  - `codec.identifier`;
  - `timestamps.entries` and `locations.entries` under the library's raw values;
  - `extractionRevision` into `asset_metadata.extraction_revision`.

  Otos's role set is the library's `CaptureTimestamps.Role`, less the audio-only roles
  (MED-004). The upright size is `PixelGeometry`'s.
- **The wall clock follows `wallClockPrecedence`.** It is selected from Otos's persisted
  records in that order. So an AVI's RIFF recording date (ICRD/IDIT), when no earlier
  role is local, now names the file instead of the mtime-less-duration fallback:
  - an embedded fact is better than a derived one;
  - files already imported keep their names;
  - a card re-imported after this change would name such an AVI by its recording date.
- **Kind:** the platform's type decides first (it alone knows RAW); otherwise the library's
  `format.kind`.
- **A parser fix reaches the catalog through the revision, from local bytes only.**
  - `MetadataRefresher` runs once per launch with enrichment.
  - It re-reads library rows whose stored revision is lower or unknown and whose
    enrichment is otherwise current.
  - It reads only originals already on this Mac, checking materialization immediately
    before each read, and writes only metadata and the columns derived from it (through
    the same `writeMetadataProjection` enrichment uses), only while the row's file
    signature is unchanged.
  - A cloud-only row is skipped and offered again next launch. Card and camera rows are
    never refreshed.
  - No per-fix migration is written again.
- **Import reuse derives like enrichment.** A reused overlay is written through
  `writeMetadataProjection` with the destination's own mtime, so a reused video row
  derives the same capture wall a fresh enrichment of that file would.

## Consequences

- A cloud-only row keeps its older record until its original is local for some other
  reason:
  - opened full size, edited, handed off or exported;
  - re-enriched after a change;
  - or downloaded by the provider.

  For 0.7.0 that stale record is Info's W × H for portrait videos and a few EXIF-less
  HEIFs; nothing displayed is shaped by it (APP-040, APP-048).
- Every library release that raises the revision re-reads every *local* row once. Rows are
  cheap to re-read locally; the library re-reading is bounded by what is on disk.
- `best_capture_unix` still coalesces original → quickTimeCreation → digitized → gps,
  while the library's `instantPrecedence` puts digitized before quickTimeCreation.
  Adopting the library's order changes a STORED generated column (a table rebuild) and can
  reorder the grid, so it is a separate decision.

## Rejected

- **Make a lower revision stale for enrichment**, as the library's documentation suggests.
  Enrichment downloads cloud-only stale rows (ENR-008). For 0.7.0 that is ~779 GB, ~713 GB
  of it downloads, to change, in a differential over every local file, 3 portrait videos'
  orientation, 11 HEIF sizes and one AVIF's family out of 3,424 files
  (`docs/research/2026-10-25-mediametadata-0.7.md`).
- **A hand-written migration per parser fix** (as v5 was). It puts the parser's knowledge
  of what changed into Otos.
- **Delete and rebuild the catalog.** The catalog holds likes, edits and import history,
  which cannot be rebuilt from files.
