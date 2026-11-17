# The performance program on the owner's library (2026-11-16 to 2026-11-17)

Date: opened 2026-11-16, closed 2026-11-17; final measurement on installed revision 87e272a1.
This note is the program's lasting record: its targets, the first baseline, the final
measurement, what moved each number, what was measured and rejected, how to measure again,
and what remains.

## Method

- Read-only tours of the owner's library (about 167k assets, 103k faces) on the installed app
  (`script/scorecard.sh --tour`). Nothing was written to his catalog or folders, and no copy of
  either was made. The saved scorecards are local files; this note cites the revisions.
- Two tour kinds (ADR 0015): a **launch** tour takes its first step at the first grid, under
  the launch's own load; a **settled** tour (`--settled`) waits for the launch's background
  work to settle first. The final launch-kind session lasted 607.8 s; the settled one 69.7 s.
- Acts (Move to Trash, Put Back, Like, Dislike, Not Rated) only in a sandbox: a generated
  library on its own volume (`--dev --optimized --seed <photos>`). The owner's library takes no
  act.
- Whole-machine surveys (`script/survey.sh`) and the static survey
  (`2026-11-16-broad-survey-static.md`) for the first baseline.
- Other agents' builds ran during every session; none ran on a quiet machine.

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

## Final measurement (installed 87e272a1, 2026-11-17)

| Number | Baseline 661be172 | Final launch / settled | Target |
| --- | --- | --- | --- |
| Launch to first grid | 4,038 ms | 1,026 / 1,105 ms | ≤ 2,000 |
| First import | 676 ms | 124 / 146 ms | ≤ 1,000 |
| First library | 1,008 ms | 266 / 214 ms | ≤ 1,000 |
| First People | 48,818 ms | 51 / 52 ms | ≤ 1,000 |
| First person | 4,094 ms | 471 / 343 ms | ≤ 1,000 |
| First Places | 1,469 ms | 428 / 208 ms | ≤ 1,000 |
| On This Day | 137 ms | 110 / 106 ms | ≤ 1,000 |
| Duplicates (18 groups) | 193 ms | 60 / 40 ms | ≤ 1,000 |
| Return to All Media | 545 ms | 74 / 85 ms | ≤ 300 |
| Photo open / Compare / Info | skipped | 294 / 256, 183 / 166, 406 / 321 ms | ≤ 1,000 |
| First search: first results | 9,281 ms (complete) | 278 / 253 ms | ≤ 1,000 |
| First search: complete | 9,281 ms | 1,092 / 362 ms | none |
| Filter: videos | skipped | 221 / 89 ms | ≤ 1,000 |
| Sort by name | 41,806 ms | 176 / 117 ms | ≤ 1,000 |
| Store stall lines | 62 (235 s) | 0 in each tour | 0 |
| Main-thread stalls over 250 ms | 0 | 0 | 0 |
| Peak footprint | 3,730 MB | 411 / 345 MB | ≤ 700 |

Every target is met. Across the last three installed builds (1fe52a12, 509cc0a0, 87e272a1)
every launch-kind and settled tour passed every target, except one settled tour on 1fe52a12
that failed sort by name at 1,075 ms, fixed by #909's order indexes. Both final tours had
zero failures. More from the final builds:

