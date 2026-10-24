# ADR 0020 — Production data locations are named at the entry point, and the smoke seam is read-only

## Status

Accepted.

## Context

Otos is an unsandboxed macOS app whose product data — the SQLite catalog, the
thumbnail/metadata overlay, and `UserDefaults` — lives at one well-known place per
install. Dev builds and the installed app are separate installs with separate
places (`net.melisma.Otos.dev` and `net.melisma.Otos`, ADR 0030); smoke runs use
the dev install's catalog, which registers the same real libraries. Two developer workflows run the same code against that place:

- **The test suite.** `OtosTests` is a hosted test bundle: `TEST_HOST` launches
  `Otos.app`, so `@main struct OtosApp` runs inside every test process.
- **Smoke runs.** `script/smoke-run.sh` deliberately launches the real app against
  the user's real library, because scan, enrichment, materialization, and import
  planning only behave realistically at real scale.

Both were reaching production data by accident rather than by intent. Every data
location in the construction chain carried an ambient default, so a test-host
process constructed the production stack merely by starting: one measured run
scanned the user's three real roots and opened the 80 MB production catalog. The
smoke seam read an environment variable and called the same "add a library" intent
as the Add button, so pointing a smoke run at a scratch directory permanently
registered that directory as a library in the user's catalog — a row that outlived
the directory and remained visible in the product sidebar.

The shared failure is not "tests were careless." It is that reaching production
data required *no decision*: it was what happened when nobody said otherwise.

## Decision

**Production data locations are named exactly once, at the app entry point, and are
never defaulted anywhere else.** `OtosApp` is the only place that names the
production catalog location, `UserDefaults.standard`, and the user's system Trash
(`MediaTrashCoordinator.FileOperations.live`). Every type that needs one takes it as
a required, non-defaulted parameter, so a caller cannot reach production data by
omitting an argument — reaching it is a thing you have to write down. Tests pass
temporary locations, a self-cleaning `UserDefaults` suite, and a Trash that is a
folder they own (or one that refuses every move);
the hosted test app additionally declines to start the product stack at all
(`RunContext.isTestRun`), so the test host comes up inert rather than merely
pointed somewhere else.

**A developer smoke seam may steer what the app looks at; it may never change what
the user has configured.** `SmokeLibrarySelection` resolves
`OTOS_SMOKE_SELECT_ROOT` against the roots the Store already holds and applies the
ordinary `selectSidebar` intent. If the requested path is not an already-registered
root, it selects nothing and logs the registered roots. There is no path in the seam
that registers, removes, or edits a root. The whole seam is `#if DEBUG`: a release
build contains no way for an environment variable to steer the catalog.

The environment variable was renamed from its previous spelling rather than reused,
so an exported value left over in a shell cannot silently keep the old
"register this path" meaning under the new read-only one.

**A durable operational journal, not a log scrape, is the busy truth that protects an
in-flight operation.** The app publishes busy state through `active_file_operation`
and `active_reorganization_component` (`CatalogStore.hasActiveOperationalWork()` /
`activeOperationalRootPaths()`), and `script/smoke-run.sh` reads the same predicate
through `sqlite3 -readonly` under WAL (`has_active_operational_work()`). Any
`SQLITE_BUSY`, `SQLITE_CORRUPT`, or missing-table error counts as busy, and both the
import and reorganization journals are covered. The safety invariant is global: the
single `Otos` process is never `kill`ed while any journal row exists, even for a
different root — per-root output is diagnostic only. `is_import_active` remains as an
alias.

## Rejected alternatives

- **Clean up after the fact in a teardown hook.** Deleting stray preference domains
  and catalog rows after each run treats the symptom and leaves the window open: a
  crashed or interrupted run skips its own cleanup, and the run that matters most —
  the one that failed — is exactly the one that leaves debris. It also cannot undo a
  production scan that already happened.
- **Detect XCTest at runtime and branch data locations.** A runtime
  `am-I-under-test` check as *the mechanism* puts a conditional in the middle of
  production construction and makes the production path the fallback, which is the
  same shape as the bug. Otos uses `RunContext.isTestRun` only to decline to start
  the stack, never to choose where data lives.
- **A dependency-injection container.** A registry of locations resolved by key
  reintroduces defaulting with more ceremony: a caller that asks for a key nobody
  registered still gets something. Required parameters make the omission a compile
  error instead.
- **Keeping the smoke seam able to add a root, guarded by a confirmation.** A
  confirmation a script must answer is a confirmation a script will answer. The seam
  either can modify the user's configuration or it cannot; making it unable to is
  the only version that holds under automation.
- **Deleting the smoke seam entirely.** Running against the real library is the
  point — synthetic fixtures do not reproduce cloud-placeholder behavior or 16k-item
  scroll load. A read-only seam keeps the value and removes the hazard.
- **Scraping `log show --last 5m` for busy state.** Global last-line-wins, 5-minute
  truncation, and daemon-drop false-idle could each report idle during a live
  operation and `kill` the app mid-`copyfile(3)` or mid-move. The journal survives
  window, drop, and reboot, and already drives import/reorganization recovery.

## Consequences

- Adding a type that persists data requires naming its location at a call site; there
  is no correct way to "just use the default."
- A smoke run against a path that is not registered now fails with a message listing
  the registered roots, instead of silently making itself succeed by registering one.
- Catalog rows a previous smoke run already created are not removed by this decision.
  Removing a library root purges its overlay, which is a user-owned action
  (ADR 0008); a stale root stays in the sidebar until the user removes it.
- `script/smoke-run.sh --verify` proves selection was applied by looking for
  `op=smoke.select phase=finish outcome=selected`, rather than proving a library was
  registered.
- `script/verify.sh` enforces that the production catalog and preference domains are
  untouched across a run, so a regression that reaches production data fails the
  local gate rather than being noticed later.
- A smoke run refuses to `kill` the app while any operational journal row exists, so
  an in-flight import or reorganization is never interrupted by developer tooling.

## Defers

- **Where overlay lives and when it is purged** — ADR 0008.
- **Test-suite process isolation mechanics** beyond data locations — ADR 0023.
  This ADR owns *where* data lives; ADR 0023 owns whether the test bundle is
  hosted and how a `PreferencesDomain` value resolves to a concrete store.
  `RunContext.isTestRun`, referenced above as the mechanism that kept a
  test-host process from starting the product stack, no longer exists: the
  test bundle unhosted by ADR 0023 can no longer launch the app at all, so
  the guard it existed for is unreachable.
