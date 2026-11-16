# The window's memory across scope changes (2026-11-16)

## Question

On the owner's library with every background owner off, the app peaked at about 350–494 MB,
and a heap taken at the full app's peak held 0.9–1.25 million Swift strings (87–128 MB) and
52 MB of `[MediaAssetID]` in about 35,000 arrays. Each order read makes a new string for every
row's relative path, so orders read at different times hold their own copies of the same
paths. And freed blocks of 4 KB and up stay in `phys_footprint` on this macOS
(`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). How many copies of the
paths does the window hold, and does sharing them lower the footprint?

## Method

`OtosTests/WindowMemoryTests.swift` on a generated catalog of the owner's size and shape
(`OwnerShapedCatalog`, scale 1, 166,990 rows, 164,766 in All Media; `OTOS_SCALE_TEST=1`), one
owner-size run at a time on the Mac, in the test process (Debug, unoptimized). The projection
runs with every background owner off and its states drained unkept. After All Media's first
publication, and again after 20 scope changes (three libraries, the newest import batch, All
Media, in turn), each followed by a choice changed on its first row so the shown order and its
stacks are read again whole, it counts the distinct heap storages of the path strings the held
structures reference (window, both order slots, the collapses, the held stacks, the change
log) and their bytes, and reads `phys_footprint` (`task_vm_info`) after every step.

Four trees: `main` (2c46fc07); a process-wide intern table in the Store that hands every order
and stack read the one string it holds for a path's bytes, bounded by the catalog's row count
(the "path table"); the path table with the order's rows mapped as the cursor reaches them,
the arrays reserved at the last read's size and a library's stacks taken from All Media's
held ones; and the change landed here, `CatalogOrderedAssets.holdingArrays(of:)`.

## Results

| Tree | Path storages held after 20 | Their bytes | Bytes per path | Footprint after 20 |
| --- | --- | --- | --- | --- |
| `main` (two runs) | 340,808 | 30.5 MB | 190 | 212, 220 MB |
| Path table | 164,766 | 14.9 MB | 93 | 312 MB |
| Path table, streamed rows, held stacks (two runs) | 164,766 | 14.9 MB | 93 | 299, 301 MB |
| Held arrays (landed) | 175,788 | 15.6 MB | 96 | 213 MB |

- On `main` the window held All Media's order twice. A re-read that came back unchanged left
  the held collapse in place (`collapseStacks` reuses `last` when its IDs equal the new
  order's), so the collapse and the published window kept the first read's IDs and paths while
  the order slot held the new read's: 164,766 paths and their IDs twice, about 25 MB.
- Every path table run held one string per path, and every one ended about 90 MB higher in
  the footprint than `main`. On `main` the footprint fell from 263 to 150 MB at the fourth
  step, as the strings of an order no longer held died together; with the table no string a
  read had made ever died, and strings kept for good scattered among a read's freed
  temporaries keep those pages in the footprint, as the allocator study's "one in 64 kept" row
  found. The table shares the strings and costs more memory than it saves.
- Keeping the held arrays when a re-read equals them holds one copy of the order: the
  remaining 11,022 storages beyond one per path are the held stacks' members, which their own
  read made (about 0.7 MB). The footprint after 20 steps is within the two `main` runs.

## Conclusion

The window's own strings were held twice by one ownership fault, not by the lack of a
shared table: the projection kept a re-read's arrays beside the equal ones its collapse and
window still held. `CatalogOrderedAssets.holdingArrays(of:)` keeps the held arrays wherever a
re-read's are equal, in the whole-read and keyed paths, so a re-read that changed nothing in
the order leaves one copy. An intern table for paths is rejected on this measurement: it
raised the footprint by about 90 MB while halving the strings. The footprint at rest in this
test is set by the reads' freed temporaries, not by the held order; the heap's other strings
belong to the background owners, which this test switches off.
