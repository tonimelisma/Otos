# A person's photos in order (v78)

Date: 2026-11-17. The tour's "first person" step (the most photographed person, 16,115 items
after stacks) took 1,555 ms on the reference library against a 1,000 ms target, under memory
pressure; eleven other tours took 343–609 ms. The order read logged `orderSqlMs=1361`, and its
reach decision (`op=catalog.query.reach … reach=walk`) was logged 1.2 s after the read began:
the two counts that decide whether a person seeks or walks, and the walk itself, read pages in
proportion to the catalog, not to the person. This note measures every narrow scope at its
largest on the reference library, the person's reads before and after v78, and what v78 costs.
No benchmark was run.

## Method

- **The reference catalog** (v77, 167,253 assets, 103,149 faces, 745 people), opened only while
  no Otos ran, with `sqlite3`'s library read-only (`file:…?mode=ro`, `mmap_size=0`, a cache
  larger than any read), so `SQLITE_DBSTATUS_CACHE_MISS` counts the distinct pages a read takes
  from the file. "Cold" is the file's pages dropped from the buffer cache first
  (`msync(MS_INVALIDATE)` on a read-only mapping; `mincore` then reported none resident). The
  reads are the gateway's SQL with its arguments written in, made on an empty catalog (a sized
  seek walks there) or one with rows (it seeks), with the reference catalog's largest batch, day, area and
  stack put in. Nothing was written, copied or migrated.
- **The generated catalog** (`ReferenceShapedCatalog`, scale 1), now shaped like the reference catalog's people:
  its eight people of 1,203–17,285 faces and 57, 303 and 377 of about 300, 28 and 5; one face in
  ten no one's; 64,756 stills and 10,343 videos holding 87,476 and 15,673 faces, several on one
  photo as often as on the reference (it gave every person about 130 faces, one a photo, before). Each
  read was made on a fresh cold connection as above. v78 cannot be emulated read-only on the
  reference catalog (it is a table), so every "after" is the generated catalog's.

## 1. The narrow scopes at their largest on the reference library

Cold, the order read as the app chooses it (seek or walk), the reference v77 catalog:

| Scope (largest) | Rows | Pages | ms | Reads |
| --- | --- | --- | --- | --- |
| All Media (for scale) | 164,981 | 4,173 | 56 | the date index |
| A person (17,285 faces) | 17,266 | 4,520 + 3,056 to decide | 159 + 20 | the whole date index, a face seek a row |
| An import batch (1,374) | 1,374 | 226 | 5 | the batch index, sorted |
| On This Day (31 December, the largest day) | 3,665 | 9,522 | 640 | the day index, each row's table row and search embedding |
| A map area (1°, 45,568 located) | 45,568 | 5,768 | 229 | walks: the date and location indexes |
| Places | 75,922 | 5,768 | 202 | the date and location indexes |
| A map stack (the same 45,568) | 45,568 | 25,129 | 532 | each member's table row, sorted |
| Duplicates (62) | 62 | 363 | 29 | the digest index |
| Liked (21) / Disliked (3) | 21 / 3 | 1 / 1 | 0 | the chosen rows' index |
| Unidentified Faces (filter, 7,475) | 7,475 | 10,343 | 446 | the date index, a face table row a row |
| A person filter on All Media | 17,266 | 4,521 | 155 | the date index, a face seek a row |

Only the person scope read in proportion to the catalog: it walks every row of the date index
whatever the person's size, and a person past the seek's bound (`SeekSize.personRatio`, 40
walked rows per face) is decided by first counting the person's faces (293 pages) and the
catalog's rows (2,763 pages of `idx_media_asset_relative_path_key`). Its seek, for a person
under the bound, reads each photo's 2 KB table row by key: 15,305 pages and 627 ms for the same
person forced to seek, 5,255 pages for one of 3,420. The others read pages in proportion to
their rows:

- an import batch, a duplicate group, Liked and Disliked through the index that names them —
  few rows, bounded by what an import, a set of identical files or the user's choices hold;
- a map area and Places walk the order when the area holds a large share of the located rows
  (`SeekSize.areaRatio`), which is then the pages of the order and location indexes;
- On This Day's largest day reads 2.6 pages a row, each row's table row and its search
  embedding (the screenshot-and-document exclusion, `OnThisDayPicks.exclusionSQL`), bounded by
  the photos of one calendar day;
- a map stack reads 0.55 pages a member, bounded by the located photos the cluster holds.

Unidentified Faces and a person filter are filters of a wide scope: they walk its order and test
each row with a face lookup. They are left as they are (section 5).

## 2. What the person's reads cost, and why

On the reference catalog, person 1, cold:

