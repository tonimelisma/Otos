# Plan 0116: the performance program

Status: **active** (2026-11-16). Stages 1, 2 and 4 are merged; on installed f192041a the
tour logged no store stall line (section 2.1b). The bets below are ranked by how much of
the gap to the targets each one closes. The baseline is
`docs/research/2026-11-16-performance-baseline.md`.

## 1. Targets

The program is done when one tour on the owner's library, on a quiet machine, shows every
one of these. The scorecard (`script/scorecard.sh`) prints each one it can read beside its
target (`docs/scorecard-targets.json`).

| Target | Scorecard number | Tour 661be172 → f192041a |
| --- | --- | --- |
| Launch to a usable window ≤ 2 s | `launch.firstGridMs` ≤ 2,000 | 4,038 → 2,760 ms |
| Click to paint ≤ 1 s for every view | `click.smallScopeMs` ≤ 1,000; the loupe, Compare and Info `photo.stepMs` ≤ 1,000 | 137 to 48,818 → 119 to 35,495 ms; 3 → 4 of 7 met; photo steps not measured |
| First visit to All Media ≤ 2 s | `click.allMedia.firstMs` ≤ 2,000 | not visited first; 14,456 ms before stage 1 |
| Return to any view ≤ 0.3 s | `click.returnMs` ≤ 300 | 545 → 385 ms |
| A search, sort or filter result ≤ 1 s | `query.resultMs` ≤ 1,000 | 9.3 to 41.8 → 1.7 to 27.9 s; filter not measured |
| Every act's result visible ≤ 0.1 s (Like, Dislike, Move to Trash) | `act.resultMs` ≤ 100, from a tour in a sandbox home | not measured on the owner's library; a sandbox library of 28 generated photos on its own volume (`--seed 28`): Move to Trash 28 to 139 ms, Put Back 12 to 25 ms, five in a row 2 to 48 ms; choices not measured while the window was covered (`windowOccluded`) |
| No `op=catalog.store.stall` line in a 10-minute session | `stalls.count` = 0 and `stalls.per10Min` = 0 | 62 in 4 minutes (158 per 10 minutes) → 0 in 3 minutes |
| No main-thread stall over 250 ms in Otos code | `mainThreadStalls.worstMs` ≤ 250 | 0 stalls of any length |
| Peak app footprint ≤ 700 MB | `memory.peakFootprintMB` ≤ 700 | 3,730 → 3,804 MB (336 MB with every owner off) |
| `StallReproductionTests` passes with no known-issue marker | the test | no marker: window waits, window read work and walks once per drain asserted; answer times reported |
| The app's disk growth is measured and explained | `disk.derivedFolderMB` (the launch's census) | measured; 11 MiB of leftovers removed each launch from the next build on; remote previews an owner question |

## 2. Evidence

### 2.1 Before and after stage 1

| Number | Before (installed 487baebd and the next build) | After (661be172) |
| --- | --- | --- |
| Launch to first grid | 1.7 s (an import) / 4.2 s (All Media) | 4.0 s (All Media) |
| Import, first click | 2.8 s | 0.68 s |
| A library, first click | – | 1.0 s |
| People, first click | – | 48.8 s |
| A person, first click | – | 4.1 s |
| Places, first click | – | 1.5 s |
| On This Day, first click | – | 0.14 s |
| Duplicates, first click | – | 0.19 s |
| All Media, first click | 14.5 s | (launch scope) |
| All Media, return | – | 0.55 s |
| Search: many results / few results | – | 9.3 s / 19.9 s |
| Clear the search | – | 24.8 s |
| Sort by name | – | 41.8 s |
| Store stall lines | 83 and 62 | 62 |
| Longest connection wait | 23.4 s | 21.7 s, a background read |
| Window reads that waited for a connection | 7 and 4 | 0 |
| Main-thread stalls | 0 | 0 |
| Peak footprint | 3,926 MB (four minutes, no clicks) | 3,730 MB (tour) |
| Disk read | about 55 GB (four minutes, no clicks) | 49 GB (tour) |
| CPU | 193 s (four minutes, no clicks) | 329 s (tour) |
| Connection waits | 57, 275 s in all (four minutes, no clicks) | – |
| v65 migration on the real file | – | 4,159 ms |

### 2.1b After stage 2 and the paged search load (tour on installed f192041a)

Build f192041a holds #807, #809, #810 and #811. The first after-tour, on 5d80f22e, ran on an
overloaded machine and is not evidence.

| Number | 661be172 | f192041a |
| --- | --- | --- |
| Store stall lines | 62 | **0** |
| Launch to first grid | 4,038 ms | 2,760 ms |
| People, first click | 48,818 ms | 35,495 ms |
| A person, first click | 4,094 ms | 4,261 ms |
| All Media, return | 545 ms | 385 ms |
| Search: many / few results | 9.3 s / 19.9 s | 6.2 s / 17.7 s |
| Clear the search | 24,818 ms | 1,653 ms |
| Sort by name | 41,806 ms | 27,922 ms |
| `copies` store changes | 227 of 277 | 2 of 170 |
| Disk read | 49 GB | 21 GB |
| Peak footprint | 3,730 MB | 3,804 MB |

