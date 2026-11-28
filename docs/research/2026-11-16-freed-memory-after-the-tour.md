# Freed memory after the tour's scope visits (2026-11-16)

## Question

At idle after a ten-minute tour on the reference library (installed 5f77e2e5), the app held
627 MB. Its malloc regions were 460 MB dirty, and its live heap was 324 MB, so malloc held
about 136 MB of freed blocks. On macOS 27 a freed block of 4 KB or more stays in the
footprint until malloc reuses it (`2026-11-16-freed-memory-stays-in-the-footprint.md`).
Which code makes and frees those blocks?

## Method

`TransientMemoryTests` runs a generated catalog of the reference library's shape (`ReferenceShapedCatalog`,
scale 1, about 167k rows) with every background owner running (`RunningBackgroundOwners`).
It runs the launch, then the tour's scope visits: All Media's first grid, a library, People,
a person, Places with its clusters, On This Day, Duplicates, All Media again, a video filter
and a sort by name. The test bundle holds no search model, so the test makes no search.

- **After each step:** `vmmap --summary` of the test process: the malloc zones' dirty and
  swapped bytes, the bytes allocated in them, and their difference (`FRAG SIZE`, freed bytes
  malloc holds).
- **Throughout:** `MallocSiteProbe` hooks libmalloc's `malloc_logger`. For every block of 4 KB
  or more it records the call stack, the bytes allocated, and the bytes freed again before
  the sequence ends. Its tables are mapped memory, so the probe allocates nothing itself.
- **Scope:** a Debug test host, one run each way, with the reference-scale lock held. Nothing was
  run on the installed app or the reference catalog.

## Before (commit b42f9800, the tests alone)

| Step | Malloc dirty MB | Allocated MB | Freed, held MB |
| --- | --- | --- | --- |
| first grid | 144 | 105 | 38 |
| library | 152 | 112 | 40 |
| People | 259 | 240 | 19 |
| person | 245 | 189 | 56 |
| Places | 349 | 295 | 54 |
| On This Day | 304 | 224 | 80 |
| All Media again | 320 | 244 | 76 |
| sort by name (end of sequence) | 270 | 188 | **82** |
| owners shut down | 263 | 144 | 118 |

### Top transient sites by bytes freed (4 KB to 36 MB blocks)

| Freed MB | Blocks | Largest KB | Where |
| --- | --- | --- | --- |
| 3,746 | 226,050 | 40 | `CatalogStore.oweFacesAgain`: one UPDATE compiled per photo (`db.execute(sql:)`), about 150 KB of statement program each time |
| 1,195 | 67,204 | 31 | SQLite statement compiles in the walks: uncached per page (`CandidateWalk`) |
| 697 | 16,892 | 128 | `requestEnrichmentDownload`: SQLite's statement journal for a write |
| 321 | 619 | 898 | `PhotoDescriptionWriter.drain`: a `Set` of every paced still, copied per page |
| 292 | 19,936 | 20 | `photoDescriptionFacts`: two statements compiled per still |
| 153 | 32 | 9,010 | `CatalogWindowPolicy.assetIDs`: each published order's arrays, freed when the next replaces it |
| 119 | 55 | 32,863 | `SamePhotoPolicy.candidatePairs`: `Dictionary(grouping:)` growing a group of candidates |
| 67 | 57 | 15,231 | the order read (`fetchOrderedAssetIDRows`): an array grown row by row |
| 55 | 12 | 32,863 | the duplicates candidates read (`fetchSamePhotoCandidates`): grown row by row |
| 53 | 8 | 16,416 | `CatalogGridContent.positions`: each order's index, freed with it |
| 48 | 13 | 24,575 | `PeopleAssignment.syncVectors`: a filter over every face |
| 26 | 59 | 2,047 | `PhotoStackRule.stacks`: filters and `compactMap` over a root's candidates |
| 22 | 53 | 2,047 | the stack candidates read: grown per root |
| 21 | 112 | 1,535 | the filter options tally's first read: three columns grown row by row |
| 14 | 335 | 140 | the derived folder's walk (`namedRows`): `fetchAll` then `map` |
| 11 | 67 | 4,095 | the People snapshot's face columns: grown face by face |

70 call stacks grew an array, outgrowing its buffer, while they held a catalog connection.