| Sort | Rows | Walk (the app's plan) | Seek, forced |
| --- | --- | --- | --- |
| date | 17,266 | 4,520 pages, 159 ms | 15,305 pages, 627 ms |
| name | 17,266 | 7,174 pages, 185 ms | — |
| size | 17,266 | 4,524 pages, 162 ms | — |
| likeness | 17,266 | 8,684 pages, 346 ms (and sorts) | — |

Plus the decision's two counts, 3,056 pages, before every read. The tour's 1,361 ms of SQL is
these pages under memory pressure and a load of ~40: 90 MB were read from disk in that step,
and the decision alone took 1.2 s of it. `stacks=read:55` is the walk's stacks: a walked scope
judges its rows by every stack of its roots, read from `idx_media_asset_stack_candidate` (15,055
candidates, 55 ms) and decided by the rule (79 ms).

## 3. The design

A person's photos are a fact the faces hold; what the window orders and tests a photo by is a
fact `media_asset` holds. An index walk proportional to a person's photos needs the two in one
structure. v78 makes `person_photo`, one row per person and photo holding a face of theirs that
is a face, with the photo's order keys and tested columns under `media_asset`'s names, keyed by
person: a person's rows are one range of the table's key. Triggers keep it in the write that
changes a face's person or not-a-face mark, or a copied column of the photo; foreign keys carry
a move and purge it with the photo or the person. A photo the person is in only through a
copy (ADR 0054) is found at read time from the person's photos that have copies
(`idx_person_photo_copies`). The order read is one compound select of the two, which SQLite
merges in order; the person's own arm sorts its rows.

A prototype of each design written into the generated catalog by hand before the migration, cold (person 1: 17,284 photos; 5: 6,819; 100: 30; 700: 5; section 4 has v78's own read):

| Person | Sort | v77 walk | v78, one table (chosen) | v78, an index per order |
| --- | --- | --- | --- | --- |
| 1 | date | 7,881 pages, 907 ms | 798, 15 | 3,915, 93 |
| 1 | name | 7,238, 897 | 798, 13 | 4,187, 95 |
| 1 | size | 4,536, 532 | 798, 17 | 3,912, 155 |
| 1 | likeness | — | 1,070, 59 | — |
| 5 | date | 7,716, 876 | 319, 8 | 2,969, 78 |
| 100 | date | 7,598, 883 | 5, 1 | 58, 6 |
| 700 | date | 7,598, 857 | 4, 1 | 16, 2 |

Rejected:

- **An index per order over the rows** (six: date, name and size each way), so no read sorts:
  79 MB against the table's 23 MB, every assignment and choice moving six more entries, and it
  read five times the pages — a row's virtual `parent_path` (the Live Photo rule) and its digest
  (the shown-copy rule) are not in an index, so SQLite went to the table for rows of the walk.
  Sorting the person's rows costs a few milliseconds: 15 ms with the read for 17,284.
- **The order indexes extended so a person is a semi-join**: what v77 did; it reads the whole
  index for any person.
- **A table People writes from its snapshot** (like `person_summary`): it would lag every
  rename, choice and Trash until the next pass, and the order must be exact in every snapshot.
- **Copy membership in the table**: it would make the table a second owner of the copies rule
  (ADR 0054), maintained on every digest and presence change.
- **Likeness in the table**: People writes likenesses for thousands of faces each pass; the
  likeness order reads them from `idx_face_person_photo`, now carrying each face's index and
  likeness (1,070 pages for person 1).

## 4. The migration and the write cost

On the generated reference-shaped catalog (`CatalogMigrationCostTests`, one run): 1,155 ms and
28,967,752 bytes of write-ahead log; the file's size unchanged (2,340,237,312 bytes; the free
pages it had held the new trees) and no compaction owed. `person_photo` holds 92,631 rows in
17.3 MB, `idx_person_photo_photo` 5.4 MB, `idx_person_photo_copies` one page, and
`idx_face_person_photo` grows from 5.8 to 6.0 MB with each face's index and likeness. The time is
the join of every assigned face to its photo, written in key order, then the two indexes and the
face index made again; the log is those trees written once. The reference file is fragmented on
disk, so its migration will be slower.

What People's writes cost, on the same catalog: the most photographed person's 17,284 faces given
to the second person and back, each page its own transaction, as a pass writes guesses:

| | Faces a page | Pages | Most log a page | All of it | Time |
| --- | --- | --- | --- | --- | --- |
| v77 | 256 | 136 | 3.3 MB | 359 MB | 4,291 ms |
| v78 | 85 | 408 | 2.9 MB | 945 MB | 12,591 ms |

A face's reassignment now also takes its photo out of one person's rows and puts it in the
other's: 0.36 ms and 27 KB of log a face against 0.12 ms and 10 KB. A page holds as many faces
as fit in 256 changed rows, the triggers' rows counted (`AssignmentWrite.mostRows`: a guess or
a seed three, a lapse two, a likeness one), so no transaction grows — the largest page's log is
smaller than before — and `PeopleStoreTests/noPeopleWriteTransactionChangesMoreThanAPage`
holds. A pass that reassigns every one of the reference catalog's 103,149 faces would take about 37 s of
writer time in 1,200 transactions, against about 13 s in 400; a pass writes only the faces whose
guess moved. A likeness write changes no row of `person_photo`. A Like on a photo of the person
logs 78 KB against 70 KB; a scanned file's insert and removal are unchanged.

The person's order after v78, the same generated catalog, cold: 803 pages for every date, name
and size order of the 17,284 photos (92–98 ms with other checks building on the machine; 10–14
ms with the file's pages in the OS cache), visiting 1.00 rows a row returned; the likeness order
1,109 pages (139 ms), visiting the person's row and two face index entries a row.

The order's stacks. A sought scope built only its own rows' stacks; for the person's 17,284
photos that read about every candidate of the roots and cost more than reading every stack
(warm: 284 ms against 186; cold: 715 against 204). The crossing is at about 2,000 rows (174
against 177 ms at 1,856; 193 against 172 at 3,424; 27 against 173 at 30), so a sought order of
more than 2,000 rows builds every stack of its roots (`PhotoStackSQL.rowsSpanMostRows`), as a
walked one does. This also moves On This Day's largest day and a large map stack to every stack
of their roots.

## 5. What is left

- Unidentified Faces and a person filter on a wide scope walk its order with a face lookup a row
  (10,343 and 4,521 pages on the reference catalog).
- On This Day's largest day reads each row's table row and search embedding for its exclusion.
- A large map stack reads each member's table row.
- The count and the filter's options of a person still find the person's photos from their
  faces (`SeekSize`): only the order read is first paint.
- The people.* and order-read benchmark cases may move: not measured until the next daily run.
