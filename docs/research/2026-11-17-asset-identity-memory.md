# What holds asset identity in memory, and a 4-byte ID (2026-11-17)

## Question

A heap of the installed app, idle on the reference library, after a full tour (installed 5f77e2e5, about 159,000 items in
All Media, 103,000 faces) held 324 MB live in 1.41 M nodes, and about 190 MB of it was asset
identity: 590,952 `Swift.StringStorage` (57.5 MB), 11,744 `[MediaAssetID]` (55.8 MB), 5,879
`Set<MediaAssetID>` (16.8 MB), three `[MediaAssetID: Int]` (19.4 MB), one
`[MediaAssetID: Int32]` (16.8 MB) and smaller dictionaries keyed by `MediaAssetID`. Who holds
each, and what is the smallest design that holds identity without them?

## Method

A probe test on a generated catalog of the reference library's shape (`ReferenceShapedCatalog`, scale 1:
166,990 rows, 159,382 in All Media, 102,979 faces) in the test host, Debug, with
`MallocStackLogging=lite`. It builds the window's whole stack as the app does
(`CatalogWindowViewModel` with People, Duplicates, the search index and place names
running; enrichment, metadata refresh, render signatures, preview faces, descriptions and
Immich off, since the generated rows have no files or server), with a scanner that refuses,
so the empty library folders delete no rows. It takes the tour's scope sequence through the
window's intents: All Media, the newest import, a library, People, the most photographed
person, Places, On This Day (Duplicates showed no row yet), All Media, three searches (the
search index never answered in the test host; each waited 90 s), a kind filter, a name sort,
and back. Then `heap -s`, `heap --addresses`, `malloc_history` for each block's allocation
stack, and `leaks --trace` for the path from a root to each large block. Never on the installed
app. The probe was not landed.

`MemoryLayout<MediaAssetID>.stride` was 56 bytes (two path types of a `String` and a
fingerprint each, and a fingerprint of the pair), not 16: 55.8 MB of ID arrays on the installed app's
heap is about 1.0 M IDs, about 6 per asset, not 22.

## Results: who holds it (generated reference shape, after the tour)

Heap: 900,615 nodes, 283.7 MB live; footprint 405 MB.

