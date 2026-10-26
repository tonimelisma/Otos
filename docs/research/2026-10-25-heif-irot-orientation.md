# HEIF orientation from `irot`: what the catalog missed

Date: 2026-10-25. Why some HEIFs looked stretched in the loupe, and what MediaMetadata
0.6.1 changes. Probes ran read-only against the live catalog and library. Cloud-only
files were skipped, so nothing was downloaded.

## The file that showed it

`20261024_165604.heif` (Sony ILCE-6700), a portrait photo.

| Reader | Orientation | Size |
| --- | --- | --- |
| exiftool | no `Orientation` tag; `Rotation: Rotate 90 CW` | 6192 × 4128 |
| HEIF boxes | `irot` with angle 3 (270° anticlockwise, i.e. 90° clockwise); no Orientation in Exif IFD0 | `ispe` stored size |
| ImageIO | 6, applied on decode (upright 4128 × 6192) | 6192 × 4128 stored |
| MediaMetadata 0.6.0 | none (read 1) | 6192 × 4128 |
| MediaMetadata 0.6.1 | 6 | 6192 × 4128 |

The catalog held 6192 × 4128 with no orientation, so Otos took the stored landscape size
as the upright one.

## Across the library

- 7,326 HEIF/HEIC/AVIF rows in total; 5,668 had no stored orientation (5,669 of them in
  library roots, counted by the migration's own join).
- Of all of them, 1,756 were local and 5,192 cloud-only. For every local one,
  MediaMetadata 0.6.1 and ImageIO agree on orientation: 1,756 agree, 0 disagree. 964 are
  rotated (orientation 5–8).
- Neither tool could be run on the cloud-only files without downloading them, so how
  many of those rows are rotated is unknown.

## A test file of the same shape

ImageIO, asked to write a HEIC with orientation 6, writes both `irot` and an Exif
Orientation tag. Renaming that IFD0 entry's tag to 0 leaves only `irot`, as the Sony
camera writes it. On that file 0.6.0 reads 1 and 0.6.1 reads 6 (`writeIrotOnlyHEIC` in
the test support).

## Conclusion

- Take MediaMetadata 0.6.1.
- Re-read the library HEIF rows with no orientation, through enrichment's own staleness
  predicate (migration `v5_heif_orientation_reread`, ADR 0009).
- An upright HEIF with no tag is re-read too, because only its bytes tell the two apart.
  Cloud-only ones are downloaded under the free-space floor, like any re-enrichment.
