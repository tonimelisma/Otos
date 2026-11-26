# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. The user's filesystem — or, for
an Immich account, its server — is the single source of truth for what media exists
and where it lives. Otos overlays
organization, metadata, previews, and editing intent on top of user-owned media
that stays on disk wherever the user chose to keep it, including cloud-synced
folders. Originals are read-only, and Otos never takes the user's media hostage:
it never relocates originals into an opaque app-owned library, and nothing it
derives or authors (catalog, ratings, edits, metadata, thumbnails, previews) is
written into the user's media folders.

`docs/architecture.md` is the current-state code map. `docs/requirements.md` is the
authoritative registry of implemented behavior. `docs/adr/` justifies the
architecture. `docs/design/design-system.md` is the authoritative registry of
design rules for user-facing surfaces; per-screen specs live beside it in
`docs/design/`. Read those for detail; this file is how to work here.

## Taylor's Standing Rules (apply everywhere)

These are Taylor's own rules for every project. They are copied here because a cloud
session never reads his `~/.claude/CLAUDE.md`.

- When it is already clear what Taylor wants, do it. Never ask whether to do it, how to
  do it, or which piece to do first, and never end a turn with a go-ahead question or a
  "Yes, do it" button. Ask only for what only Taylor can do (his accounts, devices,
  approvals) or a real product choice he has not made yet.
- Never end a turn while any item Taylor asked for can still move forward without him.
  When one item is blocked (the Mac locked, something only he can do), go on to the
  next unblocked one; stop only when every item is done or truly blocked, and list just
  the Taylor-only steps at the end.
- Live tests may write to Taylor's real apps; every test removes what it made in its own
  teardown, even when it fails, and confirms the removal. Never leave test data behind.

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture. Do not add compatibility
  shims. If a structure is wrong, replace it with the right structure; do not
  patch around bad boundaries.
- **Engineering effort is free. Never take a shortcut.** Every engineering
  decision assumes effort costs nothing, so effort, diff size, file count, and
  schema migrations are never reasons to choose a design. When a code smell or
  anything iffy appears, stop and ask: if this were being built from a blank
  slate today, what approach and architecture would it have? Build that, and
  delete what it replaces. No quick fixes, no call-site patches for a type-level
  defect, no "good enough for now", no follow-up deferred to save work. Free
  effort is not license to gold-plate: the blank-slate answer is still the
  smallest correct design for the verified requirements.
- Keep the app as simple as possible. Prefer the smallest correct model, owner,
  schema, state flow, and UI that satisfies verified requirements. Simplicity is
  a requirement, not a shortcut.
- Performance comes after correctness, simplicity, and clear ownership. Do not add
  caches, pools, background pipelines, generalized abstractions, split schemas, or
  scale machinery for anticipated load before measurement or a verified
  requirement proves the simple path insufficient.
- The machine's free resources are for the work (owner, 2026-11-18: "if there's resources
  on the computer, use them to do the work that needs doing!"). Never hold work or trade
  throughput to keep Otos's own footprint small; only the machine's conditions hold it
  (ADR 0057). Otos's footprint is a number, not a target; the pressure it causes is
  judged. A leak — memory that never comes back — is still a bug.
- Do not guess. Inspect the repo, read the relevant APIs, and verify claims with
  code, docs, tests, profiling, or runtime evidence.
