# Small scopes read in proportion to themselves (2026-11-15)

## Question

`2026-11-15-small-scope-reads-and-tile-waits.md` (#765) measured three scopes that read
library-sized page counts for a few hundred rows and left them: a map area, On This Day and
Duplicates. No key names their rows, so #765's keyed-scope plan (a seek by the key index)
did not apply. What is the smallest correct read for each?

## Method

- **Catalog:** an APFS clone of `build/catalog-backups/catalog-v53-before-v55.sqlite`
  (166,737 rows; libraries 6 and 7, the Immich account 15) in the worktree's `build/`,
  migrated to head by `CatalogStore.migrator` alone in a temporary test that was never
  committed (no Store, no source, no watcher), and deleted afterwards.
- **Digests:** v60 clears every digest, so the copy had no Duplicates groups. Every row of the
  three roots was given a random current SHA-1 (as an account's rows all carry one), then 63
  pairs were made to share one: 40 within the account, 15 within library 7, 8 across a library
  and the account — 126 copies, the count the owner's app showed.
- **Measures:** as #765: for each read, the pages a fresh read-only connection with no memory
  map reads (`SQLITE_DBSTATUS_CACHE_MISS`, what a read costs once the cache is paged out, as
  the owner's was), the best of three warm times, and `EXPLAIN QUERY PLAN`. The order is
  measured twice: with every stack of the roots held (`heldStacks`, the projection's usual
  case) and as the Store reads it with none held (`noHeldStacks`: rows plus the stacks the
  read builds, `CatalogQueryGateway.readOrder`). For On This Day the pages include the
  years-or-months match, which runs inside each read. The machine ran other sessions' checks
  throughout, so warm times are loose; pages are exact.
- Scopes: Helsinki (60.15–60.20 N, 24.85–25.0 E), Finland (59.5–70.1 N, 19–31.6 E), the world
  (85 S–85 N), a box across the antimeridian (150 E–150 W, empty here), On This Day for
  15 November 2026, Duplicates within each library and across.

## Findings

### Before

| Scope (rows) | Order, held | Order, no stacks held | Types | Places | Count |
| --- | --- | --- | --- | --- | --- |
| Helsinki (283) | 55,704 (168 ms) | 79,824 (452 ms) | 81,649 (182 ms) | 132,319 (217 ms) | 246,740 (431 ms) |
| Finland (2,442) | 55,704 (171 ms) | 79,824 (455 ms) | 81,649 (188 ms) | 132,319 (216 ms) | 246,740 (431 ms) |
| World (50,548) | 55,704 (272 ms) | 79,824 (556 ms) | 81,649 (199 ms) | 132,319 (239 ms) | 246,740 (465 ms) |
| On This Day (705) | 5,303 (34 ms) | 29,248 (322 ms) | 29,187 (333 ms) | 131,741 (490 ms) | 28,861 (328 ms) |
| Duplicates, within (110) | 155,058 (343 ms) | 178,983 (648 ms) | 187,027 (363 ms) | 111,238 (226 ms) | 11,101 (94 ms) |
| Duplicates, across (125) | 155,058 (344 ms) | 178,983 (625 ms) | 187,027 (357 ms) | 111,238 (229 ms) | 5,603 (46 ms) |

- **A map area** walked the date index over every row and looked up each row's
  `asset_metadata` to test its box; the count walked `idx_media_asset_relative_path_key`
  and read both table rows of every row. The area's cells were never used.
- **On This Day** tested `strftime('%m-%d', best_capture_local)` on every index entry
  before the year's start (the order's 5,303 pages), and every read with no stacks held
  first built every stack of the roots (23,967 pages, 0.3 s) because the match judged its
  rows by them. Its place options started from every named cell.
- **Duplicates** grouped the digest index once (the subquery's ~5,600 pages) and then walked
  the date or candidate index over every row of the catalog, reading each row's table row
  to test its digest against the groups (149,000–187,000 pages).

### Designs

Each scope gets a seek (`ScopeClause.Seek`): every read of it — the order under every sort,
the filter's types, the count, the place options — starts from an index that holds its rows
and little else, then sorts the few it finds. Its stacks are built from its rows, like a keyed
scope's (`PhotoStackSQL.isBuiltFromRows`).

- **A map area** seeks `idx_asset_metadata_place_cell`, which v43 built for place names: the
  cells the box's corners fall in (`PlaceCellSQL.cells(covering:)`, the same floor of the
  same product SQLite's generated column takes, pinned by
  `anAreasCellsAreTheCellsSQLiteGivesItsCoordinates`) bound every row inside the box, so the
  read is the latitude band's entries, the longitudes tested in the index, then each
  candidate's coordinate and its `media_asset` by key. No schema change.
- **On This Day** stores the date the clock showed as generated columns, `capture_day` and
  `capture_month` (v62, never written), leading `idx_media_asset_capture_day` with the order's
  and a combined scope's tested columns. The years match is
  `capture_day = ? AND capture_month = ? AND best_capture_local < ?`, the months match
  `capture_day = ? AND best_capture_local < ?`: a seek of the day's rows. The match and the
  count judge their rows by the stacks that hold them, built from those rows' folders and
  bursts in the same read (`AnniversaryStacks.judging`), which judge each of them exactly as
  every stack of the roots would: a row's stack is built whole from its folder and burst.
- **Duplicates** seeks `idx_media_asset_content_sha1` by the digests its group subquery finds
  (`content_sha1 IN (…)`, or `(content_sha1, library_root_id) IN (…)` within each library).
  The subquery still reads every digest: a group is a digest another row shares, and no
  index holds fewer entries than the digests themselves. A stored group marker would answer
  it in fewer pages, but it is a second owner of the Duplicates rule (the twins' visibility,
  the Live Photo motion rule, the reach), which the copies read and `DuplicatesProjection`
  already own; it was not built. The digest index is about 5,600 pages, 45–50 ms warm.

### After

| Scope (rows) | Order, held | Order, no stacks held | Types | Places | Count |
| --- | --- | --- | --- | --- | --- |
| Helsinki (283) | 869 (1 ms) | 1,072 (2 ms) | 869 (0 ms) | 1,156 (1 ms) | 869 (0 ms) |
| Finland (2,442) | 5,632 (10 ms) | 8,106 (55 ms) | 5,632 (5 ms) | 7,484 (8 ms) | 5,632 (4 ms) |
| World (50,548) | 103,382 (294 ms) | 145,216 (908 ms) | 103,382 (179 ms) | 130,388 (263 ms) | 103,382 (163 ms) |
| On This Day (705) | 4,937 (6 ms) | 5,514 (12 ms) | 5,221 (7 ms) | 6,171 (9 ms) | 5,515 (14 ms) |
| Duplicates, within (110) | 5,743 (50 ms) | 17,039 (158 ms) | 5,743 (49 ms) | 5,760 (48 ms) | 5,594 (47 ms) |
| Duplicates, across (125) | 5,775 (46 ms) | 17,103 (158 ms) | 5,775 (45 ms) | 5,790 (45 ms) | 5,603 (45 ms) |

All Media and Places (wide scopes, unchanged code) read the same pages before and after.

- The reads now cost about two to eight pages per row of the scope. On This Day's 705 rows
  still read about 5,000 pages: each row's table row (`media_choice`, the exclusion) and its
  search row. Duplicates' "no stacks held" order adds the stacks of its rows' folders (about
  11,000 pages: a library row's folder holds a month of a camera roll).
- **The world as an area is the one regression.** A seek costs a few pages per row and the
  date walk a fixed 55,704, so an area of more than about 25,000 located rows reads more
  pages than before: the world's order 103,382 against 55,704 (294 ms against 272 ms warm
  with stacks held), and with no stacks held 145,216 against 79,824 (908 ms against 452 ms),
  because the stacks of 50,000 rows' folders read more than every candidate does. Its count
  and types fell (246,740 to 103,382 pages, 465 to 163 ms). An area is the box the user has
  zoomed to before opening it (`openVisibleMapArea`), so most are a city or a country; the
  whole located library is Places, which stays wide. Choosing the plan by an estimate of the
  area's rows would need a count before every read or a size guess, a second rule for what
  the planner is told; neither was built. If world-sized areas turn out common, the next step
  is a held-stacks rule for large narrow scopes, measured first.

### Plans

Pinned by `CatalogStoreQueryPlanTests.narrowScopesSeekTheirOwnRows` (every read of an area,
one across the antimeridian, On This Day and both Duplicates reaches starts with its seek and
scans no table) and `onThisDaysYearRowsAreSoughtThroughTheDayIndex`:

```
SEARCH asset_metadata USING INDEX idx_asset_metadata_place_cell (place_cell_latitude>? AND place_cell_latitude<?)
SEARCH media_asset USING INDEX sqlite_autoindex_media_asset_1 (library_root_id=? AND relative_path=?)
USE TEMP B-TREE FOR ORDER BY

SEARCH media_asset USING INDEX idx_media_asset_capture_day (capture_day=? AND capture_month=? AND best_capture_local<?)

SEARCH media_asset USING INDEX idx_media_asset_content_sha1 (content_sha1=? AND library_root_id=?)
LIST SUBQUERY … SEARCH twin USING INDEX idx_media_asset_content_sha1 (content_sha1>?)
```

### Benchmarks

`projection.windowState.duplicates` (750 copies of the benchmark catalog's 15,000 stills) and
`projection.windowState.mapArea` (every still given a place, one in fifty inside the area) are
new cases; the existing `projection.windowState.onThisDay.years` and `.months` measure the day
index. Instructions are in the PR's DoD report.

## Conclusions

- A map area, On This Day and Duplicates read in proportion to their rows: Helsinki's reads
  fell 64–284×, On This Day's 1–21×, Duplicates' 2–33×.
- v62 adds two generated columns and one index for On This Day; the area uses the cell index
  it had; Duplicates the digest index it had.
- A world-sized area reads up to 1.9× the pages it did. Places, the located library as a
  whole, is unchanged.
