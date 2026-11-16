# What a catalog's open costs, migration by migration (2026-11-15)

Supports ADR 0002's "Schema Migrations At Launch" and DES-121 (the window while its catalog
opens).

## Question

The owner's launch of build `191ffe1a` spent 43.1 s in `op=catalog.start`'s `openMs`, with a bare
spinner and an empty sidebar; nothing in the log said what the open did. What does an open
spend its time on, what does each migration from v59 to v64 cost on a catalog shaped like his,
and which part of that cost is waste?

## The owner's catalog (read only)

Read with `sqlite3 -readonly "file:…/catalog.sqlite?mode=ro"`; nothing was written or copied.

- 2,563,067,904 bytes: 625,749 pages of 4,096, none free. A 38,641,512-byte WAL beside it.
- Migrations recorded through `v64_photo_copies`, `v63_asset_metadata_location_index` last.
- 166,982 `media_asset` rows (544 MB: a 1 KB `render_gray` on most rows, a 200-byte sort key);
  140,010 `asset_metadata` (189 MB); 102,963 `face` (403 MB, a 2 KB embedding each);
  165,630 `search_embedding` (648 MB, a 3 KB embedding each); 58,598 `search_text` (19 MB).
- 4,665 rows held a digest and none had a copy when v64 ran on it (`has_copies` is 0 on every
  row); 24 rows hold a choice.
- Nine roots: two libraries, one Immich account, two removable volumes, four cameras.
- Twelve tables declare a foreign key; the five above hold nearly all of the file.

His app's log for the launch has nothing between `op=removableVolume.refresh` at 19:53:25.928 and
`op=catalog.database.open phase=finish` at 19:54:08.227: the open logged no step.

## Method

A test that was never committed (and deleted afterwards) built a catalog at v58 with
`CatalogStore.migrator` and filled it in SQL to the owner's shape: 166,982 `media_asset` rows
(16,000 in a library, 1,000 in a second, the rest in an account; a 1 KB `render_gray` on four
rows in five, a 200-byte sort key, one row in fifty Liked), 140,010 `asset_metadata` rows with a
1.1 KB record and half of them located, 96,000 faces with 2 KB embeddings on 48,000 rows,
165,630 search embeddings of 3 KB, 55,660 text readings. The file was 1,958,600,704 bytes: 76 %
of his. Thumbnails are files, not rows, so nothing else makes his larger.

It then applied v59 to v64 one at a time on a fresh `DatabasePool` with Otos's configuration,
timing each, and timed `PRAGMA foreign_key_check` alone before each. Before v63 it gave 16,000
library rows and 16,000 account rows one shared digest each (32,000 copies), so v64's row writes
are measured on a catalog with copies; his had none. v64's statements were also run one by one
inside a transaction that was rolled back, in the order v64 shipped with and in the order of
this change, twice each. The machine was running other sessions' checks; times are loose,
ratios between neighbouring runs hold.

What could not be reproduced: a cold read. Nothing in a test can empty the system's file cache
(`purge` needs root), and a file just written is in it. His launch read a file the previous
session had written hours earlier, with Otos and other apps holding memory on a 16 GB Mac.

## Findings

