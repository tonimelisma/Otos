# ADR 0015: Observability (Unified Logging + Instruments)

- Status: Accepted
- Date: 2026-07-09

## Context

Otos previously had three overlapping diagnostic sinks: `OtosLog`/signposts,
a bespoke `CatalogDiagnostics` JSONL actor, and `GridTelemetry` scalar counters
flushed to JSONL. No human reads logs; the agent consumes unified logging, and
Instruments consumes interval signposts. The extra sinks had no consumer and
added actor-hop latency plus maintenance cost.

## Decision

**One facade (`OtosLog`), one sink (unified logging), plus interval signposts
solely as Instruments annotations.**

### Logging

- Levels: `.error`/`.fault` for failures and stalls (always persisted);
  `.notice` for operation boundaries the agent greps after a run; `.info`/
  `.debug` for detail available only live, during `log stream`. **macOS does not
  persist `.debug` (or, in practice, `.info`) for a subsystem without an explicit
  logging configuration profile** — confirmed 2026-08-03 by capturing a live
  session and finding zero `.debug` messages retrievable via
  `log show --info --debug`, even though `log show` requests both levels. A
  signal named in `docs/requirements.md` as a diagnostic contract — anything the
  agent must be able to find in a capture taken after the fact — is therefore
  emitted at `.notice` or above; `.debug` is only for chatter the agent accepts
  losing (per-frame/per-asset volume) and is willing to read solely via a live
  `log stream` session. The app bundle now carries that profile
  (`OSLogPreferences` in `Config/Otos-Info.plist`, ADR 0030), so `.info`/`.debug`
  from the app process persist; the rule above still holds because the unhosted
  test process (`xctest`) carries no profile.
- Structured `op=`/`phase=` boundary lines go exclusively through
  `Logger.noticeOperation`/`errorOperation`/`debugOperation`
  (`Otos/Support/Instrumentation.swift`) — never a hand-rolled
  `.debug("op=…")`/`.info("op=…")` string. A SwiftLint custom rule
  (`structured_log_via_helper`) makes the accidental form a build error, so the
  log level of a structured line is always a deliberate choice.
- Everything is `privacy: .public` — the agent must read paths and scalars;
  this is an unsandboxed local tool on the user's machine.
- Structured convention: messages start with a stable `op=` token, then
  `key=value` pairs (e.g. `op=catalog.library.ensure phase=finish rootPath=…`).

### Signposts

Interval signposts remain only for operations an Instruments template inspects
(structural apply, zoom, scan enumerate/write/flush/reconcile, enrichment
batch write, store queries, window publication/state build/apply, filesystem
event batch). A new signpost must name the Instruments question it answers.
Bare event signposts (`emitEvent`) are rejected — no Instruments workflow
consumes them; use a log line instead.

### Agent workflows

- `script/logs.sh stream [Category]` — live capture.
- `script/logs.sh show --last <duration> [Category]` — post-hoc ndjson.
- `script/profile.sh "<Template>" <duration>` — `xctrace record`.
- `script/profile-export.sh <trace>` — `xctrace export` wrapper.
- `script/stall-stacks.sh --last <duration>` — each main-thread stall with the stacks
  sampled while it lasted, parts joined and Swift symbols demangled.
- `script/survey.sh` — one session's whole-machine picture from outside the app, without
  root: a Time Profiler trace attached to the pid, footprint and memory by region at each
  moment, disk, CPU and energy counters for Otos and every readable process, the
  neighbours' memory, folder sizes before and after, network bytes, and one
  `summary.md`/`summary.json` holding names, counts and sizes only
  (`docs/research/2026-11-16-broad-survey-static.md`).

### The performance loop's instruments

Performance work is measured on what the owner feels, on his library, and attributed
before it is fixed (owner, 2026-11-16). The daily benchmarks (ADR 0043) count instructions
on a generated catalog: they guard CPU work against regression, and they cannot see a read
waiting for a connection, a cold disk read, memory pressure, owners waking each other or a
real backlog. Three instruments see those:

