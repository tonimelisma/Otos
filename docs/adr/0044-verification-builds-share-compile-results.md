# ADR 0044: Verification builds share compile results across worktrees, gates run in one pass, and a check can be scoped while iterating

- Status: Accepted
- Last updated: 2026-11-01

## Context

`script/check.sh` took 5.5–7 minutes, and an increment ran it several times. The owner
asked for a verification loop of a couple of minutes, measured, and allowed doing less
work per commit to get there. The measurements and sources are in
`docs/research/2026-11-01-build-and-check-speed.md`. The facts that decide this:

- Every increment starts in a fresh git worktree with an empty `build/DerivedData`, so
  its first build is a clean build: 137–388 s depending on machine load. Incremental
  builds after that already recompile only what an edit affects.
- An APFS clone of another worktree's DerivedData does not help: the next build
  recompiles everything, because DerivedData records absolute paths and modification
  times.
- Xcode 26+ compilation caching with a store shared by all worktrees, and with every
  worktree-specific path mapped to a fixed prefix, turned a fresh worktree's build into
  38 s with every compile job a cache hit.
- Two gates were process-spawn bound: the requirements authority check (109 s, serial,
  before the build) and the design-system guard (138 s, parallel with the build, so the
  critical path once the build is fast).
- Xcode 27 compiles Debug test builds with code coverage on by default, and every
  compile job also writes an index store. Nothing in a script build reads either.

## MECE Decision Scope

Owns: the build settings of the verification build (`script/build.sh`) and the
benchmark build (`script/bench.sh`); how tests find the checkout; how fast the static
gates run; the scoped `check.sh --only` mode and what counts as verification evidence.

References but does not own: the check's supervision (heartbeat, deadlock detection,
one entry point; `AGENTS.md` and ADR 0015), the benchmark design (ADR 0043), the
installed app's build (ADR 0030), test architecture (ADR 0023).

## Decision

1. **One shared compilation cache.** `otos_build_settings` in `script/lib/xcode.sh` is
   the single list of settings `build.sh` and `bench.sh` pass. They build into the same
   `build/DerivedData`, so they must pass the same settings or each rebuilds what the
   other built. The list turns on `COMPILATION_CACHE_ENABLE_CACHING` with
   `COMPILATION_CACHE_CAS_PATH` at Xcode's own default store,
   `~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex`. That store is
   content-addressed, used concurrently by Xcode's own builds, and pruned by Xcode.
   Each worktree still keeps its own DerivedData.
2. **Prefix mapping makes keys path-independent.** The Swift and Clang SDK, toolchain
   and project prefix mappings are on, and the worktree root itself maps to
   `/^worktree`. The root mapping is required: a package target's compiler working
   directory is the Otos project, which the package-level mapping does not cover, and
   without it every GRDB and MediaMetadata job missed.
3. **Tests never derive a path from `#filePath`.** Under mapping it names
   `/^worktree/…`, which does not exist. The scheme passes `OTOS_SOURCE_ROOT =
   $(SRCROOT)` and `OtosTests/SourceTree.swift` is the one reader.
4. **No coverage, no index store in script builds.** `ENABLE_CODE_COVERAGE=NO` and
   `COMPILER_INDEX_STORE_ENABLE=NO` are in the shared list; `test.sh` and `bench.sh` pass
   `-enableCodeCoverage NO` to the test run.
5. **Gates run in one pass.** The requirements authority check is one Python pass that
   reads each cited file once. The design-system domain-noun scan greps each file for
   lines holding both a string literal and a domain noun, and only those reach the
   per-line comment and allowlist tests. Rules and messages are unchanged and each
   gate's self-test still passes.
6. **`check.sh --only <Suite>` is iteration feedback, not evidence.** It runs every gate
   and the full build, then only the named suites (`-only-testing:OtosTests/<Suite>`),
   and says on its first and last lines that it is not evidence. Verification evidence
   is still a no-argument `check.sh` on the final tree.

## Alternatives Considered

### Clone a warm DerivedData into each new worktree

Rejected on measurement: the build recompiled every file (107 s against 137 s clean).

### Share one DerivedData between worktrees

Rejected: parallel runs against one DerivedData caused the suite deadlocks
`AGENTS.md` describes, and their builds would invalidate each other.

### Compilation caching without prefix mapping

Keeps per-file incremental builds (a body edit recompiled one file in 18 s), but every
key contains the worktree's absolute path, so no worktree ever hits another's results.
It helps only a worktree rebuilding its own earlier state, which incremental builds
already cover.

### Select tests by what an edit touched

The full suite runs in about a minute, the 19 s slowest tests set its floor, and
deriving test impact from source edits is a dependency analysis Otos would have to own
and keep right. Explicit `--only` gives the iteration speed without that.

### Split OtosKit into more modules

Incremental builds already recompile per file; the clean build, not module size, was
the cost, and caching removes it.

## Consequences

- A fresh worktree's first check builds in under a minute when the store holds a nearby
  tree, which it does whenever any worktree built recently. The first build after a
  toolchain or setting change repopulates the store at clean-build cost.
- **Edits rebuild their whole module.** With caching and prefix mapping, the Swift
  driver cannot read the bare `.swiftmodule` path and recompiles every file of an edited
  module and of modules whose interface it changed (swift-driver#2236, open). Measured:
  58 s for a body edit in OtosKit, 114 s for an interface edit that reaches the test
  target, at heavy load. Revisit when that issue is fixed: the incremental cost then
  returns to one file.
- Debug info and `#filePath` in check builds carry `/^worktree` paths. These builds are
  never debugged; `script/install.sh` and `script/build_and_run.sh` keep their own
  settings and real paths.
- The benchmark build takes the same settings. Measured against `main` on 2026-11-01,
  every benchmark case retired within 0.5% of its base instructions.
- `OTOS_SOURCE_ROOT` is also set when Xcode launches the app from the scheme; the app
  never reads it.
