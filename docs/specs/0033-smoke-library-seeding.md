# Spec: Smoke Library Seeding

## Classification

- Work type: Process/tooling / small behavior
- Current requirement IDs: FND-002, FND-005, FND-007, FND-008, FND-011,
  FND-014, FND-015, FND-018, FND-019, FND-020, FND-025, FND-065, FND-070,
  APP-004, APP-005, APP-014
- ADRs: ADR 0002 and ADR 0003 are updated to record the current root
  normalization rule. This increment does not add a new ADR because it tightens
  the existing filesystem-source-of-truth/root-identity decision rather than
  creating a new architecture boundary, schema, scan owner, or user-facing
  library-management decision.

## Problem

The user reported that every new release or clean schema reset starts Otos with
no configured libraries because the rebuildable catalog database is erased. For
agent smoke tests, launching into an empty catalog is not meaningful: it proves
that the window opens, but not that the real catalog browser can load the user's
main OneDrive Pictures library, enumerate a large library, publish library state,
and begin the normal scan/enrichment flow.

Before implementation, repo inspection found:

- The production catalog database lives under
  `~/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite`.
- `CatalogStore.addLibrary(url:)` already owns the correct path normalization,
  overlap validation, migration/load coalescing, root insertion, watcher setup,
  notification, diagnostics, and scan enqueue behavior.
- `CatalogWindowViewModel.addLibrary(url:)` is the single UI-facing mutation path
  for library adds, delivered losslessly to Store.
- `script/build_and_run.sh` builds and launches the Debug app, but it launches
  without any catalog seed and does not pass environment variables through the
  app when using LaunchServices.
- `script/capture-run.sh` and the process docs currently describe launch/log
  capture, but not the requirement that agent smoke launches use a real saved
  library.
- `script/poc-content-type-by-extension.swift` documents the real local Pictures
  path as `~/Desktop/OneDrive/Pictures`, a symlink to
  `~/Library/CloudStorage/OneDrive-Personal/Pictures`.
- Runtime smoke evidence then showed the bad edge case directly: the library row
  was selected, but the browser rendered "No Media" because the root was saved as
  the Desktop symlink path while `FileManager` enumeration returned files under
  the resolved OneDrive provider path. Every media file was rejected with
  `relativePathUnavailable`.

## Scope

In scope:

- Add an app startup smoke seed hook that reads a script-supplied library root
  path and submits it through the existing ViewModel/Store catalog mutation path.
- Add an idempotent Store-owned ensure-library operation so repeated smoke
  launches do not report duplicate/overlap errors when the root is already saved.
- Add a script that defaults to the user's main OneDrive Pictures folder and
  launches the Debug app with the seed environment set.
- Add an automated jank-smoke mode that lets the seeded app run for about
  10 seconds, then scrolls down and up in the media browser while capturing
  unified logs/signposts and catalog diagnostics.
- Resolve symlink components for existing selected roots before they become
  durable `LibraryRootPath` values so Store, scanner, and root-relative paths use
  one filesystem spelling.
- Update process docs to make seeded smoke launches the standard agent path.
- Update requirements and the documentation index.
- Add focused tests/source-hygiene checks for the idempotent Store behavior, app
  hook, script, and process docs.
- Fix attached actionable review findings that still apply to this branch:
  query-request generations, redundant tile-detail prune removal, shared filter
  menu content, shared observation test helper, and less brittle source-hygiene
  checks.
- Verify with the script against the real default path when it exists in this
  agent environment.
- Handle any unclaimed actionable review comments found in the recent-PR sweep
  required by FND-065.

Out of scope:

- Persisting a special "default library" preference.
- Adding a user-visible automatic import, onboarding, first-launch flow, or
  hidden main-window control.
- Changing the current clean schema reset policy.
- Hardcoding the user's OneDrive path into catalog domain code.
- Counting the 23K assets in the script or reading media bytes before launch.
- Changing scan, enrichment, materialization, thumbnail, or filesystem-event
  ownership.
