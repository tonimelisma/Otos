# ADR 0044: Verification builds share compile results across worktrees, gates run in one pass, and a check can be scoped while iterating

- Status: Accepted
- Last updated: 2026-11-10

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
gates run; the scoped `check.sh --only` mode and what counts as verification evidence;
one run at a time per build folder, the tree identity a run reports, and the path tests
load each model from.

References but does not own: the check's supervision (heartbeat, deadlock detection,
one entry point; `AGENTS.md` and ADR 0015), the benchmark design (ADR 0043), the
installed app's build (ADR 0030), test architecture (ADR 0023).

## Decision

1. **One shared compilation cache.** `otos_build_settings` in `script/lib/xcode.sh` is
   the single list of settings every verification build passes: `build.sh`, `bench.sh`
   and `face-accuracy.sh`, each through `otos_build_checkout ... verification`. They build
   into the same `build/DerivedData`, so they must pass the same settings or each rebuilds
   what the other built. The list turns on `COMPILATION_CACHE_ENABLE_CACHING` with
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
7. **One run at a time per build folder.** Sessions share the primary checkout, where one
   installs, one benchmarks and one checks. Two `xcodebuild` runs against one DerivedData
   fail on its locked build database (exit 65). `otos_hold_build_folder` in
   `script/lib/build-folder.sh` holds the folder for the rest of the calling script:
   `check.sh`, `build.sh`, `test.sh`, `face-accuracy.sh` and
   `build_and_run.sh` hold `build/DerivedData`, `bench.sh` its measured checkout's, `install.sh` holds
   `build/InstallDerivedData`. A second run waits for the first to exit, which the
   kernel reports, and logs `op=<run>.wait reason=buildFolderBusy holder=<pid> op=<run>`.
   `check.sh` waits before its deadlock detector starts; a static-tier check (§10) builds
   nothing and holds nothing. A nested script inherits its caller's hold through
   `OTOS_HELD_BUILD_FOLDERS`. The lock lives in a holder process (`script/lib/hold-lock.py`,
   which also holds the weekly performance run's lock, ADR 0043), not in a descriptor every build
   child would inherit.
8. **A run names the tree it measured.** `otos_tree_identity` is the git tree id of the
   checkout with uncommitted and untracked files, built in a private copy of the index.
   `check.sh` prints it at the start (`op=check.tree`) and fails when it differs at the
   end, because a pull during the run leaves a result that describes neither tree.
   `bench.sh` reads the commit before building and records nothing if the tree
   changed, so a pull mid-run cannot record results on the commit it moved to.
   `install.sh` refuses to install a build whose tree changed under it.
9. **A new worktree starts from the primary checkout's packages.** Each worktree resolves
   the Swift packages into its own `build/DerivedData/SourcePackages`. GRDB's SQLite
   submodule clones over HTTPS, and on 2026-11-12 that clone hung a fresh worktree's
   build for minutes at 0% CPU. `otos_build_settings` seeds a worktree with no packages
   from the primary checkout's copy (`ditto`), and xcodebuild then resolves the pins
   against it without the network. The folder is copied, never shared: two builds
   resolving into one package folder at once is not a case SwiftPM guards.
10. **The diff picks the tier.** `check.sh` lists the paths the working tree changes
    against its merge base with `origin/main`, untracked files included, with rename
    detection off (`--no-renames`), so a move lists the path it left as well as the one it
    reached: with it on, moving `Otos/Foo.swift` to `script/` listed only the `script/`
    path and the tree took the static tier with the build missing a file. When every one
    is in `docs/`, `.github/`, `.claude/`, a Markdown file, the lint config, or a script
    off the build path, it runs the **static** tier: every gate, no build, no tests.
    Nothing in such a diff is read by the app build or the test suite, so their result
    for it is the merge base's. Every other path takes the **full** tier, and so does any
    path the list does not name and a tree with no diff, so a misread path costs a build,
    never coverage. `check.sh`, `verify.sh`, `build.sh`, `test.sh` and `script/lib/` are
    the build path itself and always take the full tier. `--only` runs always take it.
    - **Rejected: choosing tests by changed source file.** OtosKit is one module; an edit
      rebuilds all of it (§1), and its owners reach each other through the catalog, so
      the map from a source file to the tests it can break would be a guess.

11. **Every checkout loads one path per model version.** Core ML compiles a model on first
    load into the process's Caches and keys the copy by the path it was given and the file's
    identity, and all test
    processes share the test runner's one Caches folder
    (`docs/research/2026-11-12-core-ml-compile-cache-in-test-runs.md`). With a path per
    checkout the folder gained about 1.3 GB per checkout, reached 37 GB, and was pruned.
    The pruning took Vision's text models too, which every parallel check then recompiled at
    once, for 80–220 s and sometimes failing (`e5rtError … 13`). After a build,
    `otos_share_built_models` (`script/lib/xcode.sh`; called by `otos_build_checkout` for a
    verification build) moves each model of the framework the tests load to
    `~/Library/Developer/Otos/SharedModels/<hash>/<name>.mlmodelc`, read-only,
    published by rename, and leaves a symlink. `BundledModel.url(named:in:)` resolves it, so
    Core ML is given the shared path. Before each build into `build/DerivedData`,
    `build_and_run.sh`'s included, `otos_build_checkout` calls `otos_unshare_built_models`
    to remove the links: the models are Xcode's outputs, and an incremental build compiled
    into a link, which the read-only copy refused. Compiling the five again costs about 6 s a build. The app bundle's copy is left as built. A shared
    copy is published once and never replaced, so its identity holds. The installed app's models
    are copied anew by each install and compile once more each time, which is left to macOS's
    pruning of its Caches. The hash is of the source package's
    files and the Xcode build, not of the compiled model: coremlc writes a different
    `coremldata.bin` each time it compiles the same package, so a compiled-content name
    made a new path every build.
    - **Rejected: a home per checkout (`CFFIXED_USER_HOME`).** Entries were written to the
      new home and not found by the next process, so every run compiled every model.
    - **Rejected: retrying a failed read in the test.** It waits out a compile storm the
      harness causes.

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

### Wait on a timer and retry when a build folder is busy

Rejected: the release is a fact the kernel reports (ADR 0033), and a retry loop guesses
how long the other run takes.

### One lock for the whole checkout

Rejected: `install.sh` builds into its own folder and need not wait for a check.

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
