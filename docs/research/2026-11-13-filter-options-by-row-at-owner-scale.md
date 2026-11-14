# Filter options by sidebar row, at owner scale (2026-11-13)

## Question

The filter popover's options (file types, countries and towns) move from one read over
every available source to one read over the shown sidebar row's scope (ADR 0011, ADR 0051).
What do those reads cost for every kind of row on the owner's catalog, and do any plans
scan?

## Method

An APFS clone of the owner's read-only catalog backup
(`build/catalog-backups/catalog-before-review-fixes.sqlite`, 166,554 photos, 32,161
located, 201 named cells, schema v42) in the session scratchpad, given v43's place-cell
columns and index and v45's language key by hand, with no `sqlite_stat1` (the app runs no
`ANALYZE`). A temporary test built each row's options reads with
`CatalogQueryGateway.distinctFilterableTypesQuery` and `placeOptionsQuery`, printed
`EXPLAIN QUERY PLAN`, and ran each three times. Fixed libraries 6, 7 and 15; card 10.
Milliseconds are warm runs on a loaded machine (other agents' checks in parallel).

## Results

| Row | Types ms | Places ms | Plan |
| --- | --- | --- | --- |
| Every source (the read replaced) | 456–582 | 137–159 | types by `idx_media_asset_stack_candidate`; places from `idx_place_cell_names` → `idx_asset_metadata_place_cell` → media_asset by key |
| All Media | 388–460 | 114–137 | same |
| A library (15, 147,024 items) | 360–406 | 95–119 | same |
| A library (7, 16,669 items) | 29–37 | 47–52 | same |
| A card (10) | 0 | 23–29 | same |
| Places | 500–660 | 163–228 | types add `asset_metadata` by key |
| On This Day, `NOT IN` exclusion | 53–84 | **8,945–12,272** | the left-out list re-read per place-cell row |
| On This Day, `NOT EXISTS` by key | 25–47 | 125–152 | `search_embedding` by its primary key |
| Duplicates | 667–680 | 457–486 | twin group read by `idx_media_asset_stack_candidate` |
| People | 532–912 | 205–281 | `face` by key |
| An import batch | 0 | 27 | `idx_media_asset_import_batch` |
| `SELECT DISTINCT language FROM place_cell` | — | — | `SCAN place_cell` (201 rows) |

No plan scans `media_asset`, `asset_metadata`, `face` or `search_embedding`.

## Conclusions

- Every row's reads are the scale of the every-source read they replace; a library's are
  cheaper.
- On This Day's exclusion was the one outlier: `(root, path) NOT IN (SELECT … FROM
  search_embedding WHERE <labels>)`, when the read starts from the place cells, cost 9–12 s.
  The correlated `NOT EXISTS` by the search row's key costs 0.13–0.15 s there and is
  cheaper in the media-driven reads too (types 25–47 ms against 53–84 ms). It replaces the
  `NOT IN` for every On This Day read, and v52 drops `idx_search_embedding_left_out`, which
  no read uses after it.
- The languages read scans `place_cell`, one row per named cell (201 for the owner).