- **Resource checkpoints** (`ResourceCheckpoint`, `Otos/Support/ProcessResources.swift`).
  At events, never on a timer — session start, window attached, catalog open, first grid,
  search index loaded, each People build, each scope intent and its paint, each store stall, each tour
  step and the system's memory-pressure report (`DispatchSource.makeMemoryPressureSource`,
  the platform reporting the fact) — one serial utility queue writes `op=process.memory`
  (`phys_footprint` from `TASK_VM_INFO`, its kernel-kept lifetime peak
  `ri_lifetime_max_phys_footprint`, resident size, SQLite's heap, the system's free,
  compressed and swapped memory), `op=process.usage` (CPU time, disk bytes read and
  written, and page-ins `ri_pageins`: faults served from disk, `proc_pid_rusage`) and, where the caller reaches the Store, `op=catalog.store.use`:
  every transaction's time by connection role and Store operation, and the change
  notifications by kind of fact, since launch. The kernel keeps the peak, so no periodic
  sampler exists. A store stall's holders leave on `op=catalog.store.stall.holders` parts
  beside its line, so the line keeps its waiter and wait; a named write that waited 100 ms
  for the writer logs `op=catalog.store.writeWait`; the order read splits its SQL
  (`orderSqlMs`) from making the window's IDs (`mapMs`).
