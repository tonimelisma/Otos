# The window's reads under enrichment, and launch to the first grid (2026-11-14)

## Question

While background enrichment (faces, Immich metadata) writes to the owner's catalog, the
installed app rebuilt the whole window state back to back, each pass 5–7 s at over 300%
CPU. Launch took 8.7 s to the first grid on a quiet machine and 14.5 s on a loaded one.
Which Store changes woke a full rebuild, what does each of the window's reads depend on,
why does each read cost what it does at 166k assets, and what sits between launch and
the first grid?

## Method

- The installed app's unified log, three hours on 2026-11-14 (revision 3a2c022f, 166,555
  assets, 147,024 shown in All Media): every `catalog.projection.window`,
  `catalog.store.query.order`, `catalog.store.query.filterOptions`, `projection.stacks`
  and `catalog.enrichment.batch` line.
- A copy of the owner's catalog (`build/catalog-backups/catalog-v51-before-second-fixes.sqlite`,
  2.3 GB, 166,555 rows) in the worktree's `build/`, never committed and deleted after:
  `EXPLAIN QUERY PLAN` and `.timer on` in `sqlite3` 3.54 for each read and each launch
  write, before and after the indexes below.
- A temporary test (not committed) that opened a copy of that catalog with `CatalogStore`,
  loaded it with a `CatalogProjection` subscribed, waited for the first published grid,
  then wrote three capture dates and one pair of copies kept together and timed each pass,
  run once on the parent commit and once on this change. The machine ran three other
  agents' builds and tests throughout (load average around 38), so wall times are
  several-fold what a quiet machine shows; the ratios and the read counts are the result.

## Findings

### What woke a full rebuild

- 933 passes in three hours: 642 read the order again, 930 read the filter's options, 930
  collapsed the stacks. 368 of the 642 order reads returned the identities the window
  already showed (`mediaIdentityChanged=false`), and 43 more changed only the options;
  those 368 passes alone summed to 7,243 s of pass time.
- 6,460 enrichment batches, 5,866 of them one Immich still or video whose bytes were read
  for the first time (`namingChanged=1`). Before its read an Immich row sorts by
  `created_at_unix + assumed_utc_offset_seconds`, which carries Immich's milliseconds
  (e.g. 1789253787.353); after it, by the wall clock read from the bytes, whole seconds
  (1789228587.0, the same second). The stored `best_capture_local` moves by a fraction of a
  second, so `structureChanged` was true and the batch was a `.catalogChanged`: the full
  rebuild, order, options and collapse, for a photo that almost never moves.
- 139 `people.applyAssignment` writes and 36 place-name writes, each `.catalogChanged`:
  a full rebuild for facts the All Media order and its file types do not read.
- The only distinction the projection had was detail-only versus structural, and every
  other write was structural.

### Why All Media's order changes this often

195 of the 642 order reads in the three hours did return a new order, and the grid's own
log counted 524 of 530 applies in six hours as reorders. On the catalog copy (taken before
those hours), the Immich account held 101,737 stills and 14,326 videos whose bytes had not
been read:

- An unread Immich still sorts by Immich's own date with milliseconds plus an assumed
  offset; its read replaces that by the wall clock in whole seconds. Of the 16,041 read
  stills whose unread value can be recomputed, the read's value equals it for 14,614,
  differs by under a second for 300 and by a second or more for 1,127. A fraction of a
  second reorders a photo only against another taken in the same second.
- (Corrected in `docs/research/2026-11-14-whole-second-capture-time.md`: no unread Immich
  video in this copy or a later one has a NULL offset or a NULL `best_capture_local`; each
  sorts by the server's date in an assumed offset, and a read moves it only when the bytes'
  wall clock is in another zone.)
- A read that finds a Live Photo's content identifier pairs a movie with its still, and
  the movie leaves the order (`LivePhotoSQL.isPairedMotion`).

The first's sub-second part is removed by v56 (whole seconds in both readings). The first and third are real changes of what the
order holds, and with this change each costs an order read (0.08–0.10 s of SQL on the copy)
but no options read unless a kind or a location changed with it.

### What each read depends on

- Order (`CatalogStore.orderedAssetIDs`, with its stacks in the same transaction): which
  rows are shown (trash, attachment, source hiding, roots, availability), the sort keys
  (capture date; name and size change only through a scan), kind and format (the filter;
  which movies a Live Photo hides), the Live Photo and burst identifiers, the user's choices
  and stack keys (the choices filter, On This Day's order, a stack's shown file); location
  and place names only for the Places scopes and the Places filter; faces only for People,
  a person, the People filter and the likeness sort; digests only for Duplicates; On This
  Day's labels only there.
- Filter options (`CatalogStore.filterOptions`): rows shown in the sidebar row, kinds and
  formats, Live Photo grouping, locations and place names; faces, digests and On This Day's
  inputs for those rows.
- Stack collapse: a pure function of the scoped order, its stacks and the expansions.

### Why one order read cost 2–4 s