- Introducing sandbox bookmarks or security-scoped access.
- Building UI test-only product controls or requiring user-operated scrolling
  for DoD evidence.

## Definition Of Ready

- [x] Goal, change type, scope, and non-goals are explicit.
- [x] Current repo state was inspected and summarized.
- [x] Captured user guidance was restated to the user as precise requirements in
      the work log; the guidance is explicit enough to implement directly.
- [x] Observable requirements and acceptance examples are identified.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and verification are addressed.
- [x] At least three alternatives are compared below.
- [x] The selected approach is identified and complexity is justified.
- [x] Stale-document and code-comment audits are defined.

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| SLS-001 | Process | Agent smoke launches of Otos shall not treat an empty catalog as useful evidence when the user's main library can be seeded. | Current | This spec, docs/process/development-workflow.md |
| SLS-002 | Tooling | The repo shall provide a simple command that launches the Debug app with the user's main OneDrive Pictures folder as the seed library by default. | Current | This spec, `script/smoke-run.sh` |
| SLS-003 | Architecture | Smoke seeding shall reuse the normal ViewModel and CatalogStore library-add path instead of writing SQLite rows directly or creating a second catalog owner. | Current | This spec, `CatalogWindowViewModel`, `CatalogStore` |
| SLS-004 | Functional | Repeated smoke launches shall be idempotent: if the seed root is already saved, startup shall keep the existing library and avoid duplicate/overlap errors. | Current | This spec, `CatalogStoreEnsureLibraryTests` |
| SLS-005 | Privacy | The smoke seed script shall validate only that the directory exists and shall not enumerate, count, read, materialize, or write media originals. | Current | This spec, `script/smoke-run.sh` |
| SLS-006 | Tooling | Agents may override the default smoke root with an environment variable or explicit script argument when the real OneDrive path is unavailable. | Current | This spec, `script/smoke-run.sh` |
| SLS-007 | Diagnostics | Smoke seeding shall use bounded logs/diagnostics that identify operation outcome and root path, without secrets, media bytes, thumbnails, or metadata blobs. | Current | This spec, `CatalogStore`, `SmokeLibrarySeed` |
| SLS-008 | Process | The standard seeded smoke test shall let the app sit for about 10 seconds after launch before automated scrolling starts, so startup and initial catalog work can overlap with the idle period before scroll jank is sampled. | Current | This spec, `script/smoke-run.sh` |
| SLS-009 | Tooling | The seeded smoke test shall drive up/down scrolling automatically and capture log/diagnostic artifacts so agents do not rely on user-operated visual scrolling for DoD evidence. | Current | This spec, `script/smoke-run.sh`, `script/smoke-scroll.swift` |
| SLS-010 | Functional | A symlinked selected or seeded library root shall persist as the resolved existing directory path before scanning, so a selected root cannot render empty merely because enumeration reports provider-resolved child paths. | Current | This spec, FND-020 |
| RCF-001 | Regression | If the recent-PR sweep finds an unclaimed actionable review thread, this increment shall claim it, fix it through the normal owner path, add focused regression coverage, and reply with the fixing PR or commit. | Current | This spec, FND-065 |
| RCF-002 | Regression | Query-control freshness shall use monotonic query request generations rather than descriptor equality or a pending flag, so rapid A -> B -> A toggles cannot accept a stale projected descriptor as current. | Current | This spec, APP-014 |
| RCF-003 | Non-functional | AppKit structural apply shall not do redundant tile-detail cache pruning; visible detail reads replace the visible-detail map after apply. | Current | This spec, FND-044 |
| RCF-004 | Architecture | Toolbar and View menu filter rows shall share one filter-menu content implementation so partial-kind symbols and kind availability cannot drift between surfaces. | Current | This spec, APP-013 |
| RCF-005 | Test | ViewModel observation tests shall share one `waitForWindowState` helper instead of carrying duplicated timeout loops. | Current | This spec |
| RCF-006 | Test | Source-hygiene tests for the smell follow-up shall assert current invariants without brittle exact local-variable spelling or broad file-wide `MainActor.run` bans. | Current | This spec |

