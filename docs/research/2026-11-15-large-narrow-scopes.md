# Large narrow scopes (2026-11-15)

Follows `2026-11-15-small-scope-reads-and-tile-waits.md` (#765) and
`2026-11-15-proportional-small-scopes.md` (#766).

## Question

#765 and #766 made a person, On This Day and a map area seek their own rows (`ScopeClause.Seek`)
and build only the stacks that hold them. Three measured costs were left:

1. `projection.windowState.onThisDay.years` and `.months` rose from 1,471 and 1,465 to 1,601 and
   1,602 M instructions. #766's author put it on building stacks from 14,625 rows: the
   benchmark catalog takes all 15,000 stills on one day, so On This Day is most of it.
2. A world-sized map area's order read 103,382 pages against the date walk's 55,704.
3. The most photographed person's order (16,218 photos) read 19,484 pages against 3,820.

The same shape each time: a seek is right for a scope of tens of rows and wrong for one that is
a large share of the catalog. What fact, known before the read, chooses the plan?

## Method

No data from the reference library was read (by rule). Two generated catalogs, both built by tests
that were never committed and deleted afterwards:

- **The benchmark catalog** (`BenchmarkLibrary`, 15,000 stills, one folder, no RAW): temporary
  per-phase `Benchmark.measure` cases on the commit before #766 (`92c9c229`) and on
  `734db9e6`, one Debug test process each (`script/check.sh --only`, no deterministic hash seed,
  so the counts are good to a percent or two).
- **A reference-shaped catalog** made with SQL after `CatalogStore.migrator`: 166,000 rows, 16,000
  in a library of month folders (one in twenty a RAW) and 150,000 in an account, one folder
  each; capture times spread over 2011–2026 independently of the rows' keys; every row given an
  `asset_metadata` row with a 1.1 KB metadata record and 50,000 of them located in nested
  clusters assigned independently of the keys (Helsinki 300, Finland 2,500 with it, Europe
  20,000, Europe and North America 35,000, the world 50,000); three people of 24, 1,660 and
  16,218 photos. Its All Media date walk with a location test reads 62,946 pages, the reference catalog's
  55,704 (#766), so a row costs about what it does there. A first version without the padding and
  with clustered keys read 7,400 and was set aside: it made every plan look cheap.
- **Measures**, as #765: the pages a fresh read-only connection with no memory map misses
  (`SQLITE_DBSTATUS_CACHE_MISS`) and the best of three warm times, for each scope's order with
  every stack of the roots held (`held`) and with none (`noStacksHeld`, `readOrder`), the
  filter's types and the count — each with the seek forced, the walk forced, and as decided. The
  machine ran other sessions' checks throughout, so warm times are loose.

## Findings

### On This Day: the stacks and the sorted seek, about equally (proven per phase)

Benchmark catalog, On This Day a year after its one day (14,625 rows), M instructions:

| phase | before #766 | #766 | this change |
| --- | --- | --- | --- |
| window state (the bench case) | 1,468 | 1,596 | 1,485 |
| store order | 1,339 | 1,469 | 1,354 |
| the match (and, in this change, the plan's two counts) | 7 | 12 | 29 |
| the rows' read | 391 | 438 | 410 |
| stacks: every candidate of the root | 3 | — | 3 |
| stacks: from the rows (`build(holding:)`) | — | 90 | — |
| the order read (`readOrder`) | 394 | 529 | 422 |

The claim holds in part: stacks from the rows are 87 M of the 135 M. The rest is the seek
itself: the day index's rows read with each still's burst and sorted, against a walk of the date
index that hands them over in order (47 M). The match grew 5 M, because it judges its first row
by the stacks that hold it rather than by stacks already built.

### The plans on a reference-shaped catalog

Pages (warm ms), the order with every stack held unless noted:

| scope (rows) | seek | walk | decided |
| --- | --- | --- | --- |
| Helsinki (300) | 996 (3) | 62,946 (216) | 1,003 (3) |
| Finland (4,000) | 11,266 (33) | 62,946 (217) | 11,351 (34) |
| Europe (20,000) | 58,764 (159) | 62,946 (264) | 63,640 (265) |
| Europe and America (35,000) | 98,372 (307) | 62,946 (319) | 63,574 (317) |
| World (50,000) | 138,419 (473) | 62,946 (682) | 63,540 (378) |
| World, no stacks held | 139,357 | 63,754 | 64,528 |
| World, types | 138,419 (514) | 26,435 (223) | 27,377 (126) |
| Person of 24 | 107 (1) | 2,447 (49) | 112 (1) |
| Person of 1,660 | 3,330 (18) | 2,477 (80) | 3,523 (13) |
| Person of 16,218 | 9,522 (213) | 2,637 (131) | 3,139 (130) |
| Person of 16,218, types | 9,522 | 3,527 | 4,124 |
| On This Day (452) | 487 (3) | 2,929 (48) | 496 (3) |

- **A seek costs per row, a walk per catalog.** An area's seek reads about 2.8 pages a row (an
  `asset_metadata` row and a `media_asset` row by key, each on its own page); the walk a fixed
  62,946 for the order and about 26,000 for the types and the count. A person's seek reads about
  0.6 pages a photo here (1.2 on the reference catalog, #765); the walk about 2,600 (3,820 there).
- **A person's walk tests each row with one seek of `idx_face_person_photo`** (`EXISTS`, as
  before #765). Testing membership in the person's photo list instead read the same pages and
  ran three times slower warm (354 ms for the 16,218-photo person).
- **A day's seek never reads more pages than its walk**: both read the day's table and search
  rows; the walk adds the index. What the walk saves is CPU — no sort, no burst column, no stacks
  built from tens of thousands of rows — which matters only when the day is most of the rows.

### The rule

A sized seek (`SeekSize`) counts, in the read itself and from indexes alone, the entries it
would visit — the person's faces (`idx_face_person_photo`), the day's entries
(`idx_media_asset_capture_day`), the located rows of the area's cells
(`idx_asset_metadata_place_cell`) — and then the rows a walk visits (a one-root scope's rows, else
the catalog's, as the global order indexes hold them), counted no further than the candidates
times a ratio. It seeks when the walk's rows outnumber that product. Counting is in proportion
to the cheaper plan: Helsinki's decided reads cost 7 pages more than the forced seek, the world's
600 more than the forced walk.

The ratios are the walk's rows per sought row at which the two plans read the same:

- **Area, 10.** The order alone crosses at about 22,000 rows here (62,946 / 2.8; a ratio of
  7.4), the types and count at 9,300 (ratio 18). A window reads the order and the filter's types
  for a scope, which cross together at 89,000 / 5.6 ≈ 16,000 rows: ratio 10.4, taken as 10.
  Europe (20,000) now walks: its order reads 8 % more pages than the seek did and its types 53 %
  fewer.
- **Person, 40.** 2,600 / 0.6 ≈ 4,400 photos here (ratio 38); 3,820 / 1.2 ≈ 3,200 on the
  reference catalog (ratio 52). 40 sits between. The 1,660-photo person keeps the seek, which is
  six times faster warm than the walk.
- **Day, 2.** Pages always favour the seek, so the ratio is the CPU's: on the benchmark catalog
  the seek costs about 0.5 µs a sought row more than the walk (7.6 ms over 14,625 rows), and the
  walk about 0.3 µs a walked row (48 ms over 166,000 rows). A day walks only when it holds more
  than half the rows walked: a library taken in one day. On This Day's months fall back to about a
  thirtieth of the catalog, which seeks.

A scope that walks judges its rows by every stack of its roots, held or built: building stacks
from tens of thousands of rows' folders costs more than every candidate does (#766's world
area: 145,216 pages with no stacks held, against 79,824 for the walk). The match always seeks,
since it stops at the first row shown.

Rejected:

- **Choosing by the number of cells an area covers.** It is known without a read, but the rows
  per cell differ by orders of magnitude between a city and an ocean, and Europe and the world
  read alike for someone who lives in Europe.
- **The located-row count the projection holds** (Places' order). It would be a second owner of
  a planning fact, passed into every read, and it says nothing about a person or a day.
- **Estimate tables** (`ANALYZE`): the planner is told its indexes (`INDEXED BY`) on every read,
  so statistics would change nothing it decides.
- **Changing the benchmark fixture.** One day holding the whole catalog is a real shape (a
  library imported from a card with no capture metadata), and it is the one that exercises the
  walk; the reference-shaped catalog above covers the seek.

## Conclusions

- On This Day's bench case falls from 1,596 to 1,485 M instructions in one process (before #766:
  1,468); `script/bench.sh compare` figures are in the PR's DoD report. The remaining 1 % is the
  two counts and the match's first judgement.
- A world-sized area's order reads 63,540 pages (decided) instead of 138,419, and its types
  27,377 instead of 138,419; Helsinki and Finland are unchanged.
- The most photographed person's order reads 3,139 pages instead of 9,522 and runs 130 ms
  instead of 213 warm; people of up to about 4,000 photos keep the seek.
- Pinned by `ScopeReachPlanTests`: for each kind, one candidate fewer than the boundary seeks
  and builds the stacks of its rows, one more walks the order with no temporary sort and builds
  every stack of its roots, and both read the same rows.
- Not sized: an import batch, a stack's members, a set of identical copies and Duplicates still
  always seek. None was measured large here; a stack opened zoomed out and an import of a whole
  card are the ones that could be.