Switch-off tours on the same build put the footprint in the owners:

| Owners running | Peak footprint |
| --- | --- |
| none | 336 MB |
| the search index alone | 973 MB |
| People alone | 2,263 MB |

### 2.2 What is scarce

- **Memory.** The Mac has 16 GB. About 100 MB are free and about 4 GB are in swap before
  Otos starts. The footprint is 355 MB at the first grid and 2,179 MB once the search index
  has loaded, 21 s in. At the peak the heap holds up to 1.6 GB of face and search vectors.
  With every owner off the app peaks at 336 MB. People alone takes it to 2,263 MB and the
  search index alone to 973 MB (f192041a).
- **Disk reads paid cold.** Memory pressure evicts the catalog's pages, so background reads
  read from disk: 49 GB in a four-minute tour, 21 GB in a three-minute tour on f192041a.
- **Connections no longer limit the window.** No window read waited in the tour. Background
  reads still keep the main pool's readers busy for most of a session (664 s of reader time
  in 235 s).
- **Disk space.** The thumbnails folder is 52.9 GiB, of which about 35 GiB are previews of
  the remote Immich library. The files no row names are 1,000 thumbnails (11 MiB) and 3
  others; the 3.58 GiB first counted was a census that skipped face frames. The volume has
  13 to 24 GiB free.

### 2.3 Who holds the readers (tour, 661be172)

