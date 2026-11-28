# Why an Immich listing batch slows as the account grows (2026-11-12)

## Question

After #681 and #682 the test Immich server's 147k-asset account finished its first sync, but
applying one 500-line batch took about 0.2 s at the start and 1.2–3.8 s at 95k–147k rows,
and `catalog.sqlite-wal` reached 257 MB. Where does a batch's time go, why does it grow
with the account, and what is the owner fix?

## Method

1. Time Profiler attached to the installed app for 33 s during that first sync (the earlier
   session's `sync-apply.trace`), exported with `xctrace export` and summed per frame.
2. The installed app's own unified log after the sync (pid 59518, 12:55–16:07): the
   window's order query and every grid structural apply on a 158–164k-item catalog.
3. The window's order query run with `sqlite3` against a backup of the reference catalog
   (967 MB; deleted after the run), cold and after `cat` had read the file into the page
   cache.
4. The Store's batch write replayed in plain SQLite (Python, the catalog's own schema,
   500-row transactions, 150k rows, with and without `checkpoint_fullfsync`, which Apple's
   SQLite turns on and Python's does not).
5. A temporary probe test: a file-backed Store, an Immich account, 100k assets listed in
   500-line batches with nothing subscribed, with the window's `CatalogProjection` (which
   drives Duplicates and People), and with the window plus `PhotoSearchIndex`. Per 20
   batches it records batch time, process CPU time, blocks read from disk and the WAL's
   size. Run on base and fixed trees at the same time, on a machine running other
   agents' builds (load average 80–196, 60 MB free memory, 3.8 GB swap in use): wall
   times are indicative only, so the conclusions rest on CPU, block and WAL counts.

## Findings

### A batch's time is waiting for reads, not CPU

In the 33 s trace the whole app ran 1.56 s of CPU. The Store's write took 224 ms of it;
its top frame is `pread`, which Time Profiler samples only while it runs, so the seconds a
batch spends are spent blocked on reads. Each catalog change in the same window started
whole-catalog reads in four other owners, each costing about as much CPU as the write:

| reader | CPU in 33 s |
|---|---|
| `CatalogProjection.buildWindowState` → `orderedAssetIDs` | 136 ms |
| `DuplicatesProjection.build` → `fetchDuplicateCopies` | 118 ms |
| `PhotoSearchIndex.refresh` → `searchEmbeddingCandidates` | 114 ms |
| `PeopleAssignment.run` → `peopleSnapshot` | 111 ms |

The installed app's own log shows what those reads cost in wall time on this Mac: the
window's order query on 164k items took `execMs` 1,442–3,250 with ~136 ms of CPU. Against
a copy of the catalog the same query took 4.7–10 s cold (0.3 s user, 0.8 s system) and
0.7–1.1 s once the file was in the page cache. Every reader scans the whole catalog, the
catalog does not fit the page cache this machine leaves it, and each scan competes with
the writer for the same disk.

### The write itself does not grow in plain SQLite

The batch's statements replayed in plain SQLite on the same schema stayed flat from 30k to
150k rows: 43–360 ms executing and 118–420 ms committing per batch, with or without
`checkpoint_fullfsync`. The growth is not in the statements.

### Overlapping readers keep the WAL from ever resetting

SQLite resets the write-ahead log only when no reader is using it. In the probe the WAL
stayed at 25 MB through 100k rows with nothing subscribed; with the window's readers it
held 23 MB to 60k rows and then grew to 357 MB by 100k (and to 75 MB with the window plus
search, whose timing differed). A starved WAL is read through `pread` (it is not memory
mapped) and grows the file without bound on a disk this Mac keeps near full.

### The readers, not the write, are what grows

The probe run on both trees at once (base `origin/main` 53c1dd65; fixed this change), 100k
assets in 500-line batches, process CPU time per batch (the readers run in the same
process, so this is the work one batch sets off), averaged over 20 batches:

