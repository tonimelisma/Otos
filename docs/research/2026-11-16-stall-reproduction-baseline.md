# The sidebar stall, rebuilt on a generated reference-shaped catalog: the baseline (2026-11-16)

## Question

On the test Mac a sidebar click takes 3–15 s. Its `op=catalog.store.stall` lines put the
time in `connectionMs` (up to 23 s, `lockMs=0`, `storeMs=0`): the window's reads wait for one
of the main pool's four readers while background reads hold them — `readSearchEmbeddings`
32.8 s, `photoDescriptionCandidates` 23.8 s, `renderSignatureCandidates` 20.6 s (and 8.6 s
×16), `searchEmbeddingCandidates` 8.8 s, `metadataRefreshCandidates` 8.7 s,
`samePhotoDetails` 7.1 s, `samePhotoCandidates` 6.4 s, `mirrorProbes` 36 s, `peopleSnapshot`.
Three sandbox launches did not rebuild it (worst wait 98 ms,
`2026-11-15-startup-read-stalls.md`): their catalogs had no backlog and small derived
tables. Does a catalog with the reference library's sizes, widths, root split and backlog rebuild it in a test,
and what does each read cost there? This is plan 0116's experiment P0, and the "before"
every option is measured against.

## Method

Nothing touched the reference catalog but read-only `sqlite3 -readonly … ?mode=ro` counts; no
app was launched.

- **The catalog** (`OtosTests/ReferenceShapedCatalog.swift`). One SQL transaction writes, at
  `scale` 1, the reference catalog's roots and every count below, with widths matched to its
  (`length()` averages): 166,990 `media_asset` rows in its split (library 6: 788, library 7:
  16,914, account 15: 147,064, four card and camera roots: 2,224), stills and videos per root
  as the reference's, `sort_key` 154 B in libraries and 544 B in the account (reference average 502 B), a
  1,024 B render on every library and account still with a thumbnail; 165,787
  `search_embedding` rows of 3,072 B (reference 165,652); 102,979 `face` rows of 2,048 B, 15,653
  of them video frames (the reference's exactly); 140,034 `asset_metadata` records of about 1.1 KB, the
  account's 120,108 of 147,064 as the reference's, three in four located in one of 1,435 named cells;
  58,599 `search_text` rows (reference 58,598), 5,521 `photo_description` rows (as the reference), 748 people,
  6 named; 45 import batches of 11,401 library rows; one `immich_mirror` row (15 → 7).
  The account's rows are drawn by its server (`source_products_*`, no rendering of Otos's
  own), as the reference's are. Whether a derived row is current is decided by the product's own
  source SQL (`StoredThumbnailSQL`, `SearchEmbeddingStorage`, `SearchTextStorage`,
  `PhotoDescriptionStorage`, `currentExtractionRevisionSQL`).
