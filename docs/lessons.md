# Lessons

Rules learned the hard way that are not obvious from the code, and problems still open. When an
open problem is solved, or a rule moves into a test, an ADR or CLAUDE.md, its entry is deleted
here.

## Rules learned

- A long check is watched, never awaited: a verify run once hung for 9 h 40 m and nothing
  reported it. `script/check.sh` prints a heartbeat and detects a stalled test host itself
  (`long-checks` skill).
- Green checks do not prove what a user sees: on 2026-11-19 every check passed while half of
  All Media's tiles were blank. Every full-tier CI run captures each view, and the final report
  says what each capture showed (`dod` skill).
- A test that passes alone can fail under load. Two such failures were reproduced only by
  running a test 150 times in parallel inside the full suite
  (`docs/research/2026-11-15-two-load-only-test-failures.md`); "flake" is never a root cause.
- Reading CI right after a push or a description edit can read the previous, green `CI gate`
  while the new run is still queued: wait until no run on the head commit is unfinished first
  (`script/stage pre-merge`).
- A cloud session's proxy refuses GraphQL, tag pushes and branch deletion: use REST (`gh api`)
  and leave branch deletion to GitHub's delete-on-merge and the Branch cleanup workflow.

## Open problems

- Suites that have failed only sometimes, repeated every week by the Repeat A Suite workflow:
  `StallReproductionTests`, `RemovableVolumeMonitorLiveDiskImageTests`,
  `MediaOperationCoordinatorTests`, `CatalogProjectionShownFirstTests`. A suite leaves the list
  once its cause is fixed and a weekly repeat has passed since.
- The rest of the blank-slate architecture review (the fix-table recount, Duplicates waiting
  behind People, an HEVC frame-seek failure seen only on real files) is tracked in
  [issue #51](https://github.com/tonimelisma/Otos/issues/51).
