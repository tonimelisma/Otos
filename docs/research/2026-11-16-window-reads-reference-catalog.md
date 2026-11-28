# The window's own reads on the reference catalog (plan 0116 stage 5)

Date: 2026-11-16. Method: the reference catalog (2.56 GB, 166,990 assets, schema v65) opened
read-only with `sqlite3 -readonly "file:…?mode=ro"`, Otos not running; "cold" means the
file's pages were dropped from the buffer cache with `msync(MS_INVALIDATE)` on a read-only
mapping and `mincore` reported none resident; "pages" are SQLite's page cache misses in a
fresh process (`.stats on`). The installed build's unified log of the read-only tour on it
(build 661be172, 2026-11-16 09:01–09:05 UTC) was read for the order of events. No benchmark
was run.

## 1. Where the tour's long steps went

The tour's `op=projection.*` lines, in order (times in seconds from each intent):

| Step | Shown after | Waiting for | Then |
| --- | --- | --- | --- |
| Search with few results | 19.9 s | the options read of the previous pass, 16.4 s | 3.5 s: the order read again for the new descriptor, and the search |
| Clearing the search | 24.8 s | the previous pass's options read, 22.9 s | 1.8 s: the order read again |
| Sort by name | 41.8 s | the previous pass's options read, 15.4 s | 25.9 s: the order read through the name index |

Three mechanisms, each shown in the code and measured below:

1. **A pass waits for its own options read before the next pass can start.** The options are
   read after the window publishes, inside the same pass (`CatalogProjection.pass` awaits
   `readOwedFilterOptions`), and an intent on the same sidebar row does not supersede them,
   since they still answer it. So a search, a sort or a filter change waits for the whole
   options read. The options were owed on almost every pass: of the tour's 277 Store
   changes, 227 named `copies`, and All Media's options depended on `copies` because All
   Media shows one copy of identical files.
2. **The held order is keyed by the whole descriptor, search included.** A search narrows
   the order after it is read, but `CatalogProjectionReads.heldOrder` compares the
   descriptor with its search, so typing a search, changing it and clearing it each read the
   whole 164,762-row order again, and the search's order replaced All Media's in its slot.
3. **The name and size order indexes hold no visibility columns.** The date indexes carry
   every column the scope tests (v55), so the date order reads 3,578 pages; the name and size
   indexes carry only the key, so their walk reads every table row.

## 2. The order read by sort, All Media (roots 6, 7, 15)

| Order | Index | Pages | Time (OS cache warm) |
| --- | --- | --- | --- |
| Date, newest first | `idx_media_asset_best_capture_global_desc` | 3,578 | 0.08 s |
| Name | `idx_media_asset_name_global_asc` | 152,822 | 9.07 s |
| Size | `idx_media_asset_size_global_desc` | 183,828 | 0.76 s |

The name order took 25.9 s in the tour, cold on a Mac with 86 MB free.

## 3. The stack candidates

`PhotoStackSQL.candidateQuery` for roots 6, 7 and 15:

| Read | Candidates | Pages | Cold | Warm |
| --- | --- | --- | --- | --- |
| Every still of every folder holding a RAW, `UNION` burst stills | 25,944 | 24,249 | 1.91 s | 0.16 s |
| Only folders holding a RAW and another still, `UNION ALL` | 15,038 | 13,037 | 0.58 s | 0.08 s |
| Of which the folder test alone (index only) | 6 folders, 15,009 stills | 4,381 | 0.14 s | |

The reference library's RAW folders: library 7 has 6, all holding other stills; a camera (13) has 5; the
Immich account has 10,906, every one alone in its asset's staging folder. Its bursts: 33
identifiers on 39 stills, one burst of seven frames and 32 identifiers carried by one still.
Its pairs: 5,849 stacks in all.

Of the narrower read's 0.58 s cold, 0.44 s is the 15,038 candidates' table rows. A covering
index would have to carry `sort_key` (154 to 544 bytes a row), which the rule reads to order a
pair's files and a burst's frames: about 96 MB over the 146,391 stills, against 20.6 MB for
`idx_media_asset_stack_candidate` today, written on every still's write. It is not built: the
stacks are held across passes while nothing they are built from moves (ADR 0005), so the read
is paid at launch and after a stack fact moves, and 96 MB of index is page cache the window's
other reads lose on a Mac that already pages.

## 4. The order read's Swift work, unoptimized and at `-O` (E1)

`OrderReadPhaseTests` at the reference library's size (`ReferenceShapedCatalog`, scale 1: 164,766 rows of All
Media, 159,382 shown once stacks collapse), three rounds in one ordinary test process, the
file warm after the first. Milliseconds, rounds 2 and 3:

| Phase | Before, unoptimized | After, unoptimized | After, OtosKit at `-O` |
| --- | --- | --- | --- |
| SQL and its rows | 912–1,000 | 764 (2,263 under load) | 74 |
| Stack read | 224–225 | 69–174 | 35 |
| Stack rule | 542–548 | 253–279 | 20–21 |
| Rows made IDs (`orderedAssets`) | 2,833–2,882 | 133–138 | 12–13 |
| Collapse | 795–1,055 | 202–233 | 32–42 |
| Position index | 362–408 | 233–319 | 16–19 |
| Sum | about 5,800 | about 1,800 | about 200 |

"Before" is main at 5386d36f. "After" changes three things:

- A media asset's fingerprint is mixed from its two paths' own fingerprints. It was FNV over both paths' bytes again, and most of the rows-to-IDs phase, the stack rule and the position index was that hashing.
- The rows-to-IDs loop compares each row's root and day with the row before it instead of looking each up.
- The collapse probes each file once and runs its two levels over the stacked files alone.

The `-O` column builds OtosKit, GRDB and MediaMetadata with `-O` and the test target unoptimized; the Swift 6 compiler crashed compiling the test target at `-O`. The command:

    xcodebuild test -project Otos.xcodeproj -scheme Otos -configuration Debug \
      -destination platform=macOS -derivedDataPath build/DerivedDataO \
      'SWIFT_OPTIMIZATION_LEVEL=$(OTOS_OPT_$(TARGET_NAME))' OTOS_OPT_OtosKit=-O \
      OTOS_OPT_GRDB=-O OTOS_OPT_MediaMetadata=-O OTOS_OPT_OtosTests=-Onone \
      OTOS_SCALE_TEST=1 -only-testing:OtosTests/OrderReadPhaseTests

The app target builds at `-O` with `get-task-allow` in its signature, so the installed build
compiles with `-O` (ADR 0030).
