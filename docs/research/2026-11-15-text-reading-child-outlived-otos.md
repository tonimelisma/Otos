# A text-reading child outlived the Otos that started it

2026-11-15. Follows `2026-11-15-a-card-left-waiting-for-metadata.md`: during that pass's
verification, each quit of a sandboxed dev build left an `Otos --read-text` child running,
12 after 12 launches, at 0% CPU inside a Vision reading; the one watched exited about eight
minutes later.

## Mechanism (proven)

- **What ended a child.** `SearchTextReadingProcess.serve` read its requests with `readLine` on
  its one thread and read each picture on that same thread. Its input's end was the only thing
  that ended it, and it saw that end only between readings.
- **What a quit did.** Otos exits without ending its search index (`applicationShouldTerminate`
  answers `.terminateNow`), and the kernel closes its descriptors, so the child's input did
  end. But a child inside a reading was blocked in Vision, and a first reading in a cold
  process compiles the model: minutes (269 s and 218 s measured in
  `2026-11-15-text-reading-lost-to-a-cache-purge.md`). It read its input's end only after that,
  wrote an answer no one read, and exited.
- **A crash or a kill** closes the descriptors the same way, with the same delay.
- **Who else holds the pipe.** Nothing. `Process` closes every descriptor but 0–2 in a child it
  starts: a second child started from the same process listed none of the first child's pipe
  descriptors (a probe, 2026-11-15). Otos is the pipe's only writer, so the input's end is a
  complete fact for "Otos is gone or ended this session".

**Reproduced on real Vision.** `logs/vision-orphan.sh` (not committed) starts the built
executable with `--read-text` under a `/bin/sh` parent and a scratch `CFFIXED_USER_HOME`, so the
first reading compiles cold, sends one picture, waits 20 s, and kills the parent with SIGKILL.

| Build | Child 20 s in | After the parent's kill |
| --- | --- | --- |
| `origin/main` c9c6e2a7 | `R`, 1.66 s CPU | still running 60 s later, parent 1 (launchd), 5.83 s CPU; killed by the script |
| this change | `S`, 1.19 s CPU | gone within the script's first 0.1 s check after the kill |

## Change

- **The child reads its input on a thread of its own**, which never reads a picture, and exits
  the process (`_exit(0)`, `op=search.text phase=childInputEnded`) at the input's end, mid-reading
  or not. Readings run on a serial queue; Otos asks for one picture at a time, so at most one is
  queued. One fact covers every way Otos ends: a session ended, a quit, a crash, a kill. A
  watch on the parent's pid (`NOTE_EXIT` on `getppid()`) was not added: it would answer the
  same question a second way, and the pipe's end is already complete because Otos is its only
  writer.
- **The reader's shutdown ends the live child and waits for its exit.**
  `SearchTextReader.shutdown` is not isolated to the reader, because a reading holds the
  reader's queue until its session answers or ends. It marks the reader shut down and ends the
  session it recorded: `SearchTextChildLifetime.end` closes the input and returns when
  `Process.terminationHandler` reports the exit. A session is started and recorded under the
  same lock as the mark, so none starts after it and none escapes it. `PhotoSearchIndex.shutdown`
  calls it, and the window's teardown now shuts the index down with the other owners.
- **A quit adds no step.** The input closes with Otos, and the child exits at once.
- **The still being read stays owed.** A reading cut short comes back `.exited` (no answer) or
  `.ended` (its request could not be written). Neither is a result, so nothing is stamped, and
  the reader returns `.sessionEnded(before:)` without starting another session.

## Tests

All use real child processes and wait on the exit the kernel or `Process` reports, never on
time.

- `aChildWhoseInputEndsMidReadingExits`: 20,000 requests for a missing picture, whose answers
  (19 bytes each) overfill the unread output pipe several times over, so the child's reading
  thread is blocked writing an answer, as Vision blocks it. The input is then closed, and the
  child exits with status 0. On the old serve loop the test's own write never finishes: the
  child stops reading its input once its output is full.
- `aChildWhoseParentIsKilledMidReadingExits`: a `/bin/sh` parent starts the child on two FIFOs
  it alone holds, floods it the same way, and is killed with SIGKILL. The test waits on the
  child's `NOTE_EXIT`.
- `theReadersShutdownEndsTheLiveSessionAndStartsNoOther`: the reader's shutdown during a
  reading returns with the child gone (`kill(pid, 0)` is `ESRCH`), the reading returns
  `.sessionEnded(before: [])`, and a later read starts no session. `cat > /dev/null` stands in
  for a child mid-reading: it keeps its output open (as descriptor 3) and never answers, and
  exits at its input's end. A first version sent its output to `/dev/null`, which closed the
  answers pipe at once: the reading came back `.exited` before the shutdown, and under the full
  suite's load a second session started (`started.count` 2) before the shutdown landed.
- `aReadingCutShortByShutdownStaysOwed`: the same stand-in under a real `PhotoSearchIndex`.
  After the index's shutdown, both stills are still text candidates.

## Other processes Otos starts

- **`SearchTextChild`** is the only process the app starts itself (`Process(`, `posix_spawn`,
  `NSTask`, XPC, `fork` and `system` searched in `Otos/`). Its lifetime owner is
  `SearchTextReader`.
- **Open With and Reveal in Finder** (`WorkspaceOpening`, `NSWorkspace`) ask LaunchServices to
  open another app. That app is the user's own and is meant to outlive Otos.
- **Tests:** `hdiutil` (`MountedTestDiskImage`) and `touch` (`CatalogFilesystemWatcherLiveTests`)
  are each run to their exit and waited on. The new lifetime tests kill every process they
  start in their own teardown.
