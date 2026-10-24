# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. The user's filesystem is the
single source of truth for what media exists and where it lives. Otos overlays
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

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture. Do not add compatibility
  shims. If a structure is wrong, replace it with the right structure; do not
  patch around bad boundaries. Effort is not a decision criterion — choose the
  correct architecture even when it needs a larger refactor.
- Keep the app as simple as possible. Prefer the smallest correct model, owner,
  schema, state flow, and UI that satisfies verified requirements. Simplicity is
  a requirement, not a shortcut.
- Performance comes after correctness, simplicity, and clear ownership. Do not add
  caches, pools, background pipelines, generalized abstractions, split schemas, or
  scale machinery for anticipated load before measurement or a verified
  requirement proves the simple path insufficient.
- Do not guess. Inspect the repo, read the relevant APIs, and verify claims with
  code, docs, tests, profiling, or runtime evidence.
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
- The filesystem is the single source of truth. The catalog and every overlay Otos
  stores are a subordinate, rebuildable projection; when they disagree, the
  filesystem wins and the catalog reconciles.
- Otos never takes media hostage: no opaque app-owned vault. Everything Otos
  derives or authors lives in Application Support, never in the user's media
  folders, and it generates no sidecar files for identity or authored overlay. The
  user's files change only through explicit, user-initiated file operations:
  import (copies media and its existing `.xmp` / `.srt` companions into a library),
  library reorganization (moves them within it), Move to Trash, and card Erase
  (removable volumes and cameras only; library roots are read-only to it). The
  default is that nothing on disk changes.
- Overlay has one lifecycle. Every overlay Otos holds for an item is kept as long
  as that item exists and is purged in full only when the item is proven deleted
  (absent from a reachable, fully enumerated root) or the user removes its root.
  A temporarily missing original is never a deletion. Asset identity is the
  filesystem path; Otos invents no durable IDs, content fingerprints, or sidecars.
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
  materialize a file: check the `FileMaterialization` detector (`SF_DATALESS`)
  immediately before any byte read. Deliberate non-blocking background
  materialization for enrichment is permitted (up to eagerly materializing the
  whole library); its unreclaimable local-disk cost is deliberately accepted. The
  scanner reads only filesystem facts and materializes nothing; byte-reading
  consumers submit deliberate transfers to the shared `MaterializationCoordinator`.
  `EnrichmentCoordinator` is the background enrichment owner. See ADR 0008 and
  `docs/adr/0009-enrichment-storage-and-staleness.md`.

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
     user sees (lint `error_becomes_value`).
  5. **Intents travel in one ordered stream with one consumer** (`.unbounded` for commands,
     `.bufferingNewest(1)` for newest-wins state), never one `Task {}` per call. An intent
     that starts long work returns when it is applied. A platform callback yields into its
     owner's stream; it never hops through its own `Task { @MainActor … }` (lint
     `unordered_main_actor_hop`).
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

Use full Xcode (not Command Line Tools). Install tools with `brew bundle`. The
required local check is **`script/check.sh`** — the single entry point, run with
`run_in_background: true`. It runs the seconds-long gates first, then the full
verification (requirements-authority + lint + build + test), and prints a heartbeat
every 60 s carrying elapsed time and the running test count. Do not invoke
`script/verify.sh`, `script/test.sh` or `script/build.sh` directly:
`script/hooks/guard-long-checks.sh` denies it, because those skip the gates and
emit no heartbeat, which is how a hung run is mistaken for a slow one. Read logs
with `script/logs.sh stream [Category]` (live) or
`script/logs.sh show --last 10m` (post-hoc ndjson); profile with
`script/profile.sh "<Template>" 10s` and `script/profile-export.sh <trace>`.
See `docs/adr/0015-observability.md`.

Dev builds (scripts, Xcode ▸ Run) are `net.melisma.Otos.dev` with their own
Application Support data; `/Applications/Otos.app` is the installed
`net.melisma.Otos`, built by `script/install.sh` (ADR 0030). The installed app is
a Debug build: attach with `lldb -p` or `xcrun xctrace record --attach <pid>`, and
read its logs with `script/logs.sh` — `.info`/`.debug` persist for it.

### Supervising long checks

