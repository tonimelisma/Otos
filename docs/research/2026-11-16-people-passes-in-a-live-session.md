# People passes in a live session (macOS 27, 2026-11-16)

## Question

A read-only tour of the owner's library on the installed build (6c973892; about 167k assets,
103k faces, 749 people) kept the footprint under 700 MB through every step, peaking at 648 MB.
Then, in the tour's idle step, with nobody touching the app, `event=peopleBuilt` samples showed
the footprint at 526 MB, then 773 MB 43 s later, and 770–809 MB for the next 50 s, peaking at
851 MB. What ran, which of it was owed, and what held the memory?

## What ran (the installed app's unified log, read-only)

`peopleBuilt` is written when the window applies a new People state, which follows every
gallery read (`PeopleGallery`), not every assignment pass. The passes themselves are
`op=people.pass` and `op=people.read`:

| Time | Pass | Read | Assigned | Footprint when its admission ended |
| --- | --- | --- | --- | --- |
| 13:58:46 | launch | whole, 702 ms | no (hash equal) | 332 MB |
| 13:58:48 | after enrichment | whole, 581 ms | no | 476 MB |
| 13:58:52 | after a reading of 6 photos | by key, 106 ms | **yes**: every vector read (758 ms), assignment 5.6 s | 526 → **721 MB** |
| 13:59:34–14:00:23 | after content hashes | whole ×7, by key ×2 | yes ×5, writing 1–8 likenesses each | 762–777 MB |

