# A narrow `media_asset` (2026-11-16)

## Question

Plan 0116 bet 8: the reads that test rows outside a covering index read about 150k pages of
`media_asset` on the owner's catalog. What makes the row wide, what can leave it, and what
does a rebuilt table cost and buy?

## Method

- **A read-only design study on the owner's catalog** (schema v68, 167,215 assets), opened
  `mode=ro` while no Otos ran: `dbstat` page counts, column byte sums, and page counts of the
  window's reads against an emulated narrow table built in a scratch file of generated rows.
- **A read-only check of the product names**: every stored `thumbnail_path`, `preview_path`
  and `face_frames_path` compared with the name `ThumbnailStore` derives from the row's
  identity (SHA-256 of the root path and the relative path), in a scratch script outside the
  repository that wrote nothing.
- **Code reading** of every writer and reader of each column that could leave the row.
- **The migration and the reads measured on a generated catalog of the owner's shape**
  (`OwnerShapedCatalog`, scale 1): `CatalogMigrationCostTests`, which puts the generated
  catalog back to v70, counts each read's pages on a cold connection (no memory map, a cache
  that holds every page, `SQLITE_DBSTATUS_CACHE_MISS`), migrates it, and counts them again.

No benchmark was run.

## The owner's catalog (v68)

| | Value |
| --- | --- |
| File | 2,814 MB, 98,827 free pages (386 MB) |
| `media_asset` | 545 MB: 139,473 leaf pages 60 % full, 326 MB of payload, about 2 KB a row |
| Its 41 indexes | 346 MB |
| `search_embedding` | 649 MB |
| `face_embedding` | 403 MB (51 % full) |
| `asset_metadata` | 190 MB |

Bytes by column of `media_asset`:

| Column | MB | Note |
| --- | --- | --- |
| `render_gray` | 147.9 | 884 B a row: Duplicates' 32 × 32 gray render |
| `sort_key` | 84.1 | a pure function of the root path and the relative path |
| `render_signature_source` | 14.0 | the thumbnail identity a signature was read from, as text |
| `name_sort_key` | 11.1 | |
| `thumbnail_path`, `preview_path`, `face_frames_path` | 11.3, 10.0, 0.8 | |
| `relative_path_key`, `relative_path` | 9.2, 9.2 | |
| `source_item_id`, `source_path_sha1` | 5.3, 3.0 | |
| `name`, `content_type_identifier` | 3.6, 2.2 | |
| the stamps | about 10 | |
| everything else | about 15 | |

`edit_recipe_json`, `trash_path`, `burst_identifier`, `pending_trash_batch_unix_ms`,
`shown_copy_root_id` and `media_choice_sequence` were NULL in every row; `content_sha1` in
96.6 %.

Reads that leave a covering index touched about 148k–152k table pages: the choices filter and
the filter options 148,264, People's face-to-asset join 79,171 (7.5–7.9 s cold), the stack
candidates 13,050. Against the emulated narrow table: the choices filter 1,850–5,290 pages,
People's join 6,286, the stack candidates 3,669. The default date order reads only its
covering index (3,584 pages) and does not change.

## Product names are stored facts

All 166,630 stored thumbnail names, 144,452 preview names and 10,336 face-frame names equal
the name derived from the row's identity; none differs. They still cannot become derived:

- A respell, a move witnessed outside Otos and a reorganization take a row to a new key and
  keep its names, so no product file moves in a re-key. Deriving the names would move every
  product file of every re-keyed row outside the write that re-keys it.
- The derived-file lifecycle names the files a row holds by these columns.
- The search embedding, text reading and description stamps embed the names
  (`StoredThumbnailSQL.identity`): 16.6 MB, 10.1 MB and 1.4 MB of stamps over 165,670,
  59,532 and 5,849 rows. A derived name would make every one of them stale, or need the
  migration to rewrite them, the 649 MB embedding table among them.

## What leaves the row

| Column | Where | Why |
| --- | --- | --- |
| `render_gray` | `render_signature`, one row per signed still | only Duplicates reads it, to confirm a proposed pair |
| `render_signature_source` | `render_signature_read`, a flag, and the trigger `media_asset_render_signature_stale` | the trigger clears the signature in the write that changes the thumbnail's identity, which the string's comparison did at each read |
| `sort_key` | gone | only the stacks read it, to order a stack's files; they share a root, so the path's own natural key orders them the same |

Everything else stays, the names included. `name_sort_key` must: v69 made the name order
indexes carry the columns the window tests rows by, and an index can hold only its own
table's columns. A second table for the name, the path key, the content type and the import
provenance (about 15 MB) would add a write to every scanned insert and rename and a join to
every read of a name.

The table keeps its row id, and its rows are copied in key order, so a folder's rows sit
together. A first build without a row id (as the study proposed) changed three plans the
plan tests pin: with no statistics, SQLite's planner priced a lookup by key from an index
that does not cover the read above a walk of the key's range, so the filter's types, the
owed faces and a mirror's pairing left their partial indexes to walk a whole root. Pinning
each with `INDEXED BY` would leave every unpinned read open to the same choice; a table with a
row id keeps every plan as it was, for the 12 MB of its key index.

## The migration (v71)

SQLite's twelve steps: the rows copied into a new table in key order, the gray copied into
`render_signature`, the old table dropped and the new renamed, the indexes made over the rows
from their own definitions (the two that named the string stamp replaced), the triggers made
again. Foreign keys are off while it runs: with them on, dropping the table would delete
every face, record, embedding, text reading and description by cascade. It checks that the
new table holds every key the old one did and runs `foreign_key_check` on the two tables it
made.

