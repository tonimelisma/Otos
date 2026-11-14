# People assignment at the owner's scale (2026-11-13)

Why an assignment pass took minutes once video and Immich faces were read, what each phase
cost, and what changed. All timings are from the Debug build the installed app runs (ADR
0030), on a consistent copy of the owner's catalog: 89,474 faces, 682 people (the five
largest have 14,218, 13,706, 8,377, 7,316 and 6,265 faces), 1,821 faces given by the user and
3,511 seeds.

## The symptom

The installed app's `op=people.assignment phase=wrote` lines:

| When | Faces | `assignMs` |
| --- | --- | --- |
| 2026-11-12 19:20 | 26,750 | 24,357 |
| 2026-11-12 20:36 | 35,131 | 68,581 |
| 2026-11-13 08:55 | 38,557 | 138,147 |
| 2026-11-13 14:10 | 82,241 | 263,297 |
| 2026-11-13 14:55 | 85,978 | 226,850 |

Passes ran back to back, each writing a few dozen rows and starting the next.

## Where the time went

A temporary test ran `FaceAssignmentPolicy.assign` on the catalog copy with a timer around
each phase (never merged):

| Phase | Before | After |
| --- | --- | --- |
| Whole assignment | 101 s | 16.1 s |
| `Fill.run` (one run, 11 rounds) | 98.9 s | 13.4 s |
| — raising each open face's best per person (`raise`) | 62.5 s | 12.5 s |
| — ranking each open face's top two people (`top`) | 33.7 s | 0.4 s |
| Every matrix product of the pass | 4.8 s | 4.5 s |
| Likeness | 2.0 s | 1.8 s |
| Grouping new people | 0.3 s | 0.3 s |

The phase split is from the run before the last tidying; the final code's whole assignment
measured 16.1 s.

The arithmetic was never the cost: every matrix product of the pass took under 5 seconds.
`raise` visits each open face once per person with new evidence, 75,164,402 visits a pass,
and each visit copied a `PersonRun` (two arrays, retained and released), built a `[Range]`,
and ran a generic binary search; at -Onone each of those is a checked call. `top` looped over
all 682 people for every open face every round, with a `Set` union per face.

## What changed

- `top` copies the face's row of per-person bests, lowers the people it may not have
  (rejected, already in the photo, born after it) to -2, and takes two vectorised maxima
  (`vDSP_maxvi`, which returns the first index of the maximum, the same tie-break as the
  loop).
- `raise` reads each round's run layout and capture times through pointers, and every visit
  calls one shared reach scan, `PersonRun.best(in:times:dated:count:capture:birthday:)`,
  which allocates nothing. `PersonRun.best(for:)` (likeness, the ranker) uses the same scan,
  so the reach rule (a child's faces within two years, an adult's always) has one
  implementation.

Rejected: building the face code optimised in Debug (`@_optimize(speed)` is an
underscored attribute; changing the module's optimisation level would cost the installed
app the debuggability ADR 0030 keeps), and an incremental assignment, which would add a
second path for the same result while the simple path now takes seconds.

## Same decisions

Every guess, new person and lapsed seed is identical before and after (155,234 decisions
compared). Likeness values differ in the last bits, and so do two runs of the same code: the
old and new code differed in 2 to 6 likeness values (at most 4.8e-7), and two runs of the new
code in 6. Accelerate's matrix product rounds differently from process to process.

## People never settled

Because a likeness that differed by a last bit was written, and every write starts the next
assignment, People could never settle even with no new faces. A likeness is now written
only when it appears, goes, or moves by more than 1e-5
(`FaceAssignmentPlan.likenessPrecision`), twenty times the largest wobble measured; likeness
only orders a person's photos.

## Benchmark

`people.assign.400people` (20,000 faces, 400 people, five of each given by the user): cost
grows with faces times people, which the existing 10- and 20-person cases cannot show.
