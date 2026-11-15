# What holds the cooperative pool, and why visible tiles' reads still waited (2026-11-15)

## Question

#765 (`2026-11-15-small-scope-reads-and-tile-waits.md`) proved that an import's eight
blocking copies took every cooperative-pool thread, moved copies to a dedicated queue, and
amended ADR 0032's rule 6 to separate work that computes (the pool) from work that waits (a
dedicated queue). It left every other owner alone as unproven, and one wait unexplained: at
06:29:08→06:29:38 a visible tile's detail read logged `waitMs=30070 execMs=9` with no import
running. On the installed build ad84ab33 (screen locked, no import, only background
enrichment) visible tiles' detail reads still waited 1,018–6,197 ms between 09:45:52 and
09:48:02 with `execMs` 1–229. Which owners can starve the pool, and what held those reads?

## Method

- **Inventory.** Every place app code holds a thread inside the pool: the call, the mechanism
  it runs under, the priority it runs at (traced to where its task is created) and how many can
  run at once.
- **Probe.** A temporary test (never committed) holding N tasks of a kind at a priority, with
  a GRDB `DatabasePool` of two readers (as `interactiveReader`), asking a user-initiated read
  six times, 250 ms apart, **from a dispatch queue**: the instant a read is asked must not
  itself wait for a pool thread. (A first version asked from the test's own task after a
  `Task.sleep`; the sleep's resumption waited for the pool with everything else, so every
  read measured 0 ms and the version was discarded.) Kinds: a semaphore wait (2 s), a
  `copyfile(3)` of a 400 MB file, a SHA-1 of it read with `F_NOCACHE` in 1 MiB `read(2)`s
  (`ContentHasher`'s loop), 20 `volumeAvailableCapacityForImportantUsage` reads (CacheDelete
  XPC, `FreeSpaceFloor`), and a 2 s busy loop. Priorities `.userInitiated`, `.medium`,
  `.utility`; 8 and 16 tasks; an 8-core Mac (6 performance cores) running other sessions'
  checks.
- **Owner probe.** Eight `MediaEnricher.live` workers enriching 48 generated 24 MP JPEGs
  (metadata, rendering, digest), as `EnrichmentCoordinator` runs them, at `.userInitiated`
  and `.utility`, with a user-initiated read asked every 150 ms.
- **The 30 s wait.** The installed app's log (`log show`, 06:28:40–06:29:42) and
  `pmset -g log`.
- **The installed app, live.** Its log for 09:45:50–09:48:05 and `sample` of its threads
  (read-only, 5 s and 30 s).
- **Release probe.** A pool of two connections; two `.utility` reads take both, each body
  holding 300 ms on its connection's queue; sixteen 2 s `.utility` busy tasks then take every
  utility thread; a user-initiated read asked from a dispatch queue 400 ms in. Three rounds
  through GRDB's async `read`, three through its callback `asyncRead`.

## Findings

### Priority decides starvation, not waiting versus computing

| Kind, 8 tasks / 16 tasks | `.userInitiated` | `.medium` | `.utility` |
| --- | --- | --- | --- |
| Semaphore wait, 2 s | read waits up to 1,745 / 3,739 ms | 0 / 0 | 0 / 0 |
| `copyfile` 400 MB | 1,198 / 2,853 ms | 0 / 0 | 0 / 1 ms |
| SHA-1, uncached 1 MiB reads | 47 / 278 ms | 0 / 0 | 14 / 0 ms |
| CacheDelete capacity read ×20 | 0 / 0 | 0 / 0 | 0 / 0 |
| Busy loop, 2 s | 1,756 / 3,749 ms | 2 / 19 ms | 1 / 1 ms |

- Eight tasks at the read's own priority that hold their threads — blocked **or computing** —
  make a user-initiated read wait for one of them to finish. Sixteen ran in two waves (held
  4.0 s for 2 s tasks): the pool gives a priority one thread per core.
- The same tasks at `.medium` or `.utility` never delay it: higher-priority work gets threads
  of its own.
- A hash's many short reads and CacheDelete's XPC replies hold a thread only briefly; neither
  starves the read even at `.userInitiated`.
- Every background owner Otos starts runs at `.userInitiated`: `CatalogWindowViewModel.start()`
  runs on the main thread, so the `Task {}` that starts enrichment, materialization, search,
  faces, descriptions, place names, render signatures and metadata refresh inherits
  user-initiated priority, and each owner's own loop and children inherit it again. So a
  background owner that held eight threads would starve visible tiles exactly like the import's
  copies did.

### No owner holds eight threads

