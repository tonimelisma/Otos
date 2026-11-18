# The performance program on the owner's library (2026-11-16 to 2026-11-17)

Date: opened 2026-11-16, closed 2026-11-17; final measurement on installed revision 3fa7ee1b.
This note is the program's lasting record: its targets, the first baseline, the final
measurement, what moved each number, what was measured and rejected, how to measure again,
and what remains.

## Method

- Read-only tours of the owner's library (about 167k assets, 103k faces) on the installed app
  (`script/scorecard.sh --tour`). Nothing was written to his catalog or folders, and no copy of
  either was made. The saved scorecards are local files; this note cites the revisions.
- Two tour kinds (ADR 0015): a **launch** tour takes its first step at the first grid, under
  the launch's own load; a **settled** tour (`--settled`) waits for the launch's background
  work to settle first. The final launch-kind session lasted 615.1 s; the settled one 75.3 s.
  Each final tour was read from a live log capture that reported `complete=yes` (#918,
  `2026-11-17-scorecard-live-capture.md`).
- The machine beside each tour: since #925 the scorecard's `MACHINE` section reads the
  kernel's memory-pressure level at launch, each report of the pressure source, the seconds at
  each level, and the CPU and footprint of Otos's process tree (the app and its text-reading
  helpers).
- Acts (Move to Trash, Put Back, Like, Dislike, Not Rated) only in a sandbox: a generated
  library on its own volume (`--dev --optimized --seed <photos>`). The owner's library takes no
  act, since an act changes data.
- Whole-machine surveys (`script/survey.sh`) and the static survey
  (`2026-11-16-broad-survey-static.md`) for the first baseline.
- Other agents' builds ran during most sessions; the quiet-machine measurements below say
  what each recorded of the machine.

## Targets

From `docs/scorecard-targets.json`, which the scorecard prints beside each number.

| Target | Scorecard number |
| --- | --- |
| Launch to a usable window ≤ 2 s | `launch.firstGridMs` ≤ 2,000 |
| First visit to any view ≤ 1 s; the loupe, Compare and Info ≤ 1 s | `click.smallScopeMs` ≤ 1,000; `photo.stepMs` ≤ 1,000 |
| First visit to All Media ≤ 2 s | `click.allMedia.firstMs` ≤ 2,000 |
| Return to any view ≤ 0.3 s | `click.returnMs` ≤ 300 |
| A search's first results, a sort or a filter ≤ 1 s | `search.firstResultsMs`, `query.resultMs` ≤ 1,000 |
| Every act's result visible ≤ 0.1 s | `act.resultMs` ≤ 100 (sandbox only) |
| No store stall line in a ten-minute session | `stalls.count` = 0, `stalls.per10Min` = 0 |
| No main-thread stall over 250 ms | `mainThreadStalls.worstMs` ≤ 250 |
| Peak app footprint ≤ 700 MB | `memory.peakFootprintMB` ≤ 700 |
| A quiet machine stays quiet: memory pressure stays normal (ADR 0015) | `machine.pressureCaused` PASS (0 s above normal; judged only from a normal launch) |
| `StallReproductionTests` passes with no known-issue marker | the test |
| The app's disk growth is measured and explained | `disk.derivedFolderMB` |

## First baseline (revision 661be172, 2026-11-16)

