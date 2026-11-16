# Plan 0116 due diligence: what five experiments found

Date: 2026-11-16. Context: plan 0116's first version proposed a work ledger (A), derived data
in separate files (B) and search vectors as a mapped file (C) to fix 3 to 15 s sidebar clicks.
The owner asked for its soft spots, a full review and experiments before accepting it. This
note records what was measured. The plan document carries the design that survived.

Method common to all: no benchmarks; the owner's catalog (2.56 GB, 166,990 assets) was opened
read-only for schema, counts, plans and timings, never written or copied; destructive and
write measurements used generated catalogs of the owner's shape; "cold" means the file's
pages were dropped with `msync(MS_INVALIDATE)` and checked with `mincore`. Throwaway scripts
were not kept.

## 1. The stall reproduces (P0)

`OtosTests/StallReproductionTests.swift` and `OwnerShapedCatalog.swift`, merged in #798; full
tables in `2026-11-16-stall-reproduction-baseline.md`. On a generated 2.27 GB catalog with a
realistic backlog and every background owner running, window reads waited 1.0 to 1.5 s for a
main-pool connection with `lockMs`, `storeMs` and `snapshotMs` near 0, behind the holders the
owner's log named. Rows visited per pass to return 0 to 24 items: descriptions 984,811,
embeddings 329,489, text 309,181, render signatures 164,766, mirror probe 294,129; metadata
refresh, which keeps a cursor, 408. Of 21 Store changes in 14.6 s, 12 were enrichment
recording what it could not read and 9 were the render refresher waking itself.

## 2. Independent critique (P5), with what was re-run

Read-only on the owner's catalog, Otos not running.

| Read | As written | Changed | Owed now |
| --- | --- | --- | --- |
| `mirrorProbes`, library 6 | 57.96 s (re-run here: over 75 s, stopped) | 0.011 s with `CROSS JOIN` (re-run here: 0.16 s) | 0 mirrors |
| `photoDescriptionCandidates` LIMIT 16 | 17.0 s; sorts the whole set | 0.085 s walking the existing capture-order index | 53,077 |
| `renderSignatureCandidates` | 5.6 s cold, 0.37 s warm | partial index | 0 |
| search embedding owed | 5.3 s cold | | 960, all on card and camera roots |
| every current vector | 0.92 s warm SQL; 32.8 s in the app | | |

Findings beyond the plan's own soft spots:

- The holders are the owners that did not follow the house pattern. Enrichment claims and
  preview faces already use partial indexes and keyset cursors and never appear as holders.
- A loop between owners: `drainTexts` runs a whole-library `searchEmbeddingCandidates(limit:
  1)` after every page of 8 text readings (85,795 owed) and each page rings the description
  owner, which runs the 17 s query.
- GRDB's reader pool is first-in first-out, so a window read waits behind every queued
  background read, not only the four running. GRDB's reader queues run at user-initiated QoS
  whatever the caller's task priority.
- `boundWAL`'s truncating checkpoint takes GRDB's barrier, which waits for every read in
  flight and holds new ones, the window's included. It did not fire in the logged minute.
- The window's own load: an All Media click costs about 5 s with zero wait (`execMs` 4,241 of
  which stacks 2,455, collapse 498 ms, equality 190 ms), and the cadence re-read the order
  three times in a minute while enrichment changed capture dates.
- Memory: the index's first load holds a full array and then the matrix (about 1 GB at peak);
  `peopleSnapshot` fetches 102,979 faces with embeddings (211 MB) on `.images` and
  `.captureDate`, which fire on almost every enrichment flush. Free memory at the time was
  about 75 MB, with 36 M pageouts. Inference, not measured: pressure evicts the catalog's
  pages, so every scan reads cold.
- `ANALYZE` should not be run: the code pins plans with `INDEXED BY` and `CROSS JOIN` on
  purpose.

## 3. Can a ledger be kept correct, and which shape (P2)

Generated catalog, 2.49 GB, the owner's real DDL including the copy triggers; 1,629
embeddings and 51,119 descriptions owed.

| Shape | Next 16, little owed | Count owed | Write overhead | A revision bump | To maintain |
| --- | --- | --- | --- | --- | --- |
| Today | 11 to 17 s cold, 437k to 645k pages | the same scan | none | free | none |
| L0: covering and partial indexes, per-root keyset cursor | 8 ms to 0.18 s cold, 25 to 546 pages | 1.0 to 1.3 s cold, 20k to 26k pages | enrichment flush 34 to 43 ms | free | about 9 indexes, about 170 MB; 13 s to build |
| L1: trigger-maintained ledger | 8 to 12 ms | 12 to 64 ms | enrichment flush 34 to 157 ms; person rename 0 to 835 ms; language switch 0.6 ms to 4.7 s | a migration: 28 triggers rewritten, 4.0 s rebuild | 28 triggers, 280 KB of SQL |
| L2: stamp in the asset row | 7 ms | 0.45 s cold | +12 %; 575 MB WAL to backfill | index rebuild 3.6 s | a stamp in two tables |
| L3: in-memory list fed by notifications | as L0 after one walk | memory only | a second code path | free | notifications must carry ids |
| L4: re-walk only when inputs moved | no gain: inputs move on every flush while a backlog drains | | | | |

- L1 held: no drift in 8,000 random operations drawn from the app's real writes; dropping any
  one of 17 triggers made the random run drift and directed cases proved 7 more; 4 were not
  proven load-bearing.
