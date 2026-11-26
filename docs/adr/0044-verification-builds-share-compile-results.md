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
the five-minute budget for a commit's check and CI's caches between runs; where a check's
log lives; one run at a time per build folder, the tree identity a run reports, and the path tests
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

12. **A machine with no Xcode runs the gates and builds nothing.** A Claude Code cloud
    session is an Ubuntu VM (AGENTS.md, "Cloud Sessions"). Every gate is a shell, Python or
    Ruby script or a pinned lint binary, and `script/lint-tools.sh` pins a Linux build of
    each binary beside the macOS one, so the VM runs all of them. The Linux SwiftLint
    cannot load SourceKit and skips the rules that need it, `custom_rules` among them;
    `script/lint.sh` names them (`op=lint.partial`). A static-tier tree is otherwise
    verified there in full. A full-tier tree runs the gates as the static tier does and
    ends `check: INCOMPLETE` with a failing status (`phase=gatesOnly reason=noXcode`), so a
    VM's result never reads as a pass: its build, tests and SourceKit rules are CI's run of
    the same `check.sh` on GitHub's Xcode 27 runner (`Build And Test (Xcode 27)`), which
    builds from the compilation cache main's newest run saved (item 14).
    - **Rejected: building on the owner's Mac through a remote shell.** It made every cloud
      contribution depend on one machine being awake and reachable, and on a shell that
      fences Xcode's own sandboxes.
    - **Rejected: a second entry point for the VM.** It would hold a second list of
      gates, which drifts from `check.sh`'s.
13. **A commit is checked within five minutes, here and on CI together.** The owner
    (2026-11-26): "just try to ensure each commit wraps up in 5 minutes of testing from
    the moment dev works. local and CI together, everything." Every `check.sh` run prints
    its stages' durations (`op=check.stage … seconds=`, `op=check.duration`), and the
    budget counts from the moment a commit is ready to push until CI's `Required CI Gate`
    reports. Measured on 2026-11-26, before this item: `Build And Test (Xcode 27)` took
    7 min 45 s, of which SwiftFormat 64 s, the build 3.5 min (SwiftCompile 420 CPU-s on the
    runner's three cores, every job a miss) and the suite 2 min 20 s; a cloud VM's first
    `check.sh` took 256 s, 245 of them SwiftFormat with no cache. With items 14–16, a run on
    `main` that restored the cache (run 45785268709) took 7 min 44 s from trigger to gate:
    no queue that time, setup and checkout 27 s, the cache's 198 MB restored in 5 s, the
    gates 19 s, the Swift packages fetched afresh about 60 s, a build of cache hits about
    90 s (SwiftCompile gone from Xcode's timing summary), and the suite about 4 min. The
    suite is about 420 CPU-seconds on the runner's three cores, and a runner waits 0–3 min
    for a Mac before it starts: these two are what item 17 and the queue note answer.
14. **CI keeps its caches between runs, saved only by `main`.** `Build And Test` restores
    the compilation cache, the resolved Swift packages and the lint caches with
    `actions/cache/restore`, keyed by the
    Xcode build, and the lint job restores its lint caches the same way. Only a push to
    `main` that passed saves (`actions/cache/save`), so every pull request reads the store
    of the newest `main` it can see and no branch's entries reach another. A compile job's
    key is its inputs with the checkout path mapped away (item 2), so a restored store is
    exact: a hit replays a job whose inputs are unchanged, never a stale one.
15. **SwiftFormat lints what changed, once per check.** `check.sh`'s fast gates lint the
    Swift files the change touched against its merge base with `main`, and the whole tree
    when `.swiftformat` or the SwiftFormat version pinned in `script/lint-tools.sh`
    changed. `main`'s CI lints every file on every push (`script/lint.sh`), so an unchanged
    file is already proven formatted under the same options and version. `verify.sh` runs
    SwiftLint alone (`script/lint.sh swiftlint`): the fast gates ran SwiftFormat. Both
    tools keep their per-file caches beside the pinned binaries
    (`script/lint-tools.sh cache-dir`), which is the folder CI restores.
16. **A check keeps its own log.** `check.sh` writes everything it prints into
    `logs/check/<UTC time>-<pid>.log` and names it first (`op=check.log`), so where a caller
    sends the output never decides what evidence survives. The guard hook therefore asks
    nothing about a log's path, and lets a run in the foreground on a machine with no
    Xcode, where `check.sh` builds nothing and ends in seconds.
17. **CI runs the suite as three shards side by side.** `Build And Test (Xcode 27) <k>/3`
    each restore the caches, run the gates, build, and run shard k
    (`OTOS_TEST_SHARD=<k>/3`, `script/lib/test-shards.py`). A suite is a top-level test
    type, as `--only` names one; suites are dealt into three groups by their number of
    tests, largest first, each to the lightest group. Shards 1 and 2 run their groups
    (`-only-testing:`), and shard 3 runs everything else (`-skip-testing:` of those two), so
    a test the dealing does not see still runs. `Required CI Gate` passes only when every
    shard did, which is the verification. Only shard 1 saves the caches on `main`.
    - **The queue is GitHub's.** A hosted Mac took 0, 100 and 180 s to start on
      2026-11-26, and three shards ask for three. Five macOS jobs run at once on the
      owner's plan. No setting of a job removes that wait; it is reported beside the job's
      own time, and a run that misses the budget only because of it says so.
    - **Rejected: one larger runner** (`xcode-27-xlarge`): billed even for a public
      repository, and its cores would still run the suite's CPU-seconds in series with the
      build.
    - Measured warm (run 45790357749, no queue): 5 min 54 s from trigger to gate; the
      slowest shard 5 min 44 s, of which checkout 26 s, cache restore 20 s (710 MB), gates
      33 s, build about 70 s, a 52 s start before the first test, and its tests about 2 min.
    - **Rejected: one build shared by artifact.** The products hold about 500 MB of Core
      ML models; uploading and downloading them costs what a cached build costs.

18. **CI's Ubuntu jobs run the fast gates; the Mac shards do not.** Every gate of
    `check.sh`'s first stage runs in an Ubuntu job: text hygiene, requirements and time in
    Text Hygiene; shape and the scripts' self-tests in Workflow YAML And Script Shape;
    SwiftFormat and SwiftLint in the lint job. The shards set
    `OTOS_CHECK_FAST_GATES=ubuntuJobs` and skip that stage
    (`op=check.stage phase=skipped stage=fast-gates`): on the runner's Mac it took 30 s of
    every shard. The SourceKit SwiftLint rules and the guards still run on the Mac, beside
    the build (`verify.sh`). The shards check out history without file contents
    (`filter: blob:none`).

## Alternatives Considered

### Run the fast gates on CI's Mac as well as on Ubuntu

Rejected by measurement: they cost 30 s of every shard on the runner's three cores, and
the Ubuntu jobs, which run beside the shards, already run each of them (item 18).

### Larger runners

`xcode-27-xlarge` has more cores but is never free for a public repository; the cache
removes the compile work instead of buying faster compile work.

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
