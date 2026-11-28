# Capture day: instant in the viewer's zone vs. the wall clock where taken (2026-11-10)

## Question

On which day does Otos put a photo, in the grid's day sections, the Date sort and On This
Day, and is that the day it was taken?

## Method

A read-only look at the test Mac's installed catalog
(`~/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite`, opened with
`sqlite3 -readonly`), with the Mac on AEDT (UTC+11) that day. For each row with a stored
wall clock (`capture_wall_compact`, the library's `captureWallClock`), compare the wall
clock's date with the date `best_capture_unix` fell on in the Mac's zone, which is how
`CatalogStore.orderedAssetIDs` bucketed days and how `AnniversaryRanges` matched them.

```sql
WITH r AS (SELECT library_root_id root, capture_wall_precision p,
  julianday(date(best_capture_unix,'unixepoch','localtime'))
  - julianday(date(printf('%04d-%02d-%02d', capture_wall_compact/10000000000,
      (capture_wall_compact/100000000)%100, (capture_wall_compact/1000000)%100))) d
  FROM media_asset WHERE capture_wall_compact IS NOT NULL)
SELECT root, p, count(*), sum(d=0), sum(abs(d)=1), sum(abs(d) BETWEEN 2 AND 7),
       sum(abs(d) BETWEEN 8 AND 31), sum(abs(d) BETWEEN 32 AND 365), max(abs(d))
FROM r GROUP BY 1, 2;
```

## Findings (before)

Rows with a wall clock but **no instant** (floating Exif, no offset). `best_capture_unix`
fell back to the file's creation date:

| Root | Precision | Rows | Same day | ±1 | 2–7 | 8–31 | 32–365 | Max days off |
|---|---|---|---|---|---|---|---|---|
| 6 (OneDrive family folder) | localFloating | 713 | 83 | 109 | 0 | 17 | 504 | 101 |
| 6 | derivedFromDuration | 5 | 0 | 5 | 0 | 0 | 0 | 1 |
| 7 (OneDrive Camera Roll) | localFloating | 220 | 0 | 141 | 33 | 44 | 2 | 34 |
| 7 | derivedFromDuration | 19 | 2 | 17 | 0 | 0 | 0 | 1 |
| 10 (card) | localFloating | 71 | 0 | 32 | 0 | 0 | 39 | 100 |
| 14 (camera) | all | 59 | 2 | 57 | 0 | 0 | 0 | 1 |
| 5 (camera) | localFloating | 1 | 0 | 1 | 0 | 0 | 0 | 1 |

So 1,088 rows had a wall clock and no instant. 87 were on their own day, and 589 were
8–101 days off.

Rows with a wall clock **and** an instant (offset-bearing). They were bucketed in the
Mac's current zone:

| Root | Precision | Rows | Same day | Other day |
|---|---|---|---|---|
| 7 | localWithOffset | 15,188 | 27 | 15,161 |
| 13 (camera) | localWithOffset | 393 | 0 | 393 |
| 14 | localWithOffset | 586 | 2 | 584 |
| 5 | localWithOffset | 13 | 0 | 13 |

All of these are off by exactly one day: the photos were taken in a UTC−7/−8 zone and
viewed from UTC+11. A photo taken at 15:00 in California sat on the next day. This is the
same defect as the first table: a day computed from an instant needs a zone, and the
viewer's zone is not the capture zone.

1,800 rows had no wall clock at all. 948 were images whose files carry no capture time,
761 had only an absolute time (GPS, a bare-`Z` movie date, a camera's ImageCapture date),
and the rest were not yet read.

## Reference products

- Lightroom Classic's Capture Time is the camera's local wall clock, and the Library
  grid's capture-date grouping and Capture Time sort use it unconverted. A file without
  Exif capture time takes the file's date in the computer's zone at import.
- Apple Photos shows and groups a photo at the time and day where it was taken (its
  Adjust Date and Time keeps the capture zone).

## Conclusion

Order and day by local capture time: the wall clock read as if it were UTC (zone-free,
indexable). Use an absolute time read in an assumed zone only when the file has no wall
clock. A fix that kept instants could not fix the floating rows: turning a floating wall
into an instant bakes in a zone, so they would move whenever the Mac's zone differs. The
decision is in ADR 0039 (MediaMetadata 0.9.3 restates which selection answers which
question).

## After

`best_capture_local`'s definition was evaluated read-only over the same catalog, with the
offset assumed in the Mac's zone as migration v23 does. Days are counted as the grid now
buckets them:

| Precision | Rows | On own wall day | Off it | No wall: same day as before |
|---|---|---|---|---|
| localWithOffset | 16,778 | 16,180 | 0 | 598 (root 13: precision stored, no wall) |
| localFloating | 1,050 | 1,050 | 0 | — |
| derivedFromDuration | 385 | 385 | 0 | — |
| no wall | 1,202 | — | — | 1,202 |

So every row with a wall clock (17,615) now sits on its own day; before, 116 did (87 floating or derived, 29 offset-bearing).
Rows without a wall clock keep the day they had in this zone. The installed catalog is
measured again after migration in the PR.
