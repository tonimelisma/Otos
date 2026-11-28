# What a People pass leaves on the heap (macOS 27, 2026-11-16)

## Question

Plan 0116's footprint target is 700 MB. The People pass's first run on the reference library
left about 278 MB more in the footprint than before it. On macOS 27 a block `malloc` frees
stays in the footprint until the allocator reuses it
(`2026-11-16-freed-memory-stays-in-the-footprint.md`), so what a step holds live at its most,
not what it keeps, is what it can leave behind. Which steps of a pass hold the most?

## Method

A throwaway test (not kept) on the generated reference-shaped catalog (`ReferenceShapedCatalog`,
scale 1: 102,979 faces, 748 people, unit vectors one direction per person, no face the user
named), `OTOS_SCALE_TEST=1`, alone. It ran each step of a pass in turn, keeping what a pass
keeps, and sampled every malloc zone's `size_in_use` every 2 ms (`liveHeapBytes`), with
`phys_footprint` before and after each step. Megabytes:

| Step | Live before | Live peak | Live after | Footprint after |
| --- | --- | --- | --- | --- |
| Snapshot read | 8 | 55 | 35 | 115 |
| Gallery facts | 35 | 47 | 35 | 138 |
| Vectors (held) | 35 | 164 | 158 | 249 |
| Facts | 158 | 174 | 174 | 271 |
| One run of chaining | 188 | 223 | 189 | 303 |
| Grouping every leftover face | 189 | **275** | 196 | 308 |
| Whole assignment | 188 | 296 | 219 | 381 |
| Plan of changes | 219 | 286 | 251 | 383 |
| Ranker | 219 | 249 | 234 | **428** |

The vectors (105 MB at half precision) and the snapshot are held between passes by design.
The rest is what the working sets left: 428 MB of footprint over 234 MB live.

## The two largest working sets

- **Grouping's links.** `unnamedGroups` kept up to ten links per face in an array of
  `(Float, Int, Int)`, 24 bytes each, and sorted a copy of it: about 50 MB of heap at once
  for 103k faces, freed when grouping ends.
- **The ranker's runs.** `PersonRun` ordered a person's faces through an array of
  `(FaceFact, Double)` pairs, a sorted copy of it and a concatenation, and `FaceRanker`
  grouped copies of every face by person first: three or four copies of every face's fact,
  about 130 bytes each, alive while the runs were built.

## Fix

The links live in a `ScratchBuffer` of 12-byte records sorted in place, unmapped when
grouping returns. A run orders its faces by position and copies each face once, into the
run it keeps; the ranker groups positions, not faces. Results are identical: the same order,
the same comparisons (`KernelDifferentialTests`, `FaceAssignmentPolicyTests`).

| Step (after) | Live peak above before | Footprint after |
| --- | --- | --- |
| Grouping every leftover face | 86 → **35** (21 in the guarded test) | 308 → 260 |
| Ranker | 30 → **15** | 428 → **386** |

`PeopleStoreTests.peopleCostsOnTheReferenceShape` now guards both: grouping holds at most 48 MB
live, building the ranker at most 24 MB.

## What is left

The snapshot read's growing arrays and the assignment's per-face dictionaries (guesses,
likeness, the plan's changes) are the rest of the gap between live and footprint. They are
keyed by face identity, so moving them off the heap means an index-based result, a change to
the kernel's types, not to its buffers.
