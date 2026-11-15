# Vision's text reader is lost for its process when its compiled model's files go

Date: 2026-11-15. Context: the installed app (build 32f39417, launched 00:18) failed every
`op=search.text` reading from 00:34:08 to 07:25 with
`e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)`:
8,576 failures, 8 at a time, and a two-hour pass that read nothing. This pass explains it and
joins the two earlier notes (`2026-11-13-e5rt-shared-compiled-model-cache.md`,
`2026-11-14-vision-text-reading-breaks-for-its-process.md`).

## One error, two spellings

`e5rtError(_, 13)` is a case of `TextRecognition.CRImageReaderError`; bridged to `NSError` it is
domain `TextRecognition.CRImageReaderError`, code 1, with no underlying error. The 11-14 note
printed the bridged form, so its "`CRImageReaderError` code 1, no `e5rt` error" is this same
failure. The case carries the runtime's message (`String`) and its status (`UInt32`: 13 here,
10 for the deadline overrun of the 11-13 note), which `Mirror` reads from the typed value
(`.0=String:…`, `.1=UInt32:13`, printed by the probe from the real error).

## What the installed app's log shows

From `/usr/bin/log show` of process 69229 (and 37674, the process before it):

| Process | Last reading that succeeded | Purges (`deleted_helper`, `fsctl purged`, urgency 3) | First failure |
| --- | --- | --- | --- |
| 37674 | before 00:10:47 | 00:10:47–00:10:48, 2.9 GB | 00:11:17 |
| 69229 | 00:33:20 (a page of 8) | 00:33:45–00:34:02, 10.8 GB in five purges | 00:34:08 |

- The data volume was 98% full (11 GB free of 460). `deleted` purged every few minutes all
  night.
- The app's own cache, `~/Library/Caches/net.melisma.Otos/com.apple.e5rt.e5bundlecache/26A434`,
  holds 47 keys and 9 files. The text reader's bundle (`0DF0EC…/A357A9….bundle`, the key the
  11-13 note tied to this reading, created 00:20:21 at this process's first reading) has its
  folders and no file: no `H13S.e5`, no `main/main_ane/model.anehash`. The folders' times
  (`H13S.bundle` 04:50:45, `main_ane` 06:14:49) fall within a second of purges at 04:50:46 and
  06:14:49: the purge empties them.
- The failures arrive 8 at a time because the index reads a page of 8
  (`PhotoSearchIndex.drainTexts`, `searchTextCandidates(limit: 8)`), one after another on the
  reader's serial queue, each failing in about 15 ms after its preview decoded. Otos never
  reads two previews at once.
- The other Vision readers in the same process did not break: from 00:18 to 07:30 it logged
  314 `op=face.analyse phase=finish`, three `op=search.index phase=embedded` (the scene
  classifier runs in that pass) and no `op=search.embed phase=failed`.
- Apple's description model (#751) ran all along, from 00:18 on, while text was read without
  error until 00:33:20; nothing in-process changed at 00:34 except the purge.

## Experiments

A standalone binary (`logs/probe/probe.swift` during this pass; not committed) does
`SearchTextReading.read`'s request on the 1,200 × 800 sign ("OTOS SEARCH 2026"), with
`CFFIXED_USER_HOME` set to a scratch home so each process has its own empty cache. Load
average 25 on 8 cores, other sessions' checks running.

| Run | Steps | Result |
| --- | --- | --- |
| A | read, read, delete every file in the cache, read ×2 (CPU), read (default device), read with Swift `RecognizeTextRequest`, wait 20 s, read, remove the whole cache folder, read ×2 | first read 269 s (compile), second 1.3 s; **every read after the deletion failed** with `e5rtError(…, 13)` in 40–600 ms, on every device and API, after the wait, and after the cache folder was gone |
| B | read, read, delete only the three `model.anehash` files, read ×2, Swift API | first 218 s, second 0.96 s; every read after the deletion failed with `e5rtError(…, 13)` |
| C | 8 first readings at once (`concurrentPerform`), then read ×3 | after 371 s **one read, seven failed** with `e5rtError(…, 13)`, and every later reading in the process failed the same way |
| B2, A2 | a new process on B's and A's damaged caches | see "A new process" below |

- **The trigger is proven:** a compiled file of the bundle disappearing while a process holds
  the model reproduces the app's error exactly, and the process never reads again. The purge
  timestamps place that disappearance at the app's onset; that the 00:33:45–00:34:02 purges
  removed this bundle's files is inferred from the folder times and the empty bundle, since
  `deleted` logs paths as `<private>`. Run A2 below caught a purge emptying a freshly compiled
  bundle and the next reading failing.
- **Concurrent first readings are a second trigger:** eight readings compiling at once leave the
  process lost the same way. Otos does not do this: its one reader reads on one serial queue.
  Every serial first reading measured here and in the earlier notes compiled and read.
- **Nothing in the process recovers it:** not a new `VNRecognizeTextRequest` and
  `VNImageRequestHandler` (every reading makes both), not the default compute device, not the
  Swift `RecognizeTextRequest`, not 20 s, and not removing the cache so the runtime would
  compile again. The runtime keeps the loaded model for the process and never reloads it.
- **A new process recovers it**, until the next purge (11-13 note, run 3: a file missing
  before a load is recompiled in about 4 s; and B2/A2 below).

## A new process, and a purge caught in the act

- **B2**, a new process on B's cache (the `model.anehash` files gone): read in 261 s, then in
  0.38 s. The new process rebuilt what was missing and read.
- **A2**, a new process on A's cache (removed by A): its first reading compiled and read in
  127 s, at 06:38:56–06:41:03; **its second reading failed** with `e5rtError(…, 13)`. The text
  bundle it had just written (`0DF0EC…/A357A9….bundle`) was left with its folders and no file,
  `main/main_ane` modified at 06:39:22. `deleted_helper` purged 6.8 GB at 06:39:20–06:39:22.
  Nothing else touched that scratch home. This is the purge doing to a test binary, unprompted,
  what A did by hand — and the 11-14 note's pattern, "the first reading succeeds, every later
  one fails", in a machine whose checks fill the disk.

## What this means for Otos

- A failure with status 13 says nothing about the photo: it is the reader's, for the rest of
  the process. Retrying it, in the pass or after the backoff, decodes a preview and fails for
  every still owed. That is what the installed app did for seven hours.
- `SearchTextReader` now tells it by the typed error (domain, code, the case's status 13) and
  stops: the page ends, nothing more is decoded or recognised in the process, the stills stay
  owed, and `op=search.text phase=readerLost` is logged once. The next launch reads them.
  Status 10, a cold reading's deadline overrun, stays a failure of one reading.
- **Rejected: reading in a short-lived helper process.** It would recover without a relaunch, at
  the cost of a new target and an XPC boundary, and of recompiling the models (4 s with one file
  gone, 120–650 s for a cold cache under load) after every purge. On the owner's disk the purges
  came every few minutes for hours, so a helper would spend its time recompiling into a cache
  the next purge empties. The cause is disk pressure, which Otos does not own; freeing space is
  the owner's.
- **Rejected: deleting or rebuilding the runtime's cache from Otos.** A removed cache does not
  bring the process back (run A), and the cache belongs to the runtime.
- **Unknown:** whether status 10 can also lose a process (not reproduced here), and whether a
  purge of another model's bundle (face, scene labels) could lose those readers the same way;
  in the installed app they kept working through the night, and they were not measured here.