| rows | base, no reader | base, window + search | fixed, no reader | fixed, window + search |
|---|---|---|---|---|
| 10,000 | 395 ms | 454 ms | 340 ms | 543 ms |
| 50,000 | 519 ms | 1,297 ms | 490 ms | 954 ms |
| 100,000 | 541 ms | 2,214 ms | 630 ms | 1,089 ms |
| WAL at its largest | 26 MB | 250 MB | 26 MB | 51 MB (truncated to 0 twice) |

With nothing subscribed the write stays flat on either tree. With the window subscribed —
which also drives Duplicates and People — and search, the base tree's batch sets off four
times more work at 100k than at 10k. The fixed tree removes the derived owners' share
(about 1.1 s a batch at 100k); what still grows is the window's own publication, one O(n)
order query per publication (144 publications for 204 batches). Blocks read from disk were
0 throughout: the probe's catalog fits in the page cache, which the reference library's 1 GB catalog
does not.

### Six of the eight readers can learn nothing from a listing batch

A batch of new rows carries no metadata, digest, rendering, faces, place or embedding:
those are written later by enrichment, and `content_identifier`, the only key a derived
query pairs rows by (Live Photos), is written only by enrichment. Duplicates, People,
search, place names, preview faces and render signatures therefore read nothing new, yet
each ran a whole-catalog pass for every batch.

### The grid's main-thread apply grows with day sections

In the installed app's log every structural apply of the 158,703-item grid spent ~20 s
building its snapshot off the main actor and `applyCallMs` 649–3,087 (median 1,116) in
`dataSource.apply` on it. That is the compositional layout re-solving every day section
(`2026-11-04-grid-snapshot-build-off-main.md`); it does not depend on how many rows a
publication changed (222 of the 224 applies inserted and removed nothing, reordering only).

## Conclusion

- A write that only inserts rows is announced as `.assetsAdded`; the window and enrichment
  take it up, the owners of derived facts wait for the enrichment write that gives them
  input. This removes the derived owners' whole-catalog passes from a first sync.
- After every bulk write (scan batch, device or source listing batch, enrichment batch)
  the Store bounds the WAL: when the log file is larger than 64 MiB, a truncating
  checkpoint behind GRDB's barrier empties it. Reading the file's size costs a `stat`;
  a passive checkpoint after every batch, to read the log's frame count, would backfill
  pages SQLite otherwise batches.
- Whether a row existed rides on the respell lookup the upsert already runs, as a second
  index seek in the same statement (`UNION ALL`; an `OR` of the two predicates is
  planned as a scan of the root). The upsert's `last_insert_rowid` cannot answer it: it
  is shared by every table on the connection, so the first row after the account's own
  insert landed on the rowid that insert left. `immich.listing.batch500.of20k` against
  its merge base: see the PR's report (`script/bench.sh compare`).
- The window's own per-publication cost is unchanged and still grows with the account: an
  O(n) order read per publication, a snapshot build that grows with days × items off the
  main actor (~20 s at 158k items) and a layout solve that grows with day sections on it
  (~1.1 s median at 158k). The grid's mutation gate applies only the newest state, so at
  that size most publications made during a listing are superseded before they are
  drawn. Removing the main-thread term needs a different layout model, which was
  ruled out on 2026-11-04 when it cost 150–200 ms; at an Immich account's size that
  decision is open to revisit.
- Disproved: that the grid rebuilds its snapshot for publications whose order did not
  change. The mutation gate already turns identical identities into a visible-tile refresh;
  the installed app's applies all changed the order (222 reorders, 2 insertions).

## Sources

- SQLite, [Write-Ahead Logging](https://www.sqlite.org/wal.html) (§ Checkpoint starvation)
  and [`sqlite3_wal_checkpoint_v2`](https://www.sqlite.org/c3ref/wal_checkpoint_v2.html).
- GRDB 7.11.0, `DatabasePool.asyncBarrierWriteWithoutTransaction` and
  `Database.checkpoint(_:on:)` (`build/DerivedData/SourcePackages/checkouts/GRDB.swift`).
- `/usr/bin/sqlite3` 3.54.0 on macOS 27: `PRAGMA checkpoint_fullfsync` reads 1.