| Read | Reader time | Runs |
| --- | --- | --- |
| `peopleSnapshot` | 131 s | 4 |
| `samePhotoCandidates` | 123 s | 5 |
| `filterOptions` (the window's) | 106 s | 11 |
| `samePhotoDetails` | 64 s | 405 |
| `orderedAssetIDs` (the window's) | 64 s | 14 |
| `currentSearchEmbeddingIDs` | 48 s | 7 |

Of 277 store changes, 227 were `copies`.

## 3. Ranked bets

Each bet names the scorecard number it moves. "Building" means a PR is in progress.

| # | Bet | Moves | Status |
| --- | --- | --- | --- |
| 1 | **People.** First paint 48.8 s, 35.5 s on f192041a. `peopleSnapshot` takes 131 s of reader time in 4 runs (40 s in 2 on f192041a). Alone, People takes the footprint from 336 MB to 2,263 MB, the largest share. Background writes are bounded. | People's first paint; footprint; reader time | building: the vectors are held in an unlinked mapped file, outside the footprint, and the snapshot and kernel read faces by position (the generated launch-then-assign sequence went 44 → 341 MB, now 44 → 157 MB; five keyed passes add 4 MB; `2026-11-16-people-passes-in-a-live-session.md`) |
| 2 | **Search index memory.** A paged load and compact labels, then Float16 vectors or a mapped matrix. | footprint (2,179 MB at load); search time | first step done (#811, stage 4: paged load, compact labels, index-only reconciles; 632 MB after load on the generated catalog). On the owner's library alone it peaks at 973 MB, and clearing a search went from 24.8 s to 1.7 s. bet 2b building: the vectors in a mapped Float16 file the catalog names (v70), no table read at a launch with a current file, the match without hashing the scope again (`2026-11-16-search-vector-file.md`). The first search 6 s after launch took 1,606 ms, 1,306 ms of it waiting for an encoder load queued behind six background loads: a query's encoder load is now one the user waits on, admitted at once, and the tokenizer is searched in its mapped file (`2026-11-16-first-search-after-launch.md`) |
| 3 | **Duplicates.** `samePhotoCandidates` takes 123 s in 5 runs and `samePhotoDetails` 64 s in 405; 227 of 277 store changes are `copies` (2 of 170 after #809). | reader time; stall lines; CPU | #809 and #814 merged, more building |
| 4 | **The window's own reads.** `filterOptions` 106 s in 11 runs, `orderedAssetIDs` 64 s in 14, the stack-candidate read, sort, search and clear. Build the installed app with `-O`, though it stays a Debug build. | click to paint; search, sort and filter | building |
| 5 | **Window isolation.** One pool of 8 readers. Background reads are admitted at most 4 at a time. The caller's handle (`WindowReads` or `BackgroundReads`) picks the lane, and a lint keeps it so. Passive checkpoints with `journal_size_limit` replace the truncating barrier. | stall lines; window waits | passive checkpoints with `journal_size_limit` done (ADR 0002, ARC-063; evidence `CatalogWALBoundTests`); the pool and lanes done (ARC-067): window waits 0–4 ms and none of a second on the owner-size reproduction (`2026-11-16-window-read-lanes.md`) |
| 6 | **Staged launch.** Background owners start after the first grid paints; heavy loads run one at a time (ADR 0055). | launch; footprint | done: owners start at `op=launch.firstGrid` below the window's priority; People, duplicates, the search index's load and mirror pairing take turns through `LoadAdmission`, the view's load first. Before (bc159591): first grid 2,677 ms, peak 4,387 MB; after: not measured until the next tour |
| 7 | **Wake on inputs.** Each owner wakes only on the facts its own SQL reads. | stall lines; CPU; disk reads | done (#807) |
| 8 | **Split tables in the file, and one `VACUUM`.** `render_gray` and face embeddings move to their own tables. | disk reads; catalog size | face embeddings moved (#810); `render_gray` and the `VACUUM` not started (one-way, needs the owner's go) |
| 9 | **Disk.** Remove orphaned thumbnails; stop the test temp-folder leak; decide whether remote-library previews exist at full size (owner question). | disk growth | not started |
| 9b | **Freed memory the footprint keeps.** On the owner's library malloc held about 136 MB of freed blocks at idle. | footprint | building: owner-scale reads build in mapped regions and return arrays of their length, groupings make groups at their length, per-row statements are prepared once; on a generated owner-size sequence the freed-and-held bytes after it went 92 → 51 MB on main with the 4-byte identities (82 → 27 MB before them) (`2026-11-16-freed-memory-after-the-tour.md`). Replaced orders' own arrays remain (identity structures) |
| 10 | **The description and text-reading backlog.** About 43 h of text readings and 66 h of descriptions. Whether it runs while the window is in use is an owner question. | footprint; CPU while in use | not started |

**Bet 5's measurement.** On a generated owner-size catalog, window waits were about 1.9 s at
p95 with 14 waits of a second or more; with one pool of eight and four background turns they
are 0–4 ms with none of a second (`docs/research/2026-11-16-window-read-lanes.md`). Lower QoS
for the background pool was rejected: in one loaded run it made background work 10 times
slower and the window gained nothing.

## 4. Done

| PR | What |
| --- | --- |
| #798 | The stall reproduction test on a generated owner-shaped catalog |
| #801 | On This Day leaves a photo out only by its current labels |
| #802 | Stage 1a: one walk per drain for every background owner |
| #803 | `script/survey.sh` and the static survey |
| #804 | The scorecard, resource checkpoints and the read-only tour |
| #805 | Stage 1b: v65, an index for every "what is owed" read |
| #806 | This plan and the baseline |
| #807 | Stage 2: each owner wakes only on what its own SQL reads |
| #808 | Bet 4: the stack candidates are the stills of folders that can hold a pair |
| #809 | A digest write wakes the copy-built owners only when it changes what is a copy |
| #810 | A face's embedding in its own table (v66) |
| #811 | Stage 4: the search index loads once, in pages |
| #812 | A listing writes an item's source facts in one statement |
| #813 | The tour opens photos without a download and filters by an offered kind; acts are timed to their result |
| #814 | A duplicates build costs what changed (v67) |

## 5. Rejected

| Idea | Why |
| --- | --- |
| A trigger-maintained work ledger | 28 triggers, enrichment writes up to 4.7 times slower, up to 4.7 s writer holds on a language switch; indexes and cursors removed about 95 % of the pages with no new state (due diligence, P2). |
| Separate database files | 60 of 150 crashes left two files out of step under one `ATTACH` transaction; cascades and renames stop following; nothing measured needs it (due diligence, P3). |
| `ANALYZE` / `PRAGMA optimize` | Even with statistics the planner left the covering index for the wide table; the code pins its plans on purpose (due diligence, P2). |
| A read model of the window in memory (D) | Swift would become a second owner of the sort, scope, copy and stack rules the SQL owns. |
| A persisted last answer | A second copy of the catalog's truth, stale after any change made while the app was closed. No research note measures it. |
| A two-step paint (grid first, stacks later) | It shows counts that are not true; the owner decides (question 3). |
| Windowed identity (only part of the order) | The order read never touches table rows: 0.07 s warm, 0.44 s cold for 6,160 pages (due diligence, P3). The cost is in stacks and options, not identity. |
| A reorder debounce | Time stands in for a fact the Store holds (ADR 0033); ADR 0005 already rejects a time-based throttle. |
| Patching the order incrementally | A second ordering path beside the SQL that owns it (ADR 0005). |
| A lower-QoS background pool | Background work 10 times slower in one loaded run, and no window gain (bet 5). |
| The nine planned indexes as one block | v65 added only what each read needs and dropped two unused `sort_key` indexes: the file shrank, and the migration took 4.2 s, not the 13 s planned (#805). |
| A per-root path cursor for the newest-first walks | It loses newest-capture-first (ENR-027, ENR-032); a cursor over `root IN (…)` seeks only on the root (#802). |

## 6. Method

- Every PR names the scorecard number it moves and reports it before and after, from a tour
  on the owner's library (`script/scorecard.sh --tour`).
- A change that does not move its number is reverted or rethought.
- A pattern that caused a regression gets a guard test.
- After every three merged bets, the attribution is redone from scratch and reviewed
  independently.
- Benchmarks stay a once-a-day CPU guard (ADR 0043). They do not see waits, cold reads or
  memory, so they never stand in for the tour.

## 7. Open questions for the owner

1. **Remote-library previews.** About 35 GiB of previews belong to the remote Immich library.
   Should they exist at full size?
2. **The backlog while the app is in use.** About 43 h of text readings and 66 h of
   descriptions. Should they run while the window is in use?
3. **All Media's first paint before stacks apply.** Today: no, because the counts it shows
   must be true.
