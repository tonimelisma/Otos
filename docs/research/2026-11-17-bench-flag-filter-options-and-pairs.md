# 2026-11-17: the daily flag on the filter options, same-photo pairs and window apply cases

The daily benchmark run of 2026-11-17 measured `origin/main` 73dffba5 against baseline
5207d482 (the last measured head, aaa43f39, the day before) and flagged three cases, each in
all three processes: `projection.filterOptions.allMedia` 70.2 M → 322.9 M instructions,
`duplicates.samePhotoPairs` 466.1 M → 696.5 M and `window.apply.republished.158k` 0.3 M →
0.4 M. This note is where the instructions went, by commit and by phase, and what changed.

## Method

One test process per point, the bench harness's Debug build (`-Onone`) and its one hash
seed (`TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1`), running only
`BenchmarkTests/catalogCases()` and `windowApplyCases()` with `OTOS_BENCHMARK=1`, each
commit in its own detached checkout. Phases were split by temporary cases beside the
flagged ones, removed before the PR. Single-process counts agreed with the daily run's
records to about 1 %.

## Where the range broke

| commit | filterOptions.allMedia | samePhotoPairs | window.apply.republished |
|---|---|---|---|
| 4d0a6f0c (before #862) | 70.8 M | 494.6 M | 0.31 M |
| d66c9163 (#862) | 314.0 M | 493.9 M | 0.31 M |
| 15441d2b (before #867) | | | 0.31 M |
| c825eecb (#867) | | | 0.42 M |
| 62e160b4 (before #881) | 312.2 M | 469.1 M | 0.41 M |
| ef4492e6 (#881) | 322.6 M | 726.9 M | 0.41 M |
| 73dffba5 (flagged head) | 322.9 M | 696.5 M | 0.40 M |

## Filter options: a walk of every row, each row decoded through GRDB

#862 made the whole read of a row's options a walk of its scope's rows, each row's type and
cell kept so a keyed re-read can patch the tally; before it, SQLite counted the types and the
places itself. At the flagged head, for All Media's 15,000 rows:

| phase | instructions |
|---|---|
| SQLite alone (`SELECT count(*)` over the query) | 34.8 M |
| the cursor's `next()` per row, reading nothing | 89.5 M |
| GRDB's `forEach`, reading nothing | 68.7 M |
| raw column reads, cells computed by SQLite's expression | 73.8 M |
| raw column reads, cells computed from the coordinate as the row is read | 52.6 M |
| each row's fact as `String`s, `MediaKind(rawValue:)`, the cell from `row[i]` | 242.3 M |
| the whole read (facts, a mapped build of `(rowID, Fact)`, the tally's appends) | 323.4 M |

Each row made two strings, parsed its kind from one, hashed a type holding the other into
the tally's index, and was copied with its strings twice more. The cell expression
`MIN(MAX(CAST(x AS INTEGER) - (x < CAST(x AS INTEGER)), …))`, twice a row, was a third of
SQLite's own work.

The read now selects the coordinate, steps the statement with `forEach`, and reads each
column from the statement by position (`FilterOptionColumns`): the row id and coordinate as
C reads, the cell computed by `PlaceCellSQL.cell(of:cells:)` (the same floor of the same
product, clamped alike), the type compared by its bytes with the last row's and decoded once
per distinct type. Rows come in runs of one type and cell (the walk is by folder), so a row
takes the last row's slots unless its own differ, and the tally's columns are made once at
their length from the mapped build (`take(whole:)`). The keyed re-read uses the same column
reads. The `capacity` a read reserved from the last read's row count went with the appends.

## Same-photo pairs: a generic grouping, at `-Onone`, per bucket and per instant

#881 replaced `Dictionary(grouping:)` with `Dictionary(exactlyGrouping:)` in
`SamePhotoPolicy.candidatePairs`, for the aspect buckets and, inside each, for the captured
stills by instant. The helper is generic code in Otos's module, compiled without
optimization in the bench's (and the check's) Debug build, while the standard library's
grouping runs optimized. Over the benchmark's candidates at the flagged head:

| phase | exactlyGrouping | Dictionary(grouping:) |
|---|---|---|
| buckets of every candidate | 135.6 M | 39.3 M |
| every candidate by instant | 146.5 M | 56.3 M |

The pass now works on positions in the candidates, never on copies: a counting sort lays the
eligible positions out bucket by bucket (each bucket a run of one array), the captured stills
of one instant are a chain of positions through one array, and the per-bucket buffers are
made once at the largest bucket's size. The library of a bucket, while Duplicates compares
within each library, is its root's number in the identity table, read for the whole pass
under one lock (`MediaAssetID.rootNumbers(of:)`), not a root path per candidate. The pairs
are the same set; `SamePhotoTests` checks them against a test of every pair on a random
library of two roots.

## Window apply: the parts comparison

#867 publishes the window state part by part (`CatalogWindowParts`): applying a state
compares each of its sixteen parts with the last, and reading the whole state registers an
access to each. On the main thread the republished apply is 0.38 M of the case's 0.40 M; the
parts' comparison alone is 0.08 M, and one read of the whole state 0.024 M. That is the
mechanism #867 added, on a sub-millisecond case; the same PR took the order-changed apply from
0.80 M to 0.67 M. It is left to be accepted rather than contorted.

## Results

Three processes of `catalogCases()` and `windowApplyCases()` on the change's tree, rebased on
9b164d62 (medians, process range in brackets):

| case | baseline 5207d482 | flagged 73dffba5 | this change |
|---|---|---|---|
| projection.filterOptions.allMedia | 70.2 M | 322.9 M | 69.4 M (69.37–69.43) |
| duplicates.samePhotoPairs | 466.1 M | 696.5 M | 277.8 M (277.82–277.83) |
| duplicates.build | 3,607.2 M | 2,957.7 M | 2,619.9 M |
| window.apply.republished.158k | 0.30 M | 0.40 M | 0.41 M |

The other cases of the two scenarios are within a few percent of the flagged head's. The next
daily run judges the change on `main`.