`EXPLAIN QUERY PLAN` for the All Media order is `SCAN media_asset USING INDEX
idx_media_asset_best_capture_global_desc`, with no temporary sort: the plan was right. But
the index held `(best_capture_local, library_root_id, relative_path)` and the read tests
every row for `pending_trash_batch_unix_ms`, `awaiting_presence`, `hidden_by_source`,
`best_kind` and `content_identifier`, so each of the 164k rows cost a read of its table row.
`media_asset` is 542 MB for 166,555 rows (about 3.3 KB a row, one row a 4 KB page), so the
read was one random page read per row: 12.9–34.1 s real against 0.5–0.8 s of CPU on the
copy, cold and under load; the installed app's warmer cache showed 2–4 s. The filter's
types read had the same shape through `idx_media_asset_stack_candidate` (18.5 s on the
copy), and the import batches' read, made every pass, through `idx_media_asset_import_batch`
(11,191 rows).

With the tested columns added to those indexes (v55), the same reads on the same copy:

| Read | Before | After |
| --- | --- | --- |
| All Media order, 164,482 rows | 12.9–34.1 s | 0.076–0.100 s |
| Filter types, All Media | 18.5 s | 0.33–0.35 s |
| Stack candidates, 25,696 rows | — | 0.99–3.1 s (its stills' join reads their rows; it is answered from the last pass unless a fact it depends on moved) |

`EXPLAIN QUERY PLAN` does not say `COVERING` for these indexes, because `best_capture_local`
and `parent_path` are generated columns; the bytecode defers the table seek and the timings
show it is not taken for rows the index's columns reject.

### What sat between launch and the first grid

`performInitialLoad` ran, in order: the roots' read, `SELECT COUNT(*) FROM media_asset` (only
logged), and two writes that walked the whole table for the few rows they change:
`UPDATE … SET enrichment_claimed = NULL WHERE enrichment_claimed IS NOT NULL` (8.9 s cold on
the copy, `SCAN media_asset`) and `UPDATE … WHERE edit_revision <> rendered_revision` (15.2 s
cold). Both matched no row on the owner's catalog. The undecodable and awaiting-presence
writes already went through partial indexes. In the installed app's quiet launch these
steps were the 4.2 s between `op=mediaOperation.recover phase=start` and
`op=catalog.enrichment.claims phase=startupClear`; the first publication then read the
order (2.4 s) and, after it, the options (0.73 s). With a partial index of exactly the rows
each write changes (v55): 1.6 ms and 0.3 ms. The count is gone.

Which steps must come before the first grid: clearing the awaiting-presence marks (a marked
row is hidden from every read) and deleting the settled remap batches (the order read
carries the pending ones). Clearing abandoned claims, releasing unrendered edits and
releasing undecodable stills are owed only before enrichment claims; each now costs
milliseconds, so the load keeps them rather than adding a second phase.

The first window state, published with `emptyState=noMedia` beside 157,971 items, is not an
empty state shown: `CatalogWindowPolicy.mediaEmptyState` answers `.noMedia` whenever the
scope holds items, and `MediaGridView` draws an empty state only for an empty grid.

## Measured on the owner-scale copy, parent commit against this change

The temporary test, one run on each tree under the same kind of load (other agents'
builds and tests). 147,024 items shown (the copy's OneDrive roots are not reachable from a
test, so All Media is the Immich account). Each launch reopens the migrated copy.

| | Parent (3a2c022f) | This change |
| --- | --- | --- |
| Catalog load (`store.start`), launch 1, 2 | 97.8 s, 107.0 s | 0.094 s, 0.011 s |
| Launch to first grid, launch 1, 2 | 177.4 s, 274.6 s | 3.9 s, 2.7 s |
| Pass after a capture date read from bytes (three writes) | 55.0, 85.8, 78.8 s; 1 order read, 1 options read each | 3.1, 8.5, 7.8 s; 1 order read each, options read only where the write also cleared a location (two of three: `facts=captureDate,grouping,location,…`) |
| Pass after copies kept together | 75.9 s; 1 order read, 1 options read | 0.45 s; no order read, no options read |

The first pass after the change, in the log (`catalog.projection.window`): order read
2.2 s of which the stack candidates' read 1.0 s, options read 2.2 s beside it, 3.8 s in all;
the pass after copies kept together `reused=order,filterOptions,collapse`, 0.42 s. Inside the
order read the SQL itself is 0.08–0.10 s on the copy; the rest is the stack candidates'
read (0.2–3.3 s under load: its stills' join reads each candidate's table row) and mapping
the rows, which now map as the cursor reaches them rather than after a copy of every row.

The migration costs one launch once: opening the copy ran v52, v53 and these indexes in 67 s under load — v53
16 s by its own log line, the rest v52's index drop and the eight indexes over 166,555
rows (one such index took 15.6 s to build cold in `sqlite3`). The
copy's whole migration and first load took 468 s, 401 s of it the test-only renaming of the
copy's staging roots to the test's own folder, which the installed app does not do.

## Conclusions

- A read is repeated only when a change that can alter its answer happened: each Store
  change names the kinds of fact it touched (`CatalogChangedFacts`) and the projection keeps
  each read's last answer with the revisions it started from (ADR 0005).
- The window's reads test rows in their indexes, and the launch's maintenance writes find
  their rows by partial indexes (v55).
- `op=launch.firstGrid` logs launch to the first applied loaded state with its parts, and
  `op=catalog.start phase=finish` logs each load step.
