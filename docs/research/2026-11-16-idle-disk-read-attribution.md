# Disk read and CPU of an idle session, by owner (2026-11-16)

Plan 0116. Source: the installed app's unified log for one read-only ten-minute tour on the
owner's library (installed d68eb425: 34 steps in about 10 s, then 600 s idle), every
`op=contentHash`, `op=process.usage` and `op=materialization.request` line of the day's
sessions, and read-only counts from the owner's catalog (`sqlite3 -readonly … ?mode=ro`
while no Otos ran). Nothing was launched on the owner's data.

## What read 18.7 GB

The session read 18,687 MiB and used 60.6 s of CPU. The app logs each original it reads
whole (`op=contentHash phase=finish bytes= owner=`):

| Who | MiB (session) | MiB (idle 600 s) | How it is known |
| --- | --- | --- | --- |
| Enrichment hashing originals (234 files: MOV 7.6 GiB, MP4 4.8, ARW 2.5, HEIF 0.5) | 15,657 | 15,049 | `op=contentHash` bytes |
| Page-ins: mapped files, models, frameworks (82,339 pages of 16 KiB) | 1,222 | 403 | `op=process.usage pageIns` |
| Not attributed: the catalog's pages, originals read for metadata and renders, previews decoded | 1,808 | 1,126 | the rest |

All 234 originals lay in the OneDrive library and were dataless: 230 were downloaded first
(`op=materialization.request phase=completed outcome=materialized`), so each byte was
fetched by the provider and then read again by the hasher. The hashing took 11.2 s of wall
time, an upper bound on its CPU.

