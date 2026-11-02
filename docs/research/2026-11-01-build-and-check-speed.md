# Build and check speed (2026-11-01)

Why `script/check.sh` took ~7 minutes, what each part costs, and what cut it. The
decision is ADR 0044; this file holds the evidence and the sources.

Machine: Apple M1 Pro, 8 cores, Xcode 27.2 (27B52), macOS 27. Every number below was
taken while other agents' builds, an iOS simulator and a VM ran on the same machine
(load average 40–200). Wall times therefore move 2–3× between runs of the same thing;
each comparison below pairs runs taken close together, and reports CPU where it helps.

## What a check spent its time on (before)

| Step | Where it ran | Measured |
| --- | --- | --- |
| `swiftformat --lint`, `time-guard.sh` | fast gates, serial | ~5 s each |
| `requirements-authority-check.sh` | serial, **before** the build | **109 s** |
| `guard-design-system.sh` | parallel with the build | **138 s** |
| other guards, doc citations | parallel with the build | < 1 s each |
| `build-for-testing`, empty DerivedData | serial | 137 s (load ~50) – 388 s (load 100–200) |
| `test-without-building`, 1,358 tests | serial | ~60 s |

The two slow gates were process-spawn bound, not work bound. The authority check
started `python3` once for each of the 844 cited tests and forked `awk`/`grep` several
times per requirement row: about four thousand processes, 14.7 s of it system time.
The design-system guard ran two `printf | grep` pipelines for every line of every view
file.

### The clean build

`-showBuildTimingSummary` for an empty DerivedData (388 s wall at load ~100–200):

| Task | Task-seconds |
| --- | --- |
| SwiftCompile (34 batch tasks) | 1,930 |
| SwiftEmitModule (5) | 152 |
| SwiftDriver (5) | 24 |
| CompileAssetCatalogVariant (2) | 14 |
| Ld (7) | 9 |
| everything else | < 10 |

Swift compilation is the whole cost, split by file count across GRDB (168 files),
OtosKit (197), OtosTests (183), MediaMetadata (16) and the app (2 plus its views).
Package resolution reported `(cached)` fetches and costs seconds. Linking, signing,
`OtosXXH3` (three C files) and asset catalogs are noise. The project has no run-script
phases, so nothing reruns for lack of declared inputs and outputs.

`-warn-long-function-bodies=200` / `-warn-long-expression-type-checking=200` found one
real hotspot: `ContentView.body` takes 5.2 s to type-check (`Otos/ContentView.swift:109`).
Everything else is under 0.4 s. It costs 5 s only when `ContentView.swift` itself
recompiles, and the app target compiles alongside the test target, so it is not on a
check's critical path.

Build settings, as `-showBuildSettings` reports them for `build-for-testing`:

- Debug is already incremental (`SWIFT_COMPILATION_MODE` unset), `-Onone`,
  `DEBUG_INFORMATION_FORMAT = dwarf`, `ONLY_ACTIVE_ARCH = YES`,
  `SWIFT_ENABLE_EXPLICIT_MODULES = YES` (the Xcode 26+ default).
- `ENABLE_CODE_COVERAGE = YES` and `CLANG_COVERAGE_MAPPING = YES`: Xcode 27 turns coverage
  on for Debug test builds by default (`script/install.sh` already turned it off for the
  installed app for the same reason). Every compile job carried `-profile-generate
  -profile-coverage-mapping`. Nothing in the repo reads coverage.
- `COMPILER_INDEX_STORE_ENABLE = Default`: every compile job also wrote an index store
  (`-index-store-path`), which only an IDE reads.
- `ENABLE_TESTABILITY = YES`, and all 178 test files `@testable import OtosKit`.

### Incremental builds are incremental

In a worktree that had already built, with the same settings:

| Edit | Files recompiled | Wall |
| --- | --- | --- |
| none | 0 | 17 s |
| one function body in `CatalogStore.swift` | 1 (OtosKit) | 64 s (load ~200) |
| a method added to a nested type | 1 (OtosKit) | 26 s |
| a member added to `CatalogPath` (used by 45 test files) | 21 OtosKit + 54 OtosTests | 105 s |

Swift's per-declaration dependency tracking holds even through `@testable import`: an
internal change recompiles only the files that use what changed. So the ~4.5 minutes
seen "even for a small edit" was not a broken incremental build. It was a fresh
worktree's empty DerivedData (every increment starts in one) and machine load.

## Starting a worktree warm

Three ways to give a fresh worktree a warm start were measured.

**APFS clone of a built DerivedData** (`cp -cR`, 2.6 s): the next build in the new
worktree recompiled every file (107 s, no faster than clean). DerivedData records
absolute source paths and file modification times, and a new checkout differs in both.
Rejected.

**Compilation caching** (`COMPILATION_CACHE_ENABLE_CACHING`, Xcode 26+): each compile
job's output is stored in a content-addressed store (CAS) under a key computed from its
inputs, and replayed on a later build with the same key. The CAS defaults to
`CompilationCache.noindex` inside the build's DerivedData; `COMPILATION_CACHE_CAS_PATH`
moves it so worktrees can share one.

| Configuration | Fresh worktree B after A populated the CAS | Hits / misses |
| --- | --- | --- |
| shared CAS, Xcode's project prefix mapping | 73 s | 202 / 36 |
| shared CAS, project mapping + worktree root mapped | **38 s** | **220 / 0** |