- The owner's production data is read, never changed (owner, 2026-11-15: "the rule says don't
  test with my … production data by changing it", and "launch the app if needed! you are
  supposed to use my production data for all read-only testing!"). Read-only work on it is
  expected, and nobody asks first: launching the installed app and looking at it, visiting
  its views, reading its unified log and crash reports, opening its catalog read-only
  (`sqlite3 -readonly … ?mode=ro`) for schema, counts, plans and timings, `stat`/`du` of
  his libraries and app folders, and read-only requests (GET) to his Immich server with the
  session token Otos stored in the Keychain (owner, 2026-11-18: "You are supposed to do read
  only tests with my library including immich key"); the token is never printed or logged
  and goes only to his own server. What is never done there is anything that changes his data
  or leaves state behind: no Move to Trash, Like or Dislike, naming or merging people,
  import, erase, edit, reorganize or settings change; no write to the catalog or to his
  Immich server; no copy or
  backup of it, and no build launched on a copy (a copy's roots are his real folders and
  devices); no reading a cloud-only file's bytes, which downloads it. An Otos the session
  launched is quit when the look is done, and the quit is confirmed (`pgrep -x Otos`).
  Experiments that write (migrations, fuzzing, destructive tests) use generated catalogs
  shaped like his.
- Do not fabricate user-visible or domain facts. Unknown dates, paths, provider
  state, progress, counts, diagnostics, and capabilities stay unknown or
  explicitly qualified until proven.
- Time is never a stand-in for a fact that can be known. If something can report that
  work finished, state changed, or an item is ready, wait on that report. Time appears
  only where nothing can report the fact, and the wait says which case it is with a
  `time:` tag — `deadline`, `backoff`, `schedule`, `measurement`, `poll`, or
  `cadence <measurement path>` — which `script/time-guard.sh` checks (ADR 0033).
- One user action has one implementation path. Buttons, menus, shortcuts,
  gestures, automation hooks, and tests call the same owner intent, not parallel
  behavior paths.
- Each source's own listing is the single source of truth: a folder's or card's
  filesystem, a camera's ImageCapture listing, an Immich account's sync stream
  (ADR 0046). The catalog and every overlay Otos stores are a subordinate,
  rebuildable projection; when they disagree, the source wins and the catalog
  reconciles. Otos never writes to an Immich server.
- Otos never takes media hostage: no opaque app-owned vault. Everything Otos
  derives or authors lives in Application Support, never in the user's media
  folders, and it generates no sidecar files for identity or authored overlay. The
  user's files change only through explicit, user-initiated file operations:
  import (copies media and its existing `.xmp` / `.srt` companions into a library),
  library reorganization (moves them within it), export (writes new files into a
  folder the user chooses, never overwriting one), Move to Trash, and card Erase
  (removable volumes and cameras only; library roots are read-only to it). The
  default is that nothing on disk changes.
- Overlay has one lifecycle. Every overlay Otos holds for an item is kept as long
  as that item exists and is purged in full only when the item is proven deleted
  (absent from a reachable, fully enumerated root; for an Immich account, a deletion
  its server reports or a completed resync that no longer lists it) or the user
  removes its root.
  A temporarily missing original is never a deletion. The one time-based removal is
  removable-source retention: a card or camera unseen for 90 days is forgotten as if
  the user had removed it (ADR 0013). Asset identity is the
  path; for a source whose originals Otos stages, the path is named by the source's
  own ID (an Immich asset's folder). Otos invents no durable IDs, content
  fingerprints, or sidecars.
  See `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.
- The media grid never blanks a thumbnail already displayed for the same on-screen
  asset in the current process. A tile may show placeholder content only before
  that asset's thumbnail has ever decoded in this process; after a thumbnail
  paints, reorder-only applies, detail-query failures, missing detail rows, nil
  thumbnail loads, scrolling, enrichment, structural applies, and availability
  churn must keep that thumbnail or replace it only with a newer thumbnail for the
  same asset.
- Otos is an image/video product. Never add audio-specific playback, metadata,
  thumbnails, icons, classification, or workflows.
- Otos is unsandboxed. Design file access around user-selected media roots and
  normal filesystem paths. Do not add App Sandbox, security-scoped bookmarks,
  bookmark schema/lifecycles, or sandbox-driven file access.
- Otos has exactly one main window — a permanent product invariant. Use a
  singleton SwiftUI `Window` (not `WindowGroup`) for it; never design, defer, or
  leave seams for multiple main windows.
- User-facing surfaces follow `docs/design/design-system.md`. Its `DES-*` rules
  are reviewed like requirements: a UI change that violates one either changes
  the rule in the same PR or is wrong. Design deviations from macOS defaults are
  marked `[deviation]` there with their justification; do not add unmarked ones.

## Measure Before Optimizing (Rob Pike's rules)

You cannot tell where a program spends its time — measure before tuning, and only
when one part overwhelms the rest. Fancy algorithms are slow when n is small (n is
usually small) and buggier than simple ones; use simple algorithms and simple data
structures. Data dominates — get the data structures right and the algorithms
follow. In Otos: choose the simplest correct data structures and owners, ship them,
and let instrumentation prove a real bottleneck before optimizing it.

## Platform And Product Baseline

- Target the latest macOS/Xcode beta configured for this repo (baseline Xcode 27
  beta, macOS deployment target 27.0). Prefer Apple-native technologies: Swift,
  SwiftUI, Image I/O, AVFoundation, Core Image, OSLog, Instruments, filesystem
  APIs. Prefer SwiftUI; use AppKit only when SwiftUI cannot provide the capability
  or meet a verified responsiveness/performance requirement.
- Third-party dependencies require a justified decision (alternatives + tradeoffs)
  in an ADR before adding one.
- App data (catalog + all overlay) lives in Application Support and is treated as
  backed up. There is no cache eviction or preview pruning; overlay follows the
  single lifecycle above.
- Most media lives in cloud-synced folders as possibly-dataless placeholders whose
  filesystem facts (name, size, dates, type) read without downloading, but whose
  bytes force materialization. Byte-reading work must never *accidentally*
  materialize a file. A reader asks `MaterializationCoordinator` where the original
  is (`locality(of:)`: local, fetchable, unreachable — for a folder, from
  `SF_DATALESS`; for a source that stages originals, such as a camera, from its
  staging folder) and fetches through `ensureLocal`, then checks the
  `FileMaterialization` detector again immediately before the byte read. Deliberate non-blocking background
  materialization for enrichment is permitted (up to eagerly materializing the
  whole library). Otos does not free what it downloads; macOS evicts uploaded, idle
  provider files under disk pressure, and background and device downloads never take
  the volume below the 5 GB free-space floor (`FreeSpaceFloor`, ADR 0027). The
  scanner reads only filesystem facts and materializes nothing; byte-reading
  consumers submit deliberate transfers to the shared `MaterializationCoordinator`.
  `EnrichmentCoordinator` is the background enrichment owner. See ADR 0008 and
  `docs/adr/0009-enrichment-storage-and-staleness.md`.

## MediaMetadata Is Ours

[MediaMetadata](https://github.com/tonimelisma/MediaMetadata) is Otos's own byte-parsing
library, with the same owner. Treat it as code Otos can change in any way it needs, not as
a third-party constraint (ADR 0039).

- **The library owns** every fact read from a file's bytes and every rule about what that
  fact means:
  - format family and kind;
  - orientation and display geometry;
  - timestamp roles, and which one names or orders a file;
  - location sources;
  - codec identity;
  - `extractionRevision`.
- **Otos owns:**
  - persistence;
  - when to pay for bytes (never downloading for a parser fix);
  - the catalog's own projections;
  - product policy such as no audio;
  - the platform decode facts it renders with.
- **Never build into Otos something that belongs in the library.** That means no
  re-derived parsing rule, no parallel copy of a library enum, and no per-fix migration.
  When Otos needs a fact the library lacks, the change goes into the library, is released,
  and Otos takes it by version bump. Write the request for the library when it is not
  being changed in the same session.
- **Store what the library reports, as reported,** with its family's
  `extractionRevision(for:)` at the read. `MetadataRefresher` re-reads older records from
  local bytes only.

## Architecture Standards

- Keep SwiftUI views small, composition-focused, and **passive**: they render
  provided state, hold local control state, bind controls, and call explicit owner
  intents. They must not subscribe to catalog streams, coordinate projection
  invalidation, call SQLite, or orchestrate scanning.
- Prefer direct, concrete designs over speculative flexibility. Add a layer, cache,
  protocol, worker queue, normalized table, or pipeline only when it removes
  current complexity or a verified requirement needs it. Protocols belong at real
  substitution boundaries.
- Prefer explicit ownership over ambient global state. Keep state at the narrowest
  correct scope (`@State`, `@Binding`, explicit dependencies, `@AppStorage`).
- Persistence has one current owner with an explicit schema/version policy and safe
  handling of unsupported/future schemas. Rebuildable cache state is overlay, not a
  second source of media truth.
- A schema migration runs at launch, before the window can show the catalog, on a
  2.5 GB file (ADR 0002, "Schema Migrations At Launch"). It costs only what its outcome
  needs: rebuild only an index whose definition changes, write rows before building the
  indexes that hold them, and keep `foreignKeyChecks: .immediate` (a table rebuild
  registers `.deferred` and says why). Its PR states its cost, milliseconds and WAL bytes,
  measured on a generated catalog of the owner's shape
  (`docs/research/2026-11-15-catalog-open-cost.md`). Never change an applied migration in a
  way that changes its outcome.
- Catalog UI ownership split: `CatalogStore` (actor) owns runtime catalog truth and
  emits cheap change notifications; `CatalogProjection` (actor) owns coalesced
  `CatalogWindowState` publication (background cadence, immediate wakeup on user
  intents) plus all sorting/filtering/hiding/empty-state/scope derivation off the
  MainActor; `CatalogWindowViewModel` (`@MainActor`) owns only final SwiftUI state
  assignment, sidebar-selection delivery, lossless serial mutation delivery, weak
  projected-state consumption, and named task lifetimes.
- Architecture-boundary files carry a file guide plus focused comments explaining
  non-obvious actor isolation, task ownership, cancellation, persistence,
  coalescing, cache validation, and view passivity. Comments describe current
  mechanics and why the boundary exists — never syntax narration, changelog/history
  entries, or comparisons with removed code.

## Swift And Concurrency

- Swift 6 language mode, strict concurrency, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
  UI-facing app code is main-actor isolated by default.
- Never do media scanning, metadata reads, image decoding, thumbnail generation,
  database work, filesystem traversal, or export on the main actor. Treat
  synchronous work inside SwiftUI `.task` as main-thread work.
- Avoid unstructured `Task` ownership: long-running work needs an owner, a
  cancellation path, and stale-completion rejection or coalesced dirty/in-flight
  handling. A long-lived stream consumer captures its owner **weakly** across
  indefinite waits, upgrades only for the smallest completed-value scope, and exits
  when that upgrade fails — a loop that only skips a beat keeps whatever its closure
  captured alive forever.
- Owner state follows ADR 0032, because an actor is reentrant and every `await` is a place
  another event can arrive:
  1. **State changes only in synchronous code.** An async operation takes its inputs as
     values, awaits without touching owner state, and returns an event that is applied
     synchronously after checking it still belongs to the identity it started for. Never
     hold a copy of owner state across an `await`.
  2. **A request is a revision counter** (`requested &+= 1`; work covers the value it
     started from; start again while `requested != covered`), never a boolean a finishing
     operation clears.
  3. **One loop per owner, woken by a doorbell** (`.bufferingNewest(1)`). Newer work never
     cancels published work; cancel only for teardown. A cancelled result is never published.
  4. **An error is not a fact.** A failed read publishes nothing, leaves the request
     outstanding and is logged; never substitute `[]`, `0`, `.empty` or `nil` for a value a
     user sees (lint `error_becomes_value`, `discarded_async_error`). An error is classified by its domain and
     code or the API's typed status, never by its localized text (lint
     `error_text_matching`).
  5. **Intents travel in one ordered stream with one consumer** (`.unbounded` for commands,
     `.bufferingNewest(1)` for newest-wins state), never one `Task {}` per call. An intent
     that starts long work returns when it is applied. A platform callback yields into its
     owner's stream; it never hops through its own `Task { @MainActor … }` (lint
     `unordered_main_actor_hop`) and never claims an isolation the platform does not give it
     (lint `dispatch_handler_claims_isolation`), and view-model work is never a bare per-call `Task {}`
     (lint `unowned_view_model_task`).
  6. **Blocking work leaves the actor by a named mechanism** (`@concurrent`,
     `Task.detached`, a task-group child, a dedicated queue): this target compiles with
     `NonisolatedNonsendingByDefault`, so a `nonisolated async` call runs on its caller's
     actor.
  Test an interleaving by delivering the competing event at that exact suspension, never
  with time.
- Intervals and deadlines inside the process use `ContinuousClock` (`Instant`, `Duration`);
  `Date` is only for persisted or displayed timestamps (ADR 0033, lint
  `wall_clock_interval`).
- Main-actor work stays below Apple's 100 ms hang threshold; scrolling/grid/
  animation/pointer paths well below it. Changes touching jank, responsiveness,
  concurrency, media I/O, or rendering include profiler/log evidence.

## Instrumentation

Every meaningful path is observable before it is done, through the repo facade
(`OtosLog.Logger` + `OSSignposter`, categories App/UI/FileAccess/Catalog/Metadata/
MediaIO/Thumbnails/Persistence/Rendering/Performance). **No human reads logs** — the
agent does, so log the things the agent must find, in a machine-greppable shape.
The agent's windows are `script/logs.sh` (unified logs) and `script/profile.sh`
(Instruments via `xctrace`). Performance work is evidence-driven: measure, change,
remeasure; attach the log/trace artifact and worst-span summary.

## Code Smells

Code smells are indicators, not guilt; when one appears, look for the deeper design
problem. Every PR notes the smells observed (`None observed` when true). Watch for:
MainActor gravity (work isolated to main because it is convenient); SwiftUI body
work (scanning/decoding/sorting/I/O in `body` or synchronous `.task`); state
duplication (two owners answer the same domain question); AppKit bridge sprawl;
unsafe concurrency escape (unchecked `Sendable`, detached tasks, shared mutable
state crossing actors without an owner); stringly-typed domain facts; ambiguous API
names; test coupling (asserting implementation details instead of observable
behavior); diagnostic payload sprawl.

## Code Review

Two lenses on every PR:

- **(A) Implementation fidelity.** Establish the oracle first: behavior-preserving
  work keeps existing tests green *unmodified* plus a runtime differential where
  useful; bug-fixes reproduce then verify; invariants get an adversarial "can I
  construct a violation?" pass. Diff against the plan, check blast radius, run
  every agent-owned check, then invert every "this is fine."
  For each `await` in the diff: what can change here, and is it re-read before being
  written? Three questions that no lint can ask:
  - For each platform delegate method or callback: is every report it can deliver
    either consumed or ignored with a stated reason? An empty method is a decision.
  - For each wait, retry or timeout: does Otos itself hold the fact being waited out?
    Then its owner releases or reports it, and time is not used (ADR 0033).
  - For each name the diff's behavior change touches — type, method, log `op=` —
    does it still say what the code now does? A changed behavior renames itself.
- **(B) Architecture.** Is this the simplest correct design? One owner per
  question? Would a blank-slate build arrive here, or is this a patch around a
  wrong boundary?

Review from the diff, not the author's intent. Prefer a cold `/code-review`; for
hot-path or store work, suggest the user run `/code-review ultra` (user-triggered
and billed — the agent cannot launch it). Rank findings by severity; each finding
is a concrete failure scenario plus `file:line`. A confirmed correctness bug or a
lost invariant/requirement blocks merge; smells and Lens-B notes are logged on
the PR.

**(C) Design, for any change to a user-facing surface.** Five checks against
`docs/design/design-system.md`, in this order:

1. Name the surface's single L1 primary fact (DES-010). If you cannot, stop — the
   surface is not designed yet.
2. Assign every string on it to a level (DES-010–013).
3. Check the zones and the fixed height across every state (DES-018, DES-053).
4. Screenshot light and dark (DES-022), then grayscale one of them (DES-029).
5. Tab through it with no mouse, and run it once with Reduce Motion on
   (DES-080, DES-075).

Cite the `DES-*` rules the change satisfies. A change that violates a rule either
changes the rule in the same PR or is wrong. When a `DES-*` rule becomes observable
behavior worth testing, add or update the `APP-*` row in `docs/requirements.md` and
cite the `DES-*` ID in its Requirement text: the design doc says what it should look
like, the requirement row says it is implemented and points at the test.

## Toolchain

This repository is public. The Apple team that signs Otos is not in it: the project
reads `$(OTOS_DEVELOPMENT_TEAM)`, which `script/lib/xcode.sh` takes from the environment
or, on the Mac, from `~/.config/otos/development-team` (one line, the team ID). A build
without it is signed to run locally, which tests and CI need; an install needs the team.
Never commit the team ID, personal media or private paths.

Use full Xcode (not Command Line Tools). Install tools with `brew bundle`;
SwiftFormat and SwiftLint are not among them: `script/lint-tools.sh` pins them,
checks their checksums, and fetches them on first use. Run `"$(script/lint-tools.sh
swiftformat)" .` to format. The
required local check is **`script/check.sh`** — the single entry point, run with
`run_in_background: true`. **One run of it on the final tree is a PR's verification:
about two to three minutes, and it runs no benchmark.** Nothing else is run per PR. The
whole suite is not looped; a failure a check reported is reproduced with
`--only <Suite>`, scoped to the suite that failed. It runs the seconds-long gates first, then the full
verification (requirements-authority + lint + build + test), and prints a heartbeat
every 60 s carrying elapsed time and the running test count. Do not invoke
`script/verify.sh`, `script/test.sh` or `script/build.sh` directly:
`script/hooks/guard-long-checks.sh` denies it, because those skip the gates and
emit no heartbeat, which is how a hung run is mistaken for a slow one. While
iterating on one area, `script/check.sh --only <Suite>` (repeatable; a suite is a test type's name, not its file's, and one that runs no test fails) runs the same
gates and build but only the named test suites; it prints `evidence=no` and never
counts as verification. Check builds share one compilation cache across worktrees,
with source paths mapped to `/^worktree` (ADR 0044): a test never locates a file
through `#filePath`, it reads the checkout from `SourceTree.root`. Read logs
with `script/logs.sh stream [Category]` (live) or
`script/logs.sh show --last 10m` (post-hoc ndjson); profile with
`script/profile.sh "<Template>" 10s` and `script/profile-export.sh <trace>`.
See `docs/adr/0015-observability.md`.

**Performance is measured once a week, in one run** (ADR 0043). `script/check.sh` prints
one `op=perf.status` line:
- `verdict=due`: start `script/perf.sh run` in the background, watch it like any long run,
  and keep working. It tours the installed app on the owner's library, read-only, then
  counts the benchmark cases on `origin/main`, and writes one verdict. Another session's
  start gets `phase=skipped`; `phase=pending` (an import in flight) leaves it due.
- `verdict=fail`: a target in `docs/scorecard-targets.json` was missed on the owner's
  library (`felt=`). Fixing it is the next work, starting with one tour that reproduces it
  (`script/scorecard.sh --tour`). One that does not reproduce is recorded with
  `script/perf.sh not-reproduced <that tour's scorecard>` and left to the next weekly run; a
  `fail` that carries `notReproduced=` asks for nothing. A target changes only with the owner's decision.
- `verdict=elsewhere`: this machine has no installed app (a cloud session's VM, a CI
  runner), so the weekly run cannot happen here and its verdict is not kept here. Nothing
  to do.
- Instruction rises (`cpu=`) decide nothing; the owner says whether one is work.

Nothing else measures. No tour, `script/bench.sh compare` or `OTOS_BENCHMARK` run is part
of a PR, a brief or a DoD, unless the owner asks for it in chat or a fix is reproducing a
`fail`. A performance PR adds a deterministic twin test for its win (rows visited per row
returned, stall lines in `StallReproductionTests`, a hosted footprint) and says "measured
in the next weekly run". `script/scorecard.sh` (ADR 0015) and `script/bench.sh history`
are for diagnosis.

Dev builds (scripts, Xcode ▸ Run) are `net.melisma.Otos.dev` with their own
Application Support data; `/Applications/Otos.app` is the installed
`net.melisma.Otos`, which updates itself with Sparkle to every `main` commit CI passed
(ADR 0059); `script/install.sh` builds and installs one on the Mac (ADR 0030). The installed app is
a Debug build compiled with `-O`: attach with `lldb -p` or `xcrun xctrace record --attach <pid>`
(for a build Sparkle installed, `script/installed-symbols.sh` first fetches its dSYMs), and
read its logs with `script/logs.sh` — `.info`/`.debug` persist for it.

### Supervising long checks

`script/check.sh` takes about two minutes: under a minute to build when the shared
compilation cache holds a nearby tree, and about a minute to run the suite. The first
build after a toolchain or build-setting change fills the cache at clean-build cost. An edit
rebuilds its whole module, not just the edited file (ADR 0044): about a minute for
OtosKit, two when the edit reaches the test target. It runs the seconds-long gates
itself, first, so a formatting nit never costs a build.

**A long check is watched, not awaited.** Waiting on process completion alone does
not work: a hung process never completes, so it never reports, and the wait is
unbounded. **Arm a `Monitor` that emits a line every 60 seconds**, and stop it in
the same action that reads its result — an unstopped watcher keeps running for hours.
`check.sh` also detects its own deadlock (below), so a hang reports itself even if
no watcher was armed. Read the tail of the log:

    op=check.heartbeat elapsed=MM:SS stage=<stage> tests=<count>

`tests=` climbing is healthy. `tests=` unchanged three heartbeats running is hung.
No heartbeat at all means the script itself died — read the tail. Reading one file
answers it; `ps -eo pid,etime,command` is the fallback, and note `etime` is
`[[DD-]hh:]mm:ss` — `09:40:13` is nine *hours*, not nine minutes.

A failed run says why in the same log, one line per issue:

    op=test.failure test=<Suite/case> at=<file>:<line> message=<issue text>

xcodebuild's console never prints Swift Testing's issue text and DerivedData keeps only
the newest few result bundles, so `test.sh` reads these from the run's bundle the moment
it ends. Read them before rerunning anything. A failed `script/bench.sh` run prints the same
lines, since a measured commit's checkout is removed with its log.

A run at 3× normal is hung, not slow. Diagnose it rather than waiting it out. When
`tests=` holds for three heartbeats, `check.sh` reports the host as `op=check.hang`
lines, and again when its CPU detector fires. Read those before inspecting by hand.
Each tool shows half:
- `xcrun swift-inspect dump-concurrency <xctest pid>` prints every task object still
  allocated, each with the async backtrace of its last suspension. It does not mark a
  task that has finished. A finished task that something still holds reads exactly like
  a parked one, so only tasks under Swift Testing's runner are tests in flight
  (`inFlight`). The rest are `mayBeFinished`
  (docs/research/2026-11-16-finished-tasks-in-concurrency-dumps.md).
- A test blocked synchronously (a lock, a semaphore, a `sync` call) is a *running* task:
  the dump gives only its thread (`onThread`). `sample` gives that thread's stack and the
  main thread's (`threadStack`). A test parked at an `await` owns no thread, so `sample`
  cannot show it.

Do not paper over a
hang with a kill-timeout in shared tooling — a wall-clock limit destroys a
legitimately slow run, and it hides the bug instead of surfacing it. **A suite that
hangs has a defect; fix the defect.**

**Checks run in parallel.** Several agents in several worktrees run `check.sh` at once,
often while Otos is running; that is the normal case, not a contention to wait out.
Each worktree builds into its own `build/DerivedData`, `check.sh` watches and kills
only its own descendants, and tests run in a standalone `xctest` host, never inside
Otos.app. Runs that share one checkout (a check, a bench, an install in the primary
checkout) take turns on its build folder and log `op=<run>.wait reason=buildFolderBusy`
while they wait; a check whose tree changed mid-run (another session pulled) fails with
`op=check.tree phase=changed` (ADR 0044). Do not wait for an idle machine before starting a check. A test that fails
or hangs only under that load has a defect — a wall-clock bound, an order between two
async facts it does not own, or a leaked thread or file in shared machine state —
and the fix is to that test or its harness, never to serialize the runs.

Kill the **tree**, never the parent alone — killing `verify.sh` leaves its `test.sh`
and `xcodebuild` children orphaned (`PPID 1`), and an orphan competing against the
same `build/DerivedData` is itself a cause of the deadlock above. Confirm with `ps`
that nothing survives before starting the next run.

Verification evidence must come from the run that measured the **final** tree. A
green run followed by any edit the build or tests can see — source, tests, scripts,
project, config, including a refactor or a comment — no longer proves anything;
re-run and say which run the evidence is from.

`check.sh` picks its tier from the diff against the merge base (`op=check.tier`, ADR
0044). A diff confined to `docs/`, Markdown, `.github/`, `.claude/`, lint config and
scripts off the build path takes the **static** tier: every gate, no build, no tests,
in seconds. Anything else takes the **full** tier, and so does any path the classifier
does not know, and a tree with no diff. The build-path scripts (`check.sh`,
`verify.sh`, `build.sh`, `test.sh`, `script/lib/`) take the full tier, because only a
build proves them.

## Cloud Sessions

A Claude Code cloud session (claude.ai/code or the phone) runs in a fresh Ubuntu 24.04
x86_64 VM with `CLAUDE_CODE_REMOTE=true`: no Xcode, no macOS, no display. Otos cannot build,
test or run there. The session does everything else — reads, edits, runs every gate,
commits, pushes, opens and merges the PR — and GitHub Actions builds and tests the pushed
branch on a Mac. Every other rule in this file holds unchanged; the production-data rule
holds trivially, since nothing in the VM reaches the owner's Mac, library or Immich server.

- **Setup.** The SessionStart hook `script/cloud-setup.sh` installs what the gates call and
  the pinned Linux SwiftFormat and SwiftLint (`script/lint-tools.sh`); off the VM it does
  nothing. Claude Code loads a repository's hooks only in a session with that one
  repository; in a session with several, run `script/cloud-setup.sh` once by hand.
- **In the VM.** `script/check.sh` runs every gate: SwiftFormat, time guard, app folder,
  text hygiene, repo shape, scorecard parser, perf rules, requirements authority, the
  `guard-*` scripts and SwiftLint. A static-tier tree is verified in full there. A
  full-tier tree ends `check: INCOMPLETE` (`phase=gatesOnly reason=noXcode`), and its
  verification is CI's run. Two lines read differently there, by design: the Linux
  SwiftLint cannot load SourceKit, so `op=lint.partial skippedRules=…` names the rules it
  did not check (`custom_rules`, `statement_position`), and `op=perf.status
  verdict=elsewhere` says the weekly run is the owner's Mac's.
- **Build and test: GitHub Actions.** Every push runs `CI`, whose `Build And Test (Xcode
  27)` job runs `script/check.sh` on GitHub's `xcode-27` runner with its newest Xcode 27.
  That run, on the PR's final commit, is the PR's verification, as a local run would be.
  The VM reaches GitHub through a proxy that refuses GraphQL (so every `gh pr …` command
  fails), tag pushes, remote branch deletion, and REST ref and release writes. Read CI
  through REST:

      gh api repos/tonimelisma/Otos/commits/<sha>/check-runs --jq '.check_runs[] | "\(.id) \(.name) \(.status) \(.conclusion)"'
      gh api repos/tonimelisma/Otos/check-runs/<id>/annotations --jq '.[].message'
      gh api repos/tonimelisma/Otos/actions/jobs/<id>/logs | grep -E 'op=test.failure|op=check.(stage|hang|tier)|op=lint|check: '

  Watch it with a `Monitor` that reads the check runs every 60 s and exits on every terminal
  fact: all completed, any failure, or a job GitHub did not start (its annotation says why,
  such as a billing limit). A failed build-and-test job prints the same `op=test.failure`
  lines a local run does; read them before pushing a fix. Each push is a full run: there is
  no `--only <Suite>` in CI, so reproduce by reading the failure, fixing, and pushing once.
- **Opening and merging.** Open the PR and merge it with the GitHub MCP tools
  (`create_pull_request`, `merge_pull_request`), which use REST. The repository deletes a
  merged branch itself. A full-tier change merges only on a green build-and-test run: a
  cloud session has no other run to merge on, so while GitHub cannot run the job (the
  stuck-GitHub rule below), it waits, and says so. A static-tier change merges on the
  cloud `check.sh`.
- **What only the owner's Mac does.** Some steps need the owner's Mac, installed app or library,
  and a cloud session cannot reach them: the look at the installed app (Definition Of Done), the weekly performance run and tours
  (`script/perf.sh`, `script/scorecard.sh`), profiling and unified logs
  (`script/profile.sh`, `script/logs.sh`), read-only tests on the owner's library or Immich
  account, and the macOS-only owner tooling: converting and validating Core ML models (the
  `.mlpackage` files in `OtosKit/Resources/` come from the owner's research repositories, which hold
  private family data and are out of scope here), Apple Translation's language resources,
  and the evaluations on the owner's own data (`script/face-accuracy.sh`,
  `script/description-eval.sh`, `script/scene-label-hierarchy.sh`). A cloud session's DoD
  report lists the ones its increment needs as owner steps, the non-blocking after-DoD notes
  the Definition Of Done allows, and completes the increment. The install is not among
  them: the installed app updates itself to every merge CI passed (Definition Of Done).

