# Places' first paint (2026-11-15)

Follows `2026-11-15-scope-returns-and-superseded-builds.md` (#774) and
`2026-11-15-large-narrow-scopes.md` (#779).

## Question

On the reference catalog a click on Places took 7.5 s to its first state (70,372 located items;
the order read 6.4 s cold, 1.8 s read again). #774 put it on the map: it draws a stack for
every located item, so its first paint needs the whole located order. The map draws at most a
few dozen stacks (DES-103) and one count (DES-105). Is the first paint's read an aggregate per
visible cluster cell — a count and a representative — rather than the rows?

## Method

No data from the reference catalog was read (by rule). The reference-shaped catalog of #779, built
again by a test that was never committed and deleted afterwards: `CatalogStore.migrator`, then
SQL — 166,000 rows (16,000 in a library of month folders, one in twenty a RAW; 150,000 in a
second root, one folder each), capture times spread over 2011–2026 independently of the keys,
every row an `asset_metadata` row with a 1.1 KB metadata record, 50,000 located in nested
clusters assigned independently of the keys (Helsinki 300, Finland 2,500 with it, Europe
20,000, Europe and North America 35,000, the world 50,000). Measures as #779: the pages a fresh
read-only connection with no memory map misses (`SQLITE_DBSTATUS_CACHE_MISS`) and the best of
three warm times. The machine ran other sessions' checks throughout, so warm times are loose.

## Findings

### What Places reads, and where its pages go

The Places order walks the capture index over every row and joins each located row's
`asset_metadata` row by key for its coordinate. That table holds every row's metadata record:
55,473 of the catalog's pages are `asset_metadata`, 7,207 `media_asset`. Joined by key, the
order reads nearly the whole table.

| read (50,000 located of 166,000) | pages | warm ms |
| --- | --- | --- |
| Places order, every stack held | 59,151 | 377 |
| Places order, no stacks held | 59,157 | 391 |
| Places count | 64,718 | 178 |
| An aggregate of the world's cells (count and a front date per cell, 240 cells) | 64,718 | 197 |
| All Media count, for scale | 7,720 | 36 |
| Helsinki (303 rows), order or count | 1,056 | 2–3 |

### An aggregate is not cheaper, and it cannot be the same map

- **The first paint is the entry fit, which shows every located item** (`centeredBounds`:
  centered on the average location and reaching every item). The cells it draws hold every
  located row, so an aggregate of them tests every located row, as the order does: the world's
  cells read 64,718 pages, more than the order's 59,151. A read proportional to the stacks
  drawn exists only below the entry zoom, where Helsinki's rows already read 1,056 pages
  through the cell index (#766).
- **Pan and zoom read nothing today.** The cluster lane clusters the held located items for
  each viewport in memory (`MapClusterLane`, `@concurrent`). An aggregate per viewport would
  be a catalog read on every pan and zoom, each superseding the last.
- **SQL cannot give a stack's identity.** A stack is fronted by its first member in display
  order (any sort, a search's ranking included), counts what the scope shows after its
  stack and Live Photo rules and the one-copy rule, merges with any earlier stack within a
  cell of it in the order of their first members, and opens as exactly its members. Each of
  those needs the rows' order; the fit, the pan band and the fit check need every
  coordinate.

### The pages are the join, and an index of the located rows removes them

`idx_asset_metadata_location` (schema v63) holds the key and the coordinate of exactly the
located rows, partial on the same condition the Places scope tests. The join reads it and not
the table (`SEARCH asset_metadata USING COVERING INDEX idx_asset_metadata_location`), and the
order still walks the capture index with no temporary sort.

| read | before | after |
| --- | --- | --- |
| Places order, every stack held (the first paint) | 59,151 pages, 377 ms | 2,863 pages, 164 ms |
| Places order, no stacks held | 59,157 pages, 391 ms | 2,869 pages, 164 ms |
| Places order by name | — | 9,968 pages, 193 ms |
| Places' filter types | — | 9,451 pages, 85 ms |
| Places count | 64,718 pages, 178 ms | 9,451 pages, 49 ms |

"Before" is this catalog with the join by key; "after" the same catalog with the index. The
index is 712 pages (2.8 MB) for 50,000 located rows; on the reference catalog's 70,372 about 4 MB. First
paint reads 2,863 pages at the world's zoom and at a city's alike: the read does not depend on
the zoom, because the map clusters the held rows in memory. Nothing a user sees changes: the
same rows, order, stacks, counts and clicks, so `MapClusterPolicy` and its tests are untouched.

### Areas join through the same index

An area under the map joins through the same index too, with Places' located test first, so a
walk of the order rejects a row outside the box's latitudes in the index and reads the table
row — for the virtual place cells the area also tests — only for a row inside them. The seek
of a small area is unchanged.

| area (rows) | #779, decided (its own catalog of the same shape) | after, decided |
| --- | --- | --- |
| Helsinki (303) | 1,003 | 1,063 |
| Europe (20,296) | 63,640 | 3,473 |
| World (50,000) | 63,540 | 3,547 |
| Across the antimeridian (2,417) | — | 6,114 |

The #779 figures are from a catalog generated the same way with other random draws, so they
compare in shape, not to the page.

## Benchmarks

`projection.windowState.places` measures Places' window state on the benchmark catalog (every
still located). Instructions are in the PR's DoD report. Its metadata records are small, so its
pages fall less than the reference-shaped catalog's.

## Not established

- The reference catalog's 6.4 s cold read was on a machine under load 60–104; the share of it that was
  the join's pages is inferred from the generated catalog, whose All Media walk reads about
  what the reference catalog's does (#779), not measured on the reference catalog.
- Nothing was verified on the installed app after this change.
