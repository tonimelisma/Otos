# MediaMetadata 0.8.0 and the library's capture instant (2026-10-26)

## MediaMetadata 0.8.0

Released from github.com/tonimelisma/MediaMetadata PR #19 (tag `0.8.0`, adb6154):
- PNG, WebP and GIF are format families of their own (`.png`, `.webp`, `.gif`, kind
  image), with their size from the container header (`IHDR`, `VP8X`/`VP8`/`VP8L`, the GIF
  logical screen) and, for PNG and WebP, Exif from `eXIf` / `EXIF` through the TIFF parser.
- A RIFF file is identified by its form type: `AVI `, `WAVE`, `WEBP`; any other is
  `unknown` (before, every RIFF file was `riffAVI`).
- Revisions: `unknown` 1 → 2; `png`, `webp`, `gif` start at 0; no other family moved.
- Validated read-only on real files (no download): 93 local PNGs from the library, 191
  WebP and 108 GIF from system folders; every size matched `sips` or, where `sips` had
  none, the header bytes decoded by hand. Bounded reads: at most 264 bytes per file.

## Otos adoption

- Revisions are generic in Otos (`currentExtractionRevisionSQL` covers every family the
  library names), so a PNG that 0.7.1 stored as `unknown` at 1 is a refresh candidate and
  is re-read from local bytes as `png` at 0.
- **Defect found:** the refresh write guard compared the stored revision with the new
  record's (`1 < 0` is false), so no re-read that changes family was ever written. The
  guard is now the candidate test itself — the stored record is older than its own
  family's current reading.

## Capture instant

The library orders capture instants original, digitized, QuickTime creation, QuickTime
content-create, GPS (`CaptureTimestamps.instantPrecedence`). Otos's `best_capture_unix`
coalesced its own four columns in another order (original, QuickTime creation,
digitized, GPS) and never saw content-create. Migration v8 keeps one
`capture_instant_unix`, the library's choice from the stored records, and makes
`best_capture_unix` a virtual column falling back to the file's creation and modification
dates. SQLite measured on 3.54.0: a stored generated column can be dropped once its
indexes are, its source columns then dropped, and a virtual generated column added and
indexed; a stored one cannot be added.

## MediaMetadata 0.8.1: selections asked of stored records

Otos walked `instantPrecedence` and `wallClockPrecedence` itself over its stored records,
because the library's `captureInstant` and `captureWallClock` exist only on a
`CaptureTimestamps` value. 0.8.1 (tonimelisma/MediaMetadata#20) adds
`CaptureTimestamps(entries:)`, the inverse of `entries`; Otos rebuilds the value from its
records (`CaptureTimestamps(records:)`) and asks it.

The two can differ only for an asset whose records repeat a role, name a role this build
does not know, or are not valid capture times (Otos leaves those out, as its own loop
skipped them). Measured on the installed catalog (2026-10-26): 62,206 records over 17,876
assets — 0 repeated roles, 6 roles all known, every record with a precision and in-range
components. The selections therefore return exactly what the catalog stores, and no
migration is needed.

