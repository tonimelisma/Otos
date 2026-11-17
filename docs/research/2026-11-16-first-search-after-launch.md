# The first search seconds after launch (2026-11-16)

## Question

On the owner's library (installed 5f77e2e5, a read-only ten-minute tour) the first search
took 1,606 ms against a 1 s target; the two tours before it took 476 ms and 636 ms. The tour
searched about 6 s after launch. Later searches took 177 ms and 159 ms. What did the 1.6 s go
to?

## Evidence: the installed app's own lines (one session, read-only)

Times are seconds after the first grid (`op=launch.firstGrid`, 1,123 ms after launch).

| +s | Line | Meaning |
| --- | --- | --- |
| 0.00 | `load.admission granted load=people` | the first People pass runs 1,357 ms |
| 0.53 | `search.index phase=loaded from=file ms=184` | the index is ready from its mapped file |
| 1.36 → 3.03 | duplicates, derivedFolder, immichMirror, people (again), duplicates (again) | each granted before readying search, which runs last |
| 3.03 | `load.admission granted load=searchPrepare waitMs=2691` | the readying is admitted |
| 3.24 | `load.admission released load=searchPrepare ms=204` | the admitted body ends; it only rang the reader, so the encoder loads outside the turn |
| 3.50 | `load.admission granted load=people request=9` | a People pass runs 8.9 s beside the encoder's load |
| 3.96 | `search.encoder phase=loaded ms=902` | tokenizer and model |
| 5.10 | the tour's search is typed (its step ends at +6.71 with `ms=1606`) | |
| 6.41 | `search.encoder phase=prepared ms=3373` | the first prediction took 2,449 ms |
| 6.50 | `search.encode first=true ms=91` | the query's reading |
| 6.63 | `search.match ms=105` | |
| 6.71 | the tour's step ends | |

So of the 1,606 ms: **1,306 ms waiting for the encoder's preparation** (the query's reading
queues behind it on the encoder's actor), then 91 ms encoding, 105 ms matching and about 100
ms publishing and painting. The preparation itself had started 2.7 s late, behind six
background loads, and its load ran outside its admitted turn, beside a People pass; its
first prediction took 2,449 ms where it takes about 40 ms alone (below). In the sessions of
the day that searched later, loaded-to-prepared took 38 to 63 ms.

## Evidence: the encoder's load, alone

A scratch program (no Otos code but a copy of the tokenizer) loaded the installed app's
bundled resources, `-O` as the installed app is built, on the owner's Mac:

| Step | First run | Second run |
| --- | --- | --- |
| Tokenizer: parse `SigLIP2Tokenizer.bin` into hash tables | 361 ms, +37 MB | 398 ms, +37 MB |
| `MLModel(contentsOf:)` of the compiled text tower | 907 ms (Core ML compiles into the process's Caches) | 7 ms |
| First prediction / later ones | 41 ms / 13 ms | 38 ms / 13 ms |

The installed app's Caches hold the compiled model, so its 902 ms load is mostly the
tokenizer's parse: 256,000 heap byte arrays for the vocabulary, 580,604 concatenations
hashed for the merges.

## Changes

- **The tokenizer reads its file in place.** `SigLIP2Tokenizer.bin` now holds the tables
  sorted (format `OTBPE2`, in `SearchTextTokenizer`'s guide), and the tokenizer binary-searches
  the mapped file. Load: 395 ms and 37 MB → 0.2 ms and 0 MB. 22,682 strings (the 2,682
  reference strings and 20,000 random strings over eight scripts, emoji, tabs and
  punctuation) tokenize to the same ids as the old tables. 2,682 strings tokenize in 24 ms
  against 17 ms before (binary search instead of hashing), about 9 µs a query. The file grows
  from 7.1 MB to 13.3 MB.
- **A query's own need is a load the user waits on.** `LoadAdmission` tells a user-waited
  load (`LoadWaiter.user`) from a background one: it is granted at once, whatever runs or
  waits, and no waiting load starts while it runs. A query read while the encoder is not
  prepared, and the intent to search, load it that way (`SearchQueryReader`).
- **The first grid's readying loads inside its turn.** The admitted body awaits the encoder's
  preparation (`prepareWhileAdmitted`), so a People pass no longer runs beside it.

## Not measured here

- The tour after the change: the next tour on the owner's library.
- The first prediction's 2.4 s under load: it ran beside a People pass and the tour's photo
  steps, with about 550 MB free; which of CPU and page-ins cost it was not separated.
