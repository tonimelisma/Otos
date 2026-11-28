# The first search while the text encoder loads (2026-11-16)

## Question

After the first search's encoder load became a load the user waits on
(`2026-11-16-first-search-after-launch.md`), the reference tours measured the first search,
typed about 5–6 s after launch, at 476, 636, 1,606 (before that change), 382, 725 and then
2,582 ms on final `main` 7138219e. It passes when the text encoder is ready and fails when the
search arrives while it loads. What did the 2,582 ms go to, why did the load take 3 s, and what
design keeps a first answer under 1 s whatever the load costs?

## Evidence: the failing session (installed app, read-only tour)

Local times, from the app's unified log (pid 66189):

| Time | Line | Meaning |
| --- | --- | --- |
| 19:45:33.196 | session start | |
| 19:45:34.370 | first grid; People granted | |
| 19:45:38.347 | `load.admission granted load=searchPrepare request=4 waitMs=3689 waiter=background` | the first grid's readying, last of the loads |
| 19:45:38.347–.380 | Translation's language list | `supportedLanguages`, 33 ms |
| 19:45:38.490 | `(MIL) MMapped … size 126180` on the encoder's queue | Core ML maps the model's program |
| 19:45:38.956 | `(MIL) MMapped … size 86414592` | Core ML maps the weights |
| ~19:45:39.5 | the tour types its query | |
| 19:45:39.766 | `search.prepare done ms=250` | the intent's scope rows; the encoder is still loading |
| 19:45:41.424 | `search.encoder phase=loaded ms=3043` | |
| 19:45:41.704 | `search.encode first=true ms=233` | the query's reading, queued behind the load on the encoder's queue |
| 19:45:42.003 | `search.match ms=261 matched=433 textMatches=11` | |
| 19:45:42.099 | `tour step searchMany resultMs=2582` | |

The query waited about 1.9 s for a load already in flight: the encoder's queue held the
synchronous load, and every step of a reading (even recognising its language) ran on that queue.

## Evidence: what the 3 s load did

The installed app's Caches folder holds Core ML's compiled programs
(`com.apple.e5rt.e5bundlecache/26A434/<key>/<bundle>/H13S.bundle/main/main_bnns/bnns_program.bnnsir`).
For this session's key:

- The bundle directory was created at 19:45:38 and its `bnns_program.bnnsir`, 342,914,402
  bytes, was last written at 19:45:41, the second the load ended. So this load compiled the
  text tower afresh and wrote a 343 MB BNNS program while it ran.
- The key's parent directory was created at 19:42:11 by the session the install launched
  (pid 65917), whose load took 433 ms (mapped weights at 19:42:11.462, loaded at 19:42:11.772).
  Its bundle is not there: the one present is the 19:45:38 one.
- 82 keys sit beside it, one per install of the last days; all but the current one are empty
  (0 B), so the compiled program is kept for one install at a time. The cache was 333 MB.
- No Core ML, Espresso or e5rt line in the log names a compile, a cache miss or a deletion.
- The Mac had about 380 MB free and 4.8 GB of swap during the load (`op=process.memory`).

Established: the 3,043 ms load included Core ML compiling the model and writing 343 MB.
Unknown: why the compile of the 19:42 session of the same install was not reused, and why
this compile took 3 s where the 19:42 load took 433 ms (the memory pressure is consistent with
it but was not separated from the compile's own cost).

## Decision

**A query's first answer never waits on the text tower** (ADR 0048, "The words first"):

- The model moves to its own owner, `SearchTextTower`, on its own serial queue; the encoder's
  queue only awaits it. A **words reading** (`SearchQueryEncoder.wordsReading`) reads the query
  as typed with no tower, no Translation and no new Maps lookup: its facts (dates, people, a place
  Maps answered before) and its picture words, which only the words Vision read in photos match
  (`SearchQueryPicture.unread`). Its matches are shown at once, still searching (`refining`).
- The reader never awaits the load. A query read while the tower is not prepared is read for its
  words, the load is started as a named task (a load the user waits on), and the loop returns to
  its doorbell; the load's end rings it. The first grid's readying awaits the same task, so there
  is one load whoever asks first.
- A query whose words match nothing keeps what the window shows, still searching (DES-108,
  DES-120): an unknown is not "no results".

On the failing session's numbers the words reading would have published the 11 photos whose
text matched within the time of a reading and a match (about 0.5 s after the query, the encode
and match steps measured at 233 and 261 ms under that load), and the picture's 433 at the load's end.

**Rejected:**

- **Readying the encoder earlier, ahead of People and duplicates.** It would move a load of
  433–3,043 ms (measured above) ahead of People's first pass, which the People view waits on,
  while the search's first answer no longer waits on it either way; a query already loads it as a
  load the user waits on. Launch to first grid is unaffected either way: loads start after it.
- **Keeping the compiled model in Application Support.** The compiled program the load wrote is
  Core ML's own device compilation (`e5rt` BNNS), placed in the process's Caches; no public Core
  ML API names where it goes or loads one from elsewhere, and the app already ships the model
  compiled (`.mlmodelc`). Loading only the text function does not apply: the text tower is its
  own model. Nothing here makes the load itself cheaper; the design stops anything visible from
  waiting on it.
- **Always reading the words first.** With the tower ready, the picture's answer comes within a
  reading's time, so a words phase would change the grid twice for nothing.

## The scorecard

The tour's search step reports `firstMs` (the first state of the query that is not `reading`:
its first matches, or its answer) and `resultMs` (its complete answer). The scorecard reports
both: `search.firstResultsMs` held to 1,000 ms, `search.completeMs` a number with no target.

## Not measured here

- The tour after the change: the next tour on the reference library.
- Why the 19:42 compile was not reused (above).
