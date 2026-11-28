# Small scopes' reads and visible tiles' waits (2026-11-15)

**Superseded in part:** the pool-hop wait this note reads as `waitMs` no longer exists in store
reads; `2026-11-15-cooperative-pool-holders.md` removed it (`readFreeingConnection`), and store
queries now log it apart as `resumeMs`.

## Question

On 2026-11-15 (06:29–06:33, installed build 32f39417, about 164,500 rows, three libraries
and an Immich account) the user opened a running card import's batch. #764 fixed the
batch's order and place-option plans (`2026-11-15-keyed-scope-query-plans.md`). Three
questions were left:

1. The batch's order still read every stack candidate of the three libraries (`stackCandidates`
   25,734–25,821 for a batch of 2–98 rows, `stackReadMs` 2.6–7.0 s), on every publication of
   the import, because each new row moves the stacks' inputs and so drops held stacks.
2. Visible tiles' details (`op=catalog.store.query.tileDetail`, #750's two-reader
   `interactiveReader` pool) ran in 1–10 ms but waited 2–47 s (`waitMs` 7,742, 8,664, 9,694,
   10,194, 12,414, 25,132, 30,070, 47,258). What did they wait on?
3. Do the other small scopes (a person, Duplicates, a map area, On This Day) read in
   proportion to the catalog?

## Method

- **Log:** `log show` of the installed app for 06:28–06:36.
- **Catalog:** an APFS clone of `build/catalog-backups/catalog-v53-before-v55.sqlite` (v53,
  166,971 rows), migrated to head by `CatalogStore.migrator` alone (no Store, no source, no
  watcher), in a temporary test that was never committed. Fixed roots 6, 7 (Camera Roll,
  16,674 rows) and 15 (the account, 147,051). A batch of 210 rows was stamped on Camera
  Roll's 210 newest rows (one folder, `2026/11/`: 174 processed images, 29 RAWs, 7 videos).
  The clone was deleted afterwards.
- **Measures:** each read's `EXPLAIN QUERY PLAN`, its warm time, and the pages a fresh
  read-only connection with no memory map read for it (`SQLITE_DBSTATUS_CACHE_MISS`): pages
  are what a read costs on a machine whose cache was paged out, which the test Mac's was.
  The copy's digests form no duplicate group, so the Duplicates scopes read zero rows.
- **Probe:** a GRDB 7 program (`DatabasePool` as `CatalogStore` configures it, a second
  read-only pool of two readers as `interactiveReader`) timing a read on the second pool
  while the first held four long readers, a writer committed every 2 ms and truncating
  checkpoints ran behind GRDB's barrier; and while `Task.detached` bodies that block their
  thread filled the cooperative pool at each priority. The Mac has 8 cores.

## Findings

### Visible tiles waited for a thread of the cooperative pool (proven)

- The import ran eight workers (`mediaOperation.batch phase=start workers=8`, 06:29:41) and
  each worker's `copyfile(3)` blocked its thread for the whole copy (`copyMs` 0.2–10.8 s per
  file, eight at a time). The copy ran in `Task.detached`, whose comment said it ran "rather
  than on a cooperative-pool thread": a detached task runs on the cooperative pool, which has
  one thread per core. Eight held copies held all eight threads.
