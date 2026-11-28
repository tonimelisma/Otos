# Same-photo calibration on the reference library

Date: 2026-10-31. Plan 0109 increment 0, item 2. A read-only measurement: the probes read
the installed app's stored thumbnails and previews in Application Support plus a snapshot
of its catalog, and 13 originals that were already local (each re-checked for
`SF_DATALESS` immediately before its header read). Nothing was downloaded, written to a
media folder, or changed in the catalog. The probe sources were throwaway scratch files
and are described here instead of kept.

Item 1 of increment 0 (the staged-hash cost) is still open: it needs one real card
import, and no import has logged `op=contentHash owner=import` in the last 14 days.

## Data

The catalog snapshot covers two fixed libraries (OneDrive `Summer Photos` and `Camera
Roll`): 14 445 stills and RAWs with thumbnails, 9 491 of them with stored previews. The
labelled pair sets were built from catalog facts alone:

| Set | How it was built | Pairs |
| --- | --- | --- |
| `burst_same_second` | same root, same camera model, same kind, same whole-second capture instant, different file names | 3 070 |
| `burst_within_3s` | as above, capture instants 1–3 s apart | 16 917 |
| `rawjpeg_pair` | same folder and stem, one RAW and one processed file | 5 338 |
| `same_second_other` | same instant and camera model, any other relation | 3 000 |
| `random` | random pairs | 1 499 |
| synthetic copies | 500 stored previews, each made into a copy the way a messaging app or web export would (resize to 1024 px at JPEG 0.6, 2048 px at 0.8, 640 px at 0.5, 320 px at 0.4), compared with the same preview rendered without the copy step | 500 × 4 |

The synthetic copies stand in for the "known resized and re-saved copies" set; the
library has only eight byte-identical pairs and no labelled re-saved ones. Both sides of a
synthetic pair are rendered by the same path, because a real copy's thumbnail is made by
the same Otos pipeline as its original's. A first run that compared the stored thumbnail
against a copy rendered from the stored preview showed differences coming from the two
rendering paths, not the copy, and was discarded.

## Results

**Vision feature print (revision 2) on 256 px thumbnails does not separate copies from
bursts.** Median distance for matched synthetic copies is 0.14–0.22 (p95 up to 0.31);
re-encoding a 256 px thumbnail at JPEG 0.4 alone gives 0.55. Same-second burst frames
start at 0.11 (p01) with median 0.33. The 0.005 measured on a system wallpaper in the
design study does not hold for real, small, compressed renders. The print is dropped.

**Pixel difference and a 64-bit difference hash do separate copies from unrelated
photos.** Measured on previews decoded to 512 px: the mean absolute difference of
32 × 32 grayscale renders (MAD, 0–255) and the Hamming distance of a 9 × 8 dHash.

| Set | MAD p01 / p05 / p50 / p95 | dHash p05 / p50 / p95 |
| --- | --- | --- |
| synthetic copies (all four) | 0.1 / 0.1 / 0.6–3.6 / 2.0–5.1 | 0 / 0–2 / 2–10 |
| `burst_same_second` | 0.9 / 3.8 / 25.9 / 56.7 | 2 / 11 / 30 |
| `burst_within_3s` | 3.0 / 12.3 / 37.9 / 68.9 | 4 / 18 / 34 |
| `rawjpeg_pair` | 10.0 / 14.3 / 20.2 / 24.6 | 0 / 2 / 5 |
| `random` | 41.3 / 51.1 / 73.4 / 113.7 | 23 / 31 / 40 |

With **dHash ≤ 10 and MAD < 4**, 89 % of synthetic copies are found, and no random pair,
RAW+JPEG pair or `same_second_other` pair matches. A RAW and its camera JPEG never pass
(MAD ≥ 9.8): the two renders differ more than a copy does.

**No pixel threshold separates a static burst.** At those thresholds 82 of 1 634
same-second burst pairs (5 %) and 52 of 4 000 pairs 1–3 s apart (1.3 %) match. The 1–3 s
pairs already differ in the whole-second capture instant Otos stores
(`media_asset.capture_instant_unix`), so gate 1 excludes them today. The same-second
pairs do not: the stored instant has no sub-seconds.

**Sub-seconds separate every checked same-second pair.** 13 of the 66 files behind those
82 pairs were local. All 13 carry `SubSecTimeOriginal`, and within every pair the values
differ (for example `…_115506_001` .387 vs `…_115506_002` .604; `…_185200.arw` .123 vs
`…_185200_001.arw` .707). None carries a body serial (EXIF `BodySerialNumber`) or an
Apple BurstUUID, so for this library sub-seconds are the gate that matters. The other 53
files were cloud-only and not read.

Not measured: screenshots and other utility images (`isUtility`), exposure brackets as a
labelled set, and dHash on 256 px thumbnails rather than previews (only 9 491 of 14 445
stills have a stored preview).

## Consequences for plan 0109

- Increment 5 replaces the feature print with a 64-bit dHash of the stored render as the
  candidate index (Hamming ≤ 10) and keeps the 32 × 32 MAD as confirmation (< 4). Both are
  deterministic and need no Vision revision tracking.
- Gate 1 needs MediaMetadata to report capture sub-seconds; Otos's stored capture instant
  is whole seconds. Body serial and BurstUUID stay in the library request, but this
  library's files would not use them.
- Increment 5's tests re-measure these thresholds on 256 px thumbnails, the render every
  enriched still has, before they ship.