- **The backlog.** 24 thumbnails owe an embedding and 24 stills a render signature (the reference's
  are all current; a few dozen stand for an import's), spread through the table; 85,816
  previews owe a text reading (the reference account's 85,795 plus library 7's 21); the describable
  stills not yet described; 19.7 % of metadata records read by an older parser (reference 27,595 of
  140,034; 3,473 of them in the libraries, which the refresher reads); 896 videos owe faces;
  43 stills await a preview; 162,275 rows are never hashed (reference 162,294 in the
  `needs_enrichment` indexes: the account and most of the OneDrive library). Nothing the
  rows name is on disk, so every owner finds work and cannot finish it. No `ANALYZE`, as in the reference.
- **Size and time.** Scale 1: 2.27 GB (reference 2.56 GB), generated in 24.7 s on this Mac. Scale
  0.01, which every check runs: 22.8 MB in 0.3 s. The test directory, and the file with it,
  is deleted after each test.
- **Quiet replay.** A first `CatalogStore` on the file runs every read once, one after
  another, with nothing else running. Each connection's SQLite trace is replaced by one that
  sums `sqlite3_stmt_scanstatus(SQLITE_SCANSTAT_NVISIT)` — the rows each loop of a statement
  visited — over every statement that finished (the system SQLite is built with
  `SQLITE_ENABLE_STMT_SCANSTATUS`). The Store exposes no connection and this work adds none,
  so the test reaches its pool by reflection; that Store writes no stall line.
- **Live run.** A second `CatalogStore` on the same file, its owners started as
  `CatalogWindowViewModel` starts them: `MaterializationCoordinator` (every download fails,
  every original dataless), `EnrichmentCoordinator` (nothing materializes),
  `RenderSignatureRefresher`, `PreviewFaceReader` (analysis fails), `PlaceNameReader` (every
  cell has no name), `PhotoSearchIndex` (the test bundle holds no model, as on a Mac whose
  model is still loading; texts read nothing), `PhotoDescriptionWriter` (the model fails),
  `MetadataRefresher` (every original unreachable), `CatalogProjection` (which runs
  `DuplicatesProjection` and `PeopleAssignment`), and one `mirrorProbes` as an account's
  launch sync asks. Right after they start, the test makes 15 scope changes (All Media,
  library 7, the account, library 6, an import, three rounds): the order, the filter's
  options and the imports asked together, then the first 60 tiles' details, each timed from
  its ask. The Store's own `op=catalog.store.stall` lines for the run are read back from the
  process's log (`OSLogStore`) and parsed; each hold a line names is counted once.
- **Runs.** `OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests`, twice, on
  build 487baebd's tree with these tests. The tables are the second run's; the first had the
  same waiters and holders, with times up to 30 % apart. The reference-size test took 121 s, under the
  test host's 2 GB footprint limit.

## Findings

### The stall reproduces, at a smaller magnitude

Window reads waited for a connection with `lockMs=0`, `storeMs=0` and `snapshotMs` 0–4 ms,
the reference signature, and the stall lines name its holders.

| Window read (15 asks) | Quiet p50 / max | Live p50 / max | Stall lines | Worst `connectionMs` | `snapshotMs` | `lockMs` | `storeMs` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `orderedAssetIDs` | 144 / 1,356 ms | 479 / 2,307 ms | 1 | 1,015 | 0 | 0 | 0 |
| `filterOptions` | 159 / 732 ms | 673 / 2,101 ms | 3 | 1,187 | 2 | 0 | 0 |
| `importBatches` | 94 / 99 ms | 288 / 1,639 ms | 3 | 1,499 | 4 | 0 | 0 |
| `mediaTileDetails` (interactive pool) | 2 / 3 ms | 3 / 9 ms | 0 | – | – | – | – |

The tile details, on the two readers nothing else uses, never waited. A stall line is
written only for a wait of a second or more, so the other asks' waits are in the live
column and not split.

| Holder named in stall lines (live) | Longest hold seen | Holds | Lines naming it | The reference's |
| --- | --- | --- | --- | --- |
| `readSearchEmbeddings` | 8,813 ms | 1 | 22 | 32.8 s |
| `peopleSnapshot` | 3,444 ms (still running) | 1 | 15 | named |
| `samePhotoCandidates` | 1,884 ms | 1 | 11 | 6.4 s |
| `orderedAssetIDs` (the window's and the projection's) | 1,490 ms | 5 | 27 | – |
| `photoDescriptionCandidates` | 1,264 ms | 5 | 19 | 23.8 s |
| `filterOptions` | 1,103 ms | 4 | 16 | – |
| `renderSignatureCandidates` | 944 ms | 5 | 12 | 20.6 s, 8.6 s ×16 |
| `mirrorProbes` | 805 ms | 1 | 1 | 36 s |
| `importBatches` | 153 ms | 5 | 16 | – |
| `unnamedPlaceCells` | 62 ms | 4 | 18 | – |

A hold still running when a line was written counts its age then, so a long one is a lower
bound: `peopleSnapshot` took 22.6 s quiet. `searchEmbeddingCandidates`,
`metadataRefreshCandidates` and `samePhotoDetails` held no connection long enough to be
named in the live run.

### What each background read visits (quiet replay)

| Read (page size) | Returned | Rows visited | Sorts | Quiet time | Mainly visits |
| --- | --- | --- | --- | --- | --- |
| `renderSignatureCandidates` (128) | 24 | 164,766 | 0 | 165 ms | every `media_asset` row of the member roots |
| `searchEmbeddingCandidates` (16) | 16 | 329,489 | 1 | 455 ms | every row, and its embedding |
| `searchTextCandidates` (8) | 8 | 309,181 | 1 | 297 ms | every row, and its reading; sorts 85,816 owed to take 8 |
| `photoDescriptionCandidates` (16) | 16 | 984,811 | 1 | 1,359 ms | every row, its record, its description and readings |
| `unnamedPlaceCells` (32) | 0 | 210,052 | 0 | 44 ms | every located record |
| `mirrorProbes` | 0 candidates | 294,129 | 0 | 443 ms | both libraries' rows by size, for a library with no mirror too |
| `metadataRefreshCandidates` (64) | 64 | 408 | 0 | 1 ms | a cursor: what it returns |
| `previewFaceCandidates` (32) | 0 | 0 | 0 | 0 ms | its partial index |
| `readSearchEmbeddings` (all) | 164,699 | 329,465 | 0 | 8,475 ms | every embedding: 506 MB of vectors |
| `currentSearchEmbeddingIDs` | 164,699 | 329,465 | 0 | 2,838 ms | the same rows without vectors |
| `currentSearchTextIDs` | 9,768 | 68,367 | 0 | 208 ms | every reading |
| `samePhotoCandidates` | 144,391 | 309,157 | 0 | 2,498 ms | every still and its record |
| `samePhotoDetails` (60) | 60 | 120 | 0 | 4 ms | what it returns |
| `duplicateCopies` | 0 | 4,715 | 0 | 4 ms | the hashed rows |
| `peopleSnapshot` | – | 562,774 | 2 | 22,603 ms | every face, twice its photos |

Six candidate reads visit the whole library to return a page — 24 rows for 164,766 visits,
16 for 984,811 — and the four with an order sort what they owe first. Only the metadata
refresher's cursor and the faces' partial index visit in proportion to what they return. The
window's own order read visits 213,175 rows for All Media (1,356 ms quiet) and its filter
options 376,253.

### Passes and what woke them

In the 14.6 s of the live run the Store announced 21 changes: 12 `.changed(.detail)`
(enrichment recording what it could not read) and 9 `.changed(.duplicateFacts)` (the render
refresher's own writes of the 24 owed signatures, recorded unreadable). The render, face,
search and description owners and the projection ring on these, so each one is a pass of
every candidate read above, the writer's own included. The holds column above is the passes the
stall lines saw: five each of the description and render candidates, one of each full load.
`PhotoSearchIndex` finished no pass in the run: its first load (`readSearchEmbeddings`) was
still the one in the stall lines.

### How close it is to the reference

Same mechanism, same holders, same zero lock and Store waits; about a tenth of the reference's
magnitude. Its holds are 4–45 times these: `readSearchEmbeddings` 32.8 s against 8.8 s,
`photoDescriptionCandidates` 23.8 s against 1.3 s, `mirrorProbes` 36 s against 0.8 s. Its
window waited 3–15 s per click; here the worst read took 2.3 s. Two of its holders cost
little here: `metadataRefreshCandidates` (8.7 s there) pages with a cursor, and
`samePhotoDetails` (7.1 s) reads 60 rows — what holds them on the test Mac is not their SQL.

## What it does not capture

- **OneDrive.** The reference libraries are File Provider folders; every `locality(of:)` and
  materialization talks to `fileproviderd`, and the metadata refresher spent 3.4 ms a row
  there. Here every original is absent and answers at once.
- **The on-device models.** No search, face or description model runs; the test Mac's first Foundation
  Models request silenced the whole process for 5 s (`2026-11-15-startup-read-stalls.md`).
- **Memory pressure and a cold file.** The test Mac swaps under the models and the 506 MB vector
  load; this file was just written and sits in the page cache.
- **Time.** The run covers the owners' first passes, 14.6 s. The test Mac's waits come minutes into a
  session, after hundreds of passes, imports and downloads that keep the Store changing.
- **The reference's real distributions.** Dates, paths, faces per photo and the owed sets are spread
  evenly; the reference's cluster. Sorts and index choices may differ on the reference data (no `sqlite_stat1` in
  either).

## The requirement it states

`StallReproductionTests.windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns` asserts, at
the reference library's size: every window read is answered within 250 ms of its own quiet time, no
window read writes a stall line, and every background read visits at most four rows for
each it returns or asks for. Today all three fail, so they run inside `withKnownIssue`
naming the open defect; the design that passes them removes the `withKnownIssue`, which then
fails if the test is left as it is.

Run it with `OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests` (about four
minutes; not a benchmark, never through `script/bench.sh`). It writes these tables to
`build/stall-reproduction/reference.txt`; every check runs the 0.01 scale and writes
`small.txt`.

## Conclusions

- The stall reproduces without the test Mac: window reads wait 1.0–1.5 s for a main-pool
  connection with no lock or Store wait, behind `readSearchEmbeddings`, `peopleSnapshot`,
  `samePhotoCandidates`, `photoDescriptionCandidates`, `renderSignatureCandidates` and
  `mirrorProbes`. Plan 0116's P0 holds; its later numbers can be measured here.
- Six background candidate reads visit every row of the library each pass to return a
  page, and every owner's pass is rung by every change, its own writes included.
- The test Mac multiplies the same holds by 4–45; the test bounds what Otos's own reads
  cost, not what OneDrive, the models and memory pressure add.