## Architectural Alternatives

### Alternative A: Document Manual Settings Setup Only

Pros:

- no code changes
- uses the existing user-facing Settings flow

Cons:

- depends on user or agent UI operation before every useful smoke launch
- leaves release/smoke loops easy to run against an empty catalog
- does not solve schema-reset or clean-catalog launch churn

Failure modes:

- agents forget the manual setup and report misleading empty-window evidence
- UI automation becomes a fragile prerequisite for smoke checks

Rejected because the user explicitly asked to make this part of the process, not
a manual afterthought.

### Alternative B: Direct SQLite Seed Script

Pros:

- simple shell-only implementation
- can run before the app starts

Cons:

- creates a second writer for catalog roots
- must know schema/migration state or launch the app once to create the schema
- bypasses Store overlap checks, diagnostics, watcher setup, notifications, and
  scan enqueue ownership

Failure modes:

- schema changes break the script
- direct inserts leave runtime state unaware until a later launch
- a script bug writes an unsupported root row that the app owner would reject

Rejected because CatalogStore already owns this mutation and should remain the
single catalog writer.

### Alternative C: App Startup Hook Plus Seeded Launch Script

Pros:

- reuses existing ViewModel and Store mutation path
- idempotent ensure behavior can be tested at the Store boundary
- script can default to the user's real OneDrive Pictures path while the app
  remains path-agnostic
- no media bytes are read before launch; the normal scanner/enricher own their
  work

Cons:

- adds a small developer hook to app startup
- `open` through LaunchServices cannot reliably pass the environment, so seeded
  launches need a direct executable path in the script

Failure modes:

- if the configured root is missing, the script must fail clearly rather than
  silently launching empty
- if the app is already running, the script must terminate it first or the new
  environment will not affect the existing process

Useful but incomplete because launch-only smoke still misses the user's jank
concern.

### Alternative D: App Startup Hook Plus Automated Scroll/Jank Smoke

Pros:

- includes Alternative C's owner-preserving seed behavior
- waits for initial startup work, then exercises the real scroll path with
  synthetic scroll-wheel events
- captures unified logs and catalog diagnostics for the run
- keeps the automation outside the product UI

Cons:

- requires Accessibility/CGEvent permission in the agent environment to drive
  scroll events
- cannot prove every visual hitch without Instruments; it is a smoke signal, not
  a full performance profile

Failure modes:

- if the app is not frontmost or Accessibility is unavailable, the scroll helper
  must fail with a clear message and the DoD must record that blocker
- if the seeded library has not published enough rows after 10 seconds, the
  scroll still runs but may exercise less content than a full warm catalog

Selected.

### Alternative E: Persist A Default Development Library Preference

Pros:

- easy for repeated local launches after initial setup
- no special launch script needed once configured

Cons:

- adds persistent preference state for a developer-only workflow
- risks blurring user-visible product behavior with agent process needs
- still needs initial setup and reset handling

Failure modes:

- stale preference points at a missing path and hides the actual smoke setup
  failure
- future user onboarding gets coupled to local agent defaults

Rejected because the requirement is tooling/process, not product onboarding.

## Selected Approach

Select Alternative D.

Add a small `SmokeLibrarySeed` helper that reads one environment variable,
`OTOS_SMOKE_LIBRARY_ROOT`. `OtosApp` calls it after `CatalogWindowViewModel.start()`;
if the variable is present, it submits an ensure-library intent through the
ViewModel. Store owns the idempotent logic: load/migrate if needed, no-op when the
normalized root is already present, otherwise use the same insert/watch/notify/
scan path as a manual add.

