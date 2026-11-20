# The test host's peak under parallel load (2026-11-19)

## Question

Two consecutive `script/check.sh` runs on a branch whose only runtime test change was a few
string-scoring cases failed with `Test-host resource ceiling exceeded`: `footprint_mb=2431` (last
test `SearchQueryReaderTests`) and `footprint_mb=2050`, against `script/test.sh`'s 2,048 MB
ceiling. The run that killed the host left 811 and 876 `OtosTests-<pid>-*` folders
(`op=test.tempLeak`), as a killed host does. `main` had passed the same suite an hour before.
Is a test leaking, or is the ceiling below the suite's own peak?

## Method

Two full runs with the guard lifted (`OTOS_TEST_HOST_FOOTPRINT_LIMIT_MB=9000`), a probe beside
each sampling every `xctest` host's `footprint` once a second, as in
`2026-11-15-test-host-footprint-and-a-parked-shutdown.md`. The second probe recorded the test
log's line count with each sample, to place the spike among the tests, and took `vmmap
--summary` and `sample` past 2,300 MB.

## Results [measured]

| Run | Peak | Shape |
| --- | --- | --- |
| Probe 1 | 2,848 MB | 1,217 MB → 2,848 MB in 21 s, held 2,650–2,850 MB for 10 s, 1,835 MB 5 s later |
| Probe 2 | 2,913 MB | 1,247 MB at log line 1,118 → 2,913 MB at line 1,424 → 1,741 MB at line 2,101 |

- **The spike is load, not one test.** Lines 1,118–2,101 of the test log are the suite's widest
  parallel stretch: store migrations, query-plan, photo-copies, search-reading, edit-analyzer
  and launch-settlement cases each taking 6–13 s at the same moment.
- **Nothing is kept.** Both runs fell back to about 1.7 GB within seconds, and both passed
  with `op=test.tempLeak phase=clean`.
- **What it is made of** (`vmmap` at 1.7 GB on the way up, probe 1): 1.3 GB of small mallocs
  and a 440 MB SQLite page cache across the tests' open catalogs.
- One sample at the host's start read 8,593 MB; `vmmap` of the same process five seconds later
  read 105.8 MB. A single misread by `footprint` at process start, not a peak.

## Conclusion

The suite has grown since 2026-11-15, when its peak was 1.4 GB, and its legitimate peak is now
about 2.9 GB. A 2,048 MB ceiling kills healthy runs at random, which is how `main` passed and a
branch with no new load failed twice. The ceiling is raised to 4,096 MB, about 40% above the
measured peak, as 2,048 MB sat 45% above 1.4 GB. It still catches a test that grows without
bound. Owner direction (ADR 0057): a footprint is a number, not a target, so the suite is not
squeezed under a ceiling set before it grew.
