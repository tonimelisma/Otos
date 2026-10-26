# MediaMetadata 0.7.0: what it changes in this library, and what re-reading would cost

Date: 2026-10-25. Measured before Otos took MediaMetadata 0.7.0. The probes ran read-only
against the live catalog and library and skipped cloud-only files, so nothing was
downloaded.

## What re-reading would download

Library-root rows, by kind and family, with the bytes that are cloud-only:

| Kind / family | Rows | GB | Cloud-only rows | Cloud-only GB |
| --- | --- | --- | --- | --- |
| video / isoBMFF | 1,699 | 551.0 | 1,623 | 513.7 |
| raw / tiff | 5,358 | 191.1 | 4,888 | 174.6 |
| image / heif | 6,950 | 34.3 | 4,484 | 21.4 |
| video / riffAVI | 71 | 2.0 | 71 | 2.0 |
| image / jpeg | 1,303 | 1.0 | 1,072 | 0.8 |
| image / unknown (PNG and others) | 292 | 0.4 | 161 | 0.2 |

Re-reading every row would move ~779 GB, ~713 GB of it downloads, through a disk with
15–19 GB free and a 5 GB floor.

## What 0.7.0 changes for the same bytes

0.7.0 read every local library file (3,424), and its output was compared with the stored
record (read by 0.6.x):

| Change | Files |
| --- | --- |
| video orientation `nil` → `1` (upright: no visible change) | 73 |
| video orientation `nil` → `6` (portrait) | 3 |
| HEIF stored size `nil` → present | 11 |
| AVIF family `isoBMFF` → `heif`, size `nil` → present | 1 |
| `camera` is now `nil` (identity only; API shape, no stored fact changes) | 319 |
| JPEG, RAW and TIFF records | no change |
| video codec identifiers | no change |

The stored size and orientation feed only Info's W × H and the loupe's 100 percent, which
uses the long edge, the same either way. Grid tiles size from the thumbnail; the loupe and
crop take their shape from the decode (APP-040, APP-048).

## Review of the proposed adoption plan

A plan written alongside the library proposed how Otos should adopt 0.7.0. Item by item:

- **Bump, geometry, codec identifier:** correct; adopted.
- **Display size from the library:** correct; the gateway uses `PixelGeometry`. The swaps
  in `PreviewImageLoader` and `ImageRenderer` read ImageIO's and Core Image's own
  orientation for the decode they draw and stay.
- **Timestamps and locations over `entries`, Otos's role enum as a filtered view:**
  correct; Otos's enum is deleted in favour of `CaptureTimestamps.Role` less the audio-only
  roles. The raw values are identical, so no data migration is needed.
- **Capture wall from `result.timestamps.captureWallClock`:** the live overload it names
  was dead code. Otos selects from its persisted records, which import reuse also needs.
  The record selection now walks `wallClockPrecedence`. The RIFF behaviour change is
  accepted and pinned by a test.
- **Kind from `format.kind`:** adopted. Its stated reason, that AVIF stills were misfiled
  as video, does not hold: the platform's type for `.avif` classifies it as an image
  before the family fallback is reached (the one AVIF row is `image`).
- **Make a lower `extractionRevision` stale for enrichment:** rejected. Enrichment
  downloads stale cloud-only rows, so this re-downloads the library above to change the
  handful of fields in the table. `MetadataRefresher` re-reads stale rows from local bytes
  only (ADR 0039).
- **Check that portrait videos come out portrait in the grid:** not affected; tiles size
  from their thumbnail image, not the catalog.
- **Leave `best_capture_unix`, the camera reader and preview decoding alone:** agreed.

## 0.7.1

0.7.1 answers the requests this review raised:
- per-family revisions;
- "may re-read", not "must";
- camera RAW and file type from the bytes;
- `Role.isAudioOnly`;
- file-type names by extension.

0.7.1 read every local library file (2,666 at the time) and its answer was compared with
Otos's stored kind:

| Library | Files | Agrees with Otos |
| --- | --- | --- |
| heif, `image` | 1,842 | yes |
| arw, camera RAW | 374 | yes |
| jpeg | 305 | yes |
| png: unknown from the bytes, `png` by extension | 83 | yes, through the extension |
| mp4, mov | 61 | yes |
| avif | 1 | yes |

Otos therefore takes kind from the library (bytes, then extension) with no change for
any local file. PNG is not identified from its bytes yet, which is a request back to the
library.
