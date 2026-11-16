# The search index's vectors in a mapped file

Date: 2026-11-16. Context: plan 0116 bet 2. With search the only background owner, a tour on
the owner's library peaked at 973 MB, against 336 MB with no owner at all. The search index
finished loading at 16.5 s; its matrix alone was 482 MB. The whole app's target is 700 MB.
The due-diligence note (P4) had measured a throwaway mapped Float16 file. This note records
the measurements behind the design ADR 0048 now describes ("The index: one owner, one mapped
file").

Method:
- The owner's catalog was opened read-only (`mode=ro`). Embedding blobs were read into memory
  by a scratch program; nothing was written or copied.
- Timings were taken in scratch programs, at `-Onone` as the installed app is built.
- No benchmark was run.

## 1. Where a tour's search time went

From the installed app's own lines (f192041a, the full tour):

| Step | Total | Encode | Waiting | Order re-read | `search.match` |
| --- | --- | --- | --- | --- | --- |
| Many results | 6,195 ms | 4,104 ms (recognised as another language, translated) | – | 1,211 ms | 624 ms |
| Few results | 17,705 ms | 64 ms | 14,049 ms on the window's `filterOptions` read | 2,960 ms (stacks 1,675) | 455 ms |

- **The order re-read:** the projection holds a scope's order by a descriptor that includes
  the search, which the order SQL never reads. Bet 4 owns that fix.
- **The `filterOptions` wait:** a window read, also bet 4's.
- **The encoding:** search's own; a separate change.
- **The match:** this change. In it:

| Part of one match, 165,000 photos, `-Onone` | ms |
| --- | --- |
| `Set(scope)` | 83 |
| The scope's rows looked up by asset | 99 |
| Text matching, one word list over 10,023 readings | 45 (run twice) |
| Float32 matrix product | about 25 |

## 2. Float16 against Float32 on the owner's embeddings

165,653 embeddings, scored against Float32 with the shipped cut (best − 0.04, floor 0.08).
Text queries also go through the label gate: the labels they name and the exact stored
confidences.

| | Text queries (1,303 label names) | Image queries (500 random photos) |
| --- | --- | --- |
| Max / mean absolute cosine error | 5.1e-5 / 7.3e-6 | 2.7e-4 / 4.9e-5 |
| Top-10 overlap | 99.88% | 99.72% |
| Memberships shown with Float32 | 352,147 | 1,987 |
| Memberships that move, gate applied | 294 (0.08%), in 113 queries | 8, in 8 queries |
| Memberships that move, cut alone | 537 | 8 |

Every move is a photo within the error above of a cut, at best − 0.04 or best − 0.02. The
cut was calibrated in steps of 0.01 (`2026-11-09-keyword-search.md` §8). The label
confidences are kept exact, so the classifier half of the gate never moves.

## 3. The kernel

The vectors are widened from Float16 to Float32 a chunk at a time, then multiplied by the
query. 165,648 slots, pages resident:

| Kernel | `-Onone` | `-O` |
| --- | --- | --- |
| `vImageConvert_Planar16FtoPlanarF` in chunks of 1,024 slots, then `sgemv` | 13.5 ms | 14.9 ms |
| The same, chunks of 4,096 | 19.4 ms | 19.9 ms |
| Swift `SIMD16<Float16>` loop under `@_optimize(speed)` | 6,279 ms | 65 ms |

The Swift loop is not usable in a Debug build. The shipped kernel uses `vDSP_mmul`, which the
old matrix used, in place of `sgemv`. Evicted pages are read back at the disk's rate: about
254 MB, some 85 ms at 3 GB/s. That figure is estimated, not measured.

## 4. What stays where

- **The vectors stay in `search_embedding`** at full precision. The file is rebuilt from them,
  so a lost file costs about a minute of paged reads, not hours of re-embedding.
- **Cross-file commits are not atomic** (P3: 60 of 150 crashes left two files out of step).
  So the catalog is the one commit point: it stores the file's name and its committed slot
  count (v70). A file short of the count is rebuilt.
- **Disk:** the 650 MB the vectors take in the catalog would leave the disk only with a
  `VACUUM`, which bet 8 holds for the owner. The file adds about 254 MB of vectors and about
  25 MB of keys.

## 5. On a generated owner-size catalog

`SearchIndexLoadMemoryTests` at owner size, Debug test host, 164,699 embeddings:

| | Value |
| --- | --- |
| Building the file from the catalog (first launch, a new model) | 10.6 to 19.0 s |
| A later launch: map the file and parse its keys | 273 ms |
| Footprint that load adds | 16 MB |
| Mapped vectors / keys | 241 MB / 28 MB |

The first parse took 1.9 s. Most of it was a check of each label's number, 3 million of them;
a number is now checked where it is read. Asset fingerprints were also read through a generic
iterator, 2.4 µs a 55-byte path; they now hash each string's contiguous UTF-8 and continue from
the root's own fingerprint (`PathFingerprint`). The v70 migration took 2 ms and wrote 41,232
WAL bytes (`CatalogMigrationCostTests`).

## 6. A query's first reading (the encode's 4.1 s)

The tour's many-results query, an English word, was recognised as Italian and translated:
`search.encode ms=4104 reading=translated`, Translation cold. Measured on the bake-off's judged
queries, 52 queries in 17 languages, against the app's image embeddings. The tools and
judgments are in the bake-off folder, outside the repository; the scorer is its
`score_appquery.py`.

| Reading | English | Other 16 languages, mean |
| --- | --- | --- |
| As typed, SigLIP 2's multilingual tower | 85 | 65.4 |
| The app's reading (recognise, translate when installed) | 83 | 75.0 |
| The same, with Latin text English spelling accepts read as English | 85 | 74.9 |

- 13 of the 52 English queries were recognised as another language. Their top 10 matched the
  as-typed one at 92%.
- For a translated non-English query, the as-typed and translated top 10 share 39% (Finnish
  26%, Japanese 24%, French 55%).
- The spelling gate moved Dutch from 77 to 73 ("kind met rode hoed", "See"); Swedish, Polish
  and Turkish rose 1 to 2 points.

The design that follows (ADR 0048):
- Spelling gate: an English-spelled query is read as English, at once.
- Any other query that waits on Translation or Maps shows its as-typed reading first, still
  searching, and the full reading replaces it.

## 7. Not measured here

- The footprint and load time on the owner's library: the next tour.
- Query time with the pages evicted.
- Power loss.
