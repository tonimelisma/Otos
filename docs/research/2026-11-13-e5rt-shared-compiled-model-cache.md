# Vision's `e5rt` error 13 under parallel checks: a shared compiled-model cache

Date: 2026-11-13. Context: ADR 0048's accurate text reading, pinned to the CPU, failed
`SearchReadingTests.textInAPictureIsRead` and the benchmark's `searchCases` four times today with
`.e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)`.
Each time the test passes when run alone.

## Evidence

- **The failing process's own log.** xctest pid 33432, 19:19:31, `com.apple.e5rt`:
  `Missing E5 bundle resource required for loading ExecutionStreamOperation. Must re-compile the
  E5. Resource path = ~/Library/Caches/com.apple.dt.xctest.tool/com.apple.e5rt.e5bundlecache/26A434/0DF0EC…/A357A9….bundle/H13S.bundle/main/main_ane/model.anehash`.
  A file of a compiled bundle that the runtime expected was gone when the operation loaded.
- **One cache for every test process.** Every `xctest` process, from every worktree's check
  and every benchmark, runs as `com.apple.dt.xctest.tool`, so all of them share that directory.
- **The cache grows without bound.** It holds 26 GB in about 800 entries, 125 of them written
  in the three hours before the failure, and still after #700 gave each Core ML model one path.
  Entries repeat a few input shapes (`h320w416` 115 times, `h320w480` 114, `h480w320` 87), so
  the key varies with something other than the model's input size. The installed app's own
  cache is 3.9 GB, and the dev build's 1.8 GB.
- **The compiled bundle includes the Neural Engine half** (`main_ane`) even though Otos pins the
  request's only compute stage (`VNComputeStageMain`) to the CPU. Pinning the stage does not
  keep the runtime from loading that half.
- **The disk was nearly full all session**, with 1.9 to 15 GB free; at one point a build failed
  writing its build database. The cache-delete daemon (`deleted`, `com.apple.cache_delete`) was
  purging at 19:15, four minutes before the failure. Under disk pressure macOS purges files in
  `~/Library/Caches`.

## Conclusion

The likely mechanism: a compiled bundle in the shared cache loses a file (a purge under disk
pressure, or another process recompiling it) while a test process loads it. The log proves a
file was missing at load time; that the purge removed it is likely, not proven.

- The cache is regenerable, and deleting it is safe. It is outside the repository, so that is
  the owner's call. Freeing disk space removes the pressure that drives purges.
- The growth is an Otos-side question still open: what makes the runtime compile a new entry
  for the same model and shape. Until that is known, both caches keep growing.

## Follow-up: what a fix must not do

- **A cache per check run is the wrong fix.** `CFFIXED_USER_HOME` does move the runtime's cache:
  a probe doing the same accurate text reading wrote `<fake home>/Library/Caches/<process>/com.apple.e5rt.e5bundlecache`.
  But #700 made the cache shared on purpose: recompiling Vision's text models costs every
  check 80–220 s (ADR 0044 §11). A fresh cache per run would bring that back on every run.
- **Otos's own models already load from one path.** `BundledModel` resolves each model's link
  before Core ML sees it, and the tests that build a temporary resources folder link back to the
  real models, so the tests hand Core ML one path per model version.
- **The growth is still unexplained.** All 196 top-level keys and 231 compiled bundles are
  distinct, and the same input shapes recur across them (`h320w416` in 115 entries). Otos's
  model paths do not explain the keys. Finding what varies in them, without deleting the shared
  cache that #700 relies on, is the open question.

## Follow-up: a purged entry recovers; a purge during a load does not

Measured 2026-11-12 21:20–21:40 PST with a standalone binary doing `SearchTextReading`'s exact
request (accurate level, automatic languages, language correction, main stage on the CPU) on the
benchmark's 1,200 × 800 sign, run with `CFFIXED_USER_HOME` set to a scratch home.

| Run | Cache state before it | Result | Time |
| --- | --- | --- | --- |
| 1 | empty | read "OTOS SEARCH 2026" | 155 s (compile, under load) |
| 2 | warm | read | 0.34 s |
| 3 | `main_ane/model.anehash` deleted from `0DF0EC…/A357A9….bundle`, the file the failing xctest log named | read, recompiling that bundle | 4.2 s |
| 4 | warm again | read | 0.29 s |

- **The keys do not vary by process or path.** The scratch run wrote the same three top-level
  keys the xctest cache holds for this reading (`0DF0EC…`, `2F7922…`, `DFD288…`): the key is a
  function of the model, the input shape and the OS build (`26A434`), not of the caller.
- **A file missing before a load is repaired.** The runtime recompiles the incomplete bundle and
  the reading succeeds, so a purge between two processes costs one recompile, never an error.
  Error 13 needs a file to disappear while a process is loading that bundle. A purge, or another
  process replacing the bundle (the `.tmp.<pid>_….bundle` siblings), can do that during a load.
- **The cache was purged twice the same evening.** At 21:03 the xctest cache held 1.1 GB in 14
  keys instead of the 26 GB found at 19:19. Six keys from 18:10–18:19 were bundle folders with
  their files gone, which is a purge's signature. By 21:45 it held 1 MB. The data volume had 20
  GB free at 21:03 and 11 GB at 21:45 (98% used).
- **The app recovers on its own.** A failed reading publishes nothing, and the still is read
  again after the index's backoff (ADR 0048), when the runtime rebuilds the bundle as in run 3.

**Conclusion:** no Otos-side defect explains error 13. It is a load racing a cache purge that
disk pressure drives. This reading's keys are stable, so the growth seen at 19:19 is not it
recompiling under new keys; which callers wrote the other entries stays unmeasured. Freeing disk space is what
removes the failure, and that is the owner's to do: the space is held by data outside the
repository.