### Owner setup

Done on 2026-11-25: Otos and MediaMetadata are public (Otos's history was rewritten to
drop private media and the team ID before it went public), and `main` requires the
`Required CI Gate` check. Pending, for the installed app's self-update (ADR 0059):
1. Sparkle's update key: run Sparkle's `generate_keys` once on the Mac (after a build has
   resolved the package, `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`).
   It keeps the private key in the login keychain and prints the public key, which goes in
   `Otos.xcodeproj` as `OTOS_SPARKLE_PUBLIC_ED_KEY` (public; a session commits it).
2. In the repository's Environments, an environment `release` with the secrets
   `OTOS_CERTIFICATE_P12` (the Apple Development certificate and key, exported from Keychain
   Access as .p12, base64), `OTOS_CERTIFICATE_PASSWORD`, `OTOS_DEVELOPMENT_TEAM`, and
   `OTOS_SPARKLE_PRIVATE_KEY` (`generate_keys -x`).
3. One install from the Mac of a build that carries the key (`script/install.sh` on `main`);
   from then on it updates itself.

## Documentation

Documentation is organized around **current truth**, not increments. Each kind has
one MECE home:

- **`docs/requirements.md`** — the authoritative registry of implemented product/
  system behavior. Rows have a stable ID and map to the source files and tests that
  implement/verify them. Current-state only: no future ideas, no process/workflow
  rows, no roadmap. Every behavior change updates the affected rows in the same PR.