## Results on the generated catalog (scale 1)

`CatalogMigrationCostTests`, one generated catalog of the owner's shape (166,990 assets): put
back to v70, measured, migrated, measured again, then rebuilt once more without a row id
(the layout v71 does not take) and measured a third time. Pages are those read on a cold
connection; milliseconds are one run each, on a machine other agents' builds were loading, so
read them as orders of magnitude.

| Read | v70 pages | v71 pages | without row id | v70 ms | v71 ms | without row id ms |
| --- | --- | --- | --- | --- | --- | --- |
| Default order | 3,147 | 3,148 | 26,212 | 681 | 245 | 1,509 |
| Name order | 147,594 | 28,586 | 28,839 | 2,053 | 361 | 1,364 |
| Choices filter (Liked, 1 %), walking the table | 144,905 | 25,897 | 26,212 | 449 | 100 | 235 |
| Choices filter (Liked, 1 %), through `idx_media_asset_chosen` | – | 82 | 3,539 | – | 2 | 8 |
| Filter options | 4,852 | 4,853 | 22,952 | 519 | 62 | 124 |
| People's face-to-asset join | 96,943 | 31,185 | 28,606 | 1,055 | 420 | 1,500 |
| Stack candidates | 6,585 | 1,931 | 3,597 | 266 | 57 | 157 |
| Search embeddings: reconcile | 18,921 | 18,922 | 18,879 | 1,786 | 359 | 2,528 |
| Search embeddings: owed | 18,921 | 18,922 | 42,080 | 307 | 158 | 663 |
| Text readings: owed | 15,025 | 15,026 | 14,983 | 517 | 222 | 1,530 |
| Render signatures: owed (one library) | – | 47 | 83 | – | 0 | 3 |
| Same-photo candidates | – | 9,525 | 9,338 | – | 1,215 | 2,120 |

(– : the v70 schema cannot prepare the v71 statement.)

| Tree | v70 | v71 |
| --- | --- | --- |
| `media_asset` | 141,766 leaf pages, 330 MB payload | 22,934 leaf pages, 84.5 MB payload |
| its key index | 2,757 pages | 2,757 pages |
| `idx_media_asset_same_photo_candidate` | 9,452 pages | 6,076 pages |
| `render_signature` | – | 48,131 pages, 156 MB, and a 2,399-page key index |
| every other index | unchanged | unchanged |

The migration: **10.0–15.7 s and 642 MB of log** over three runs on the generated file
(2.85 GB), slower while other agents' builds ran. v69's index migration took about twice its
generated time on the owner's file, so 20–30 s there.

The compaction after it (`compactIfOwed`): the file was 27 % free; VACUUM took **12.0 s on a
quiet machine and 47.7 s under load**, and the file went from 2,846 MB to 2,081 MB. On the
owner's file, 35 % free once v71 has run (386 MB free before and about 590 MB freed), expect
twice that, once.

The owner's choices, read-only: 21 Liked, 3 Disliked and 167,191 Not Rated rows. So a filter
to Liked or Disliked seeks `idx_media_asset_chosen` (v71: the chosen rows, with the columns
every order sorts by and the window tests) and sorts the few it finds: 82 pages for the
generated catalog's 1,647 Liked rows, against 25,897 walking the table.

Without a row id the table was 10 % smaller (20,371 pages), but the planner left the date
order's covering index for the key (26,212 pages against 3,148), the filter options' (22,952
against 4,853) and the owed embeddings' walk (42,080 against 18,922), and three plan tests
failed. With a row id every plan is as it was.

Each index the study expected the narrow table to make unnecessary, measured with and
without (`WindowReadPages.indexVariants`, the same generated catalog after v71):

| Index | Read | Pages with it | Pages without | Decision |
| --- | --- | --- | --- | --- |
| `idx_media_asset_product_stamps` (41 MB) | embeddings owed / text owed / reconcile, walking the date order instead | 17,994 / 14,601 / 17,994 | 32,604 / 29,211 / 32,604 | kept |
| `idx_media_asset_stack_candidate`, covering | stack candidates / filter options, plain | 1,930 / 4,852 | 3,434 / 27,069 | kept covering |
| `idx_media_asset_capture_day`, covering | On This Day's 432 rows, plain | 590 | 587 | **made plain** (13 MB index, the day's rows cost the same) |
| `idx_media_asset_import_batch`, covering | one batch's 253 rows, plain | 281 | 280 | kept covering: the batch list walks all 11,263 stamped rows through it, testing each from its entry, and the index is 139 pages |

One index was added (`idx_media_asset_chosen`, 63 pages). Every other index v71 makes again
answers a read that would otherwise read table rows: the date, name and size orders, global
and per root, ascending and descending, are the orders the window walks, and each partial
index holds only what one owner owes or seeks.

## Conclusions

- The table v71 makes is a sixth of the old one's pages: every read that tests rows outside a
  covering index reads 3–5 times fewer pages (name order 5.2×, the choices filter 5.6×,
  People's join 3.1×, the stack candidates 3.4×).
- A table without a row id would cost the reads the covering indexes answer, because the
  planner, which has no statistics here, prefers the key's range; the row id stays.
- The free pages the rebuild leaves are returned by the open's compaction (ADR 0002).