`script/check.sh` takes roughly 4 minutes to build plus 3 to run the suite. It runs
the seconds-long gates itself, first, so a formatting nit never costs a full
build-and-test cycle.

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

A run at 3× normal is hung, not slow. Diagnose it rather than waiting it out:
`xcrun swift-inspect dump-concurrency <xctest pid>` prints each parked task's async
backtrace, which names the stuck test and the await it is parked in; `sample` shows
only threads, and a parked Swift-concurrency test owns none. `check.sh`'s detector
prints the OtosTests frames of that dump when it fires. Do not paper over a
hang with a kill-timeout in shared tooling — a wall-clock limit destroys a
legitimately slow run, and it hides the bug instead of surfacing it. **A suite that
hangs has a defect; fix the defect.**

**Checks run in parallel.** Several agents in several worktrees run `check.sh` at once,
often while Otos is running; that is the normal case, not a contention to wait out.
Each worktree builds into its own `build/DerivedData`, `check.sh` watches and kills
only its own descendants, and tests run in a standalone `xctest` host, never inside
Otos.app. Do not wait for an idle machine before starting a check. A test that fails
or hangs only under that load has a defect — a wall-clock bound, an order between two
async facts it does not own, or a leaked thread or file in shared machine state —
and the fix is to that test or its harness, never to serialize the runs.

Kill the **tree**, never the parent alone — killing `verify.sh` leaves its `test.sh`
and `xcodebuild` children orphaned (`PPID 1`), and an orphan competing against the
same `build/DerivedData` is itself a cause of the deadlock above. Confirm with `ps`
that nothing survives before starting the next run.

Verification evidence must come from the run that measured the **final** tree. A
green run followed by any edit — including a refactor or a comment — no longer
proves anything; re-run and say which run the evidence is from.

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
- Remote CI is a fast gate (checkout sanity, workflow YAML, text hygiene, script
  inventory, macOS lint); it does not run Xcode 27 build/test until a runner exists.
  Xcode 27 build/test proof is local `script/check.sh` evidence. A CI job that
  ran and failed always blocks: never waive failures, syntax errors, missing
  tools, or flakiness.
- **A stuck GitHub never blocks a merge.** A job GitHub cannot run is not a
  failure. Such a job is either queued with no runner while githubstatus.com
  reports Actions not `operational`, or blocked by a billing/quota limit. For
  it, run that job's exact commands from `.github/workflows/ci.yml` locally on
  the PR head. Post on the PR the outage evidence and each command's result, and
  merge. When Actions recovers, the push run on `main` verifies the merge; a red
  result there is fixed first (red-`main` rule above).
- **Opening a PR is not a stopping point.** The agent reads CI status itself
  (`gh pr checks`) and continues straight through merge, cleanup, install, and
  the DoD report in the same turn. A CI watcher exits on every terminal fact:
  all checks done, a check failed, or GitHub degraded (the rule above). A
  watcher that can only exit on success waits forever on an outage. Never end
  the turn to wait for a CI notification: a green run may never send one.
- **Doc-only increments** (the diff touches only documentation — `docs/`,
  `AGENTS.md`, and similar prose; no source, tests, scripts, or config) use a
  lightweight path: skip the last-five-PRs review-comment sweep, skip
  `script/check.sh` build/test (run `script/ci-text-hygiene.sh check` and
  `script/requirements-authority-check.sh` locally instead), and integrate
  quickly — branch, PR, merge to remote `main`, remove the worktree/branch, and
  send the DoD report. The DoD report notes the doc-only scope; everything else
  about the DoD (one final report, posted on the PR and sent in full) still
  applies.

## Definition Of Done

There is **one** DoD report per increment, and it is the final report — never a
partial, pre-merge, or ready-for-review DoD. An increment is done only when the
work has landed on `main`, the branch/worktree/stashes are cleaned up, and the tree
is clean on the next-start branch.

An increment that changes the app (`Otos/`, `Otos.xcodeproj/`, `Config/`) also
updates the installed app: after the merge, run `script/install.sh` from the
primary checkout on `main` and include its `op=install` line in the DoD report.
It quits a running installed Otos only when no import or reorganization is in
flight, and relaunches it; a `phase=pending` result is reported, not retried
around (ADR 0030).

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