- **`docs/adr/`** — one architectural decision per ADR, justifying what was built
  (context, decision, rejected alternatives, consequences). MECE: each names what
  it owns and what it defers. Supersede/rewrite an ADR when a decision changes;
  never append increment history.
- **`docs/architecture.md`** — the one-page current-state code map (dataflow, actor
  ownership, where-to-change table). Update it when ownership or dataflow changes.
- **`docs/research/`** — every online-research pass, POC, and benchmark, dated with
  sources and conclusions. Write research here in the increment that relies on it.
- **`docs/plans/`** — active work plans, numbered. **Delete a plan when its work is
  fully done.**
- **`docs/product/roadmap.md`** — a non-authoritative idea pile. It never guides
  work unless the user explicitly asks for roadmap input.
- **Code reviews and DoD reports live on the PR, never in the repo tree.**

Whenever the user gives guidance that changes product direction, behavior,
architecture, or workflow, capture it in the correct home above during the same
increment (implemented behavior → requirements; a decision → an ADR; an unbuilt
idea → roadmap or a plan). Restate non-trivial captured requirements to the user
for confirmation before relying on them.

### Boundaries (do not let these regress)

- Do not create `docs/specs/` or per-increment spec files. Decisions go in ADRs;
  requirements go in `docs/requirements.md`; work goes in `docs/plans/`.