- **What rang them:** in the idle step, enrichment hashed local originals
  (`enrichment.contentHash phase=applied facts=copies,detail`), one every one to five
  seconds. A hash that finds an identical copy is a `.copies` change, which People reads
  (`PeopleAssignment.inputs`): it moves which file stands for a photo (`photoOf`), so it is
  read whole and moves the assignment's inputs. Each of the five passes that assigned wrote
  likenesses (a likeness is compared only with the person's faces in other photos).
- **Were they owed?** Yes. The request accounting already coalesces: the three hashes during
  the pass of 13:59:34 cost one pass after it, and so did every later run of them. Ten passes in
  50 s is one pass after each pass, for changes that each moved an input.
- **Where the memory went:** the footprint did not climb with the passes. It climbed once, by
  195 MB, in the pass of 13:58:52, the session's first that assigned: it read every vector
  onto the heap and ran the kernel. The later passes moved it within ±30 MB, peaking at
  851 MB while one ran.

## Attribution on a generated catalog of the owner's shape

A probe (not kept) in two test processes on `OwnerShapedCatalog` at scale 1 (102,979 faces,
755 people, unit vectors one direction per person): the first process generated the catalog and
settled it; the second opened it fresh and ran the live session's sequence with one owner — the
launch pass, a pass after a new reading of one photo (named, as a reading's change names it),
five such keyed passes, and one whole pass. It sampled `phys_footprint` and every malloc
zone's live bytes every 2 ms, each connection's page cache (`SQLITE_DBSTATUS_CACHE_USED`) at
each transaction's end, and ran `vmmap --summary` on itself between steps. Megabytes:

| Step | Footprint | Live heap | Live peak | Footprint − live |
| --- | --- | --- | --- | --- |
| Store open | 42 | 7 | 7 | 35 |
| Launch pass (whole read, hash equal) | 44 → 165 | 8 → 52 | 72 | 113 |
| First pass that assigns | 166 → **341** | 52 → 169 | 250 | 172 |
| Five keyed passes | 341 → 358 | 169 → 166 | 236 | 191 |
| Whole pass | 358 → 302 | 166 → 164 | 244 | 137 |

Holders, from the same run:

| Holder | Live | Evidence |
| --- | --- | --- |
| Vectors (`FaceVectors`, Float16 on the heap) | **113** | read alone: live +113; `Malloc Large` 22 → 141 MB in `vmmap` |
| The held snapshot (`lastRead`) | 44 | read alone: live +44 |
| A pass's working set beyond what it keeps | 80–85 | live peak above the held state, every assigning pass |
| What the launch pass's read freed and malloc kept | 66 | `Malloc Large (empty)` 45 MB, `Malloc Small (empty)` 21 MB |
| SQLite's page cache | 0 | 33 MB a connection, in its own `SQLite Page Cache` region with no dirty pages: not in the footprint |
| The catalog's mapping (256 MB `mmap_size`) | 0 | `mapped file` resident 177 MB, clean |

So the first assigning pass's +175 MB is the vectors (113 MB held) and about 60 MB of the
kernel's freed working set that malloc keeps; the launch pass's +121 MB is the snapshot (44 MB
held) and about 70 MB its read freed. Repeated passes do not ratchet much: they reuse the
blocks the first freed (+17 MB over five keyed passes).

## The vectors in a mapped file

`FaceVectors` now writes each page of vectors into a file of its own — created in the
temporary directory, unlinked at once — with `pwrite`, and maps it read-only and shared. Its
pages are clean and file-backed, so `phys_footprint` does not count them. The same probe, same
catalog:

| Step | Footprint, heap | Footprint, file |
| --- | --- | --- |
| Launch pass | 44 → 165 | 44 → 172 |
| First pass that assigns | 166 → 341 (+175) | 172 → **251 (+79)** |
| Five keyed passes | 341 → 358 | 251 → 287 |
| Whole pass | 358 → 302 | 288 → 194 |
| Reading every vector alone, live | +113 | **+2** |

Assignments are identical: the file's vectors are the same Float16 values
(`FaceVectorsTests.theFilesVectorsAssignAsVectorsOfTheirOwn`, and the People, kernel and policy
suites unmodified).

## The parts of a pass

With the vectors in the file, the same catalog, each part alone in a fresh process. Live heap
in megabytes: what it held at its most above where it started, and what it kept.

| Part | Transient | Kept |
| --- | --- | --- |
| The snapshot's whole read | 64 | 44 |
| — its faces with a likeness dictionary keyed by face, alone | 63 | 40 |
| — the stacks of every root, alone | 16 | 0 |
| — iterating the rows only | 0 | 0 |
| Gallery facts | 12 | 0 |
| Every face's `FaceFact` | 24 | 24 |
| Lapsed seeds (each bare person's seeds copied) | 16 | 0 |
| The faces copied with lapsed seeds opened | 12 | 12 |
| One run of chaining | 24 | 0 |
| A face-to-index dictionary | 26 | 0 |
| The whole assignment | 51 | 18 |

The generated catalog's faces are all anchors, so a run of chaining there has no open rows; on
the owner's, most faces are guesses, so the rows a run copied are most of the faces.

## Faces read by position

- **The snapshot:** the stored likeness is a column of `PeopleFaces` (NaN for none), not a
  dictionary keyed by `FaceID`. A photo is held once per run of its faces, which every read
  gives together, so the lookup that found a photo already held is gone.
- **The kernel:** a run of chaining reads its rows and its evidence through their positions
  in the faces, never copies of them, and the evidence is grouped by person as positions. A
  column's maximum into the rows is the same in any order of the run's columns, so this is not
  `PersonRun`'s order. Lapsed seeds are found by position. The faces are copied only when a
  seed lapsed, and the face-to-index dictionary is built once, only when grouping finds a
  person.
- **Identical results:** `KernelDifferentialTests`, `FaceAssignmentPolicyTests` and the People
  suites, unmodified except where they read the snapshot's likeness dictionary.

The live session's sequence, same probe, same catalog (footprint, MB):

| Step | Heap vectors | File | File and positions |
| --- | --- | --- | --- |
| Launch pass | 44 → 165 | 44 → 172 | 44 → **109** |
| First pass that assigns | 166 → 341 | 172 → 251 | 109 → **157** (+48) |
| Five keyed passes | 341 → 358 | 251 → 287 | 157 → **161** (+4) |
| Whole pass | 358 → 302 | 288 → 194 | 161 → 176 |
| Held snapshot, live | 44 | 44 | **31** |
| A pass's live peak above what it keeps | 81 | 86 | 72 |

The on-demand owner-scale test, in one process after the earlier parts: five keyed passes
249 → 251 MB.

## Why the passes ran in a second session (#874 installed, 942d82d1)

The owner's tour after #874 peaked at 812 MB. Its log, read-only:

- **People passes:** five in the first 23 s, not six. `peopleBuilt` is written by each gallery
  read, and there were more gallery reads than passes.
  - 14:46:42: the launch pass, a whole read, with the hash equal.
  - 14:46:44: a whole read after the first changes.
  - 14:46:46, 14:46:53 and 14:46:59: three keyed passes, four photos each.
    - The first read every vector (1.26 s) and assigned.
    - The second assigned again, because Immich enrichment had changed the capture dates of
      faced photos meanwhile (`facts=...faceTiles`, a capture time being an input). It wrote 9
      rows: 4 guesses, 4 lapsed seeds and 1 person forgotten.
    - Forgetting a person moves an input, so the third assigned once more and wrote nothing,
      as designed.
  - Every pass was owed by a change it reads. Changes that arrived during a pass cost one pass
    after it.
- **Footprint at each pass's end:** 491, 615, 711, 725 and 756 MB. These numbers include the
  tour's grid, loupe and search steps, which ran at the same moments (`tourStep` samples up to
  730 MB before the first assignment).
- **Idle:** no People pass ran after 14:47:04. The peak of 812 MB came in idle, and no sample
  logged near it says what reached it. The owners active then were enrichment (180 content
  hashes, materialisation) and photo descriptions (114 written). People's part is unknown.