- **The tour** (`SmokeTour`, debug builds, which the installed app is). `OTOS_TOUR=1` makes
  a session walk the sidebar, scroll, open four neighbouring stills the loupe can show
  without a download (an original on this Mac, or a stored preview), step through them,
  compare two, show Info, search, filter by a kind the scope's published options offer,
  sort and sit idle, each through the gesture's own intent and each waiting on the fact
  the app reports (a paint, the visible thumbnails, the loupe's image, a query's state),
  then put the window back and quit. A scroll ends when every visible tile shows what the
  catalog holds for it now (its detail read, and its thumbnail decoded or none rendered
  yet), on a report whose visible set holds the step's target; the report counts the
  tiles with no thumbnail yet (`withoutThumbnail`), so a render backlog is a number, not a
  deadline. A tour's loupe and Compare never download an original:
  their requester refuses every download for the session (`PaneOriginalDownloads.never`,
  `ReadOnlyOriginals`), so a cloud-only photo shows its stored preview and nothing more.
  The act steps (Like, Dislike, Not Rated, Move to Trash then Undo, then five of each in a row, each issued once the one before shows its result) run only in a sandbox
  home (`CFFIXED_USER_HOME`, not the account's home) whose every source lies inside it, and
  are skipped as `notSandboxHome` elsewhere. Each act is timed from its intent to the grid
  change that shows it, `op=ui.actToResult` (the grid drawing the act's tile, now or when it
  is next laid out; committing an order without the trashed items; or, for Undo's Put Back,
  with them again), in every session, toured or not. The scorecard reports a Move to Trash's
  and a Put Back's file work apart, matched by batch (`fileWorkDoneMs`). Projection's intents
  are forwarded off the main actor, so an act's hold never waits for a main-thread turn.
  `OTOS_TOUR_ABLATE` leaves named
  background owners unstarted for that session ("what if it were free"); it is read only
  beside the tour flag, every owner starts otherwise (`BackgroundOwners`, tested), and a
  session with any off says so at `.error`.
- **The scorecard** (`script/scorecard.sh`, parser `script/lib/scorecard.py`). Reads one
  session's lines and prints launch, every click to paint with its breakdown, stalls and
  their holders, background passes, memory, who held which resource, the tour's steps and
  the idle window, each number beside its target (`docs/scorecard-targets.json`); a number
  no line carries is listed as not measured, and a tour step that ended at its deadline
  is a FAIL row of its own. Each paint carries what the process paid between its intent's
  checkpoint (`event=paintStart`) and its paint's (`event=paint`), matched by order and
  scope; one with 100 or more page-ins is marked `pagedIn=<n>`, so the machine paging the
  process back in reads apart from a wait of Otos's own. The mark never changes a verdict.
  The tour's restore of its launch scope after the idle window is a `return after idle`
  (`click.returnAfterIdleMs`), reported apart so `click.returnMs` holds warm returns only.
  `--compare` reads a field an older saved scorecard lacks as unknown. `--tour` runs a tour and saves the scorecard
  under `build/scorecards/`; `--optimized` with `--dev` first builds the dev app with the
  installed app's compiler settings (ADR 0030) into a DerivedData of its own, so a sandbox
  tour times the code the owner runs; `--ablation-matrix` tours with every owner off, each alone
  and none off, in one table. It is a report: it never fails a run and is not part of
  `script/check.sh`; its parser is tested there against synthetic lines.

### Explicit rejections

| Rejected | Reason |
| --- | --- |
| Bespoke JSONL sinks (`CatalogDiagnostics`) | No consumer; unified logging already persists `.notice`+ |
| Bare event signposts (`emitEvent`) | No Instruments workflow points at them |
| Scalar counter snapshot machinery (`GridTelemetry`) | One unread JSONL row; hot-path counters without a reader |
| MetricKit hang diagnostics for stall attribution | Delivered to the app later in a payload, not beside the stall's own log line; the agent reads logs as the stall happens |
| Time Profiler as the only way to name a stalled frame | A stall at launch, or one that happens once a day, is over before a trace can be attached |
| A periodic memory sampler | The kernel keeps the lifetime peak footprint, and the events a user feels already checkpoint it |
| The daily benchmarks as the measure of a performance fix | They count CPU work on a generated catalog; the waits, cold reads and memory the owner feels never reach them |

## Consequences

- Smoke `--verify` asserts `op=catalog.library.ensure` via `log show`, not JSONL.
- Stall detection logs `op=mainThreadStall` at `.fault`, with a `stallID` and the
  number of stack samples taken while it lasted (`stackSamples`). The monitor's tick
  runs only once the main thread is free again, so it cannot see what held the thread.
  `StalledThreadWatcher` can: on a thread of its own, from the second missed beat on
  (150 ms of silence), it samples the main thread's stack every 50 ms by suspending it,
  walking its frame-pointer chain inside its own stack, and resuming it, with nothing
  allocated, locked or logged while it is suspended. The tick then logs the stall's
  distinct stacks, the two most sampled, as `op=mainThreadStall.stack` lines at
  `.notice`. Each frame is `image+0xoffset` with the image's nearest symbol, and each
  stack is split into parts of at most 900 characters, because the unified log keeps
  only about 1,017 characters of a message (measured 2026-11-11).
- Session correlation: `op=sessionStart session=… kind=…` once at launch.
- Store query paths emit `waitMs` (pool acquisition) and `execMs` separately so
  GRDB reader-pool contention is measurable without Instruments; tile-detail
  logs those fields at `.debug` (live-stream only, not durable — see above), and
  slow queries (`queryMs > 50`) also at `.notice` (durable). See
  `docs/research/2026-07-10-grdb-reader-pool-qos.md`.
- Import naming decisions, presentation frames, enrichment-to-plan invalidation,
  and the explicit card-erase path are durable structured diagnostics. Naming
  logs identify wall-clock versus settled filesystem-mtime decisions; presentation
  logs identify the state and byte progress applied to the bar; erase logs report
  actual deleted, skipped, failed, and freed-byte totals rather than planned
  counts.
- A source import session mints one `run=` identifier when planning begins. The
  identifier is carried through plan, readiness, batch, erase, and presentation
  boundaries so a single run can be reconstructed without treating `batch=` as a
  substitute; `script/logs.sh` accepts `--process` because test-host diagnostics
  are emitted by `xctest`, not `Otos`.
- `script/synthetic-card.sh` creates and destroys scoped ExFAT and case-sensitive
  APFS image-backed removable volumes for agent-owned import and erase checks.
  Its measurements and the detach/re-attach procedure live in
  `docs/research/2026-08-21-synthetic-removable-volume.md`.
- The `OtosLog` subsystem is the constant `net.melisma.Otos`, never
  `Bundle.main.bundleIdentifier`. OtosKit is loaded by the app *and* by the
  unhosted test bundle (ADR 0023), whose `Bundle.main` is the `xctest` tool, so
  deriving it filed every test-run log line under `com.apple.dt.xctest.tool`
  where `script/logs.sh`'s subsystem predicate could never match it. The
  subsystem identifies this code, not the process that loaded it. A test run is
  readable with `script/logs.sh show --last <duration> --process xctest`, which
  is how the naming-fact and readiness defects ADR 0026 settles were diagnosed.
- `script/verify.sh` runs every stage to completion and reports which failed. No
  stage may hide another: the static gates once aborted the script under `set -e`
  before the test suite ran, so a formatting nit and five failing tests were
  indistinguishable at the exit code. Guard self-tests print an expected `FAIL:`
  against a seeded bad oracle; that output is suppressed unless the self-test
  itself fails, so every `FAIL:` in a verify log is real.
