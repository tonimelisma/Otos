# People's memory and assignment kernel (2026-11-16)

Plan 0116 bet 1. What People holds and computes on the owner's library, and the two facts the
kernel's redesign rests on. Read-only on the owner's catalog (102,978 faces, 751 people with a
face; schema v66), opened with `?mode=ro`; a throwaway program read the vectors and was not
kept. Nothing was written to or copied from his catalog.

## Where the time and memory went (installed 661be172, 4-minute tour)

- Every People pass read every face with its 2 KB vector (`readMs` 18–65 s, contended) and ran
  the whole kernel (`assignMs` 22–27 s, Debug build); all three passes ended `guesses=0 rows=0`.
  The gallery was published only by such a pass, so the first People paint waited 48.8 s
  (48.6 s on a quiet machine with every other owner off).
- With only People running, peak footprint 2,263 MB against 336 MB with every owner off.
- Time Profiler, the session: `PersonRun` 20.4 s (`firstIndex` 9.3 s self — two binary searches
  per open face and person every round), `BlockedSimilarity` 15.2 s, BLAS 16.5 s,
  `Array.init(repeating:count:)` 5.7 s self (a fresh `rows × columns` product per 512-row block
  and a `rows × people` best table, 103k × 752 × 4 B ≈ 310 MB, per run of chaining).

## How many people a face is ever close to

For 1,515 faces sampled evenly, the best similarity to each person's faces within reach (two
years, as the policy compares a child's): on average 5.7 people reach 0.264 or more, and none
of the sample reached 20. A decision reads a best only when it reaches the threshold (0.434),
and a runner-up only when it is within the margin (0.16) of one that does, so a best under
0.264 decides nothing. A face therefore needs a list of about six people, not a value for all
752: the table shrinks about 125-fold.

## Half precision

The same vectors rounded to Float16 and compared again, for 3,029 faces sampled evenly
(2,737 of them with a best person at the threshold):

| | Changed |
| --- | --- |
| Best person | 0 |
| Best at or above the threshold | 0 |
| Best minus runner-up at or above the margin | 0 |
| Largest similarity error | 9.6e-5 |
| Pairs crossing the 0.65 grouping link | 555 of about 312 million (1.8e-6) |

Half precision halves the resident vectors (211 MB to 105 MB for 103k faces). Recognisability
is decided from the stored single-precision values before rounding, so it cannot change.

## Conclusions

- The gallery is published from a vector-free read; assignment runs only when its inputs
  moved (ADR 0047, Work and placement).
- The kernel keeps per face only bests of 0.264 or more, visits evidence a block of faces and
  a chunk of evidence at a time (one vectorised maximum per evidence face and block, never one
  per face and person), and reuses its buffers.
- Vectors are held at half precision.
