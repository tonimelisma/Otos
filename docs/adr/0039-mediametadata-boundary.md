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
- `MediaMetadataReader.extractionRevision(for:)`, one number per format family that rises
  when the same bytes of that family can read differently (0.7.1);
- `format.fileType` and `isCameraRaw` read from the bytes, and `MediaFileType(fileExtension:)`
  with `displayName` for a file nothing has read (0.7.1);
- `CaptureTimestamps.Role.isAudioOnly` (0.7.1);
- PNG, WebP and GIF as families of their own, read from their headers (0.8.0);
- `CaptureTimestamps(entries:)`, the inverse of `entries` (0.8.1).
- `contentIdentifier`, Apple's Live Photo pairing identifier (0.8.2; ADR 0041).
- `levelingTurnDegrees`, the turn that levels a picture from the camera's gravity reading,
  and the rule for when that reading means nothing (0.9.1; ADR 0036).
- `extractionRevision(for:)` also rises for a newly reported field (0.9.2), and the
  fields added since 0.7.1 moved it: a stored row cannot tell "the file has none" from
  "the reader did not look", so a revision that announced only corrections left every new
  field to a consumer migration.
- 0.9.3 restates which selection answers which question: the wall clock names an item,
  puts it on a day and orders a timeline, and the instant compares across zones. Ordering
  by instant had put photos on the viewer's day rather than their own, and could not place
  a floating time at all.
- `exposure`, a still's Exif exposure, and the revision it moved for every family that
  reads Exif (0.9.4; ADR 0050).

## Decision

**What MediaMetadata owns:** every fact read from a file's bytes, and every rule about
what those facts mean. That covers:
- format family and kind;
- orientation semantics and display geometry (`PixelGeometry`, `Orientation.swapsDimensions`),
  and the camera's level at capture;
- the list of timestamp roles and location sources;
- which role names, days and orders a file (`wallClockPrecedence`) and which pins its
  instant (`instantPrecedence`);
- codec identity;
- the extraction revision.

**What Otos owns:**
- persistence and its schema;
- when to pay for bytes (materialization, the free-space floor, never downloading for a
  parser fix);
- the catalog's own projections (`best_capture_local`, the stored capture wall), including
  the zone it assumes for an item whose file records no wall clock;
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
  - its family's `extractionRevision(for:)` into `asset_metadata.extraction_revision`;
  - the file type's name (`format.fileType`, else the extension's `MediaFileType`) as
    the format token, so `HEIC`, `HEIF` and `HIF` are one token, `HEIF`.

  Otos's role set is the library's `CaptureTimestamps.Role`, less the audio-only roles
  (`Role.isAudioOnly`, MED-004). The upright size is `PixelGeometry`'s.
- **Selections are the library's, asked of the stored records.** The persisted records
  are put back into the library's value (`CaptureTimestamps(records:)`, through
  `CaptureTimestamps(entries:)`, 0.8.1) and Otos asks it, restating no precedence. A
  record whose precision or wall-clock components are not a valid capture time is left
  out (`CaptureTime(record:)`).
- **The timeline runs on local capture time** (0.9.3). The library's `captureWallClock`
  is the local time when and where an item was taken. It names the item, puts it on a day,
  and places it in the timeline. `captureInstant` is for comparing across zones. Otos
  stores it as `capture_instant_unix`, and it orders nothing on its own.
  - `best_capture_local` is the wall clock read as if it were UTC (`CaptureLocalTime`). An
    item is ordered by that reading and belongs to its date, so a photo taken at 15:00 in
    California is a 15:00 photo of that California day, also on a Mac in Sydney. Two
    clocks in different zones order by their readings, as Lightroom's Capture Time does.
  - An item whose file records no wall clock is placed by its absolute time: capture
    instant, else creation date, else modification date. That time is read with
    `assumed_utc_offset_seconds`, the offset of the Mac's zone when Otos recorded it
    (`CaptureLocalTime.assumedUTCOffset`), which is how Lightroom and Photos date such a
    file at import. The assumption is kept while that absolute time is unchanged, so no
    item moves when the Mac changes zone. Migration v23 made it for every existing row in
    the zone the migration ran in.
  - Both readings are whole seconds. A wall clock has no fraction, so the absolute time
    is taken at the second it falls in (`CatalogSchema.absoluteCaptureWholeSecondsSQL`).
    An Immich asset is placed by the server's date, which has milliseconds, until its
    bytes are read. The read's wall clock for the same second then leaves it where it
    was. Migration v56 redefined the column; before it, 41,048 of 51,327 read Immich
    stills on the owner's catalog had moved by under a second when read
    (`docs/research/2026-11-14-whole-second-capture-time.md`).
  - The grid's day sections (`CatalogStore.orderedAssetIDs`), the Date sort, On This Day
    (`AnniversaryMatch`), search's date spans, People's birthday rules and Info's
    Captured line all read this one value. Day sections are the reading's date. On This Day
    and search take a day on the Mac's calendar as the same readings on any clock. So the
    three always agree, and none of them depends on the Mac's zone.
  - Migration v8 replaced the four `ts_*_unix` columns Otos had coalesced in its own order.
    Migration v23 replaced `best_capture_unix` (instant in the viewer's zone, else file
    dates) with `best_capture_local`. With the Mac on UTC+11, 15,161 of 15,188
    offset-bearing photos in one library sat a day off their own day under the old column.
    718 floating photos in another fell back to file creation dates up to 101 days away
    (`docs/research/2026-11-10-capture-local-time.md`).