- Inherent to a ledger: revision constants live in code; root availability and locality are
  not in SQL; the trigger column lists are a second copy of each predicate's inputs.
- Most of the 20 s is the drain re-running the candidate scan for every page: with 51k
  descriptions owed, about 3,200 full scans a drain. A keyset cursor alone removes that.
- Two traps: a cursor over `root IN (…) AND (root, path) > (?, ?)` seeks only on the root; and
  with `ANALYZE` and the new indexes present the unhinted SQL still read the wide table.

## 4. Where a storage split could be drawn, and what it costs (P3)

- Window queries join the tables B would move: person scopes, the People filter and the
  likeness sort (`face`), Places (`asset_metadata`), On This Day's exclusion
  (`search_embedding.confident_labels`). Face assignment, `content_sha1` and `asset_metadata`
  must stay in the catalog in any design.
- `ATTACH`: one transaction across two WAL files is not atomic. Of 150 `kill -9` runs per
  mode, 60 left the files out of step under one `ATTACH` transaction, 61 and 88 under two
  transactions in either order. A trigger cannot name an attached table and a foreign key
  cannot cross files.
- A new file at an old path: with face rows moved, it appears in the old person's scope
  (measured). On This Day's exclusion has no stamp and wrongly excludes it today.
- The window's order read never touches table rows (6,160 pages, 0.07 s warm, 0.44 s cold),
  so row width matters only to background scans: a full asset scan goes from 146k to 56k
  pages without `render_gray`.
- Costs of one large file, measured: WAL recovery 0.02 s regardless of size; the search
  reconcile 317k pages, or 6.9k with a `(key, source)` index; `peopleSnapshot` 161k pages
  because each face row carries its embedding.
- The owner's asset table is 1.2 % sequential on disk. A synthetic table fragmented the same
  way scanned 7 times slower cold.
- An in-file split and one `VACUUM`: catalog 2.56 GB to about 1.0 GB (about 0.73 GB if
  `sort_key` and its two indexes are dropped; no SQL was found that reads them). Measured
  steps on the generated file: drop column 2.5 s, `VACUUM` in place 13 to 17 s with a peak of
  twice the final size in temporary disk. Estimated 45 to 60 s on the owner's fragmented
  file, not measured on it.

## 5. Mapped search vectors (P4)

On the owner's 165,652 real vectors (unit-norm; the score is a dot product).

| | Text queries (1,303 label names) | Image queries (500) |
| --- | --- | --- |
| Float16: max / mean absolute error | 5.1e-5 / 7.3e-6 | 2.5e-4 / 4.9e-5 |
| Float16: top-10 overlap | 99.87 % | 99.78 % |
| Float16: cutoff membership flips | 0.096 % of rows shown | 20 of 6,580 |
| int8: cutoff membership flips | 9.9 % | 367 of 6,580 |

| Option | Launch to searchable | ms a query | Footprint | Disk |
| --- | --- | --- | --- | --- |
| Today | 15.3 s cold, 3.3 s warm, 33 s contended | 18 | 491 MB | 649 MB in the catalog |
| Paged load, same table | 7.7 s cold, 2.7 s warm, in 83 short transactions | 18 | 491 MB | 649 MB |
| Separate SQLite store, Float16 | about 2 s cold | 15 | 245 MB | about 340 MB |
| Mapped Float16 with `MADV_WILLNEED` | 0.2 s | 14 to 16 | 6 MB (253 MB clean, reclaimable) | 254 MB |

- An append-only format (never rewrite a referenced slot; compaction writes a new generation)
  survived 2,000 fuzz rounds with `kill -9` at random points with 0 bad rows. Committing the
  map before the bytes gave 5,629 bad rows in 200 rounds, so the check detects a violation.
- Label parsing costs about 2 s of any load. The reconcile pass reads the whole table every
  wake: 0.78 s warm, 12.1 s cold.
- Not tested: real translated multi-word queries, judged recall, power loss.

## 6. Outside sources

- SQLite WAL: readers and writers do not block each other; a long read holds back checkpoints
  and the WAL grows; each file has its own WAL; a commit across attached WAL files is atomic
  per file only (sqlite.org/wal.html, isolation.html, lang_attach.html).
- GRDB: "Open one single DatabaseQueue or DatabasePool per database file"; QoS is per pool;
  `maximumReaderCount` defaults to 5 (Concurrency.md, Configuration.swift).
- digiKam keeps core, thumbnails, similarity and faces databases; Lightroom Classic, Capture
  One and darktable keep previews and caches beside the catalog; Apple Photos keeps
  `Photos.sqlite`, `psi.sqlite` and `mediaanalysis.db` and analyses in daemons (documentation
  and reverse-engineering write-ups; Apple publishes no reason).
- Immich finds work with per-asset status (`asset_job_status`, `NOT EXISTS smart_search`),
  streamed (`server/src/repositories/asset-job.repository.ts`).
- Apple QoS guidance: user-initiated work is "a few seconds or less"; background is "such as
  indexing"; inversions should be designed out (Energy Efficiency Guide, WWDC17 706, WWDC21
  10254).

## 7. Conclusion

The first version of plan 0116 named the right holders and the wrong reason they are slow.
The measured cause is unindexed, uncursored reads re-run per page and per wake, started
together at user QoS, with the window's reads in the same queue. Fixing those in place
removes the stall with no new state and no storage change. A ledger is the wrong trade at
this size; separate files add hazards and no measured benefit; mapped vectors work and are a
memory decision for later.