Before this change (`191ffe1a`, GRDB's default foreign-key handling):

| migration | ms | of which `foreign_key_check` (alone) | WAL after |
| --- | --- | --- | --- |
| v59 stack candidate path (one index rebuilt) | 2,843 | 8,774 cold, first read of the file | 12.5 MB |
| v60 SHA-1 digest and copies (every row written, ten indexes rebuilt) | 8,908 | 636 | 401.7 MB |
| v61 Immich mirrors (one partial index over a new column) | 3,805 | 1,122 | 401.7 MB |
| v62 capture day index (two virtual columns, one index) | 2,002 | 942 | 411.7 MB |
| v63 location index (one partial index on `asset_metadata`) | 803 | 612 | 4.1 MB |
| v64 photo copies (seven indexes rebuilt, the copy rows written) | 4,140 | 1,503 | 79.1 MB |

- **Every migration re-verified every foreign key in the catalog.** GRDB's default
  (`foreignKeyChecks: .deferred`) turns enforcement off for the migration and then runs
  `PRAGMA foreign_key_check`, which reads every table that declares a foreign key — here the
  five tables that are nearly the whole file — and probes each row's parent. Warm, that is
  0.6–1.5 s per migration on this catalog: 15–75 % of a migration's time. Cold it was 8.8 s,
  three times the migration it followed. None of v59–v64 writes a key, deletes a row another
  table refers to or rebuilds a table, so the check could never find anything they caused.
- **v64's statements**: the seven index builds are 0.09–0.43 s each, 2.0 s together; the
  rating-order write 0.11–0.14 s; the `has_copies` write and the photo choice pass 0.18–0.21 s
  each. The copies the probe meant to give the catalog did not satisfy v64's copy test
  (`changes=0`), so both orders wrote no `has_copies` row and timed the same (2.38–2.64 s,
  two runs each): writing rows before the builds saves an index update per written row in
  each of six indexes by construction, and is not measured here. On the owner's catalog v64
  wrote no such row either.
- **No migration rebuilt an index whose definition was unchanged.** v59, v60 and v64 drop and
  recreate only indexes whose column lists or predicates change (a column added to a covering
  index, a renamed column in a claim predicate). Each rebuild is a full scan and sort of its
  table; SQLite builds one index per scan, so N changed indexes cost N scans.
- **v60 is expensive by its outcome:** clearing every digest writes every `media_asset` row
  (the 400 MB WAL). Nothing cheaper has the same result.
- **The rest of the open** does not scan: no `integrity_check`, `quick_check`, `optimize` or
  `ANALYZE` runs, and nothing checkpoints at open. SQLite recovers the WAL the last process left
  on the first read; for a 38 MB log that is reading it once.

After this change (every migration `.immediate`, v64's row writes before its index builds):

| migration | ms before (with its check) | ms after | `foreign_key_check` alone, same run |
| --- | --- | --- | --- |
| v59 | 2,843 | 520 | 606 |
| v60 | 8,908 | 4,969 | 613 |
| v61 | 3,805 | 611 | 902 |
| v62 | 2,002 | 939 | 937 |
| v63 | 803 | 106 | 593 |
| v64 | 4,140 | 2,947 | 625 |
| all six | 22,501 | 10,092 | |

The six took 10.1 s instead of 22.5 s. The drop is larger than the checks the second run timed
alone (0.6–0.9 s each, 4.3 s): the two runs were on a loaded machine, minutes apart, and the
first had just written the file. What the change removes is one full read of the foreign-key
tables per migration; what each migration then costs is its own statements.

## Where the owner's 43 s went

What the evidence shows: the time was inside the migrator (v63 and v64 were the only work the
open had; the catalog's history ends with them, and a launch with no migration opens in
9–86 ms). On the generated catalog the same two migrations took 4.9 s warm, 2.1 s of it the two
foreign-key checks. The owner's open took nine times that. The generated catalog's one cold
check took fourteen times its warm one, so reading the file from disk rather than from memory
is the likeliest multiplier: v63 and v64 together read the five foreign-key tables twice
(≈3.4 GB), `media_asset` seven times for its index builds (≈3.8 GB) and `asset_metadata` once.
That is an inference: his launch logged nothing that times a read, so how the 43 s divide
between the checks and the index builds stays unknown. From the next migration on, each one's
own line (`op=catalog.migration phase=finish … ms=`) answers it.

## Conclusions

- Register every migration `.immediate`: enforcement stays on as its statements run, and there
  is nothing to verify after. A migration that must rebuild a table (SQLite's twelve steps,
  enforcement off) registers `.deferred` and pays the check knowingly.
- Write rows before building the indexes that hold them (v64 now does; its outcome — schema
  text, object order, rows — is the same), and rebuild only indexes whose definitions change.
- Log every migration's cost, and every step of the open, so `openMs` is never unexplained.
- A migration's PR states its cost measured on this owner-shaped catalog (ADR 0002).
- No deferred-index mechanism: an index left for after launch would leave every `INDEXED BY`
  read failing or falling back to reading the 544 MB table while it builds, and the build would
  hold the one writer for the same seconds, so every act's write would wait behind it with
  nothing on screen to say why.
