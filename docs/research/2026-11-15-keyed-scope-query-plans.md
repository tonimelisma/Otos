# Keyed scopes read their own rows (2026-11-15)

## Question

On 2026-11-15 the user imported 210 files (105 RAW+HEIF pairs and videos) from a card into
the Camera Roll library on a loaded machine. The sidebar's selection moved to the new batch
at 06:29:46, but the grid kept showing the card for 20 s (`ui.sidebarSelectionToPaint
ms=19941`), and every later publication of the batch took 6–35 s. Why?

## Evidence

The installed app's log (`script/logs.sh show`), `op=catalog.store.query.order phase=finish`:

| Scope | Rows | Stack candidates | Stack read | Whole read |
| --- | --- | --- | --- | --- |
| `library:/Volumes/CARD` (the card) | 210 | 198 | 1–7 ms | 5–21 ms |
| `importBatch:1794752981027` | 2 → 210 | 25,734–25,930 | 2.2–7.0 s | 6.4–35.3 s |

`waitMs` was 0 for the slow reads: the time was the read's own. The filter options of the
same batch read 5.5 s (`op=catalog.store.query.filterOptions`).

## Method

An online `.backup` of the installed app's catalog (166,971 rows; Camera Roll 16,895, the
Immich account 147,064), read with `sqlite3`, `EXPLAIN QUERY PLAN` and `.timer on`, first
(cold) runs. The scope is the window's: the three libraries, the visibility predicate and the
batch stamp.

| Read | Plan | Time |
| --- | --- | --- |
| Batch order, as shipped (`INDEXED BY idx_media_asset_best_capture_global_desc`) | `SCAN media_asset USING INDEX …global_desc` | 15.9 s (0.38 s CPU) |
| Batch order, by the batch's key | `SEARCH … idx_media_asset_import_batch`, temp B-tree for 210 rows | 20 ms |
| One group of identical copies, as shipped | `SCAN … global_desc` | 36.0 s |
| The same group by `idx_media_asset_content_sha1` | `SEARCH`, temp B-tree | 0.7 ms |
| Six stack members, as shipped | `SCAN … global_desc` | 0.60 s |
| The same members by the primary key | `SEARCH sqlite_autoindex_media_asset_1` | 10 ms |
| Batch place options, as shipped (`place_cell` `CROSS JOIN` first) | every named cell, then its rows | 21.6 s |
| Batch place options, batch rows first (`CROSS JOIN` from `media_asset`) | rows by key, metadata and cell by key | 20 ms |

## Conclusions

- The order read pinned the date-order index for every scope. That plan is right for a scope
  that spans whole libraries, where the index hands rows over in order and no sort is needed.
  For a scope named by a key it reads every row of the catalog to find a few hundred, and
  on a paging machine that is tens of seconds. The place options' fixed join order has the
  same fault. Both now take the scope's key index when the scope has one
  (`ScopeClause.keyIndex`), pinned by
  `CatalogStoreQueryPlanTests.keyedScopesSeekTheirOwnRowsInsteadOfWalkingTheOrder`. A
  benchmark case, `projection.windowState.importBatch`, measures the batch's publication.
- The batch's stack read still builds stacks over every library in the scope (25,930
  candidates, 2–7 s on the loaded machine, 0.12–1 s unloaded per
  `2026-11-14-reference-scale-query-plans.md`), as every combined scope's does. A batch's rows
  can stack with rows outside the batch in the same folder, so narrowing it is a separate
  question, not part of this fix.
- The selection moved before the sidebar drew the batch's row: the run names its batch as
  soon as the first item is in the catalog, and the row exists only once Projection
  publishes it. The selection now moves when an applied window state first carries the
  row (APP-002).