- Do not add process, workflow, or tooling rows to `docs/requirements.md`.
- Tests assert observable behavior or public owner boundaries. **Tests that read
  source files as text and assert on substrings are forbidden** (CI guards this).
- SwiftLint size limits (`file_length`, `type_body_length`) are warnings. Do not
  split a cohesive type only to satisfy them, and do not re-add hard `error:`
  thresholds. Cohesion sets boundaries.

## Git, CI, And Pull Requests

- **On the owner's Mac, git reaches GitHub over SSH the moment HTTPS fails.** (A cloud
  session's VM refuses every connection but HTTPS, so there HTTPS is the only path.) On
  the first HTTPS fetch,
  pull, push or clone that fails or stalls (a TLS handshake timeout, `early EOF`, a
  fetch killed by a signal, or a transfer with no progress), switch at once, with no
  HTTPS retry, to the deploy key's host alias: `git fetch
  git@github.com:tonimelisma/Otos.git main:refs/remotes/origin/main` and `git push
  git@github.com:tonimelisma/Otos.git <branch>`. Use the alias for every later fetch
  and push in that session. `gh` reaches GitHub's API over HTTPS only; when a `gh pr`
  command times out, issue the same request once through `gh api` before reporting it
  failed.
- Branch with a conventional prefix matching the work (`feat/`, `fix/`, `refactor/`,
  `docs/`, `chore/`, `research/`). Start new work in a dedicated git worktree.
- Never discard user work: do not remove worktrees/branches/stashes unless proven to
  belong to the completed increment and already merged or patch-equivalent to main.
- Use PRs for review; direct commits to `main` are not the normal path. Apply the
  same review bar to your own self-review before opening a PR.
- A red `main` blocks merge of anything that could change build or test results,
  except the fix that greens it. A PR that observes a red baseline opens that fix
  first — merging alongside a known-red `main` is exactly when a real regression
  hides, because nothing verifies the intervening PRs against a working
  baseline. **A doc-only increment is not
  blocked by a red `main`**: its diff cannot compile, run, or hide anything, and
  planning the fix is usually the first step toward it. Such a PR states the red
  baseline and the failing test by name in its DoD report, so the merge is a
  recorded observation rather than a silent pass.
- Before opening a PR, scan the last five PRs (merged or open, human or bot) for
  unresolved review comments. Claim each on the thread, land in-scope fixes through
  the normal path, and reply with how/where it was fixed (or why it is not
  applicable). Do not bypass with a parallel patch or hide a thread.
- Remote CI runs the fast gates (checkout sanity, workflow YAML, text hygiene, script
  inventory, lint) on Ubuntu, and `script/check.sh` on GitHub's Xcode 27 runner (`Build
  And Test (Xcode 27)`). A change made on the Mac is verified by a local `script/check.sh`
  run; one made in a cloud session, by that CI job (Cloud Sessions). A CI job that
  ran and failed always blocks: never waive failures, syntax errors, missing
  tools, or flakiness. Every CI job's checks also run in `script/check.sh`'s fast
  gates, so a green check is a green CI.
- **A stuck GitHub never blocks a merge.** A job GitHub cannot run is not a
  failure. Such a job is either queued with no runner while githubstatus.com
  reports Actions not `operational`, or blocked by a billing/quota limit. The
  green `script/check.sh` run on the final tree already ran its checks: merge on
  it, and never replay the jobs by hand. A cloud session has no such run for a
  full-tier change, so it does not merge one while GitHub is stuck. When Actions recovers, the push run on
  `main` verifies the merge; a red result there is fixed first (red-`main` rule
  above).
- **Opening a PR is not a stopping point.** The agent reads CI status itself
  (`gh pr checks` on the Mac; REST in a cloud session, Cloud Sessions) and continues straight through merge, cleanup, and
  the DoD report in the same turn. A CI watcher exits on every terminal fact:
  all checks done, a check failed, or GitHub degraded (the rule above). A
  watcher that can only exit on success waits forever on an outage. Never end
  the turn to wait for a CI notification: a green run may never send one.
- **Doc-only increments** (the diff touches only documentation — `docs/`,
  `AGENTS.md`, and similar prose; no source, tests, scripts, or config) use a
  lightweight path: skip the last-five-PRs review-comment sweep, run
  `script/check.sh` (it takes the static tier), and integrate
  quickly — branch, PR, merge to remote `main`, remove the worktree/branch, and
  send the DoD report. The DoD report notes the doc-only scope; everything else
  about the DoD (one final report, posted on the PR and sent in full) still
  applies.

## Definition Of Done

There is **one** DoD report per increment, and it is the final report — never a
partial, pre-merge, or ready-for-review DoD. An increment is done only when the
work has landed on `main`, the branch/worktree/stashes are cleaned up, and the tree
is clean on the next-start branch.

An increment that changes the app (`Otos/`, `OtosKit/`, `Otos.xcodeproj/`, `Config/`) reaches
the installed app by Sparkle (ADR 0059): once its merge's CI passes, the `Release` workflow
publishes the build `build-<commit count>`, and the installed app downloads it within the hour
and installs it once no import or reorganization is in flight. Nobody installs by hand after a
merge. A session on the Mac that needs the build before its look waits for that release (`gh
release view build-<N>`), chooses App ▸ Check for Updates…, and confirms the installed
`CFBundleVersion`; the DoD report names the release it looked at. A cloud session's DoD report
says the merge is installed by Sparkle once its release is published, and links that release.
The DoD report carries the `op=perf.status` line from the final `script/check.sh` run.

**The agent looks at what it shipped** (owner, 2026-11-19: "do you do visual inspection of
implemented features at all? can you add that to the process?").
Tests prove the code, but only a look proves what the owner sees: on 2026-11-19 every check was
green while half of All Media's tiles were blank. After the install, a session on the owner's
Mac looks at the installed app on the owner's library, read-only, with the screen tools it has
(computer use), looking at Otos's own window without moving the owner's pointer where the tool
allows. A cloud session cannot look; its DoD report lists the look as an owner step.
- Take a screenshot of each surface the increment changed, and of All Media's grid after any
  increment that changes the app. Read the same window's accessibility tree where the tool
  offers it: its labels name every tile, so a blank tile, a file shown twice, or a wrong
  badge or count is read rather than guessed.
- Name what the screenshot should show before taking it. Anything else is a finding: a blank
  or placeholder tile, a duplicate, a wrong label, text clipped or overlapping, a state that
  never settles, a status that contradicts the logs. A finding is fixed in this increment
  when the increment caused it; one it did not cause is diagnosed from logs and catalog, then
  fixed.
- Navigation that changes no data is allowed: selecting a sidebar row, scrolling, opening a
  photo, switching view mode. Never a Like, Trash, rename, import, edit or setting
  (production-data rule above). Put the window back where the owner left it.
- The DoD report says which surfaces were looked at and what each showed. When the Mac is
  locked or the session has no screen tools, the look is a non-blocking after-DoD note, as
  below.

Verification is **agent-owned**: never require the user to launch the app, operate
the UI, or inspect visuals as a condition of DoD. Run every check available to the
agent; when a useful check cannot be run in the agent environment, record the
limitation, the evidence gathered instead, and the remaining risk as a non-blocking
after-DoD note, and complete the increment anyway.

The final DoD report is **posted on the PR and sent to the user in full** — the same
complete report, not a summary with a link. It uses green/red status emoji with
plain-language text and answers: what was done; what was not; design decisions;
requirement/ADR/doc changes; verification (Xcode version + `script/check.sh`
result); remote CI status (with exact waiver evidence if any); instrumentation/
profiling evidence; code smells observed/addressed/accepted; media-originals and
diagnostics review; outstanding review comments claimed and how each was fixed;
risks/follow-ups; and the merge + cleanup steps completed. `script/dod-report.sh`
generates the mechanical checklist; the report must be complete before it is sent.