| Owner | Structure | Count | Bytes | Why held |
| --- | --- | --- | --- | --- |
| every ID, wherever held | `StringStorage` of a relative path, made by the read that made the ID (`String.init(sqliteStatement:)`) | ~469,000 (sampled 1 in 200) | ~54 MB | an ID carried its own path string; each read of an order, a person's faces or the stacks made a new one per row |
| unattributed by stack | `StringStorage` | ~215,000 | ~23 MB | allocation stack not recorded |
| `CatalogProjection.reads.collapses[allMedia]` | `[MediaAssetID]` `ids` (uncollapsed All Media) | 164,766 | 9.2 MB | the collapse's input, reused while nothing moved |
| same, `result.ids` = `CatalogGridContent.orderedAssetIDs` (the window) | `[MediaAssetID]` | 159,382 | 8.9 MB | the shown order |
| `CatalogGridContent.index` | `[MediaAssetID: Int]` | 159,382 | 25.2 MB | the window's position index (`prepareIndex`) |
| a cursor read of an order (`Array(cursor)`), reachable only through conservative pointers | `[MediaAssetID]` | 164,766 | 12.6 MB | a pass's frame; no typed holder found |
| `CatalogProjection.changeLog.entries` | `Set<MediaAssetID>` | 102,979 | 25.2 MB | a change naming every face's photo (`oweFacesAgain` after People found the generated vectors malformed) |
| `PeopleAssignment` snapshot (`PeopleFaces.photos`) | `[MediaAssetID]` | 102,979 | 8.9 MB | each face's photo, for the next pass |
| the stacks (`PhotoStackRule.pairs`, 5,384 pairs) | per stack `members` (2), `photos` (1), `rawMembers` (`Set`, 1) | 16,152 containers | 2.3 MB | each stack's own arrays and set |
| `CatalogStacks` | `stackedMembers` `Set`, `pairOfMember` | 10,768 each | 0.9 + 1.6 MB | the collapse's probe and lookup |
| `PhotoStackCollapse.Result` | `tiles` `[ID: TileStacks]`, `shownForHiddenMember`, `stackedPositions` | 5,384 / 5,384 / 10,768 | 2.7 + 0.9 + 1.0 MB | the window's stack tiles |
| People (`keyOfMember` merged) | `[MediaAssetID: MediaAssetID]` | 10,768 | 1.8 MB | a face's photo to its stack's key |
| `DuplicatesGateway.fetchSamePhotoCandidates` | `[SamePhotoCandidate]` | 144,391 | 50 MB | a Duplicates build in flight (on the installed app's idle heap 4.5 MB) |
| search text tokenizer (other owner) | `[[UInt8]: Int32]`, `[UInt64: UInt64]`, 258 k `[UInt8]` | — | ~40 MB on the installed app's heap | the SigLIP vocabulary and merges; not in this probe (no query reached it) |
| search index (other owner) | `rowOf: [MediaAssetID: Int32]` | ~165,000 | 16.8 MB on the installed app's heap | the vector file's row of each asset |

The 11,744 arrays and 5,879 sets on the installed app's heap are mostly the stacks: 5,384 pairs hold
10,768 arrays and 5,384 sets of one or two IDs each. The bytes are in a few large structures:
the orders, the window's position index, the change log and People's photos, each 56 bytes an
ID, and the strings every ID carried.

## Design

A blank slate holds an asset's identity as a small value and its path once:

- **`MediaAssetID` is the 4-byte place of its pair in a process-wide table**
  (`MediaAssetIdentityTable`): the table holds each distinct (root, relative path) pair once,
  the root as one of the few `LibraryRootPath`s, the path as its UTF-8 bytes in mapped regions;
  equal pairs are one place, so IDs compare and hash as integers. The path is read back when a
  consumer asks for it (`id.relativePath`, `id.fileURL`), a copy made then. Every call site
  keeps its code: only the type's storage changed. An order is 4 bytes per asset and holds no
  string; a position index entry is 12 bytes where it was 64.
- **Why not the shared path table that raised the footprint by 90 MB.** That table kept the
  first `String` each read made for a path. Those strings were small malloc blocks scattered
  among the read's freed temporaries, so the pages they sat on stayed in the footprint
  (`docs/research/2026-11-16-shared-path-strings.md`, and freed malloc memory stays in the
  footprint on macOS 27, `docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`).
  This table keeps no string a read made: the read's strings all die as they did before, and
  what the table keeps is in its own mappings of 1 MB and more.
- **Why not the catalog's row id.** `media_asset` has no `INTEGER PRIMARY KEY`, so `VACUUM`
  (the open's compaction, `CatalogStore.compactIfOwed`) and a twelve-step rebuild (v71) may
  renumber its rows, and without `AUTOINCREMENT` a deleted last row's id goes to the next
  insert: a row id held in memory across a deletion could name another file. A library
  reorganization moves a file by updating its key in place
  (`CatalogStoreReorganizationJournal`), so the row id would also follow a file across a move,
  where identity is the path. And every consumer that needs a path (a tile's name, a drag, an export, the
  clipboard) would need a Store read. The table needs none of that: equal paths are equal IDs
  for the process's life, and nothing about the catalog's row numbering reaches it.
- **Redundant copies.** With 4-byte IDs the window's identity structures for All Media are
  about 0.7 MB an order and 3 MB for the position index; holding All Media's order and
  collapse while another scope is shown costs about 1.5 MB, so releasing them on leaving a
  scope and reading them again on return (0.09–0.13 s measured now, against the 0.3 s target)
  buys less than 2 MB and is not done. The change log's sets and People's photos shrink the
  same way.
- **Cost.** The table grows by one entry per distinct pair the process names, about 24 bytes
  of entry, the path's bytes and 8 bytes of index; on the reference catalog's 167,000 rows about 15 MB,
  held for the session. Making an ID takes one lock, a hash probe and a byte compare; reading
  its path takes the lock and copies the bytes into a new string.

## Results: after

The same probe and sequence on `main` (5f77e2e5) and with the table, both without stack
logging (the attribution run above had it on), Debug test host, the generated reference shape at
scale 1. Footprint is the process's own `phys_footprint` after each step; the live heap is
`heap -s` at the end, held idle.

| | `main` | Table |
| --- | --- | --- |
| Live heap at the end | 264.9 MB, 899,987 nodes | 106.8 MB, 355,730 nodes |
| `StringStorage` | 691,087, 77.2 MB | 152,509, 30.0 MB |
| `[MediaAssetID]` | 10,774, 41.3 MB | 10,772, 2.6 MB |
| `Set<MediaAssetID>` | 5,386, 27.1 MB | 5,386, 1.6 MB |
| `[MediaAssetID: Int]` | 2, 17.9 MB | 2, 3.4 MB |
| Footprint after All Media's first publication | 235 MB | 150 MB |
| Highest footprint of the sequence | 364 MB (All Media again) | 259 MB (All Media again) |
| Footprint at rest after it | 337 MB | 230 MB |

The window's All Media order is no longer
held twice either: `CatalogWindowPolicy.assetIDs` returns the order's own arrays when the scope
keeps every row, so the collapse's input is the order slot's copy
(`WindowMemoryTests`, on every run: at most 2.2 IDs held per asset across the window, both
order slots, the collapses, the stacks and the change log, and at most 10 bytes per asset;
on the small catalog, with the table but before the copy was dropped, the same structures
held 10,218 IDs for 3,294 assets, 3.1 per asset: All Media's order once in its slot and again
as its collapse's input). What remains on the heap is Duplicates' candidate
read in flight (25 MB, half of `main`'s now that each candidate's ID is 4 bytes), the order's
day and capture arrays, People's face columns, and SQLite's own.

`WindowMemoryTests` at the reference library's size (`OTOS_SCALE_TEST=1`, background owners off, 20
scope changes each with a whole re-read): the held structures hold 335,170 IDs for 164,766
assets (2.03 per asset, 8.1 bytes per asset; 659,826 references), the same after 20 steps as
after the first, and the identity table held 164,766 entries at both checkpoints: a re-read
names no new pair. The test process's footprint after the 20 steps was 144 MB, against 212
and 220 MB on `main` when that test counted path strings
(`docs/research/2026-11-16-shared-path-strings.md`); the test now bounds it at 180 MB at the
reference library's size.

Not measured until the next daily run: the benchmark cases that make or compare IDs in bulk
(the window's apply, the projection's window state, Duplicates' build, People's pass).
