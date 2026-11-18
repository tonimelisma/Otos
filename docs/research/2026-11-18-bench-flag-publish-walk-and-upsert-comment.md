# 2026-11-18 benchmark flag: a read's publication and the scan upsert's comment

The daily run of 2026-11-18 (head 9afa1f53, baseline 73dffba5) flagged two cases. Both
were bisected with `script/bench.sh compare` against the head's records; each point is the
median of three test processes, in millions of instructions (Debug build, `-Onone`).

| Commit | `window.publish.orderChanged.158k` | `immich.listing.batch500.of20k` |
| --- | --- | --- |
| 73dffba5 (baseline) | 788.8 | 570.3 |
| 3d76279a (#919) | 783.5 | 554.4 |
| 24291456 (#920) | 978.8 | 554.7 |
| f2bee3f8 (#927) | 985.2 | 555.3 |
| 73b19b97 (#935) | — | 557.7 |
| ef41db33 (#936) | 989.9 | 613.9 |
| 9afa1f53 (head) | 980.2 | 629.4 |

## `window.publish.orderChanged.158k`: #920

#920 publishes a new order of the same query as an edit of the last publication
(`CatalogMediaGridState.sharingContent(of:)`): `Edit.walk` compares the two orders side by
side. It did so after writing the new order's whole position table (`prepareIndex()`), which
the walk read for its look-ups and the publication kept. A copy of the two steps compiled at
`-Onone` over 158,000 identities, one dropped, costs 858 M for the table and 179 M more for
the walk: the walk is the flagged rise, and the table, already paid before #920, is most of
the case.

Fix: the walk tells the runs the two orders share at either end equal item by item and
indexes only the stretch between them; the published content's index is the last
publication's carried through the walk's edit (`Positions.editing(by:into:)`), as an act's
already was, so a read's publication writes no table. A table is written again once the
composed edit names as many positions as the order holds, the point at which carrying it costs
what the table does. The same copy of the new steps costs 203 M. Guards:
`GridContentEditTests.aReadsPublicationIndexesItsEditNotItsOrder` (a one-photo move at
160,000 and at 16,000 writes at most two index entries, the same at both sizes) and
`everyPublishedReadsIndexAnswersAsItsOrderDoes` (300 random reads, every position answered as
the order answers it, the table written again within the run). ADR 0005 and ARC-064 say so.

## `immich.listing.batch500.of20k`: #936

#936 added a two-line SQL comment to the scan upsert (`upsertScannedFile`), which every item
a listing or scan writes executes, changed or not. The comment held `§`. A cached statement is
found by its SQL text (GRDB's statement cache, a dictionary keyed by `String`), so each
execution hashes the 2.5 KB text; a character outside ASCII sends Swift's string hashing
through Unicode normalization. Measured on a generated catalog of 20,000 account rows, 500
unchanged upserts on one connection:

| Upsert text | M instructions |
| --- | --- |
| without the claim clause and its comment | 143 |
| with both (#936) | 198 |
| the clause as `NULL`, the comment kept | 187 |
| prepared once (`makeStatement`), with or without | 279 k vs 282 k per execution |

SQLite's own work is unchanged: 320 against 321 VM steps per execution, no trigger fired. A
2.4 KB dictionary key costs 11 k instructions to look up in ASCII and 120 k with one `§`.

Fix: the comment moves into the Swift comment above the statement, so the SQL is ASCII.
Guard: `CatalogSQLTextTests` lists 100 account assets and lists them again unchanged; every
statement the writer runs is ASCII, an unchanged item fires no trigger, and it runs at most six
statements. It fails on the unfixed upsert.

The rest of the rise, 613.9 → 629.4 M from ef41db33 to the head (#937, #942: the copy key,
its index and triggers), is within the case's noise by the harness and is not attributed.

Neither fix is measured by a benchmark here: both are judged by the next daily run.