Add `script/smoke-run.sh` as the agent-facing command. It defaults the seed root
to `$HOME/Desktop/OneDrive/Pictures`, accepts an explicit root argument, honors an
already-set `OTOS_SMOKE_LIBRARY_ROOT`, validates that the root is a directory,
resolves symlink components with `pwd -P`, exports the variable, and delegates
build/launch to `script/build_and_run.sh`.
When the environment variable is set, `build_and_run.sh` launches the app
executable directly in the background so the app receives the seed path.

Tighten `CatalogPath` so existing directory roots resolve symlink components
before persistence and relative-path derivation uses the same resolved path
spelling. That keeps the smoke path and the manual Settings path on the same
root identity rule.

The default smoke mode captures unified logs, waits 10 seconds, then invokes
`script/smoke-scroll.swift` to post real scroll-wheel events to the Otos window:
several downward scrolls followed by several upward scrolls. It then summarizes
catalog diagnostics and quits the app. A launch-only `--verify` mode remains
available for quick seed checks; it locates the launched app's session diagnostics
by PID and fails unless a successful `catalog.library.ensure` event was recorded
for the seeded root. The process docs still define the default jank mode as the
meaningful browser smoke test.

This is the simplest correct design because it adds one developer entry point and
one idempotent owner intent without changing product onboarding, schema, or scan
architecture.

## Interfaces, Ownership, And Data Flow

- `script/smoke-run.sh`
  - default mode: `--jank`
  - default root: `$HOME/Desktop/OneDrive/Pictures`
  - override root: explicit second argument or `OTOS_SMOKE_LIBRARY_ROOT`
  - resolves the chosen directory with `pwd -P` before exporting the seed
  - side effects: kills an existing Otos process through `build_and_run.sh`,
    builds Debug, launches Debug with the seed environment, captures logs in
    `logs/`, drives scroll events in jank mode, writes diagnostics summaries
    in `build/Diagnostics`, and quits the app at the end of jank mode
- `script/smoke-scroll.swift`
  - activates Otos, finds its on-screen window, moves the pointer to the window
    center, waits the requested settle period, and posts scroll-wheel events
    down and up through CoreGraphics
  - contains no app-specific product hooks and no media or catalog access
- `script/build_and_run.sh`
  - keeps existing modes
  - when `OTOS_SMOKE_LIBRARY_ROOT` is set, launches the built executable directly
    so the app receives the variable
- `SmokeLibrarySeed`
  - parses the environment
  - logs that smoke seeding was requested
  - submits the seed to the ViewModel
- `CatalogWindowViewModel`
  - adds an `ensureLibrary(url:)` intent with the same lossless serial mutation
    delivery as add/remove
- `CatalogStore`
  - adds idempotent `ensureLibrary(url:)`
  - owns normalization, load/migration coalescing, duplicate no-op, overlap
    validation, insertion, notification, watcher setup, scan enqueue, and
    diagnostics
- `CatalogPath`
  - resolves symlink components for existing selected roots and file URLs before
    root persistence or relative-path derivation

Persistence effects:

- Existing catalog schema only.
- On a missing seed root row, one `library_root` row is inserted and the normal
  scan populates rebuildable media rows.
- On an already saved seed root, no persistence write occurs.
- Existing symlink-spelled roots from earlier development builds are repaired on
  load when the saved directory is reachable and resolves to a different path.
  Any existing child media rows for that root have their path-derived sort keys
  rewritten in the same Store-owned write.
  If repair conflicts with another saved row, Store logs bounded diagnostics and
  keeps the original row rather than blocking app startup.

Filesystem/media effects:

- The script checks only directory existence.
- The normal scanner may enumerate filesystem facts after Store accepts the root.
- No script path reads media bytes, materializes cloud files, writes originals, or
  writes sidecars.
- The scroll helper sends input events only; it does not inspect pixels, scrape UI
  hierarchy, or read files.

## Concurrency And Actor Ownership

