# What visible tiles' reads and the main pool's reads both wait on (2026-11-15)

## Question

After #773 and #775, visible tiles' detail reads still waited seconds for a connection while
background work ran: `op=catalog.store.query.tileDetail requested=25 waitMs=9368 execMs=8
resumeMs=0 priority=userInitiated` on the two-reader `interactiveReader` pool that only those
reads use. #774 saw slow passes on the main pool end within 50 ms of a tile read on the other
pool that had waited as long. On the owner's launch of build 191ffe1a (19:54, catalog open
43 s after migrations v63–v64, a library scan, enrichment, metadata refresh, downloads):
`query.order scope=importBatch waitMs=5780 execMs=23 resumeMs=0` and two tile reads waiting
5.5–5.7 s finished at one instant; tile reads and `filterOptions` waiting 10.1 s finished
within 50 ms of each other; the click on a 30-photo import took 16.8 s to show a 71 ms read
whose `waitMs` was 9.7 s. The WAL stayed at 1.1–1.7 MB against a 64 MiB budget. What can two
separate GRDB pools on one WAL database both wait on?

## Method

All probes were temporary tests, never committed, on generated catalogs deleted afterwards.
Nothing touched the owner's catalog or app. The Mac had 8 cores and ran other sessions'
checks throughout.

- **SQLite probe.** 166,000 rows written by `CatalogStore.upsertScannedFile` with a 1.1 KB
  metadata record each (a 587 MB file), the main pool and a second read-only pool configured
  as the Store configures them. A tile-detail read
  (`CatalogQueryGateway.fetchStoredTileDetails`, 25 IDs) asked every 50 ms **from a dispatch
  queue** on the second pool, its wait measured from the ask to its body, and the duration of
  GRDB's `PRAGMA schema_version` (where a read transaction takes its snapshot) traced per
  connection. Phases: six readers each scanning both tables on the main pool; a scan-like
  writer upserting 500 rows and rewriting their metadata per transaction, continuously; both;
  both plus a truncating checkpoint behind GRDB's barrier every ten batches (as
  `boundWAL`); both under 24 spinning user-initiated threads; both with 600 dispatch blocks
  sleeping on the global queues; both while two threads wrote 8 MB and called `F_FULLFSYNC` in
  a loop (the system SQLite is built with `DEFAULT_CKPTFULLFSYNC`, so every checkpoint
  full-syncs).
- **QoS probe.** `qos_class_self()` inside a GRDB read asked from background, utility and
  user-initiated queues and tasks.
- **Store probe.** The same 166,000 rows (30,000 of them in a real library folder of
  one-byte files, the rest in an absent root), a `CatalogStore` started on the file so the
  library is scanned (`count=9250` per batch, 3.4 s write transactions), four tasks looping
  the window's two main-pool reads (`orderedAssetIDs` and `filterOptions` of All Media), and a
  user-initiated task calling `mediaTileDetails` for 25 IDs every 50 ms, timing each call
  from the caller. The Store's own lines were read back from the process's log.

## Findings

### SQLite, the disk, the CPU and GCD never held the second pool (measured)

| Phase (SQLite probe) | Reads | p50 | p95 | Max |
| --- | --- | --- | --- | --- |
| Idle | 56 | 0.2 ms | 1.7 ms | 6.5 ms |
| Six long readers + scan writer | 152 | 0.3 ms | 0.9 ms | 1.3 ms |
| + truncating checkpoints (0.30–0.34 s barriers) | 111 | 0.4 ms | 7.9 ms | 26.6 ms |
| + 24 spinning threads | 140 | 0.3 ms | 24.3 ms | 228 ms |
| + 600 blocked dispatch blocks | 151 | 0.3 ms | 1.3 ms | 6.9 ms |
| Scan writer + full-sync disk load (writes 200–590 ms) | 185 | 0.1 ms | 0.5 ms | 27.7 ms |
| + six long readers | 227 | 0.2 ms | 0.5 ms | 8.6 ms |

The snapshot (`PRAGMA schema_version`) never took more than 3 ms. A GRDB reader queue runs
at user-initiated QoS whatever priority asked (`qos_class_self()` = 25 from background,
utility and user-initiated callers), so a low-priority read is not I/O-throttled. #765's
small-database probe agrees. None of these makes a second-pool read wait seconds.

