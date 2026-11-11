# ADR 0050: The Info pane shows everything Otos holds, and looks up one thing

- Status: Accepted
- Date: 2026-11-11

## Context

The Info pane (APP-041, DES-088) showed four facts: capture date, pixel size, kind and
file size. It read only the grid's hot asset row, though the catalog keeps far more for
each item: the library's whole metadata record (camera, lens, serial number, location,
video duration, frame rate and codec, every timestamp role), confirmed faces, companions,
the import an item arrived in, and its edit. The one fact photographers expect most, the
exposure, MediaMetadata did not read at all.

On 2026-11-11 the owner asked why the pane was so empty, asked what it could hold and how
it should be organized ("read apple HIG, think CRAP design principles … follow similar
design patterns as edit sidebar"), and then said to build it, to add what the library
lacked first, and to "put everything." The survey behind the layout compared Photos'
Info window (date, then a camera block with the exposure line, then a map), Preview's
inspector (General plus folding Exif, GPS and IPTC sections), Lightroom desktop's Info
panel and Lightroom Classic's Metadata panel.

## MECE Decision Scope

This ADR owns: what the Info pane shows, which owner reads it, and the place-name lookup.
It references but does not own: the inspector column and its two panes (APP-041,
DES-088, DES-092); what MediaMetadata reports and how it is stored (ADR 0039); the
primary location and Places (ADR 0040); confirmed faces (ADR 0047).

## Decision

- **Exposure belongs to the library.** MediaMetadata 0.9.4 reports `exposure` — shutter
  time as the camera wrote it, f-number, ISO sensitivity, compensation, focal length and
  its 35 mm equivalent, flash, program, metering and white balance — and raised
  `extractionRevision(for:)` for every family that reads Exif. Otos stores it as reported
  (`ExposureRecord` in the metadata record's JSON), puts it back into the library's
  `Exposure` to show it, and gets it for existing rows through `MetadataRefresher`, from
  local bytes only.
- **The pane reads everything Otos already holds, in one refresh.**
  `CatalogWindowViewModel.refreshPhotoInfo` reads, off the main actor and together: the
  asset row, the metadata record, the overlay (`CatalogStore.photoInfoOverlay`: confirmed
  names, companions, import batch, edited), the tile detail (kind, upright size), and the
  original's locality from `MaterializationCoordinator`. Nothing reads the original's
  bytes. Any read that throws fails the whole refresh, so a failure is never shown as a
  missing fact. `PhotoInfo.make` is the one place the pane's strings are made.
- **Layout follows the Edit pane.** Sections Camera, Exposure (a still) or Video (a
  movie), People, Location and File, each under a hairline with a folding heading, fold
  state remembered per person. Which sections show depends only on the kind, so rows keep
  their place between items of one kind (DES-053); a fact the catalog lacks reads
  `Unknown`, and with no single item every value reads `—`.
- **The place name is looked up, not stored.** For a located item the pane asks MapKit's
  `MKReverseGeocodingRequest` for the coordinate's city and region, in the Mac's language,
  and shows it when it arrives. The lookup sends the coordinate to Apple; the map above the
  rows fetches Apple Maps tiles. A new target cancels the lookup in flight, a failure is
  logged (`op=photo.info.place phase=lookupFailed`) and leaves `Unknown`. Places stays
  without place names (ADR 0040).

## Rejected alternatives

- **Reading exposure in Otos with Image I/O.** It reads the original's bytes for a pane,
  materializing cloud originals, and re-derives a fact the library owns (ADR 0039).
- **Storing place names as overlay.** A stored name is overlay with a lifecycle, a
  re-lookup policy when the location changes, and a backfill of the whole library against
  a rate-limited service. Looking up the one item on screen needs none of that.
- **`CLGeocoder`.** Deprecated in macOS 26 in favour of `MKReverseGeocodingRequest`.
- **An exposure summary strip above the sections**, as Photos draws. Its five values would
  repeat the Exposure rows, and a strip of unknowns has no honest empty state.

## Consequences

- An item enriched before MediaMetadata 0.9.4 shows `Unknown` exposure until its local
  bytes are re-read; a cloud-only original keeps it until it is local, as every parser fix
  does.
- Browsing located photos with Info open sends one coordinate per photo to Apple. MapKit
  throttles lookups; a throttled one reads `Unknown`.
