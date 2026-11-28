# Every order the window asks for (plan 0116)

Date: 2026-11-17. The tour's "sort by name" step (All Media, Video filter, 20,325 items) took
1,075 ms on the reference library against a 1,000 ms target, and 239–1,154 ms in other tours:
fast with the file's pages in the OS cache, slow without. The Store's read counter rose 88 MB
across that one order read. This note lists every order the window can ask for, what each
read, why, and what v76 changed. No benchmark was run.

## Method

- **Generated catalog.** `OrderReadSurveyTests` (`OTOS_SCALE_TEST=1 script/check.sh --only
  OrderReadSurveyTests`) makes the reference-shaped catalog (`ReferenceShapedCatalog`, scale 1:
  166,990 assets, 2.3 GB) and reads, for each sort (date newest and oldest, name A–Z and
  Z–A, size largest and smallest, likeness both ways under a person) × each scope kind (All
  Media; All Media with a library offline; one library, the account and library 7; Places; a
  map area; People; a person; an import batch; Duplicates; one duplicate group; a stack's
  members; On This Day) × each filter the window offers (none; Video; Images; RAW; Images and
  RAW; one file type, HEIF; Liked; Not Rated; a person; Unidentified Faces; a country; Video
  and Liked): 889 reads. Each read runs on a fresh connection with no memory map and a cache
  larger than its working set, so `SQLITE_DBSTATUS_CACHE_MISS` is the distinct pages it read
  from the file; the plan is `EXPLAIN QUERY PLAN`, the rows each loop visited
  `SQLITE_SCANSTAT_NVISIT`. Its SQL, arguments written in, goes to `build/order-survey/sql/`.
- **The reference catalog** (schema v75, 167,268 assets), opened only while Otos was not
  running, with `sqlite3 -readonly "file:…?mode=ro"`, the same pages count (`.stats`, cache
  1 GB, `mmap_size=0`) for the wide scopes' 270 reads that take no library-specific argument.
  "Cold" is the file's pages dropped from the buffer cache first (`msync(MS_INVALIDATE)` on
  a read-only mapping; `mincore` then reported 0 of 132,225 pages resident). The reference
  catalog was read, never written, copied or migrated; the "after" reads there are the new
  SQL against its v75 indexes, which is the whole change for the name, size and date orders
  under no filter or a kind filter. A file-type, Not Rated or place filter needs v76's indexes,
  so its "after" is the generated catalog's.

## 1. What every order read, before

On the reference catalog, All Media (roots 6, 7, 15), pages read; warm time in ms:

| Filter | Date, newest | Name, A–Z | Size, largest |
| --- | --- | --- | --- |
| none | 3,610 | 31,929 | 29,292 |
| Video | 3,610 | 20,317 | 17,680 |
| Images | 3,610 | 31,908 | 29,271 |
| RAW | 3,610 | 17,228 | 14,591 |
| HEIF | 29,247 | 31,908 | 29,271 |
| Not Rated | 29,268 | 31,929 | 29,292 |
| Liked | 19 | 19 | 19 |
| Unidentified Faces | 9,746 | 18,690 | 16,053 |

The account alone, library 7, Places and People read alike, scaled by their rows. Three causes,
each shown in the plans and the page counts:

1. **The name and size orders read every returned row's table row.** The order read selected
   `best_capture_local` under every order, for the day buckets and a keyed re-read, which use
   it only under a date order. Only the date indexes hold it, so the name and size walks read
   each returned row's 2 KB table row: 20,317 pages for the 20,325 videos by name, 980 and
   922 ms cold, where the same walk without it reads 6,271 pages, 82 and 81 ms cold.
2. **A file-type filter and a Not Rated filter read every walked row's table row.** No order
   index held `best_format` or `media_choice`, so `(best_kind = ? AND best_format = ?)` and
   `media_choice IN (…)` were tested from the table row of every row the walk reached:
   29,247 pages for All Media by date under HEIF, 1,074–1,111 ms cold. Liked alone does not:
   it seeks `idx_media_asset_chosen` and sorts the few chosen rows.
3. **A Places filter read every walked row's metadata table row.** The filter joined
   `place_cell` by `asset_metadata.place_cell_latitude`, a virtual column, which SQLite
   computes from the table row (it never serves a virtual column from an index): 54,822–
   81,355 pages on the generated catalog.