**This is owed work, not a re-walk.** Of 1,589 originals hashed across the day's sessions,
none was hashed twice. The owner's catalog holds 157,235 rows with no digest: 147,279 in the
Immich account (whose originals are not downloaded for a digest), 7,732 in the OneDrive
library, 389 GB of them. At the observed 16 GB per ten minutes, the library's backlog is
about four hours of open app, paced by the provider's download speed. ADR 0009 permits
deliberate background materialization for enrichment, and the window's targets passed in
this session, so no throttle was added (AGENTS.md, Rob Pike's rules).

## Why sessions read 2.5 to 18.7 GB

| Session (pid) | Disk read | Hashed | Downloads | Note |
| --- | --- | --- | --- | --- |
| 29149 | 11,760 MB | 9,578 MB | 147 | |
| 41112 | 12,211 MB | 9,642 MB | 220 | |
| 66189 | 18,045 MB | 16,546 MB | 271 | |
| 36375 | 2,579 MB | 2 MB | 0 completed | one 11 GB video's download held the byte budget all session |
| 72936 | 3,401 MB | 0 MB | 0 completed | one 12 GB video's download held the byte budget all session |
| 13952 | 18,726 MB | 16,418 MB | 230 | |

The spread is the hash backlog's progress, by fact: a session that read 2.5 or 3.4 GB hashed
nothing, because its first background download was a single 11–12 GB video that took the
whole background byte budget (`op=materialization.admission phase=blocked reason=byteBudget`
for the rest of the session) and did not finish inside ten minutes; in 36375 the 12 GB file
before it was held by the free-space floor (`phase=floorHeld available=17426317312`).
Every session that hashed read about 1.2 GB per 1 GB hashed.

## CPU

The log does not attribute CPU by owner; `proc_pid_rusage` is per process. What it bounds:
hashing at most 11.2 s; the description writer's 136 descriptions ran in the system's model
service, a separate process; text reading runs in its own helper processes. The volume
capacity figure (`volumeAvailableCapacityForImportantUsage`) costs 15.5 ms of CPU per read
(this Mac, 50 uncached reads), and the session made one per background download dispatch
(233) and one per People page of vectors.

## What the log could not say, and the instrumentation added

- The catalog's own share: now `op=catalog.store.reads` at every checkpoint, the page bytes
  each role and its heaviest operations read into SQLite's cache
  (`SQLITE_DBSTATUS_CACHE_MISS`). Pages within the mapped first 256 MB are page-ins.
- Which writes the 839 `unnamed` writer transactions (4.5 s) were: every Store write now
  goes through `CatalogWriter`, named for its caller; the open's own work is `catalogOpen`
  and a new connection's statements `connectionOpen`. `BackgroundOwnersIdleTests` fails on
  any transaction left unnamed.
- The scorecard prints `DISK READ BY OWNER` for the session and the idle window.
- Still not attributed: bytes read by image decoders (originals for metadata and renders,
  previews for faces, descriptions and search), and CPU by owner.

## Waste found and removed

- **Descriptions re-walked the described stills.** `photoDescriptionCandidates` took 11.4 s of
  reader time in 10 reads (1.1 to 3.4 s each). Every text reading and every embedding
  written (`.searchContent`, 118 in the session) restarted the walk from the newest still.
  Each restart visited every still at the top again, both the described ones and the ones
  not yet describable, before it reached the owed ones. Those writes now name their rows, and a named change owes only those stills, read by key
  (`PhotoDescriptionStorage.keyedCandidateSQL`, one seek of the row's key). A change that
  names no rows (a person, a place name) still restarts the walk.
- **Free space was calculated per decision.** `VolumeCapacityHold` keeps one CacheDelete
  calculation per volume for 60 s and lowers it live by the volume's `statfs` free count (ADR 0027).

## Owed, or left as they are

- `searchTextCandidates` (116 reads, 12 ms each) is the text reader's backlog of about 43 h,
  paged; owed.
- `mirrorPairsOwed` (56 reads in 3 passes, 1,574 ms) was the Immich account's mirror walk, run
  once per 5-minute poll with `listed=0 deleted=0`; each also probed both libraries and asked the
  server for three Camera Roll assets' paths that never confirmed. A library-side change moves
  pairs only through a library's namespace (a rename or move keeps its digest under a new path),
  and a digest pairs in its own write, so the walk now waits on the account's listing applying a
  change or `CatalogStore.libraryNamespaceRevision` moving (ADR 0054). The idle polls hash
  digests, which move neither. Its reads were already index walks: a page of digested files walks
  the library's key (16,924 rows for 9,192 digested), each file one seek of the path-checksum index.
- `sourceProductCandidates` (20 reads, 2,017 ms, longest 628) was two reads under one name. The
  product walk is a seek of an empty partial index (0.3 ms, no row, `EXPLAIN`: `SEARCH ... USING
  INDEX idx_media_asset_source_products_owed`), kept per poll. The rows-on-screen read
  (`visibleCandidatesSQL`) ranged the account's source-item index, all 147,293 rows, and tested
  each against the paths: 406 ms for 120 paths, 24 ms pinned to the key
  (`sqlite_autoindex_media_asset_1`). Pinned, with a plan test.
- `mediaAssets` (1,084 reads, 2 ms each) was enrichment asking the Store at every pass which rows
  on screen owe a priority claim; every Store change (a digest written anywhere) and every
  completion is a pass. A row it answered owes nothing is now held until a change names it or
  names no rows (`PriorityAnswers`): one read per screen, then one per named row.
- `currentSearchEmbeddingIDs` (2 reads, 1.45 s each) and `peopleSnapshot` (2 reads) are the
  launch's loads; owed once a session.

## Why the idle guard took 3 to 300 s (2026-11-17)

`BackgroundOwnersIdleTests` (1% scale) took 2.5 s alone and 26 to 178 s in full checks (11
logs). Two causes, by its own logs:

- **Production backoffs inside the round.** The owners the guard runs fail on purpose (no
  download, no model), and arm their production retries: enrichment's download at 15 s, the
  search model's load at 30 s, a description at 900 s. On a loaded run the settle outlasted
  them, the retries ran, and the guard ran its round again for each wake that came due (up to
  eight). `RunningBackgroundOwners.Backoffs.beyondTheRun` makes each a day; the guard now
  asserts that no named wake came due.
- **A process-wide burst of Store opens.** With phases logged (`op=ownersIdle.phase`), a full
  run measured: catalog made 0.7 s, `store.start` 26.3 s, owners started 1.6 s, settled 4.0 s,
  idle round 1.0 s (33.6 s in all). In the same 11 s, other suites opened about 400 fresh
  stores, each running all 75 migrations, and every Store start in the process finished at
  the same instant, its startup claim release queued 12 to 15 s (`op=catalog.start
  claimsMs=`). That wait is the test host's, not the guard's: no owner of the guard waits on
  time any more.

A release's footprint line read `task_info` on the releasing owner's thread, after the next
grant. It now runs on a queue of its own (`LoadAdmission`), so a stalled kernel read holds
neither the next load nor the owner (`LoadAdmissionTests`).
