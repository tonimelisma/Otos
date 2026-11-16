# The performance baseline on the owner's library (2026-11-16)

## Question

What does Otos feel like on the owner's Mac today, before and after plan 0116's first stage,
and where do the time, the memory and the disk go? This is the "before" every later
performance PR is measured against (plan 0116, `docs/plans/0116-performance-program.md`).

## Method

Read-only, on the owner's own library and the installed app. Nothing was written to his
catalog or his folders, and no copy of either was made.

- **Scorecards** (`script/scorecard.sh`) read from the unified log of three sessions of the
  installed app: two from before stage 1a, read back by session id, and one read-only tour
  (`script/scorecard.sh --tour`) on build 661be172, after stages 1a and 1b.
- **Surveys** (`script/survey.sh`): two four-minute sessions of the installed app with no
  clicks, one before the fix and one on 661be172, each with a Time Profiler trace, memory
  by region, heap at the peak, per-process disk and CPU counters, and folder sizes.
- **The static survey** (`docs/research/2026-11-16-broad-survey-static.md`) for the
  machine, the disk and the backlog.
- **The migration's cost** from the installed app's own `op=catalog.migration` line.

No benchmark was run. Numbers and kinds only: no paths, file names, people or search text.

| Session | Build | When | Length | What ran |
| --- | --- | --- | --- | --- |
| A | installed 487baebd | 2026-11-15 21:56 | 90 s | launch, an import click, an All Media click |
| B | installed, before stage 1a | 2026-11-15 23:14 | 187 s | launch, no clicks |
| Survey before | installed, before stage 1a (the survey's folder names 487baebd) | 2026-11-16 00:47 | 256 s | launch, no clicks |
| Survey after | installed 661be172 | 2026-11-16 00:56 | 250 s | launch, no clicks |
| Tour | installed 661be172 | 2026-11-16 01:01 | 235 s | the full read-only tour |
| After-tour | installed f192041a | 2026-11-16 02:07 | 166 s | the full read-only tour |
| Switch-off tours | installed f192041a | 2026-11-16 02:11 to 02:13 | 26 to 76 s | sidebar steps with every owner off, the search index alone, People alone |

The survey records only the checkout's revision, so both surveys' summaries carry
661be172 in their title line; the build each measured is named by its folder and by its
place in the schema history (the "before" launch ran no migration, so it predates v65).

## The machine

From the static survey: a 16 GB M1 Pro on macOS 27.0.1. Before Otos starts, about 60 to
110 MB are free and about 4 GB are in swap. The data volume had 18 to 24 GiB free during
the static survey and 13 GiB free when this note was written. Other agents' builds keep
the load average at 21 to 27.

## Before the fix

### Sessions A and B (scorecard)

| Number | A | B |
| --- | --- | --- |
| Launch to first grid | 1,673 ms (an import, 36 items) | 4,215 ms (All Media, 158,913 items) |
| Import click to paint, first visit | 2,813 ms | – |
| All Media click to paint, first visit | 14,456 ms | – |
| Store stall lines | 83 (53 in the first minute) | 62 (all in the first minute) |
| Longest connection wait in a stall line | 23,393 ms | 11,787 ms |
| Window reads that waited a second or more | 7 (worst 8,637 ms) | 4 (worst 11,521 ms) |
| Main-thread stalls | 0 | 0 |

The All Media click in session A spent 12,878 ms in its order read: 8,637 ms waiting for a
connection and 4,241 ms running, 2,455 ms of that the stack candidates. Its filter options
waited 1,983 ms and ran 6,288 ms.

Holders named in session A's stall lines (longest hold, times named):

| Holder | Longest | Named |
| --- | --- | --- |
| `mirrorProbes` | 46,663 ms | 35 |
| `readSearchEmbeddings` | 32,845 ms | 13 |
| `peopleSnapshot` | 24,891 ms | 22 |
| `photoDescriptionCandidates` | 23,797 ms | 7 |
| `renderSignatureCandidates` | 20,581 ms | 69 |
| `searchEmbeddingCandidates` | 11,440 ms | 44 |
| `samePhotoCandidates` | 10,358 ms | 30 |
| `metadataRefreshCandidates` | 8,661 ms | 19 |
| `samePhotoDetails` | 7,127 ms | 22 |
| `filterOptions` (the window's) | 6,289 ms | 17 |
| `orderedAssetIDs` (the window's) | 4,241 ms | 13 |

These builds predate the memory checkpoints, so neither session has a footprint.

### Survey before (four minutes, no clicks)

| Number | Value |
| --- | --- |
| Peak footprint (the kernel's lifetime peak) | 3,926 MB |
| Disk read by Otos and its text reader | 55,241 MB |
| CPU on the app's threads (Time Profiler) | 193 s of 201 s traced |
| CPU of the app and its text reader (rusage) | 312 s |
| Main thread on CPU | 1.1 s |
| Store connection waits | 57, 274.9 s in all, longest 19,684 ms |
| Main-thread stalls | 0 |
| System free memory | 62 to 307 MB |
| Swap | 5,140 to 6,287 MB (grew 1,147 MB) |

Where the CPU went (first Otos frame): SQLite statements 88.3 s, `PersonRun` 22.8 s,
`BlockedSimilarity` 14.9 s, `PathFingerprint` 8.4 s. Self time: `pread` 52.0 s.
At the peak the heap held 1.62 GB of `Float` arrays (205,962 of them: face and search
vectors), a 252 MB face-tile dictionary and 137 MB of label dictionaries.

## After stages 1a and 1b (build 661be172)

### The tour

| Step | Click to paint | Notes |
| --- | --- | --- |
| Launch to first grid | 4,038 ms | All Media, 158,913 items; window attached at 662 ms, catalog open at 83 ms |
| Import (first) | 676 ms | 109 items |
| Library (first) | 1,008 ms | order read 422 ms, publish 817 ms |
| People (first) | 48,818 ms | |
| A person (first) | 4,094 ms | order read 3,563 ms, of it stack candidates 2,325 ms |
| Places (first) | 1,469 ms | order read 1,093 ms |
| On This Day (first) | 137 ms | |
| Duplicates (first) | 193 ms | |
| All Media (return) | 545 ms | its filter options then ran 16,423 ms after the paint |
| Scrolls (six) | 52 to 226 ms | |
| Open a photo, next and previous ×3, Compare, Info | skipped | `noLocalOriginal`, `noLoupe`, `needsTwoLocalPhotos`: every original is cloud-only |
| Search, many results (429) | 9,281 ms | |
| Search, few results (53) | 19,899 ms | |
| Clear the search | 24,818 ms | |
| Filter: videos | skipped | `queryUnchanged` |
| Sort by name | 41,806 ms | |
| Idle | 60 s | |

| Number | Value |
| --- | --- |
| Store stall lines | 62 in 235 s (3, 23, 12, 24 by minute) |
| Window reads that waited for a connection | 0 |
| Longest connection wait in a stall line | 21,721 ms (a background read) |
| Main-thread stalls | 0 |
| Writer waits | 4, worst 1,117 ms (`claimedEnrichmentCandidates`) |
| Peak footprint | 3,730 MB (last 3,025 MB) |
| System free memory, lowest | 86 MB; swap up to 5,991 MB; one pressure warning at 135 s |
| CPU | 328.6 s in 235 s |
| Disk read / written | 49,414 MB / 629 MB |
| Store changes | 277, of them 227 `copies` |

Footprint at each milestone: session start 18 MB, catalog open 23 MB, window attached
81 MB, first grid 355 MB, search index loaded (at 21.3 s, matrix 482 MB) 2,179 MB, People
built (at 54.8 s) 1,912 MB.

Reader time by operation (the main pool's readers were busy 663.9 s in 235 s; the
interactive pool's 3.0 s; the writer 12.9 s):

| Read | Total | Transactions | Longest |
| --- | --- | --- | --- |
| `peopleSnapshot` | 131.1 s | 4 | 35.8 s |
| `samePhotoCandidates` | 122.8 s | 5 | 37.3 s |
| `filterOptions` | 106.4 s | 11 | 32.8 s |
| `samePhotoDetails` | 64.4 s | 405 | 2.2 s |
| `orderedAssetIDs` | 63.7 s | 14 | 25.4 s |
| `currentSearchEmbeddingIDs` | 48.5 s | 7 | 13.3 s |
| `unnamedPlaceCells` | 30.5 s | 224 | 0.6 s |
| `searchEmbeddingCandidates` | 29.6 s | 8 | 4.9 s |
| `readSearchTexts` | 25.7 s | 9 | 3.5 s |
| `readSearchEmbeddings` | 19.9 s | 1 | 19.9 s |
| `searchTextCandidates` | 10.3 s | 8 | 1.5 s |
| `photoDescriptionCandidates` | 8.8 s | 4 | 2.5 s |

The idle minute was not quiet: 84 s of CPU, 12.4 GB read, 59 store changes a minute (55 of
them `copies`), 1,076 transactions and 24 stall lines.

### Survey after (four minutes, no clicks)

| Number | Before | After |
| --- | --- | --- |
| Peak footprint | 3,926 MB | 3,175 MB |
| Disk read | 55,241 MB | 33,750 MB |
| CPU (Time Profiler) | 193 s | 143 s |
| CPU (rusage) | 312 s | 261 s |
| Store connection waits | 57, 274.9 s, longest 19.7 s | 46, 251.7 s, longest 20.9 s |
| `pread` self time | 52.0 s | 24.4 s |
| Swap | grew 1,147 MB | fell 173 MB |
| `Float` arrays in the heap at the first peak | 823 MB | 769 MB |

Stage 1 cut the app's disk reads by about 40 % and halved its `pread` time, and the tour's
window reads no longer waited. Background reads still waited 252 s in all for a connection
in a 250 s session, and the footprint fell by a fifth. People (`PersonRun`, `Fill`) and duplicates (`BlockedSimilarity`) are still the
largest CPU owners after SQLite.

## After stage 2 and the search index's paged load (build f192041a)

Installed build f192041a holds #807 (each owner wakes only on what its own SQL reads), #809
(a digest write wakes the copy-built owners only when it changes what is a copy), #810 (a
face's embedding in its own table, v66) and #811 (the search index loads once, in pages).
The tour ran on 2026-11-16 at 02:07, 166 s, read-only, the same steps as the 661be172 one.
The first after-tour, on build 5d80f22e, ran on an overloaded machine and is not evidence.

| Number | 661be172 | f192041a |
| --- | --- | --- |
| Store stall lines | 62 | **0** |
| Launch to first grid (All Media) | 4,038 ms | 2,760 ms |
| Import, first | 676 ms | 617 ms |
| Library, first | 1,008 ms | 626 ms |
| People, first | 48,818 ms | 35,495 ms |
| A person, first | 4,094 ms | 4,261 ms (stack candidates 2,708 ms) |
| Places, first | 1,469 ms | 1,282 ms |
| On This Day, first | 137 ms | 169 ms |
| Duplicates, first | 193 ms | 119 ms |
| All Media, return | 545 ms | 385 ms (its filter options ran 14,049 ms after the paint) |
| Search, many / few results | 9,281 / 19,899 ms | 6,195 / 17,705 ms |
| Clear the search | 24,818 ms | 1,653 ms |
| Sort by name | 41,806 ms | 27,922 ms |
| Store changes / of them `copies` | 277 / 227 | 170 / 2 |
| Disk read | 49,414 MB | 20,967 MB |
| CPU | 328.6 s in 235 s | 159.5 s in 166 s |
| Main pool's reader time | 663.9 s | 220.7 s |
| Peak footprint | 3,730 MB | 3,804 MB |
| Footprint when the search index has loaded | 2,179 MB (21.3 s) | 2,191 MB (17.4 s) |
| Footprint when People is built | 1,912 MB (54.8 s) | 2,717 MB (39.7 s) |
| Main-thread stalls | 0 | 0 |

The photo steps and the filter were still skipped (this build predates #813). The longest
reader holds were the window's own `orderedAssetIDs` (88.5 s in 15 runs, longest 43.8 s),
`peopleSnapshot` (40.4 s in 2), `filterOptions` (30.4 s in 9) and `samePhotoCandidates`
(15.1 s in 2).

**Switch-off tours** (the same build, sidebar steps only, named owners left unstarted):

| Owners running | Length | Peak footprint | Launch to first grid | Disk read | CPU |
| --- | --- | --- | --- | --- | --- |
| none | 26 s | 336 MB | 2,200 ms | 104 MB | 13.5 s |
| the search index alone | 28 s | 973 MB | 3,608 ms | 1,850 MB | 24.1 s |
| People alone | 76 s | 2,263 MB | 1,875 ms | 553 MB | 66.5 s |

With People alone, People's first paint took 48,613 ms and a person 1,348 ms. The search
index alone loaded its 482 MB matrix at 16.5 s, with the footprint at 927 MB then. With
every owner off the footprint stays under the 700 MB target, so the gap is the owners:
People is the largest holder (about 1.9 GB over the floor), then the search index (about
0.6 GB).

## The migration

v65 ran on the owner's real file in **4,159 ms** (`op=catalog.migration phase=finish
id=v65_owed_work_indexes ms=4159`, at 00:55). Its PR estimated 50 to 80 s there from cold
full-scan times; the generated catalog measured 4,186 ms. A launch 47 s earlier logged the
migration's start and no finish; the log does not say why it ended.

## The disk

From the static survey: the thumbnails folder is 52.9 GiB in 322,377 files, 49.3 GiB of it
HEIC previews. About 35 GiB of those previews (128,673 files at the median size) belong to
the remote Immich account, whose originals stay on its server. 11,334 files (3.58 GiB) are
orphans that no row names. The catalog is 2.39 GiB. In the surveys the thumbnails folder
did not change and the catalog moved by 53 MB and −5 MB. Test runs leave temporary folders
on the same volume (0.49 GB of stale ones in the static survey).

## The backlog

From the static survey: 85,834 text readings and about 53,077 descriptions are owed. At the
rates measured in a sandbox on this Mac (1.8 s a reading, about 4.5 s a description) that
is about 43 h and 66 h of running time.

## Scorecard targets

The targets the plan sets, against the tour:

| Target | Tour (661be172) | Tour (f192041a) | Met (f192041a) |
| --- | --- | --- | --- |
| Launch to first grid ≤ 2,000 ms | 4,038 ms | 2,760 ms | no |
| First visit to a view ≤ 1,000 ms | 137 to 48,818 ms; 3 of 7 met | 119 to 35,495 ms; 4 of 7 met | no |
| First visit to All Media ≤ 2,000 ms | not visited first (launch scope); 14,456 ms before | not visited first | unknown |
| Return to a view ≤ 300 ms | 545 ms | 385 ms | no |
| Search, sort or filter result ≤ 1,000 ms | 9,281 to 41,806 ms; filter not measured | 1,653 to 27,922 ms; filter not measured | no |
| An act's result visible ≤ 100 ms | not measured | not measured | unknown |
| Store stall lines in a session | 62 | 0 | yes |
| Main-thread stall over 250 ms | none | none | yes |
| Peak footprint ≤ 700 MB | 3,730 MB | 3,804 MB | no |

## What it does not capture

- Photo steps (loupe, next and previous, Compare, Info) and the filter: the tour skipped
  them.
- Act to visible result for Like, Dislike and Move to Trash: no line carries both ends.
- A ten-minute session: the tour is about four minutes.
- A quiet machine: other agents' builds ran during every session.
- Energy, per-file I/O and the system language model's own footprint: they need root.

## Conclusions

- Stage 1 removed what it aimed at: no window read waited for a connection in the tour, disk
  reads fell by about 40 %, and small views paint in 0.14 to 1.0 s.
- The app is still far from the targets. People's first paint (48.8 s), search, sort and
  clear (9 to 42 s), launch (4.0 s) and the footprint (3.7 GB on a Mac with 100 MB free)
  are the largest gaps.
- Background reads still hold the main pool's readers for most of a session. `peopleSnapshot`,
  `samePhotoCandidates`, the window's own `filterOptions` and `orderedAssetIDs` hold the most.
- Memory is the scarcest resource: the search index's load alone takes the footprint from
  355 MB to 2,179 MB.
- After stage 2 and the paged search load (f192041a) the store stall lines are gone (62 to
  0), almost no change is a `copies` change (227 to 2), the session read 21 GB instead of
  49 GB, and clearing a search takes 1.7 s instead of 24.8 s. People (35.5 s), sort
  (27.9 s), search (6 to 18 s), launch (2.8 s) and the footprint (3.8 GB) remain.
- The switch-off tours put the footprint's gap in the owners: 336 MB with none running,
  973 MB with the search index alone, 2,263 MB with People alone.