- The startup hook runs on the MainActor because `OtosApp` and the ViewModel are
  main-actor UI owners.
- The ensure intent is delivered through the existing unbounded serial mutation
  stream, preserving add/remove ordering.
- Store performs catalog load/migration and root mutation inside the existing
  actor and awaits the existing database writer.
- Repeated startup and ensure calls coalesce through Store's existing
  `loadIfNeeded` path.
- Cancellation follows the existing ViewModel mutation task lifecycle: a queued
  ensure is not started after ViewModel teardown, and an already-started Store
  operation may finish just like add/remove.
- The scroll helper is a separate process. It does not call app internals, mutate
  catalog state, or create in-app tasks.

## Instrumentation And Progress

- Store records `catalog.library.ensure` diagnostics for `start`, `exists`,
  `finish`, and `error` outcomes.
- Store and the startup hook log bounded operation messages with the root path.
- `script/smoke-run.sh` captures compact unified logs and signposts for the smoke
  run under `logs/run-<sessionID>-prod.log`.
- `script/smoke-run.sh` runs `script/catalog-diagnostics.sh summary` at the end
  of jank mode and writes the summary under `build/Diagnostics`.
- Existing scan diagnostics (`catalog.scan`, `catalog.scan.batch`,
  `catalog.projection.window`) remain the evidence for large-library scan and
  projection behavior.
- No new progress UI is added.

## Errors And Privacy

- `script/smoke-run.sh` exits non-zero if the seed root does not exist.
- Jank mode exits non-zero if the scroll helper cannot find the app window or
  cannot post events.
- If the app receives an invalid root despite script validation, Store returns
  the same catalog add/ensure error path used by manual library mutations and
  records bounded diagnostics.
- Logs may include the local root path, matching existing developer diagnostic
  policy. They shall not include secrets, media bytes, thumbnails, or metadata
  blobs.

## Test And Acceptance Criteria

- `CatalogStoreEnsureLibraryTests` proves `ensureLibrary(url:)` inserts a missing root,
  scans it, and no-ops on a repeated call without duplicating or erroring.
- `CatalogStoreRootNormalizationTests` proves adding a symlinked OneDrive-style root stores the
  resolved provider path and scans media instead of producing an empty selected
  library.
- `CatalogStoreRootNormalizationTests` proves an older saved symlink-spelled root
  is repaired to the resolved provider path on startup before scanning.
- A focused source/tooling hygiene test proves:
  - `OtosApp` invokes `SmokeLibrarySeed`
  - `SmokeLibrarySeed` reads `OTOS_SMOKE_LIBRARY_ROOT`
  - `script/smoke-run.sh` defaults to `Desktop/OneDrive/Pictures`
  - `script/smoke-run.sh` resolves symlink components before export
  - `script/smoke-run.sh` validates only directory existence and delegates to
    `script/build_and_run.sh`
  - `script/smoke-run.sh` waits 10 seconds before scrolling in default jank mode
  - `script/smoke-scroll.swift` posts scroll-wheel events down and up
  - process docs require smoke launches to use the seeded path
- `script/requirements-authority-check.sh` passes.
- `script/lint.sh` passes.
- `script/verify.sh` passes.
- `CatalogWindowViewModelQueryIntentTests` proves stale projected states cannot
  overwrite a rapid toggle-back query intent.
- Source hygiene proves the AppKit structural apply no longer prunes
  `tileDetailsByID`, toolbar and View menu filters use the shared menu content,
  and ViewModel tests share observation helpers.
- If the default OneDrive Pictures path exists in this environment,
  `script/smoke-run.sh --verify` launches the Debug app and fails unless the
  app run's diagnostics show a successful ensure request for the seeded root.
- If Accessibility/input automation is available in this environment,
  `script/smoke-run.sh` runs the default seeded jank smoke, waits 10 seconds,
  scrolls down/up, captures logs, writes a diagnostics summary, and quits the app.
  If input automation is unavailable, record the exact blocker and run the
  launch-only seed path as substitute evidence.

