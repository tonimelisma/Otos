# Reads that waited seconds at launch, under the whole app's startup (2026-11-15)

## Question

On the user's launch of build 191ffe1a (19:54, a 2.56 GB catalog of 164,700 assets, three
OneDrive libraries and an Immich account), visible tiles' reads and the window's reads
waited 5–10 s for their body with `resumeMs=0`, released within 50 ms of each other on both
reader pools. #794 could not rebuild it with probes of the Store alone
(`2026-11-15-shared-reader-waits.md`). Does the whole app's startup, run on generated data,
rebuild it, and which of a SQLite lock (`lockMs`), the Store actor (`storeMs`) or a missing
connection (`waitMs − lockMs`) does it show?

## Method

Nothing touched the reference catalog or the installed app; the test Mac's unified log was read only.

- **Sandbox.** The dev build (`net.melisma.Otos.dev`, main at 977d010f) launched by its
  executable with `CFFIXED_USER_HOME` set to a temporary home, its open catalog checked with
  `lsof` inside that home before each run, quit with AppleScript after it.
- **Data.** Two library folders of generated media: 16,000 and 1,500 distinct 160 px JPEGs
  with EXIF dates, 290 short H.264 movies and 70 movies cut to a third of their length so
  AVFoundation cannot decode them (17,860 files, 73 MB). The first launch scanned them; the
  catalog was then padded in SQL to the reference scale: eight more library roots whose folders
  do not exist, each holding a copy of the 17,860 rows with a digest, a 1 KB gray signature on
  four rows in five, an `asset_metadata` row with a 1.1 KB record and a 3 KB search embedding
  — 160,740 assets, a 1.40 GB file. One padded root's 17,860 rows carry no extraction
  revision, so the metadata refresh walks them as it walked the reference catalog's 14,836.
- **Runs.** Each launch selected the first library through the smoke seam
  (`OTOS_SMOKE_SELECT_ROOT`), so the window's order and the visible tiles' reads ran
  throughout, republished on every enrichment batch. Run 2 relaunched the padded catalog with
  10,011 items left to enrich; run 3 enriched the rest and went idle. The dev build's own log
  (`processID == <pid>`, info and debug) was read back after each run.
- **The test Mac's log.** `log show` of the installed app and of the whole system for
  19:53:50–19:55:10.

## Findings

### The sandbox did not rebuild it

| Run | Load during the run | Reads | Worst `waitMs` | Worst `storeMs` | `lockMs` |
| --- | --- | --- | --- | --- | --- |
| 2 | scan of 17,860 files, metadata refresh skipping 17,860 rows in 1.4 s, enrichment of 10,011 items (hash, render, faces, video faces of 70 undecodable movies) | 1,082 order, 2,143 tile detail | order 89 ms, tile 14 ms | 69 ms | 0 everywhere |
| 3 | scan, refresh, enrichment of the last 2,152 items, then idle | 161 order, 220 tile detail | order 98 ms, tile 4 ms | 75 ms | 0 everywhere |

Every hypothesis the fields can test is unsupported in the sandbox: no read met a SQLite lock,
no tile read waited on the Store for more than 75 ms, and no read waited for a connection for
more than 98 ms. The enrichment claim, a write, waited up to 889 ms for the writer behind scan
batches; that is the writer's queue and is not a read.

### What the sandbox could not have

- **OneDrive.** The reference libraries are File Provider folders of mostly dataless files: the
  scan's enumeration, every `locality(of:)` and every materialization talk to `fileproviderd`.
  Its metadata refresh skipped 14,832 rows in 50.1 s, 3.4 ms a row; the sandbox's skipped
  17,860 in 1.4 s, because an absent root answers `unreachable` without a file system call.
- **Apple's language model.** No description request ran in the sandbox: the generated stills
  never became describable.
- **A cold, 2.56 GB file and a 16 GB Mac under memory pressure.** The padded file had just
  been written and was in the file cache.

### What the test Mac's log does show