### Reads waited for the Store actor, which an order read held (proven)

Store probe, as shipped: tile reads took 1.8 ms at the median, and **every 1.3 s one waited
1,010–1,145 ms** (23 of 112 in 30 s, p95 1,055 ms). The Store's lines show why: each order
read of 166,000 rows ran 207–280 ms on its connection and then held the Store for about
530 ms turning its rows into the window's IDs and day buckets on the actor; the other order
read then logged `resumeMs=532–543`, both `filterOptions` reads finishing beside it
`resumeMs=1016–1066`, and the tile read asked meanwhile waited for the Store to enter
`mediaTileDetails` at all. That wait is in no log line: `waitMs` starts once the Store runs
the read and `resumeMs` once its body ends, so a read queued for the actor shows only in its
caller's wall time.

**Fix:** the order read turns its rows into IDs, day buckets and coordinates inside the read,
on the connection's queue (`CatalogStore.orderedAssets(from:…)`, a pure function of the rows
and the scope's roots taken before the read); a root that left while the read ran is dropped
from the answer on the Store afterwards, which costs nothing unless one did. The order line's
`execMs` now includes that mapping. After the fix, the same probe: 547 tile reads in 30 s,
p50 1.4 ms, p95 2.4 ms, max 47 ms; order reads `resumeMs` 0–6.

### The owner's `waitMs` is still unexplained

The owner's lines put the seconds in `waitMs` with `resumeMs=0`, which the actor stall above
does not produce; it explains the part of his 16.8 s click that no line carried (16.8 s
against a 9.7 s `waitMs` and 71 ms of work), not the 9.7 s. What remains between a read's
ask and its body is GRDB's pool queue, a free connection, `BEGIN` and the snapshot. The
probes rule out every in-process holder they could build; left untested are the 2.5 GB file
itself, memory pressure on the owner's Mac, and a lock held from outside the process (the
10.1 s waits sit just past GRDB's ten-second reader busy timeout, which is suggestive and not
proof). Until a line says which, each read now reports the split:

- `lockMs`: the part of `waitMs` spent on SQLite's locks once the read had its connection.
  Readers wait on locks through `ReaderLockWait`, a busy handler of the Store's own with GRDB's
  ten-second limit and SQLite's own back-off, which notes when the read first found the
  database busy; the rest of `waitMs` is the wait for a connection and its queue. A probe held
  a rollback-journal file's exclusive lock from another connection: a reader with the Store's
  configuration waited 461 ms for a 400 ms hold and then read, and failed with `SQLITE_BUSY`
  after 9.9 s of a hold that never ended, as GRDB's ten-second timeout did. (There the lock
  met the body's first statement, so it counted in `execMs`; a pool read meets it in GRDB's
  `PRAGMA schema_version` before the body, which is what `lockMs` counts. No WAL lock a probe
  could take in one process held a pool reader, so that path was not driven end to end.)
- `storeMs` on the tile-detail and inspector lines: the caller's ask → the Store runs the
  read (the wait above), and a slow line is written when `storeMs + waitMs + execMs` passes
  50 ms.
- The inspector's read had logged itself as `tileDetail` from the main pool; it is
  `catalog.store.query.assets` now, and reads from the interactive readers, being a read a
  user waits on with something on screen.

### A cancelled read no longer waits for its place

#773 noted a read cancelled while it waited for a connection still waited for one. Its caller
now resumes with `CancellationError` at once; when the pool reaches it, it gives the
connection straight back without running its body
(`ReadFreeingConnectionTests.aReadCancelledWhileItWaitsForAConnectionThrowsAtOnce`).

## Conclusions

- Two pools on one WAL database share no SQLite lock, disk or thread pool that held a read
  more than 228 ms in any probe, at 587 MB with a writer, long readers, checkpoints, a
  full-syncing disk, saturated CPUs and blocked GCD threads.
- What every Store read does share is the Store actor, and an order read held it for half a
  second per 166,000 rows: visible tiles waited a second at a time, invisibly. That work now
  runs in the read.
- The owner's seconds-long `waitMs` remains unknown; the next one says whether it was a lock
  (`lockMs`), a connection (`waitMs − lockMs`) or the Store (`storeMs`).