## The pattern

- **What a reference-scale read collects goes into mapped memory first.** `MappedArrayBuilder`
  (`Otos/Support/MappedArrayBuilder.swift`) grows in mapped regions and unmaps each region it
  outgrows. It hands back an array of exactly its count. `collect` does this for a cursor or
  for a sequence's filter or compactMap. `withElements` lets a build group or count rows
  before it makes its result. Used by:
  - the order rows, the duplicates candidates and the stack candidates;
  - the stacks rule, the filter options tally, the People snapshot's faces;
  - the walks' pages (search embeddings and texts, faces, descriptions, metadata, the
    derived folder);
  - keyed reads (stored assets, tile details, current embeddings, keyed candidates);
  - a root's existing rows.
- **A grouping makes each group at its length.** `Dictionary(exactlyGrouping:by:)` counts
  first, then fills arrays made at their counts. All 24 groupings in the app use it, and the
  lint `grouping_grows_arrays` refuses `Dictionary(grouping:)`.
- **A statement asked once per row is prepared once per connection.** This applies to
  `oweFacesAgain`, `photoDescriptionFacts` and the walks' pages (`db.cachedStatement`).
- **A set already held is passed, not copied.** The description walk passes its paced
  stills' keys as they are (`excluding: some Collection<MediaAssetID>`).

## After (the branch's head)

| Step | Malloc dirty MB | Allocated MB | Freed, held MB |
| --- | --- | --- | --- |
| first grid | 128 | 105 | 23 |
| library | 152 | 126 | 26 |
| People | 256 | 242 | 14 |
| person | 228 | 182 | 46 |
| Places | 345 | 280 | 65 |
| On This Day | 301 | 211 | 89 |
| All Media again | 322 | 232 | 89 |
| sort by name (end of sequence) | 206 | 178 | **27** |
| owners shut down | 171 | 118 | 53 |

- **Freed and held at the end of the sequence:** 82 → 27 MB.
- **After the owners shut down:** 118 → 53 MB.
- **`oweFacesAgain`'s compiles:** 3,746 → 161 MB freed.
- **Call stacks that grew an array inside a catalog access:** 70 → 13. The largest left is
  `PhotoStackRule.stacks` at 719 KB, a root's stacks.
- **Not changed, as expected:** the mid-sequence peaks (89 MB at On This Day and All Media).
  They are the replaced orders' own arrays (`CatalogWindowPolicy.assetIDs`, 9 MB blocks;
  `CatalogGridContent.positions`, 16 MB) and the duplicates groups (`candidatePairs`, made
  exactly now but still freed into malloc). These are held results, not reads' scratch.
  They return to the system only if a result itself lives in mapped memory, which is the
  identity structures' work, not this change.

## Again, on main with the 4-byte asset identities (#878, #879)

The identity change landed while this was built. Both trees were measured again, one run each:
main at 4acb9e0d with the two test files added, and this branch rebased onto it.

| | main | this change |
| --- | --- | --- |
| Freed and held, highest during the sequence | 92 MB | 51 MB |
| Freed and held at the end of the sequence | 92 MB | 51 MB |
| After the owners shut down | 107 MB | 14 MB |
| Footprint at the end of the sequence | 405 MB | 332 MB |
| Call stacks growing an array in a catalog access | 48 | 11 |

From run to run the end-of-sequence figure moves by tens of MB: 27 and 51 MB after this
change, 82 and 92 MB before it. So the on-demand bound is 64 MB, above every run after and
below every run before.

## Guards

- **Every run** (`theTourSequenceOnASmallCatalog`, at 2 % of the reference library's size): no
  reference-scale read grows an array past a 16 KB buffer while it holds a catalog connection,
  and 16 KB is more than a bounded page needs. The reads are the order and its stacks, the
  filter options, the duplicates candidates, the People snapshot, a root's rows and the
  derived folder's walk. The process's identity table grows by design and is not counted.
- **On demand** (`OTOS_SCALE_TEST=1`, `theTourSequenceAtTheReferenceSize`): malloc dirty minus
  allocated after the sequence is at most 64 MB.

## Not measured here

- The installed app: the next tour on the reference library.
- Search's own reads: the test bundle holds no search model.
