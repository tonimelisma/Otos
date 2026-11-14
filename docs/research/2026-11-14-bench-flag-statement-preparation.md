# 2026-11-14: the daily flag on the listing, pairs and text-match cases

The daily benchmark run of 2026-11-14 flagged three cases against baseline 7e19c9e6
(head 3a2c022f): `immich.listing.batch500.of20k` +13%, `search.textMatch.5k` +11% and
`projection.windowState.pairs` +3.5%. This note is where the instructions went, measured by
commit, and what changed.

## Method

One test process per commit (`TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1`, the bench
harness's Debug build), running only the affected `BenchmarkTests` functions, with temporary
phase cases added beside the flagged ones and removed before the PR:

- listing: `db.makeStatement(sql:)` 500 times for each statement a listed item runs (the
  put-back `UPDATE`, the scanned-file upsert, the three source `UPDATE`s), on a second
  connection to the benchmark's catalog after its 20,000-asset listing, and the count of
  indexes on `media_asset`;
- pairs: `CatalogStore.orderedAssetIDs` (order and stack read) and
  `PhotoStackCollapse.collapse` alone;
- text match: folding 5,000 readings, building `SearchTextQuery` 5,000 times, and matching
  5,000 folded readings with one query.

Single-process counts agreed with the daily run's recorded processes to about 1–2%.

## Listing: statement preparation grows with every index on `media_asset`

The measured batch re-applies 500 stored rows unchanged, so it writes nothing; most of its
instructions were preparing its per-item statements, which ran through uncached
`db.execute(sql:)`. Preparing a write on `media_asset` compiles the upkeep of each index the
write can touch, so every index added made every listed item dearer.

| commit | indexes on media_asset | upsert prepare ×500 | put-back prepare ×500 | case |
|---|---|---|---|---|
| 7e19c9e6 (baseline) | 31 | 1,415 M | 146 M | 3,762 M |
| f261c96b | 31 | 1,417 M | 146 M | 3,743 M |
| 068c4e5d (#714, account claim indexes) | 33 | 1,600 M | 149 M | 3,992 M |
| 03ab15c3 | 34 | 1,599 M | 148 M | 3,989 M |
| 6b1f5c84 (#727, faces-owed partial indexes) | 37 | 1,736 M | 216 M | 4,240 M |
| eb5b0613 (#745, covering indexes) | 39 | 1,785 M | 284 M | 4,389 M |

The three source `UPDATE`s cost 140–145 M each per 500 and rose by 5 M between baseline and
3a2c022f; at eb5b0613 the `hidden_by_source` one rose to 212 M. #714 moved the case +249 M
(upsert +184 M), #727 +250 M (upsert +137 M, put-back +68 M), #745 +150 M (put-back +68 M,
hidden +67 M). Each step is statement preparation, not the writes or reads the indexes
serve.

Every per-item statement of a source listing (`writeSourceListingChanges`), the put-back and
upsert of `upsertScannedFile` (every file a scan or listing writes), the stored-size read and
the per-folder subtree read now run as cached statements. On eb5b0613's tree the case went
from 4,389 M to 756 M, below the baseline's 3,762 M; the index set no longer enters it. The
case does not measure inserts, so it says nothing about what wider index entries cost a
first sync's new rows.

## Text match: the case measured a path no search runs

Only #729 (f948383d) changed `SearchTextReading` in the range: `matches(query:in:)` became
`SearchTextQuery(query).matches(folded: folded(text))`. 6b1f5c84 measured 421 M, 3a2c022f and
d6397ec5 463–473 M. At d6397ec5 the case's phases were: building the query 5,000 times 223 M,
folding the readings 133 M, matching folded readings with one query 128 M.

The search pass (`PhotoSearchIndex`) builds each query once and matches readings the index
already keeps folded, so the case's added instructions sat in per-reading query building that
only tests do. The case now measures the pass's own work: readings folded beforehand, one
`SearchTextQuery` per iteration. It measures 128 M.

## Pairs: the collapse built a set per stack for every member

| commit | case | order read | collapse |
|---|---|---|---|
| 7e19c9e6 | 5,066 M | 4,326 M | 578 M |
| e5cd5f1c (after #723) | 5,193 M | 4,437 M | 576 M |
| 03ab15c3 (#730) | 5,254 M | 4,340 M | 723 M |
| eb5b0613 (#745) | 4,433 M | 3,550 M | 726 M |
| this change | 4,293 M | 3,558 M | 577 M |

#723's camera-frame read added 111 M to the order read, which #730 removed with the feature.
#730 made a burst count an expanded pair's two files as one frame, building a `Set` of units
per stack for every member at both levels; on a library of 6,000 pairs that was +147 M. The
units are now counted only where they can differ from the file count, a burst level's stack
of two or more files, with the same answer. #745 had already taken the case below the
baseline through its order read.
