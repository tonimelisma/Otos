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

This ADR owns: what the Info pane shows, which owner reads it, the place-name lookup, and
how scene labels are named in the Mac's language.
It references but does not own: the inspector column and its two panes (APP-041,
DES-088, DES-092); what MediaMetadata reports and how it is stored (ADR 0039); the
primary location and Places (ADR 0040); confirmed faces (ADR 0047); how search reads scene labels and text (ADR 0048).

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

- **In This Photo shows what search recognised** (owner, 2026-11-12: list everything Otos
  identified in the image, show text only with confidence, in the Mac's language, a label
  click searches, no sidebar row for text). Between People and Location, the section holds:
  - the scene labels that pass Vision's high-precision test, stored with the search
    embedding (ADR 0048), most confident first, each a small bordered button that calls the
    search field's own intent (`setSearchText`) with its name;
  - under `Text`, the lines of the still's text reading at full confidence, selectable.
  `CatalogStore.photoInfoOverlay` reads both from the current readings only, so a reading
  still owed reads `Not Checked Yet` and a new thumbnail or preview hides the old one. While
  the pane shows an item, each announcement of new readings from search's index re-reads
  this section alone for it (`startRecognizedRefresh`), so a photo read while it is shown
  fills in without reselecting it and the place lookup is not restarted. Each Info read rings
  the same newest-wins doorbell as it lands: an announcement made while that read was in
  flight re-read the item shown before it, and the read lands with what it saw before the
  reading, so one more re-read is what covers it (ADR 0032 rule 2).
- **Label names ship with Otos.** Vision names its labels in English only. Otos ships
  `SceneLabelNames.tsv`: each label in each language Apple Translation offers, translated as a
  photo's caption ("Photo: pool") and kept only when it reads back into English as the same
  label by search's own test (`SearchLabelVocabulary`, cosine 0.95). Translation still got
  some wrong as captions (Finnish "omena", apple, for pear), and a wrong name is a wrong fact;
  a name that fails reads in English. `SceneLabelNames` (an actor) reads the table once, off
  the main actor, and names a photo's labels in `Locale.current`'s language, the one place
  names use.

## Rejected alternatives

- **Reading exposure in Otos with Image I/O.** It reads the original's bytes for a pane,
  materializing cloud originals, and re-derives a fact the library owns (ADR 0039).
- **Storing place names as overlay.** A stored name is overlay with a lifecycle, a
  re-lookup policy when the location changes, and a backfill of the whole library against
  a rate-limited service. Looking up the one item on screen needs none of that.
- **`CLGeocoder`.** Deprecated in macOS 26 in favour of `MKReverseGeocodingRequest`.
- **An exposure summary strip above the sections**, as Photos draws. Its five values would
  repeat the Exposure rows, and a strip of unknowns has no honest empty state.

- **Showing the fast level's text, or cutting it by confidence.** It reports only 0.3 and 0.5
  and misreads texture at both, so no cut separates real lines from noise
  (`docs/research/2026-11-12-text-and-labels-in-the-info-pane.md` §1).
- **Showing every label search's gate reads.** About 18 a photo from 0.05 confidence, with
  echoes (a horse beside a wagon at 0.08). Vision's own high-precision test keeps about five,
  and they are right.
- **Translating label names while browsing.** A photo's few labels took seconds under load,
  and a Mac without the language's pack could not name them at all.
- **Checking a translated name by SigLIP reading it.** Its Finnish is too weak: it rejected
  "ihmiset" (people) and "aikuinen" (adult), the commonest labels.
- **A sidebar row for photos with text.** Finding photos by their text is the search field's
  (owner, 2026-11-12).

## Consequences

- Moving search's text reading to the accurate level and storing confident labels (ADR 0048)
  makes every embedding and text reading owed once: about 25 minutes of embedding and 30 of
  text reading on the owner's library, in the background, during which In This Photo reads
  `Not Checked Yet` for photos not yet re-read.

- An item enriched before MediaMetadata 0.9.4 shows `Unknown` exposure until its local
  bytes are re-read; a cloud-only original keeps it until it is local, as every parser fix
  does.
- Browsing located photos with Info open sends one coordinate per photo to Apple. MapKit
  throttles lookups; a throttled one reads `Unknown`.
