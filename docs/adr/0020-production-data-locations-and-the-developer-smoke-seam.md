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
the test bundle is unhosted (ADR 0023): it links OtosKit and never launches the app,
so no test process reaches `OtosApp` or the production locations it names.

**A developer smoke seam may steer what the app looks at; it may never change what
the user has configured.** `SmokeLibrarySelection` resolves
`OTOS_SMOKE_SELECT_ROOT` against the roots the Store already holds and applies the
ordinary `selectSidebar` intent. If the requested path is not an already-registered
root, it selects nothing and logs the registered roots. The one non-path value,
`places`, selects the Places map (ADR 0040) when a fixed library is registered. There
is no path in the seam that registers, removes, or edits a root. The whole seam is
`#if DEBUG`: a release build contains no way for an environment variable to steer
the catalog.

**A sandbox home may be given a library; nothing else may.** A tour or a survey of a
generated library (`script/sandbox-library.sh`, camera-size photos or, at the reference
library size, small ones in a folder tree) launches the dev build with
`OTOS_SANDBOX_LIBRARY=<folder>`, and `SandboxLibrary` adds that folder once the catalog's
first load has applied, through the window's own `addLibrary` intent, the one Settings ▸
Libraries' Add button calls. It registers only when the process runs in a sandbox home
(`CFFIXED_USER_HOME`, the process's own home, neither the account's home nor a folder
holding it), the catalog's folder lies inside that home, and so does the folder; anywhere
else it registers nothing and logs `op=sandboxLibrary phase=refused` with the reason. The
user's configuration is out of its reach by construction, which is what the read-only
smoke seam above guarantees for the user's catalog, and the catalog it changes is removed
with the sandbox home. `#if DEBUG` as well. Rejected: a raw insert into the sandbox
catalog's root table, which skips the scan, the watcher and the owners a person's Add
Library starts.

**A smoke run may capture the window's own rendering, and nothing else.**
`SmokeWindowCapture` (`OTOS_SMOKE_CAPTURE_PATH`, `OTOS_SMOKE_APPEARANCE`) writes the
main window's `cacheDisplay` to a PNG once the selection has something to show — the
first stacks on the map, the first items in a grid — a fact the ViewModel publishes,
never a timer. It reads no screen and needs no permission, so a design pass (light,
dark, grayscale) is agent-owned; a Metal-backed layer such as map tiles may be blank
in it, which the run's log states. With `OTOS_SMOKE_CAPTURE_VIEWS` it walks views in one
launch (the first library's grid, Places, On This Day, Duplicates, and the Edit pane opened
on a still), each in every appearance asked for. It zooms the window to the screen, the size
a person working in it uses (a shell-launched app cannot take activation, so the window is
captured inactive); selects each view through the sidebar's own intent and opens the pane
through the inspector's; waits until the window shows it with what it holds (for the
library's grid, until the items at its top name their thumbnails); draws and commits the
window, so the screen shows the step; writes that step's PNG into the folder the path
names; and waits for the capturing
script's go-ahead (`SIGUSR1`) before the next. Opening the Edit pane writes no recipe; the
walk changes no catalog configuration and edits nothing. `#if DEBUG` as well.

**A read-only tour reads the user's preferences and writes none of Otos's.** The preference
domain is the one owner of everything Otos persists in `UserDefaults` (the browser place it
saves at quit, the grid's and strip's zoom, the Info and Edit panes' folded sections, search
languages, import and export settings): no view uses `@AppStorage` and no code but the domain
names `UserDefaults.standard` (lint `preferences_outside_their_domain`). A
tour session (`SmokeTour`, `OTOS_TOUR=1`) runs on `PreferencesDomain.sessionOnly(.standard)`,
chosen once at the entry point by `PreferencesDomain.configured`. A session-only store reads
the user's values until the session writes or removes a key, and holds every write in the
process's memory. So the tour's filter, sort, scope, search, Compare, inspector and zoom
are the visible session's alone: a tour cut by its script, crashed, or quit before its own
restore step leaves the stored place and settings byte for byte as they were. The tour's
restore step still puts the window back, for the session and its timed return. Nothing a
tour step does is persisted outside the domain: the inspector, search text and Compare
are not stored, and a map position is stored only as a `mapArea` scope in the browser
place. One writer sits outside the domain, and it is AppKit's, not Otos's: the main
`Window` autosaves its frame (`NSWindow Frame main`) and the sidebar's split view its
dividers (`NSSplitView Subview Frames main, SidebarNavigationSplitView`) into the user's
domain whenever they move. The inspector is a split of its own with no autosave name, so
showing or hiding it writes neither (a SwiftUI `Window` with a `NavigationSplitView` and an
`.inspector`, probed on macOS 27: the two keys above and no other). No tour step moves the
window, a divider or the sidebar, so a tour leaves those frames as the user left them; what
is guaranteed byte for byte is every key Otos writes, and the frames only as long as no one
moves the window while a tour runs. Rejected: clearing the window's and split view's
autosave names in a tour session, an AppKit bridge reaching into SwiftUI's own windows for
keys no tour step changes.

The environment variable was renamed from its previous spelling rather than reused,
so an exported value left over in a shell cannot silently keep the old
"register this path" meaning under the new read-only one.

**A durable operational journal, not a log scrape, is the busy truth that protects an
in-flight operation.** The app writes busy state as journal rows: `active_file_operation`
for an import (`CatalogStoreImportJournal`; a row in phase `abandoned` is cleanup owed to
the next launch, not work in flight) and `active_reorganization_component` for a
reorganization (`CatalogStoreReorganizationJournal`). `script/lib/operational-busy.sh`
reads that predicate through `sqlite3 -readonly` under WAL
(`has_active_operational_work()`), for `script/smoke-run.sh`, `script/install.sh` and
`script/survey.sh`. Any
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
  same shape as the bug. Otos has no such check: the unhosted test bundle never runs
  the app's entry point, so nothing in the product asks whether it runs under test.
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