- **The wall clock is `captureWallClock`** (`wallClockPrecedence`). So an AVI's RIFF recording date (ICRD/IDIT), when no earlier
  role is local, now names the file instead of the mtime-less-duration fallback:
  - an embedded fact is better than a derived one;
  - files already imported keep their names;
  - a card re-imported after this change would name such an AVI by its recording date.
- **Kind** is the library's: the type the bytes settled (camera RAW included), else the
  kind the bytes showed, else the type the extension names. The platform's type is kept
  only where Otos asks the platform a platform question: which files the scanner catalogs,
  and whether ImageIO or Core Image can render one.
- **A parser fix reaches the catalog through the revision, from local bytes only.**
  - `MetadataRefresher` runs once per launch with enrichment.
  - It re-reads library rows whose stored revision is lower than their family's current
    one (an absent revision counts as 0, as the library defines it) and whose enrichment is
    otherwise current. A family the library has not changed is never re-read.
  - Migration v7 cleared the single-number revisions v6 stored before per-family revisions
    existed, and renamed stored format tokens to the library's names.
  - It reads only originals already on this Mac, checking materialization immediately
    before each read, and writes only metadata and the columns derived from it (through
    the same `writeMetadataProjection` enrichment uses), only while the row's file
    signature is unchanged and its stored record is still older than its own family's
    current reading. The new record's revision is never compared with the stored one:
    revisions are per family, and a re-read can change family (0.7.1's `unknown` 1 is
    0.8.0's `png` 0).
  - A cloud-only row is skipped and offered again next launch. Card and camera rows are
    never refreshed. The one exception is a record that may be half of a Live Photo
    (ADR 0041): it is handed to enrichment, which downloads it once for every product.
  - No migration is written for a parser fix or a new field. v9 and v12 cleared
    revisions for fields the library added before its revision announced new fields
    (0.8.2's content identifier, 0.9.0's sub-seconds); since 0.9.2 the revision carries
    both.
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
- A library release that raises a family's revision re-reads that family's *local* rows
  once, which is cheap; nothing is downloaded for it.
- A photo's day no longer follows the Mac's zone. Travelling does not move anything taken
  with a wall clock. An item with only an absolute time keeps the zone Otos assumed when
  it recorded that time. The migration ran in the Mac's zone of that moment, so such an
  item recorded while away keeps that zone's day.
- Two photos taken minutes apart in different zones order by their wall clocks. This is
  the trade Lightroom makes; it keeps every day's photos together.

## Rejected

- **Order by instant and day by wall clock.** Day sections are runs of the ordered list;
  when the viewer's zone differs from the capture zone, instant order interleaves the
  photos of two days, so a day would appear twice.
- **Turn a floating wall clock into an instant in the Mac's zone.** The instant would
  carry the zone of the moment it was computed, so a floating photo would leave its day
  whenever the Mac's zone differs, the same defect as before for a different set of photos.
- **Read items without a wall clock in the Mac's current zone at every read.** That cannot
  be indexed, and a change of zone would move those items between days while everything
  else stayed put.

- **Make a lower revision stale for enrichment**, as the library's documentation suggests.
  Enrichment downloads cloud-only stale rows (ENR-008). For 0.7.0 that is ~779 GB, ~713 GB
  of it downloads, to change, in a differential over every local file, 3 portrait videos'
  orientation, 11 HEIF sizes and one AVIF's family out of 3,424 files
  (`docs/research/2026-10-25-mediametadata-0.7.md`).
- **A hand-written migration per parser fix** (as v5 was). It puts the parser's knowledge
  of what changed into Otos.
- **Delete and rebuild the catalog.** The catalog holds likes, edits and import history,
  which cannot be rebuilt from files.