- GRDB's async `read` resumes on the cooperative pool between acquiring a reader and running
  on it (`Pool.get(block:)` is a nonisolated async function in GRDB's module), so a read on an
  idle pool waits there for a free thread. That wait falls between `timedRead`'s two
  instants: it is `waitMs`.
- Probe: eight detached blocking tasks with no priority (the import's copies) starve a
  user-initiated read for the length of a block (one read in 12 s, its start delayed 3,005 ms
  by 3 s blocks); seven do not; eight at utility or background priority do not. Four long
  readers, a writer committing every 2 ms and four truncating checkpoints behind the main
  pool's barrier never held a read on the second pool beyond 3 ms: neither the reader pool
  nor SQLite's locks made the waits.
- The 06:29:46–06:32:48 waits (7–25 s) fall inside the import's copies. Before the import,
  06:28:51–06:29:38, one read waited 30,070 ms and the cause is **unknown**: no copy ran,
  nothing logged a blocking span, and the log cannot show what held the pool's threads. Text
  readings failed eight times within 0.4 s as it ended (`search.text phase=failed`), which
  is suggestive and not proof. The 47,258 ms wait (06:30:09–06:30:56) ended 265 ms after a
  truncating checkpoint whose barrier had waited 34 s for the main pool's reads; the probe
  shows the checkpoint does not hold the second pool, and copies ran throughout.

**Fix:** a blocking copy runs on a dispatch queue of its own
(`CopyfileTransfer.offCooperativePool`): the import's copies and a camera's staged-copy
reuse. ADR 0032's rule 6 now separates work that computes (the cooperative pool) from work
that waits (a dedicated queue). `MediaImportExecutorTests.heldCopiesLeaveTheCooperativePoolFree`
holds every worker's copy and runs other async work.

### A keyed scope's stacks are read from its own folders

| Stacks for the 210-row batch | Candidates | Stacks | Pages | Warm |
| --- | --- | --- | --- | --- |
| Every candidate of the three libraries (as shipped) | 25,701 | 5,752 | 23,958 | 0.3–2.0 s |
| The batch's folders and bursts (`PhotoStackSQL.Span.rows`) | 679 | 30 | 436 | 9 ms |

The narrowed stacks are exactly the whole read's stacks that hold a batch row (checked for
the batch and two people). A pair is two files of one folder and a burst is one identifier in
a root, so the stacks holding a scope row are built whole from its rows' folders that hold a
RAW, the stills of the bursts its rows and those folders' stills carry, and those stills'
folders that hold a RAW; stacks there that hold no scope row may be partial and are dropped.
A folder without a RAW is never walked: it pairs nothing, and its scope rows name their own
bursts. The scope's rows come from its order read, which runs first and carries each still's
burst, so no second read finds them. Whole-roots stacks the projection holds answer any scope
over the same roots; a scope's own stacks answer that read alone and are never held, so they
never displace held whole-roots stacks.

The benchmark (`projection.windowState.importBatch`, 210 rows stamped on a catalog of 15,000
JPEGs in one folder, no RAW and no burst, so reading every candidate reads no rows at all)
measures what narrowing costs where it saves nothing. Base 29.2 M instructions. A first
version, which walked every scope folder for its bursts and read the scope's rows a second
time, retired 95 M; reading the rows once, 50.8 M. Per-phase cases showed the rest was the
read hashing a `MediaAssetID` per scope row to drop partial stacks when there were none
(about 13 M) and compiling the candidate statement on every read (about 7 M). The set is now
built only when the rule built a stack, the statement is cached per connection, and the case
measures 29.5 M.

Plan of the scoped read: `SCAN seed VIRTUAL TABLE` (the folders' and bursts' JSON arguments),
then `SEARCH still USING INDEX idx_media_asset_stack_candidate (library_root_id=? AND
best_kind=? AND parent_path=?)`, `SEARCH still USING INDEX idx_media_asset_burst
(library_root_id=? AND burst_identifier=?)`, `SEARCH raw EXISTS USING INDEX
idx_media_asset_stack_candidate`, `SEARCH still USING INTEGER PRIMARY KEY`; no scan of
`media_asset`. Pinned by `CatalogStoreQueryPlanTests.stackCandidatesSeekTheirFoldersThroughTheCandidateIndex`.

### Other small scopes

Pages read by a fresh connection (warm time in brackets). "Before" is the shipped SQL.

| Scope (rows) | Order | Types | Places | Count |
| --- | --- | --- | --- | --- |
| Batch (210), after #764 | 144 (0 ms) | 144 (0 ms) | 258 (0 ms) | 144 (0 ms) |
| Person, 23 photos, before | 3,472 (53 ms) | 5,130 (51 ms) | 105,584 (176 ms) | 157,004 (293 ms) |
| Person, 23 photos, after | 78 (0 ms) | 78 (0 ms) | 120 (0 ms) | 78 (0 ms) |
| Most photographed person, 16,218, before | 3,820 (99 ms) | 5,620 (73 ms) | 117,384 (214 ms) | 157,190 (3,227 ms) |
| Most photographed person, 16,218, after | 19,484 (120 ms) | 19,484 (60 ms) | 34,257 (96 ms) | 19,484 (59 ms) |
| Duplicates, either reach (no group in the copy) | 149,418 (251 ms) | 181,266 (283 ms) | 105,582 (165 ms) | 15 |
| Helsinki map area (283) | 55,759 (169 ms) | 81,689 (188 ms) | 132,281 (220 ms) | 246,624 (429 ms) |
| On This Day, 15 November (705) | 29,221 (29 ms) | 29,171 (27 ms) | 131,765 (183 ms) | 28,873 (331 ms) |

- **A person was the same defect** and is now a keyed scope: its photos are found from the
  person's faces (`idx_face_person_photo (person_id=?)`), each by its key
  (`sqlite_autoindex_media_asset_1`), and sorted. A read costs the person's photos: the
  most photographed person's order reads more pages than the date walk did (19,484 against
  3,820, 120 ms against 99 ms warm), every other read of every person far fewer. Its stacks
  read 16,391 candidates and 45,848 pages (0.30 s warm) against the whole read's 23,958
  (0.31 s), since an account asset is a folder of its own; held whole-roots stacks still
  answer it. A 23-photo person's stacks read 3,237 pages (42 ms). Measured on the final code.
- The filter's types and the counts of a keyed scope now start from its key index
  (`ScopeClause.from`), like its order and place options.
- **Not fixed**, library-sized for a small scope: a map area (its box is tested on every
  located row the date walk reaches), On This Day's place options, and Duplicates (its rows
  are those whose digest another row shares, and the account's rows all carry digests, so no
  index narrows them below the catalog). None of them is named by a key; each needs its own
  design (a coordinate index for an area; reading Duplicates' rows from the groups the
  Duplicates owner already builds).

### Does it predate #750 and #756?

Yes. The order's forced date index dates from #76, the stack read over every root of the
scope from #735, the place options' fixed join from #726, the copy in `Task.detached` from
46aac418 (2026-10-23) and eight workers from #119. #750 added the interactive reader pool and
held stacks; held stacks never survive an import, whose every row moves their inputs. #756
added the one-copy test to a combined scope's clause, which the plans above carry at no
visible cost.