After stages 1a and 1b (#802, one walk per drain; #805, v65's owed-work indexes). A 235 s tour.

| Number | Value |
| --- | --- |
| Launch to first grid | 4,038 ms (All Media, 158,913 items) |
| First import / library / People / person / Places | 676 / 1,008 / 48,818 / 4,094 / 1,469 ms |
| First On This Day / Duplicates | 137 / 193 ms |
| Return to All Media | 545 ms |
| Search (many results, complete) / few results / clear | 9,281 / 19,899 / 24,818 ms |
| Sort by name | 41,806 ms |
| Photo steps, filter | skipped (every original cloud-only; filter unchanged) |
| Store stall lines | 62 in 235 s |
| Main-thread stalls over 250 ms | 0 |
| Peak footprint | 3,730 MB |
| CPU / disk read | 328.6 s / 49,414 MB |
| Main pool's reader time | 663.9 s in 235 s |
| Store changes | 277, of them 227 `copies` |

Before stage 1 (installed 487baebd and the next build, sessions with no or two clicks): launch
1.7 s to an import or 4.2 s to All Media; All Media's first click 14,456 ms; 83 and 62 stall
lines; window reads waiting up to 11.5 s for a connection; 3,926 MB peak, 55 GB read and 312 s
of CPU in four idle minutes.

Where it went at the baseline:

| Read | Reader time | Runs |
| --- | --- | --- |
| `peopleSnapshot` | 131.1 s | 4 |
| `samePhotoCandidates` | 122.8 s | 5 |
| `filterOptions` (the window's) | 106.4 s | 11 |
| `samePhotoDetails` | 64.4 s | 405 |
| `orderedAssetIDs` (the window's) | 63.7 s | 14 |
| `currentSearchEmbeddingIDs` | 48.5 s | 7 |

At the peak the heap held 1.62 GB of `Float` arrays (face and search vectors). A switch-off
tour on f192041a peaked at 336 MB with every owner off, 973 MB with the search index alone and
2,263 MB with People alone: the gap was the owners. The machine is a 16 GB M1 Pro with about
100 MB free and 4 GB in swap before Otos starts.

## Final measurement (installed 3fa7ee1b, 2026-11-17)

A full `script/check.sh` passed on the tree before it was installed. The previous finals,
installed f398d5dc and f2bee3f8, are kept beside it.

| Number | Baseline 661be172 | f398d5dc launch / settled | f2bee3f8 launch / settled | Final 3fa7ee1b launch / settled | Target |
| --- | --- | --- | --- | --- | --- |
| Launch to first grid | 4,038 ms | 1,052 / 1,271 ms | 1,024 / 1,020 ms | 975 / 998 ms | ≤ 2,000 |
| First import | 676 ms | 209 / 241 ms | 125 / 149 ms | 220 / 167 ms | ≤ 1,000 |
| First library | 1,008 ms | 269 / 255 ms | 258 / 202 ms | 234 / 207 ms | ≤ 1,000 |
| First People | 48,818 ms | 55 / 58 ms | 50 / 49 ms | 50 / 13 ms | ≤ 1,000 |
| First person | 4,094 ms | 499 / 407 ms | 235 / 194 ms | 249 / 191 ms | ≤ 1,000 |
| First Places | 1,469 ms | 257 / 254 ms | 370 / 221 ms | 250 / 211 ms | ≤ 1,000 |
| On This Day | 137 ms | 742 / 151 ms | 158 / 108 ms | 148 / 102 ms | ≤ 1,000 |
| Duplicates | 193 ms | 42 / 43 ms | 63 / 42 ms | 39 / 33 ms | ≤ 1,000 |
| Return to All Media | 545 ms | 78 / 69 ms | 130 / 85 ms | 77 / 82 ms | ≤ 300 |
| Photo open / Compare / Info | skipped | 395 / 439, 171 / 183, 480 / 416 ms | 365 / 276, 206 / 180, 554 / 437 ms | 349 / 196, 207 / 181, 465 / 437 ms | ≤ 1,000 |
| First search: first results | 9,281 ms (complete) | 939 / 281 ms | 294 / 185 ms | 351 / 187 ms | ≤ 1,000 |
| First search: complete | 9,281 ms | 2,287 / 498 ms | 563 / 441 ms | 1,206 / 397 ms | none |
| Filter: videos | skipped | 191 / 98 ms | 172 / 211 ms | 118 / 117 ms | ≤ 1,000 |
| Sort by name | 41,806 ms | 155 / 605 ms | 143 / 121 ms | 843 / 210 ms | ≤ 1,000 |
| Store stall lines | 62 (235 s) | 0 in each tour | 0 in each tour | 0 in each tour | 0 |
| Main-thread stalls over 250 ms | 0 | 0 | 0 | 0 | 0 |
| Peak footprint | 3,730 MB | 390 / 327 MB | 378 / 363 MB | 402 / 340 MB | ≤ 700 |
| Memory pressure over the session | not read | not read by the scorecard; warning in one sampled launch tour (below) | normal for all 607.6 s / all 76.7 s | normal for all 615.1 s / all 75.3 s | `machine.pressureCaused` PASS |

Every target is met; both final tours had zero failures and a complete log capture. The final
launch tour began at pressure normal (kernel level 1, 77 % available, thermal nominal, Low
Power Mode off) and stayed normal for all 615.1 s; the settled tour stayed normal for all
75.3 s. The f2bee3f8 launch tour began at 74 % available, its settled tour at 73 %.
Across the installed builds 1fe52a12, 509cc0a0, 87e272a1, 6b254b2c, f398d5dc, 60199d89,
f2bee3f8 and 3fa7ee1b every launch-kind and settled tour on the owner's library passed every target, with
two exceptions: one settled tour on 1fe52a12 failed sort by name at 1,075 ms, fixed by #909's
order indexes; one launch tour on f398d5dc, under memory-pressure warning, failed first person
at 1,555 ms, fixed by #927's `person_photo` (v78), with #926 addressing the pressure. More from
the final builds:

| Number | Value |
| --- | --- |
| First launch after an install | 296–405 MB peak (341 MB after installing 3fa7ee1b; 309 MB after installing f2bee3f8, the launch that applies v78; 315 MB after installing f398d5dc; 1,179 MB on one earlier install, fixed in #886) |
| Launch stages, tours of 87e272a1 | duplicates built at 3.2 s; launch work settled at 17.5 s (launch kind), with materialization, enrichment, the search index and descriptions reported as working a backlog, and at 4.8 s (settled). Since #918 the launch-work stage is the owners caught up to the moment all had started, not settled at one instant |
| Derived folder (the app's own counters, earlier final builds) | 54.3 GB: thumbnails 3.7 GB, previews 46.9 GB, face frames 3.7 GB |
| Session CPU | 52–84 s on launch-kind tours (67 s on f398d5dc); 28 s on the settled tour of f398d5dc (15 s on 87e272a1); on 60199d89's launch-kind tour, the first read of the whole process tree, 119 s: the app 42 s, text-reading helpers 78 s across three helper processes (the largest 184 MB) |
| Session disk read | 21.5 GB on the launch-kind tour of f398d5dc, owed hashing of cloud originals (5.6 GB on 87e272a1, of which 2.6 GB hashing; 23–26 GB, 21.4–21.8 GB of it hashing, on earlier final builds); 3.5 GB on the settled tour of f398d5dc (1.1 GB on 87e272a1) |
| Catalog pages read / page-ins (earlier final builds) | 2.0–3.0 GB / 0.9–2.2 GB |
| Owed hashing on 2026-11-17 | 7,732 cloud rows, 389 GB, not hashed |
| Catalog | schema v65 → v78; one-time compaction 2.81 → 2.13 GB |
| Full `script/check.sh` | about two minutes (over six minutes on 2026-11-16) |

**Quiet-machine measurement** (installed 87e272a1): one tour with the machine recorded as
quiet: load average 3.3 before and after, no build or test process running, 1,950 MB free at
start. During the tour free memory fell to 81 MB and swap stood at 5.7 GB with the owner's
ordinary apps open, so it is quiet of other agents' work, not of memory pressure. Zero
failures; launch 1,033 ms; worst view 506 ms (one person); first search first results 248 ms;
return 60 ms; sort by name 180 ms; peak footprint 382 MB. A tour with every other app quit has
not been run.

**Whether Otos keeps a quiet machine quiet** (launch-kind tours on the owner's library;
`2026-11-17-background-load-attribution.md`, ADR 0057):

- *Installed f398d5dc, before #926.* The tour started with the machine quiet: kernel pressure
  level 1, 61 % available, load average 5.7, no build or test process at any 30 s sample.
  Within 30 s of Otos launching the level was 2 (warning) at 29 % available, and it stayed at
  warning, load averages 13–45, for the whole ten minutes. First person took 1,555 ms, the
  tour's only failing step. No build or test process ran, so Otos's own background work is what
  made the machine un-quiet; the log does not attribute the pressure to one owner (downloads
  with hashing, descriptions and text reading all ran from the first seconds). The app's own
  pressure source reported warning only at 119 s.
- *Installed 60199d89, with #925 and #926.* The same kind of tour: level 1 for all 618.7 s,
  41–50 % available during the tour (75 % at launch, 74 % at the end), load average peaking at
  9.6; zero failures; peak footprint 379 MB; process tree CPU 119 s (above). The session
  hashed 6.7 GB of originals against 21 GB in the f398d5dc tour. The two sources differ on
  that tour: 21 GB is the figure this comparison was made with, and the session disk read above
  is 21.5 GB, while the attribution note counts 13.0 GB hashed. No hold was logged.
- *Installed f2bee3f8.* Both tours were normal throughout (607.6 s and 76.7 s).
- *Installed 3fa7ee1b, with #929.* Both final tours were normal throughout (615.1 s and
  75.3 s).

Established: before #926, Otos's background work took a quiet machine to warning within
30 s; after it, five consecutive tours on the owner's library (one on 60199d89, two on
f2bee3f8, two on 3fa7ee1b) stayed at normal pressure for their whole length. Not
established: that #926's limits are the reason. No hold was logged on 60199d89 and that
session hashed less, so the run shows the machine stayed quiet but does not by itself prove
the room kept it so. The hold itself has been shown only in deterministic tests, never live:
pressure was not produced on the owner's machine.

**Acts, sandbox only** (the tree of 87e272a1, a seeded library of 200 generated photos on
its own volume, two settled tours with the window occluded): Dislike 1 / 1 ms, Like 1 / 1 ms,
Not Rated 0 / 0 ms, Move to Trash 8 / 19 ms, Put Back 9 / 12 ms; five Trashes in a row
6–34 ms, five Put Backs in a row 4–31 ms. Every act is timed to its main-actor commit (#912).
The presented-frame number is reported apart and read `occluded` in every run because the
display was asleep, so no presented-frame figure exists yet.

**Acts at the owner's library size.** The action target is measured on a generated sandbox
library of the owner's size: 160,002 files on its own volume (`--seed 160000 --seed-media
small`), an optimised dev build, settled tours, enrichment working the whole library as
backlog, the window occluded. Times are to the main-actor commit
(`2026-11-17-acts-at-the-owners-library-size.md`, `2026-11-17-acts-on-an-unshown-reorder.md`,
`2026-11-17-acts-ahead-of-background-builds.md`, `2026-11-17-tile-store-under-a-backlog.md`):

| Build | Dislike / Like / Not Rated | Move to Trash, five in a row | Put Back, five in a row |
| --- | --- | --- | --- |
| 8cdd35f6, two tours | 2–7 ms | 272–424 ms | 325–434 ms |
| the scroll hold for the user's scrolling only (#914), four tours | 1–15 ms | 17–116 ms | 25–113 ms |
| every publication an edit of the last (#920), two tours | 3–7 ms (one tour) | 13–65 ms | 29–98 ms |
| an act never queued behind a build (#922), two complete tours | 3–8 ms | 12–61 ms | 8–64 ms |
| the final tree (#923), two tours | 21 / 22 / 1 and 5 / 5 / 0 ms | 23 and 23 ms; in a row 13–26 and 20–62 ms | 9 and 26 ms; in a row 9–75 and 8–35 ms |

- Before #914 every Move to Trash and Put Back, all 24 measured, took 272–434 ms: each waited
  out the grid's 250 ms scroll hold, begun by the grid's own anchor-keeping scroll.
- After #914, 45 of 48 were within 100 ms; the three over (101–116 ms) met a background
  reorder from enrichment's backlog and paid a whole-order comparison.
- After #920, all 24 were within 100 ms, the slowest 98 ms: an act on a reorder the grid has
  not shown is applied by its composed edit (`followsEdit=true compared=0`).
- After #922, the slowest act was 64 ms in one complete tour and 58 ms in the other; what is
  left is the main actor's commit. A third tour, with an incomplete capture, read up to 137 ms.
- On the final tree every act was within 100 ms, the slowest 75 ms.
- No presented-frame figure exists: the display was asleep in every run.

**A new library at the owner's size** (the same 160,002-file sandbox library under its
backlog; harder than the owner's settled library;
`2026-11-17-a-new-library-at-the-owners-size.md`, `2026-11-17-tile-store-under-a-backlog.md`):

| Number | Before | After | Target |
| --- | --- | --- | --- |
| First paint of the newly added library | 4,220 ms | 233–239 ms (#916) | ≤ 1,000 |
| Peak footprint | 595–671 MB before #920; 697–1,098 MB after #920 and #922 | 488 / 486 MB (#923) | ≤ 700 |
| An empty search answer | 1,052 ms | 738 ms (#921) | ≤ 1,000 |
| First search: first results | — | 374 ms with the text tower's pages resident; 1,118–1,468 ms when macOS has evicted them | ≤ 1,000 |

- The first search is the one target stated unreachable, and only in that condition: a new
  library's text is unread, so the words answer matches nothing and the first results wait
  for the tower, whose evicted pages are read back (about 330 MB). Three designs were
  measured; the nearest achievable is about 0.4 s resident and about 1.1–1.5 s evicted
  (#919). It has not occurred on the owner's library: 0.23–0.94 s across the last seven
  tours there by #919, 0.29 / 0.19 s in the two tours of f2bee3f8, and 0.35 / 0.19 s in the
  two final tours of 3fa7ee1b. The search field's focus now warms a prepared tower, so for a
  person who types the page-in comes before the query; for a query submitted with the focus,
  as the tour's immediate step does, it can still land in the first search ("What
  remains").
- The peak before #920 reads 595–671 MB in #919's tours and 582–671 MB in #923's note, which
  counts a further tour. The rise after #920 was the grid's tile store keeping every tile it
  decoded; #923 bounds it to the visible tiles and sixteen screens off screen.
- A new library is walked once (#915), and its first batch is 256 files (#916); a scan's
  baseline holds each row's facts as a digest (#917), which removes 127 MB held during a
  whole-root walk of this size.

**A new library's first launch** (seeded 28 camera-size photos, tour peak): 864–930 MB before
#899 and #903 → 435 MB (launch kind) / 458 MB (settled).

**Switch-off matrix** (`--ablation-matrix`, ef4492e6): every view painted within the same time
with all owners off, each owner alone and all on (first grid 0.76–1.11 s; a library
0.19–0.29 s; Places 0.26–0.39 s). No background owner costs felt time.

**Daily benchmark, 2026-11-17** (73dffba5 against baseline 5207d482), instructions:

| Case | Baseline | Flagged | After #904 |
| --- | --- | --- | --- |
| `projection.filterOptions.allMedia` | 70.2 M | 322.9 M | 69.4 M |
| `duplicates.samePhotoPairs` | 466.1 M | 696.5 M | 277.8 M |
| `window.apply.republished.158k` | 0.30 M | 0.40 M | 0.41 M (left as is) |

The third is #867's per-part observation and awaits the owner's acceptance. The bisect points
in #904 read 0.31 M → 0.42 M (15441d2b → c825eecb); the note's table reads 0.30 M → 0.40 M
for baseline and flagged head. The fixes are not judged until the next daily run (scheduled
for 2026-11-18). Finding: the
benchmark build is unoptimised (`-Onone`) while the installed app is optimised (`-O`, ADR
0030), so generic code in Otos's own module costs far more in a benchmark than in the app
(`Dictionary(exactlyGrouping:)` in #881; `2026-11-17-bench-flag-filter-options-and-pairs.md`).

## Attribution

Each bet is the set of changes aimed at a number. Per-step attribution inside a bet was not
isolated unless a note says so.

| Bet | What changed | PRs | Moved |
| --- | --- | --- | --- |
| Owed work found in one walk | one walk per drain; an index for every "what is owed" read (v65) | #802, #805 | disk read −40 % in idle surveys; no window read waited |
| Wake on inputs | each owner wakes only on the facts its SQL reads; copy owners only when a copy changes; idle owners write nothing and report quiescence | #807, #809, #829, #831, #840, #864, #869, #896 | stall lines 62 → 0 (f192041a); `copies` changes 227 → 2 |
| Window read lanes | one pool of eight readers, background admitted four at a time; passive checkpoints; lock waits for every connection | #826, #845, #906 | window waits 1.9 s p95 → 0–4 ms on the generated reproduction |
| Staged launch | owners start after the first grid; heavy loads take turns (`LoadAdmission`); launch stages name what each consumer needs; launch work is the owners caught up, not settled at one instant | #819, #855, #893, #895, #907, #918 | first grid 2,760 → 1,020–1,271 ms with the other bets |
| People | paint from stored assignment (v68) and a stored gallery (v73); assign only what moved; vectors in an unlinked mapped file; kernel reads faces by position; half-precision vectors | #816, #825, #828, #837, #851, #858, #860, #871, #872, #874, #875, #882, #884 | first People 48,818 → 49–58 ms; with People running the app peaks at 327–390 MB |
| Search | paged load; mapped Float16 vector file (v70); keyed reconciles; the query shown as typed; encoder load the user waits on; words answer first; text index in the catalog (v74); words and tower race; an empty answer reads no whole-scope count (v77) | #811, #822, #830, #833, #848, #855, #876, #885, #887, #889, #908, #919, #921 | first search 9,281 ms → 185–939 ms to first results; an empty answer at 160k 1,052 → 738 ms |
| Duplicates | a build costs what changed (v67); no Immich external assets | #809, #814, #904 | the candidate read touches no wide row; first Duplicates 193 → 42–63 ms |
| The window's own reads | stack candidates by folder; filter options walk a wide scope's order; name and size orders from their indexes (v69); `-O` for the installed app; keyed date re-reads; patched filter tallies; held arrays kept; every order walks its index (v76); a person's order reads the person's own rows of `person_photo` (v78) | #808, #817, #820, #827, #836, #862, #868, #909, #927 | sort by name 41,806 → 121–605 ms (1,075 ms on one settled tour of 1fe52a12 until #909's order indexes); return 545 → 69–130 ms; first person 4,094 → 407–499 ms, then 194–235 ms after #927 (1,555 ms once under memory-pressure warning before it); the largest person's order on the generated catalog 7,881 → 803 pages, 907 → 92–98 ms cold |
| Narrow tables and compaction | face embedding in its own table (v66); narrow `media_asset` (v71); the open compacts a file a tenth free | #810, #838, #847 | catalog 2.81 → 2.13 GB; name order 147,594 → 28,584 pages (generated) |
| Memory outside the heap | one reused read buffer; 4-byte asset IDs in a mapped identity table; owner-scale reads in mapped regions | #861, #878, #881, #883 | freed-and-held bytes 92 → 51 MB on a generated sequence |
| Image memory | face tiles from their region; held decodes bounded; the full-size view from Image I/O's IOSurface; one image per tile; video faces one frame at a time; renders admitted by memory; pane and lane share one budget; JPEG decode route; the tile store keeps the visible tiles and sixteen screens off screen | #865, #866, #877, #879, #886, #899, #903, #905, #923 | first launch after install 1,179 → 296–405 MB; new library tour 864–930 → 435–458 MB; new 160k library 697–1,098 → 486–488 MB |
| Acts | newest projected state applied part by part; Put Back shown before file work; a landed write read whole; only the user's scrolling holds the grid; every publication an edit of the last; an act's publication costs its edit and never waits behind a build | #859, #863, #867, #888, #914, #920, #922 | choice acts 0–1 ms; Move to Trash 8–19 ms on 200 photos; at 160k, Move to Trash and Put Back 272–434 → 8–75 ms (sandbox, timed to the main-actor commit) |
| Scan and disk | an unchanged scan takes no write; the FSEvents change journal (v75); derived files live as long as a row names them; stored folder counters (v72); test temp folders owned; a stream's history before its start is already reflected; a small first batch; a scan baseline of digests | #834, #835, #850, #891, #897, #915, #916, #917 | a launch walks a library only when its journal cannot vouch for it; a new library is walked once; its first paint at 160k 4,220 → 233–239 ms |
| The machine's room | `BackgroundRoom` holds new description requests, text-reading pages, background downloads and background heavy loads under memory warning or critical, serious or critical thermal state or Low Power Mode, and descriptions while Otos is the active app; while held only the current view's heavy load runs; each decision reads the kernel's memory-pressure level, read again every 5 s only while holding for memory (ADR 0057) | #926, #929 | the machine stayed at normal pressure in every tour since (not shown to be the room's doing; see the quiet-machine measurements) |
| Instruments | stall reproduction test; survey; scorecard, tour, kinds, sandbox volume, disk read by owner, page-ins per paint; settled tours judged from the library's walk; live log capture; the text tower's and a first batch's waits; the machine's pressure level and Otos's process-tree load | #798, #803, #804, #813, #852, #870, #873, #890, #893, #894, #900, #912, #918, #919, #925 | made each number readable |
| Check cost | the allocator probe on demand only; test catalogs start from a migrated template | #884, #902 | full check over six minutes → about two |

**Migrations added** (ADR 0002 cost rule; generated owner-shaped catalog unless stated):

| Version | PR | Cost |
| --- | --- | --- |
| v66 face embedding table | #810 | 8,058 ms, 469 MB WAL |
| v67 same-photo indexes | #814 | 719 ms, 39 MB WAL |
| v68 settled People assignment | #816 | one-row table, not timed |
| v69 sort orders' tested columns | #820 | 5,775 ms, 112 MB WAL |
| v70 search vector file | #822 | 2 ms, 41 KB WAL |
| v71 narrow `media_asset` | #838 | 10.0–15.7 s, 642 MB WAL; compaction 12.0–47.7 s |
| v72 derived folder counters | #850 | 4 ms, 49 KB WAL |
| v73 People gallery | #851 | 16 ms, 58 KB WAL |
| v74 search text words | #889 | 2,809 ms, 6.7 MB WAL (`2026-11-16-search-text-index.md`) |
| v75 library root change journal | #897 | 4 ms, 33 KB WAL |
| v76 order filter columns | #909 | 3,593–3,805 ms, 229 MB WAL; 3.9 s on the owner's catalog |
| v77 rows with no thumbnail coming | #921 | 36 ms, 53,592 bytes WAL |
| v78 a person's photos (`person_photo`) | #927 | 1,155 ms, 29 MB WAL (`2026-11-17-a-persons-photos-in-order.md`) |

## Measured and rejected

| Idea | Why | Where |
| --- | --- | --- |
| A trigger-maintained ledger of owed work | 28 triggers; an enrichment flush up to 157 ms against 34–43 ms; writer holds up to 4.7 s on a language switch | ADR 0009 |
| A per-root path cursor | seeks only on the root; loses newest capture first | ADR 0009 |
| Separate database files | 60 of 150 crashes left two files out of step under one `ATTACH` transaction | ADR 0002 |
| `ANALYZE` / `PRAGMA optimize` | with statistics the planner still chose the wide table; plans are pinned | ADR 0002 |
| A lower-QoS background pool | background work ten times slower in a loaded run, no window gain | ADR 0002 |
| A read model of the window in memory; a persisted last answer; a two-step paint; windowed identity | a second owner of the SQL's rules; stale truth; untrue counts; the order read touches no row (0.07 s warm, 0.44 s cold) | ADR 0005 |
| A reorder debounce | time standing in for a fact the Store holds | ADR 0005, ADR 0033 |
| The nine planned owed-work indexes as one block | v65 added only what each read needs: 4,159 ms on the owner's file, not 13 s | #805 |
| A delay before the owners start; two heavy loads at once; `.utility` owners | time for a fact; the measured overlap; late visible thumbnails | ADR 0055 |
| Compiled models kept apart, or one model resident at a time, for the 1,179 MB peak | the peak was two 4K videos' frames, not the models | `2026-11-16-first-launch-footprint.md` |
| Fewer decodes on the render lane | halves HEIC throughput to bound a cost only whole JPEG decodes have | `2026-11-17-first-launch-decodes.md` |
| Kind-led order indexes | 24 indexes, about 230 MB more, to save an 82 ms cold walk | #909 |
| An index per order for a person; a People-written table of a person's photos | 79 MB and more pages read; a table that lags renames, choices and Trash | #927 |
| A throttle by time for background work; cancelling in-flight downloads at `critical` | time standing in for facts the platform reports; Otos holds no handle on the provider's download | ADR 0057 |

One early rejection did not hold: "patching the order incrementally" was rejected as a second
ordering path, and #836 built it with the SQL's own comparator (`CatalogOrderPatch`, ADR 0005).

## Instruments and how to rerun them

| Instrument | What it gives |
| --- | --- |
| `script/scorecard.sh --tour` | one read-only tour of the installed app; add `--settled` for a settled-kind session; read from a live log capture that says whether it is complete (`complete=yes`) |
| `script/scorecard.sh --tour --dev --optimized --seed <photos>` | a tour of a generated library on its own volume, acts included |
| the same with `--seed 160000 --seed-media small` | the same at the owner's library size: 64 × 64 JPEGs in a folder tree, about 630 MB, written in about 95 s |
| `script/scorecard.sh --ablate <owners>` / `--ablation-matrix` | the same tour with owners left unstarted, or the whole matrix |
| `script/scorecard.sh --compare <saved.json>` | before and after, like kind with like |
| `script/survey.sh` | one session's machine picture: trace, memory by region, heap, disk, CPU |
| `StallReproductionTests` | the sidebar stall on a generated owner-shaped catalog; no known-issue marker |
| `CatalogMigrationCostTests` (`OTOS_SCALE_TEST=1`) | a migration's ms and WAL bytes |
| `OrderReadSurveyTests` (`OTOS_SCALE_TEST=1`) | pages and time for every order the window asks for |
| `script/bench.sh daily` | the daily CPU guard (ADR 0043); not a measure of felt time |

A tour never runs while Otos is running and quits the app itself.

## What remains

- **Owner decisions.**
  - Decided 2026-11-17, reversible by the owner: the cloud backlog is not downloaded for
    content hashes. A cloud-only original is never downloaded only to take its digest; the
    digest is taken when its bytes are local for another reason (ADR 0009 §12). On that day
    3,219 library files (153 GB) owed only their digest, every other product already made.
    Measured once, on b9f85b77 (2026-11-18, 729 s, the machine at memory-pressure warning
    throughout): session disk read 19,625 → 5,330 MiB against the 8eec3c42 tour,
    `originals hashed: enrichment` 14,572 → 0 MiB, `held at sessionEnd: digest waits for
    local bytes: 3218`. Process CPU rose 180 → 323 s and store changes 582 → 7,008: with the
    digest rows held, the walk reached an Immich account's backlog the earlier build never
    got to behind one download at a time — 6,842 photos, each ranged-read once (none read
    in any earlier retained session) and written in its own batch, each batch re-reading
    the window's order (`orderedAssetIDs` 31 → 1,603 reads, 3.8 → 84.5 s) and the People
    gallery (16 → 744, 1.4 → 57.6 s). No row was read twice; the build was reverted (#934)
    on a reading of the log as a loop, and re-landed. Inside it, 22 paced rows were claimed
    and released at every pass (4,336 claim and 2,674 release transactions); a paced row
    now keeps its claim (ENR-035). The tour's Duplicates step timed out because the
    memory-pressure hold grants no heavy load but the view's, and the tour waits for the
    launch's build before it shows Duplicates. Not re-measured until the next tour.
  - Accepting the flagged `window.apply.republished.158k` case (`script/bench.sh accept`).
  - Three decisions of ADR 0057, recorded for confirmation: descriptions run only while Otos
    is not the active app; Low Power Mode and a serious or critical thermal state hold all
    heavy background work; while held, only the current view's heavy load runs.
- **Needs the owner.** A tour with every other app quit has not been run. A presented-frame
  number for acts: the Mac's screen was locked in every run.
- **Measured only in a sandbox.** Acts cannot be measured on the owner's library without
  changing data; they are measured at its size in a sandbox.
- **Fixed by #929.** The app's memory-pressure notification arrived later than the kernel's
  level (in the f398d5dc tour the kernel showed warning from 30 s, the app's source reported it
  at 119 s); the room now reads the kernel's level (`kern.memorystatus_vm_pressure_level`) at
  each decision. XNU sends the notification to one chosen process at a time, skipping one
  already told at that level, and sends the return to normal only to a process it told of the
  warning, so the source may report late or never (ADR 0057).
- **One target unreachable in one condition.** A new library's first search while macOS has
  evicted the text tower's pages: about 1.1–1.5 s against 1,000 ms (about 0.4 s resident),
  after three measured designs. Not seen on the owner's library. Since then the search
  field's focus asks a prepared tower for one warm prediction
  (`op=search.tower phase=warmed cause=focus`), so a person who types after focusing the field
  has the pages read back while typing. The ~330 MB is the model's clean, mapped weights and
  is not in the footprint (`2026-11-17-the-text-towers-pages-are-not-footprint.md`). Still
  true: a query submitted in the same instant as the focus, as the harsh tour types it, can
  still pay the page-in inside its first search. `script/scorecard.sh --search-after-warm`
  reports the number for a person who types (`after warm`) beside the immediate one. Eviction
  was not reproduced for either number.
- **Not established.**
  - Why Core ML compiled the text tower again in one session of an install, and why that
    compile took 3 s (`2026-11-16-first-search-while-the-encoder-loads.md`).
  - What made the 1.1 s second prediction of 2026-11-17 on the owner's Mac
    (`2026-11-17-first-search-after-the-warm-up.md`). On a sandbox library on this Mac
    under pressure, a slow prediction read about 330 MB back (`op=search.tower
    phase=predicted`, `2026-11-17-a-new-library-at-the-owners-size.md` §2). That session
    has no such line.
  - That #926's limits are why the machine stayed quiet in the tours since (see the
    quiet-machine measurements).
  - Part of a sandbox first launch's 889 MB before #899 and #903: the loupe step's 200 MB
    inside the process (`2026-11-17-first-launch-decodes.md`).
  - Why tours after #920 and #922 decoded more tiles than before
    (`2026-11-17-tile-store-under-a-backlog.md`).
  - About 59 MB of untyped malloc and about 60 MB held by the allocator at the new 160k
    library's peak.
- **Not measured until the next daily run** (scheduled for 2026-11-18). #904's two fixes, and
  every case the PRs from #899 onward may move.