## Verification Evidence

- `script/verify.sh` passed on Xcode 27.0 build 27A5194q. The final full test
  result bundle was
  `build/DerivedData/Logs/Test/Test-Otos-2026.07.02_19-47-59--0700.xcresult`.
- Focused CatalogStore root-normalization and smoke-seed tests passed before the
  full verifier.
- `script/smoke-run.sh --verify` passed and reported the seeded root as
  `/Users/example/Library/CloudStorage/OneDrive-Personal/Pictures`.
- `script/smoke-run.sh` passed the default seeded jank smoke, waited 10 seconds,
  scrolled down and up, quit the app, and wrote:
  `logs/run-20260703T024857Z-p<smoke-script-pid>-prod.log`,
  `build/Diagnostics/catalog-diagnostics-20260702-194918.txt`, and
  `build/Diagnostics/smoke-diagnostics-2026-07-03T024918Z.txt`.
- After the smoke run, the live development catalog persisted one resolved root,
  `/Users/example/Library/CloudStorage/OneDrive-Personal/Pictures`, and
  22,466 media rows. No catalog database deletion was used.
- Smoke diagnostics recorded ordered-ID queries up to 25,050 rows, 44 active-app
  main run-loop stalls with worst `stallMs=1111`, a worst ordered-ID query of
  19,228 ms, and a worst enrichment-candidate query of 24,183 ms. These are
  performance smells for a later measured jank/query increment, not blockers for
  this process/tooling fix.

## Code-Smell Review

Smells reviewed:

- **State duplication:** addressed. Smoke seeding calls ViewModel/Store owner
  intents and never writes SQLite directly.
- **MainActor gravity:** addressed. App startup submits one UI-owner intent;
  scanning, persistence, and normalization remain in `CatalogStore`.
- **Stringly typed domain facts:** addressed for roots. Seeded and selected
  paths are converted through `CatalogPath` and `LibraryRootPath`, with symlink
  components resolved for existing roots.
- **Diagnostic payload sprawl:** addressed. Logs and JSONL carry bounded
  operation status and root paths, not media bytes, thumbnails, metadata blobs,
  or secrets.
- **Test coupling:** addressed. The symlink regression tests assert resolved root
  persistence and scanned media, and avoid coupling to private sort-key bytes.
- **Fragile UI automation:** accepted as bounded process tooling. The scroll
  helper is external to product code, fails clearly, and is backed by launch-only
  `--verify` for seed-path checks.
- **Performance/jank:** observed and accepted for this increment. The new smoke
  path made the large-library jank visible: worst ordered-ID and enrichment
  candidate queries were multi-second, and active-app stalls reached 1111 ms.
  This increment records that evidence but does not optimize it.
- **Persistence sort-key separator:** observed and accepted for a later
  persistence/query increment. While tightening the symlink startup regression
  test, an exact SQLite `sort_key` byte assertion exposed that the embedded NUL
  separator used by `MediaSortKey.make` is a questionable persisted text
  separator. The test was narrowed to the user-visible root-repair contract
  rather than expanding this process increment into a sort-key migration.

## Stale-Document And Comment Audit

Update:

- `docs/requirements.md`
- `docs/index.md`
- `docs/process/development-workflow.md`
- `docs/process/performance.md` if launch/log capture guidance changes
- `docs/onboarding.md` if startup data flow changes
- `docs/adr/0003-library-root-selection-and-access.md`
- `docs/adr/0002-catalog-persistence-and-filesystem-scan.md`

Review but likely leave unchanged:

- ADR 0004 and ADR 0005, because this increment reuses existing UI and
  publication decisions.
- Product roadmap, because this is current tooling/process, not a future idea.

Comment audit:

- Add focused comments only where the smoke hook would otherwise look like a
  product onboarding path or a second catalog owner.
- Do not add changelog comments or comments that restate this increment.