Without prefix mapping every key contains the worktree's absolute path, so another
worktree can never hit. Xcode's `SWIFT_/CLANG_ENABLE_PROJECT_PREFIX_MAPPING` maps each
project's own directory to `/^src` and DerivedData's intermediates and products to
`/^derived` and `/^built`. That covered Otos's targets, but the 36 misses were all in
GRDB and MediaMetadata: a package target's project directory is its checkout under
`build/DerivedData/SourcePackages`, while the compiler's working directory is the Otos
project, which no package-level mapping covers. Adding the worktree root itself
(`SWIFT_OTHER_PREFIX_MAPPINGS` / `CLANG_OTHER_PREFIX_MAPPINGS` `<root>=/^worktree`) made
every job hit.

### What prefix mapping costs

With mapping on, the driver no longer narrows an edit to the files it affects:

| Edit, mapping on | Recompiled | Wall | CPU (user) |
| --- | --- | --- | --- |
| one function body in OtosKit | all OtosKit batches | 58 s | 72 s |
| a member added to `CatalogPath` | 11 OtosKit + 183 OtosTests | 114 s | 178 s |
| (caching **without** mapping) one function body | 1 file | 18 s | 13 s |

This is swift-driver#2236 (open, no fix, reproduced on Xcode 27.0): with caching and
prefix mapping the driver cannot read the bare `.swiftmodule` path and falls back to
recompiling the module. Caching alone keeps incrementality, so the mapping is the
cause. Wall time for an edit stayed close to the unmapped build because a module's
batches compile in parallel; the extra cost is CPU.

The trade is one module rebuild per edit (tens of seconds) against a whole clean build
per worktree (two to six minutes). Every increment starts in a fresh worktree, so the
mapping pays for itself on the first build.

Mapping also changes what `#filePath` expands to: `/^worktree/OtosTests/…`, a path that
does not exist. Nine test files located fixtures or output directories through
`#filePath`, and 19 tests failed on the first mapped run. They now take the checkout
root from `OTOS_SOURCE_ROOT`, which the scheme sets to `$(SRCROOT)`.

### Concurrency and size

The CAS is the same on-disk store Xcode uses for every project built with caching in
the default DerivedData, so concurrent builds sharing it is its normal mode. Xcode 27.2
prunes it (`COMPILATION_CACHE_LIMIT_SIZE` / `COMPILATION_CACHE_LIMIT_PERCENT` and a
`CompilationCachingDiskSizeLimit` default in SWBCore). One full Otos build adds about
0.5–1 GB.

## Test selection

`xcodebuild test-without-building -only-testing:OtosTests/<Suite>` narrows a run to
named suites; it filters Swift Testing suites at the two-component level. A scoped run
of the nine suites touched here ran 49 tests.

## Before and after

`script/check.sh`, whole run, in two fresh worktrees at different paths. B is `main`
before this change; C is this change. Pairs ran back to back at load 35–180. Every run
passed 1,354 tests.

| Run | Before (B) | After (C) |
| --- | --- | --- |
| Fresh worktree, first check | 254 s | 127 s |
| Re-check after a one-line function-body edit in `CatalogStore.swift` | 188 s | 128 s |

C's first fresh run took 131 s with the store only partly filled (219 task-seconds of
Swift compilation still ran); the 127 s run is with the store holding this tree. In the
after runs the build takes under a minute and the suite 33–72 s, so the suite is now
about half of a check. The edit re-check gains less than the fresh run: the 109 s
authority check left the critical path, and the edit now rebuilds all of OtosKit
(75 task-seconds) instead of one file.

A scoped run (`--only`, nine suites, 49 tests, after an edit that rebuilt the whole
test target) took 125 s, almost all of it the test-target rebuild.

## Sources

- Apple, *Improving the speed of incremental builds* —
  https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds
  (measure with `-showBuildTimingSummary`; declare run-script inputs/outputs; declare real
  target dependencies; split large test targets). Fetched 2026-11-01.
- Apple, *Building your project with explicit module dependencies* —
  https://developer.apple.com/documentation/xcode/building-your-project-with-explicit-module-dependencies
  (scan, build modules, compile sources; uniform options avoid module variants).
  Fetched 2026-11-01.
- Apple, *Xcode 26 release notes* —
  https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes
  (compilation caching introduced as opt-in, largest gains on branch switches and clean
  builds; explicit modules the default for Swift). Xcode 27 and 27.2 release notes say
  nothing on caching, mapping or coverage defaults. Fetched 2026-11-01.
- swift-driver#2236, *With compilation caching and prefix mapping, an interface edit
  recompiles every consumer* — https://github.com/swiftlang/swift-driver/issues/2236
  (opened 2026-10-20, open).
- swift#92545, cached-diagnostics replay crash with mixed prefix-mapped and unmapped
  inputs — https://github.com/swiftlang/swift/issues/92545 (closed 2026-10-01). Mapping
  the whole worktree root leaves no unmapped project input.
- cmux#13037, a new DerivedData path missed the cache through one non-explicit-module
  package — https://github.com/manaflow-ai/cmux/issues/13037 (2026-09-19; 108.7 s warm vs
  ~600 s cold, verified with `COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS`).
- laching PR #159, shared and path-mapped cache across build folders —
  https://github.com/vmihalachi/laching/pull/159 (2026-10-18; 39 s → 8 s).
- Tuist, *Xcode cache* — https://tuist.dev/en/docs/guides/features/cache/xcode-cache
  (the CAS defaults to inside DerivedData; prefix-mapping settings change every key).
- Bitrise step notes and MacStadium, *Xcode tuning*, on `COMPILER_INDEX_STORE_ENABLE=NO`
  for non-IDE builds — https://docs.macstadium.com/docs/xcode-tuning.
- Xcode 27.2's own `Swift.xcspec` / `CoreBuildSystem.xcspec` for the setting names, their
  conditions and the `-scanner-prefix-map` arguments they produce.