- **The 10 s cluster was a whole-process silence.** After the scan batch at 19:54:19.18 the
  installed app logged nothing of its own until 19:54:24.51: no scan batch (they had come every
  1–1.5 s), no materialization, no enrichment. Its last other lines before the silence, at
  19:54:19.37–19.43, are its first Foundation Models request (`createStreamingRequest`,
  `Acquired RBSAssertion … Finish Task Uninterruptable`); its first line after it is that
  request's `CombinedResponseIterator.finish()` at 24.497, on the thread that then logged the
  first released tile read 16 ms later. Later requests took 0.3 s each. From 19:54:20.56
  launchd exited an idle daemon every second for the rest of the window, each with
  `JETSAM_REASON_MEMORY_IDLE_EXIT`: the Mac's memory pressure rose as the model loaded. The
  reads were stalled with everything else; the cause sits outside the reads (unproven: the
  model's load, or paging under that pressure).
- **The 5.7 s cluster was not.** From 19:54:08.6 to 14.38 the writer committed three scan
  batches (364, 544 and 731 ms), the main thread applied two zooms and materializations
  completed, while the window's order read (main pool) and two tile reads (interactive pool)
  waited for their bodies and were released within 3 ms of each other. No idle exits ran yet.
  No line names what held both pools; the fields of 191ffe1a cannot split a missing connection
  from a held queue or SQLite's own retry loop.
- **SQLite's read retry is invisible to `lockMs`.** A WAL reader that finds the log's header
  changing, or no read mark it can take, retries in `walTryBeginRead` with its own sleeps
  (growing to about 10 s over 100 tries before `SQLITE_PROTOCOL`), never calling the busy
  handler that `lockMs` watches. Only a measurement around the start of the read transaction
  separates it from a wait for a connection.

## What changed

- **`op=catalog.store.stall`, written by the waiter.** Every connection of both pools reports
  to `CatalogConnectionActivity` through its SQLite trace: when its transaction began, its first
  statement other than `BEGIN` and GRDB's pragmas, and what the Store named it for (a read's
  calling function; a timed write's). A read that reached its body one second or more after it
  was asked writes one line as its body starts, with:
  - `storeMs` (asked → its pool was called), `waitMs`, and `waitMs` split at the instant the
    connection's queue ran `BEGIN`: `connectionMs` before it (no free connection, or no thread
    for the queue) and `snapshotMs` after it (SQLite taking the read: the busy handler's
    `lockMs`, plus the retry loop above, which nothing else sees);
  - `running`: every other connection in a transaction, with its age, name and statement;
  - `endedDuringWait`: every transaction of 50 ms or more that ended after the read was asked;
  - `idle`: the connections in no transaction; `lastResumed`: the read whose caller last
    resumed, and how long ago, which is what a Store holding its actor after a read is doing.
  Nothing polls: the waiter knows it waited (ADR 0033).
- Nothing else changed: no mechanism was proven, so no owner was moved.

## What one launch on the reference library will now say

For a read that waits a second or more, one line decides it:

- `connectionMs` large, a pool's connections all in `running` or in `endedDuringWait` with
  long holds: reads held the connections, and their names and statements say which.
- `connectionMs` large with that pool's connections idle: the queue had no thread — the
  process was stalled, as the 10 s cluster looks; `running` and `endedDuringWait` then show
  what else stopped with it.
- `snapshotMs` large with `lockMs` 0: SQLite's read retry; `lockMs` large: a lock, and the
  writer's entry in `running` says which transaction held the log.
- `storeMs` large: the Store, with `lastResumed` naming the read it last resumed after.

## The open's status in a running build

The same sandbox catalog was put two migrations behind (v62's index and generated columns and
v63's index dropped, their `grdb_migrations` rows deleted) and the dev build launched while
`screencapture -l` took its window every 0.2 s:

- `Updating catalog…` over `Step 1 of 2` (v62, 2,523 ms), then `Step 2 of 2` (v63, 474 ms),
  then `Opening catalog…` with its second line blank, each over one indeterminate indicator at
  the content area's center, the title line on the same pixel row in all three (DES-121,
  DES-053). The sidebar held All Media, On This Day, People and Places and nothing else, for a
  catalog of ten library roots. Typographic ellipses (DES-037A). A grayscale copy keeps the
  status legible (DES-029).
- One captured frame after the status left drew the loaded window over an empty content area,
  no indicator, before the grid's first frame: the frame between the catalog's state and the
  grid's apply, which DES-118 allows.
- The window's title read `Library` while the catalog opened and `LibA` once it loaded: the
  selected library's name is the catalog's to read.
- A second launch, in light appearance, ran both updates in 0.9 s, before the window's first
  frame, so the status was never drawn: only the loaded light window was captured.

Move to Trash and the two failure alerts were not seen in a running build: driving the window
needs UI access, which was not granted, and the smoke seam selects a scope but has no command.

## Conclusions

- The whole app's startup on generated data at the reference row count did not make any read
  wait more than 98 ms; the reference launch's waits need something the sandbox lacks.
- The reference launch's 10 s wait was the whole process going quiet as Apple's language model first
  loaded under rising memory pressure; its 5.7 s wait held both reader pools while the writer
  and the main thread ran, and its holder is unknown.
- The next launch's `op=catalog.store.stall` lines name the holder, or show that there was
  none in Otos.
