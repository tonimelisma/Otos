# Live Photos: what pairs a still and its movie, and what the pair rule costs

Date: 2026-10-31. Feeds ADR 0041.

## What links the two files

Read on a Google Takeout folder `Google Photos/Trash/` with `exiftool -a -G1`
(files deliberately materialized for the read):

| File | `ContentIdentifier` | Device |
|---|---|---|
| `IMG_0002.HEIC` | `[Apple] 66E9019A-9CAF-4603-A6C3-2F22030B7C65` | iPhone 8 |
| `IMG_0002.MP4` | `[Keys] 66E9019A-9CAF-4603-A6C3-2F22030B7C65`, 2.97 s | iPhone 8 |
| `IMG_0002.JPG` | none | iPad mini |

- A Live Photo survives a Takeout as HEIC + **MP4** (not MOV), and the movie keeps its
  QuickTime `com.apple.quicktime.content.identifier` key.
- The same folder holds an unrelated `IMG_0002.JPG` from another device. Pairing by stem
  would join it to the movie, so the name is not evidence; the identifier is.
- `exiftool -v3` on the HEIC shows the still's side: the Exif `MakerNote` (`0x927C`, 1146
  bytes) starts `Apple iOS\0`, version `00 01`, `MM`; its big-endian IFD's value offsets
  count from the MakerNote's start; tag `0x0011` is the identifier as a 37-byte ASCII
  string.

MediaMetadata 0.8.2 reads both sides (`MediaMetadataResult.contentIdentifier`). Read with
it, the HEIC and MP4 above report the identifier and the JPG reports `nil`.

## What the pair rule costs the grid

The rule (`LivePhotoSQL.isPairedMotion`) is two correlated counts per movie that has an
identifier, each one `SEARCH … USING INDEX idx_media_asset_content_identifier
(library_root_id=? AND content_identifier=? AND parent_path=?)`; rows without an identifier
or that are not movies short-circuit before it.

Measured on a copy of the installed app's catalog (18,465 rows, 2,057 videos, 7 roots),
v9 applied, and — as a worst case — every row given an identifier (folder + stem), so every
movie runs both counts. The All Media date-ordered ID query (`INDEXED BY
idx_media_asset_best_capture_global_desc`, 16,254 library rows), `sqlite3 .timer`, two runs
each:

| Query | Run 1 | Run 2 |
|---|---|---|
| without the rule | 11.7 ms | 10.5 ms |
| with the rule | 18.8 ms | 19.1 ms |

About 8 ms more for the whole library in the worst case, on `CatalogStore`'s actor, never
the main actor. A real catalog pays less: only Apple stills and movies carry identifiers.
No stored link or cache is warranted.