| Owner | What holds a pool thread | At once | Probe |
| --- | --- | --- | --- |
| Enrichment (`MediaEnricher` in `EnrichmentCoordinator`'s group) | digest read (`ContentHasher`), metadata read, thumbnail write; the render runs on `ImageRenderer`'s queues, faces on `FaceAnalyzer`'s, camera and Immich ranges on their own queues | 8 | eight workers, 24 MP JPEGs: read waits 0 ms nineteen times, 53 ms once (`.userInitiated`); 0 ms (`.utility`); items 345–371 ms median |
| Import (`MediaImportExecutor`) | copies on `CopyfileTransfer`'s queue (#765); the staged copy's digest on the pool | 8 | SHA-1 row: 47 ms at 8 |
| Materialization (`MaterializationCoordinator`) | `floorReading` (CacheDelete XPC), `startDownloadingUbiquitousItem`, `lstat`; arrival is a vnode watch | 16 | CacheDelete row: 0 ms; the provider request is an XPC send, not measured |
| Grid thumbnails (`MediaGridBridge`) | decode of a stored thumbnail, a few ms | one per visible miss | user work itself |
| Trash, export, reorganization, hand-off, Immich sync, metadata refresh, preview faces, descriptions, render signatures, People, Duplicates | a move, copy, rename, decode or pass each | 1 each | at most one thread of eight |

No owner was moved: none but the import's copies, already moved, was shown to hold the pool.
Rule 6's split stands for what it guards — a wait of seconds leaves the pool — and ADR 0032's
review check adds the condition the probe found.

### A finished read kept its connection until its task got a thread (proven)

- In the live sample the cooperative pool's threads were idle; the main pool's readers 1 and 2
  ran `photoDescriptionCandidates` and `searchEmbeddingCandidates` for the whole sample, and the
  tiles' own pool (`interactiveReader`) had no thread at work. In the log the enrichment loop,
  which had routed every few milliseconds, stopped with the tiles' reads and resumed with them
  (09:46:03.64 → 09:46:10.57, the read logged at 10.56 with `waitMs=5158`), while downloads'
  completions ran on pool threads throughout.
- GRDB's async `read` (`DatabasePool.read`, `Pool.get(block:)`) gives its connection back in a
  `defer` of an async function in GRDB's module, which resumes on the cooperative pool at the
  reading task's priority. A read whose body has ended keeps its connection until its task gets
  a thread of its own priority back. The grid's preheat reads tiles at `.utility`
  (`MediaGridPrefetch`); a background or utility read that cannot resume holds a connection it
  no longer uses, and two of them hold the whole tiles' pool.
- Release probe:

| API | User read's wait, rounds 1–3 |
| --- | --- |
| GRDB async `read` | 3,770, 3,707, 3,674 ms |
| `asyncRead` (callback) | 0, 0, 0 ms |

- Which reads held the connections at 09:45–09:48 is not in the log, which named no priority;
  the mechanism is proven, its trigger on that machine (utility threads throttled while the
  screen was locked, or taken by other work) is not.

**Fix:** every store read runs through `DatabaseReader.readFreeingConnection`, built on GRDB's
`asyncRead`: the connection goes back to its pool from its own queue as the body returns,
whatever the caller's task waits for. Cancelling the task interrupts the body's statement
(`sqlite3_interrupt` on that connection, under a lock the body takes and gives back the
connection under) and the read throws `CancellationError`, as GRDB's own read does.
`ReadFreeingConnectionTests` hold the reading task on a suspended task executor and read
through a pool of one connection, and cancel a read mid-statement.

### The 30 s wait was not the pool, as far as the log shows

- At 06:29:27.30, inside the wait, a `MaterializationCoordinator` task (user-initiated, as
  above) ran a completion and dispatched the next download on a pool thread, so the pool had a
  thread at that priority then.
- Nothing that holds a thread ran: no import; the digests of the two videos downloaded at
  06:29:08 and 06:29:27 ran after the wait (`contentHash phase=finish` at 06:29:39, 860 and
  881 ms); text readings started at 06:29:38.58 and failed in 50 ms each; the last photo
  description finished at 06:29:08.15.
- The display was off: `pmset` logs `Display is turned on` and WindowServer `UserIsActive` at
  06:29:32, and the app's own log `kCGSDisplayDidWake` at 06:29:32.26. The process's
  RunningBoard inheritances changed at 06:29:34.18 and 06:29:38.22, and the read entered at
  06:29:38.52, 0.3 s after the second change and 0.05 s before the Dock reopened the app
  (`aevt,rapp` at 06:29:38.57). From 06:29:09 to 06:29:38 Otos's own categories logged only
  the downloads' re-requests and completions and their filesystem events: no enrichment
  pass, no projection, no search.
- That fits App Nap or a RunningBoard role change throttling the process while its window was
  not visible, which `runningboardd`'s retained log does not record, so it stays **unknown**.
  The tile read itself may have been the grid's preheat, which reads at `.utility`
  (`MediaGridPrefetch`); the line did not say.

### `waitMs` now says which wait

`timedRead` and `timedWrite` measure three spans, and every store query's greppable line
carries them with the caller's priority: `waitMs` (asked → the body runs: for a read, a free
connection and its queue, no longer through the cooperative pool), `resumeMs` (the body ends →
the Store continues: a pool thread at `priority`, then the Store actor), and `priority`. Reads
holding every connection show in `waitMs` alone; a pool with no thread free at that priority,
or a busy Store, in `resumeMs`.

## Conclusions

- The cooperative pool is one thread per core per priority. Eight tasks holding threads at the
  priority of user work — waiting or computing — hold up user reads; at `.medium` or below
  they never do.
- No owner but the import's copies (#765) was shown to: enrichment's eight workers spend their
  time on queues of their own, and hashing and CacheDelete hold a thread only briefly.
- A read's connection went back to its pool only when its task got a thread again, so reads
  that could not resume held the visible tiles' connections: 3.7 s on the probe, 1–6 s on the
  installed app. Every store read now frees its connection as its body ends.
- The 30 s wait coincides with the display off and the process's role changing as it woke;
  the held-connection mechanism fits it, and the log cannot say more. The next one will say
  its priority and whether the connection or the thread held it.