| Number | Value |
| --- | --- |
| First launch after an install | 296–405 MB peak (342 MB after installing 87e272a1; 1,179 MB on one earlier install, fixed in #886) |
| Launch stages, final tours | duplicates built at 3.2 s; launch work settled at 17.5 s (launch kind), with materialization, enrichment, the search index and descriptions reported as working a backlog, and at 4.8 s (settled) |
| Derived folder (the app's own counters) | 54.3 GB: thumbnails 3.7 GB, previews 46.9 GB, face frames 3.7 GB |
| Session CPU | 52–84 s on launch-kind tours (73 s on 87e272a1); 15 s on the final settled tour |
| Session disk read | 5.6 GB on the final launch-kind tour, of which 2.6 GB is originals hashed (23–26 GB, 21.4–21.8 GB of it hashing, on earlier final builds); 1.1 GB on the final settled tour |
| Catalog pages read / page-ins | 2.0–3.0 GB / 0.9–2.2 GB |
| Owed hashing on 2026-11-17 | 7,732 cloud rows, 389 GB, not hashed |
| Catalog | schema v65 → v76; one-time compaction 2.81 → 2.13 GB |
| Full `script/check.sh` | about two minutes (over six minutes on 2026-11-16) |

**Acts, sandbox only** (the tree of 87e272a1, a seeded library of 200 generated photos on
its own volume, two settled tours with the window occluded): Dislike 1 / 1 ms, Like 1 / 1 ms,
Not Rated 0 / 0 ms, Move to Trash 8 / 19 ms, Put Back 9 / 12 ms; five Trashes in a row
6–34 ms, five Put Backs in a row 4–31 ms. Every act is timed to its main-actor commit (#912).
The presented-frame number is reported apart and read `occluded` in every run because the
display was asleep, so no presented-frame figure exists yet.

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
for baseline and flagged head. The fixes are not judged until the next daily run. Finding: the
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
| Staged launch | owners start after the first grid; heavy loads take turns (`LoadAdmission`); launch stages name what each consumer needs | #819, #855, #893, #895, #907 | first grid 2,760 → 1,026–1,105 ms with the other bets |
| People | paint from stored assignment (v68) and a stored gallery (v73); assign only what moved; vectors in an unlinked mapped file; kernel reads faces by position; half-precision vectors | #816, #825, #828, #837, #851, #858, #860, #871, #872, #874, #875, #882, #884 | first People 48,818 → 51–52 ms; with People running the app peaks at 345–411 MB |
| Search | paged load; mapped Float16 vector file (v70); keyed reconciles; the query shown as typed; encoder load the user waits on; words answer first; text index in the catalog (v74); words and tower race | #811, #822, #830, #833, #848, #855, #876, #885, #887, #889, #908 | first search 9,281 ms → 253–278 ms to first results |
| Duplicates | a build costs what changed (v67); no Immich external assets | #809, #814, #904 | the candidate read touches no wide row; first Duplicates 193 → 40–60 ms |
| The window's own reads | stack candidates by folder; filter options walk a wide scope's order; name and size orders from their indexes (v69); `-O` for the installed app; keyed date re-reads; patched filter tallies; held arrays kept; every order walks its index (v76) | #808, #817, #820, #827, #836, #862, #868, #909 | sort by name 41,806 → 117–176 ms (1,075 ms on one settled tour of 1fe52a12 until #909's order indexes); return 545 → 74–85 ms; first person 4,094 → 343–471 ms |
| Narrow tables and compaction | face embedding in its own table (v66); narrow `media_asset` (v71); the open compacts a file a tenth free | #810, #838, #847 | catalog 2.81 → 2.13 GB; name order 147,594 → 28,584 pages (generated) |
| Memory outside the heap | one reused read buffer; 4-byte asset IDs in a mapped identity table; owner-scale reads in mapped regions | #861, #878, #881, #883 | freed-and-held bytes 92 → 51 MB on a generated sequence |
| Image memory | face tiles from their region; held decodes bounded; the full-size view from Image I/O's IOSurface; one image per tile; video faces one frame at a time; renders admitted by memory; pane and lane share one budget; JPEG decode route | #865, #866, #877, #879, #886, #899, #903, #905 | first launch after install 1,179 → 296–405 MB; new library tour 864–930 → 435–458 MB |
| Acts | newest projected state applied part by part; Put Back shown before file work; a landed write read whole | #859, #863, #867, #888 | choice acts 0–1 ms; Move to Trash 8–19 ms (sandbox, timed to the main-actor commit) |
| Scan and disk | an unchanged scan takes no write; the FSEvents change journal (v75); derived files live as long as a row names them; stored folder counters (v72); test temp folders owned | #834, #835, #850, #891, #897 | a launch walks a library only when its journal cannot vouch for it |
| Instruments | stall reproduction test; survey; scorecard, tour, kinds, sandbox volume, disk read by owner, page-ins per paint | #798, #803, #804, #813, #852, #870, #873, #890, #893, #894, #900, #912 | made each number readable |
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

One early rejection did not hold: "patching the order incrementally" was rejected as a second
ordering path, and #836 built it with the SQL's own comparator (`CatalogOrderPatch`, ADR 0005).

## Instruments and how to rerun them

| Instrument | What it gives |
| --- | --- |
| `script/scorecard.sh --tour` | one read-only tour of the installed app; add `--settled` for a settled-kind session |
| `script/scorecard.sh --tour --dev --optimized --seed <photos>` | a tour of a generated library on its own volume, acts included |
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
  - Whether to download the 389 GB cloud backlog (7,732 rows) for content hashes.
  - Accepting the flagged `window.apply.republished.158k` case (`script/bench.sh accept`).
  - Whether remote-account previews (about 35 GiB of the derived folder at the baseline)
    exist at full size.
  - Whether the text-reading and description backlog (about 43 h and 66 h at the baseline)
    runs while the window is in use.
- **Not established.**
  - Why Core ML compiled the text tower again in one session of an install, and why that
    compile took 3 s (`2026-11-16-first-search-while-the-encoder-loads.md`).
  - What made the 1.1 s second prediction of 2026-11-17 (`2026-11-17-first-search-after-the-warm-up.md`).
  - An act's presented frame: every sandbox run so far read `occluded` (display asleep).
  - Part of a sandbox first launch's 889 MB before #899 and #903: the loupe step's 200 MB
    inside the process (`2026-11-17-first-launch-decodes.md`).
- **Not measured until the next daily run.** #904's two fixes, and every case the PRs after
  the judged head 73dffba5 may move (#899–#912).
