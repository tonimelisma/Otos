# ADR 0041: A Live Photo is one item

## Context

An iPhone Live Photo is two files on disk: a still (`IMG_0002.HEIC` or `.JPG`) and a
motion movie (`IMG_0002.MOV`, or `.MP4` after a Google Takeout). Otos catalogs every image
and movie as its own row, so a Live Photo showed as two tiles, and Move to Trash on the
still left the movie behind.

The two files are linked by Apple's content identifier, which both carry: the still in its
Apple MakerNote (tag `0x0011`), the movie as `com.apple.quicktime.content.identifier`.
MediaMetadata reports it as `MediaMetadataResult.contentIdentifier` from 0.8.2 (ADR 0039).

A file name does not link them. The owner's Google Takeout folder holds `IMG_0002.HEIC` and
`IMG_0002.MP4`, one Live Photo sharing identifier `66E9019A-…`, beside an unrelated
`IMG_0002.JPG` from an iPad. Read with 0.8.2, the HEIC and MP4 report the identifier and the
JPG reports none.

## Decision

**The fact.** `media_asset.content_identifier` stores the library's value, as reported,
written with every metadata record (`writeMetadataProjection`). It is a byte fact: a
cloud-only file nobody has read has none yet.

**The pair.** A still and a movie form a Live Photo when they are in the same root and the
same folder, carry the same content identifier, and are the only still and the only movie
there that do. Any other count — two stills, two movies, a movie alone — pairs nothing, and
every file shows as before. Otos never pairs on a name, a date or a guess.

The rule is one SQL expression in `LivePhotoSQL`, evaluated where it is used rather than
stored. A stored link would need every write that renames, moves, deletes, enriches or
refreshes a row to keep it current; the expression is current by construction, and the
index `(library_root_id, content_identifier)` keeps it to one lookup per movie that has an
identifier.

**One item.** The still is the item. The movie is a member of it, not an item:
- every user-facing media query hides a paired movie through the scope clause it already
  shares with pending-trash hiding, so counts, day sections, filters, the filmstrip and
  import batches count one item;
- a still's curation, edit and Info are the item's; the movie's row keeps its own overlay
  under the one lifecycle (ADR 0008) but nothing shows it;
- Move to Trash takes both files, the movie as a member of the still's item, and undo puts
  both back;
- import and library reorganization name the pair as one bundle, so the movie is renamed
  with its still and never lands in another folder;
- Copy, Share, Open, drag and Export hand off and write the still only — one file per
  photo (ADR 0037, ADR 0038);
- the loupe plays the movie on request, in place, and returns to the still when it ends.

**Rows read before 0.8.2** carry no identifier. Migration v9 adds the column and clears the
stored extraction revision of HEIF, JPEG and ISO BMFF records, as v7 did for 0.7.1, so
`MetadataRefresher` re-reads them from local bytes.

**A cloud-only original that may be half of a Live Photo is downloaded** (owner's decision,
2026-10-31): its pair cannot form without its bytes. That is a record of a family that can
carry the identifier, read before 0.8.2 (a NULL revision after v7 and v9), made by Apple.
`MetadataRefresher` reads nothing for it and hands it to enrichment
(`CatalogStore.requestEnrichmentDownload` clears its enrichment signature), so the file is
downloaded once and everything that download can give is derived from it: metadata,
checksum, thumbnail and preview. No product waits for a second download. Any other stale
cloud-only record is still not downloaded for a parser fix (ADR 0039).

## Consequences

- A Live Photo shows as one tile once both halves have been read, and as two before that.
- Backfilling an iPhone library downloads its cloud-only Apple stills and movies once,
  under enrichment's per-library limit and the 5 GB free-space floor (ADR 0027).
  The motion tile leaving the grid is a structural apply like any other enrichment reorder.
- An edit, curation or Trash on the still covers the motion; nothing can act on the motion
  alone from the grid.
- A pair that a rename splits across folders, or a third file sharing the identifier,
  shows as separate items again, because the evidence no longer proves one Live Photo.

## Rejected

- **Pairing by stem**, as companions do (ARC-045). Proven wrong on the owner's own data
  above, and it would fabricate a domain fact (MED-002).
- **A stored `paired_still` column.** It answers the same question as the facts it is
  derived from, and every rename, move witness and reorganization settlement would have to
  maintain it.
- **Making the movie a companion** (`media_companion`). Companions are found without bytes
  and never enter media queries; a movie is media until its identifier is read, and is
  enriched, thumbnailed and played as media.
- **Exporting or handing off both files.** A Live Photo is one photo to every app Otos
  hands it to; its original files stay where they are, in the user's folders.