No wide scope's order sorts in a temporary b-tree; every wide read walks its order index in
order. The narrow scopes (a person of a few hundred photos, a batch, a duplicate group, a
stack, a small area, On This Day's day, a Liked filter) seek their rows through the index
that names them and sort what they find: 3–1,600 pages, every one of them proportional to
the rows they return.

## 2. What v76 changed

- **The order read selects the capture time only under a date order**
  (`CatalogQueryGateway.orderedAssetIDQuery`), NULL in its place otherwise. Nothing else
  reads it under another order: the day buckets group only under the date order, and the
  keyed re-read (`orderedAssetIDs(ofRows:…)`) answers only date orders.
- **The twelve order indexes also carry `best_format` and `media_choice`** (v76), after the
  columns v55/v64/v69 gave them, so every filter the window offers but people and places is
  tested from the index entry.
- **The Places filter finds a walked row's cell from its coordinate in
  `idx_asset_metadata_location`**, computing the cell with the expression the generated
  columns are (`PlaceCellSQL.cell`), the way the filter's options already did.

After, on the generated catalog, All Media (pages):

| Filter | Date, newest | Name, A–Z | Size, largest |
| --- | --- | --- | --- |
| none | 6,370 → 7,595 | 29,237 → 6,952 | 26,283 → 4,250 |
| Video | 6,370 → 7,595 | 8,983 → 6,952 | 6,029 → 4,250 |
| HEIF | 24,369 → 7,595 | 24,479 → 6,952 | 21,525 → 4,250 |
| Not Rated | 29,127 → 7,595 | 29,237 → 6,952 | 26,283 → 4,250 |
| a country | 54,822 → 9,931 | 74,157 → 9,288 | 71,203 → 6,586 |
| Unidentified Faces | 12,065 → 13,290 | 15,351 → 12,647 | 12,397 → 9,945 |
| Liked | 74 → 74 | 74 → 74 | 74 → 74 |

(The generated catalog's descending indexes are written row by row as the generator inserts, so
they are less full than the reference catalog's, which `CREATE INDEX` built: the ascending date index reads
3,547 → 4,210 pages, and the reference catalog's v75 date index 3,610.) Every wide read's pages are now the
pages of its order index, plus the location index for Places and a country, plus the face index
for a person or Unidentified Faces. The date order reads more than before by the width of the
two columns.

On the reference catalog, the change the new SQL makes on its v75 indexes, cold (two runs):

| Read | Before | After |
| --- | --- | --- |
| All Media, Video, name A–Z (the tour's step) | 20,317 pages, 980 / 922 ms | 6,271 pages, 82 / 81 ms |
| All Media, name A–Z | 31,929 pages, 1,298 / 1,206 ms | 6,271 pages, 133 / 143 ms |
| All Media, size largest | 29,292 pages, 1,315 / 1,371 ms | 3,634 pages, 136 / 134 ms |
| All Media, HEIF, date newest | 29,247 pages, 1,111 / 1,074 ms | v76: the date index's pages (generated: 24,369 → 7,595) |
| All Media, Not Rated, name A–Z | 31,929 pages, 1,243 / 1,215 ms | v76: the name index's pages (generated: 29,237 → 6,952) |
| People, Not Rated, name A–Z | 33,460 pages, 1,298 / 1,984 ms | v76: the name index's pages and the face index's |

v76 widens each order index by about 2.4–2.6 MB, so on the reference catalog the name walk will
read about 10 % more than the 6,271 pages above.

## 3. The index set, as a blank slate would build it

The orders the product has are six (`MediaSortOrder`: date, name and size, each both ways)
and likeness, which walks a date index and reads each photo's face of the person. Each is
answered by one index walked in order, in two forms: a global one led by the order's key
for a scope of several roots, and a root-local one led by the root for a scope of one. Each
carries, after the key, the row's identity (root, path: the tie order, "sort tie order
unchanged") and every column a window read tests a row by. Two forms per direction remain,
because the ties stay ascending under a descending key: a descending walk of an ascending
index would reverse them.

The name order's key is `name_sort_key`, written by the scan in the row's own write
(`ScanFactValues.nameSortKey`): `MediaSortKey.naturalKey` of the file name — lowercased by
Swift's full Unicode lowercasing, every digit run of fewer than 19 digits zero-padded to 19,
no diacritic or width folding, compared by SQLite as bytes. It is already the folded,
indexable key, kept with the name by one owner; v76 keeps it and the visible order byte for
byte (`OrderReadDifferentialTests`). It is not v71's dropped `sort_key`, a key of the whole
path, root included, 84 MB, which only the stacks read.

Rejected:

- **Indexes led by the kind** (`best_kind, key, root, path, …`), so a kind filter reads pages in
  proportion to the rows it returns rather than to the scope: a filter of two kinds is then two
  ranges SQLite can only merge by sorting, and no filter at all reads every kind's range out of
  order, so the twelve indexes would each need a kind-led twin — 24 indexes, about 230 MB more
  on the reference catalog, and twelve more index entries written with every row — to save the
  walk of an index that the reference catalog reads in 82 ms cold.
- **A shorter name key** (a digit run's length as one character instead of zero padding, about
  10 MB less over four indexes): its order would differ from the padded key's wherever a run is
  19 digits or longer or holds non-ASCII digits, so it could not keep the visible order byte for
  byte, and changing it rewrites every row's key.
- **A covering index for the Places filter or a person filter**: the location index and the
  person's face index are what the per-row test reads now, index pages only.

## 4. The migration and what it costs

v76 drops each of the twelve order indexes and makes it again with the two columns after the
ones it held. On the generated reference-shaped catalog (`CatalogMigrationCostTests`): 3,593–3,805
ms over three runs, 229,175,032 bytes of write-ahead log (the twelve indexes, 227.8 MB, written
once), the file's size unchanged (2,317,328,384 bytes: the old indexes' pages are reused) and no
compaction owed. The time is the twelve index builds, each a scan and sort of the 166,990 rows;
the log is the twelve indexes written once. The reference catalog's file is fragmented on disk, so its migration will
be slower.

| Index | Before | After |
| --- | --- | --- |
| each date index | 12.8 MB | 15.2 MB |
| each name index | 23.8 MB | 26.4 MB |
| each size index | 12.9 MB | 15.2–15.3 MB |
| the twelve | 198.2 MB | 227.8 MB |

What one row's write logs, before and after (bytes of write-ahead log): a Like 12,392 → 61,832,
a format correction 8,272 → 57,712, a scanned file's insert 391,432 → 358,472 and its removal
123,632 → 111,272 (an insert and a removal write every order index before and after, and their
page splits vary). A Like or a format correction now moves the row's entry in all twelve order
indexes, as a capture date, a size or a rename always did.

## 5. What is left

- Unidentified Faces and a person filter test each walked row with one seek of the face
  index: 9,900–13,300 and 4,200–7,600 pages on the generated catalog, the order index's and
  the face index's.
- A narrow scope sorts the rows it seeks in a temporary b-tree, by design: its rows are a few
  hundred or thousand.
- The order-read and scan-write benchmark cases may move: not measured until the next daily
  run.
