# Plan 0066 — Test/production data isolation and read-only smoke runs

## Status

Not started. Evidence in Stages 1–5 was captured on 2026-08-04 against `main` at
`bdd31e4`; Stage 6's additional evidence on 2026-08-05 against `3e94549`.
Reproduce it before changing anything: the measurements are the acceptance
criteria, and a junior implementer who has not seen them will not know when a
stage is done.

Sibling plan: `0067-measurements-that-mean-what-they-say.md` covers three defects
found in the same investigation that are about numbers and guards being wrong, not
about data isolation. Keep them separate; they share no code.

## Purpose

Two rules, currently both broken:

1. **The test suite must never read or write the user's production app data.**
   Today `script/test.sh` scans the user's real photo library, writes the
   production catalog, and leaves preference files behind on every run.
2. **A smoke run may use the production library, but only in the ways the app
   already behaves on its own** — scanning, enrichment, materialization, import
   planning. It must never change what the user has configured, and it must never
   destroy work the user has in progress. Today it permanently registers whatever
   path it is pointed at as a library root, and it force-quits the app on exit
   regardless of what the app is doing.

These are not tidiness issues. The measurements below show a `swift test`
equivalent walking a 16,159-file cloud library and mutating an 80 MB production
database, and a smoke script that killed a real 9.1 GB import mid-flight.

## Evidence

Run these yourself first. Every number is reproducible.

### 1. The test suite scans the production library

`OtosTests` is a hosted test bundle (`Otos.xcodeproj/project.pbxproj:426`):

```
TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Otos.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Otos"
```

So `Otos.app` launches, `@main struct OtosApp` runs, and its
`@State private var catalogViewModel = CatalogWindowViewModel()`
(`Otos/OtosApp.swift:14`) constructs the **production** stack — because every
data location in that construction chain is an ambient default.

During one `script/test.sh` run on 2026-08-04, the test-host process scanned the
user's real roots:

```
20:19:44.576 Otos[2175] op=catalog.scan phase=start rootPath=/Volumes/4152150790
20:19:46.952 Otos[2175] op=catalog.scan phase=start rootPath=…/Family/Summer Photos
20:19:47.265 Otos[2175] op=catalog.scan phase=start rootPath=…/Pictures/Camera Roll
```

### 2. The test suite writes the production catalog

Same run, `~/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite`:

| | mtime | size | `library_root` rows |
| --- | --- | --- | --- |
| before | 2026-08-04 19:39:16 | 80,584,704 | 8 |
| after | 2026-08-04 20:19:52 | 80,584,704 | 8 |

No rows were added, but the production database was opened and written. Row
count is not the safety property — "tests do not touch it at all" is.

### 3. The test suite leaks preference domains, permanently

`OtosTests/CatalogWindowViewModelGridZoomTests.swift:123`:

```swift
private func isolatedDefaults() -> UserDefaults {
    let suiteName = "net.melisma.Otos.tests.gridZoom.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)   // clears BEFORE
    return defaults                                        // never cleared after
}
```

`~/Library/Preferences` currently holds **1,518** `net.melisma.Otos.tests.gridZoom.*.plist`
files. One test run added **8** (1,510 → 1,518). Newest timestamp tracks the last
`verify.sh`, so this grows with every run, forever.

`OtosTests/MediaCompanionInventoryTests.swift:68` already does this correctly
(`defer { defaults.removePersistentDomain(forName: suite) }`). Copy that
guarantee, do not copy the `defer` discipline — see Stage 3.

### 4. Tests write production preferences through `UserDefaults.standard`

`MediaOperationCoordinator.persistDestinationMappings()`
(`Otos/Services/MediaOperationCoordinator.swift:823`) writes
`import.destinationBySource` to `UserDefaults.standard`, and it is called at the
end of every `refreshSources`. `MediaOperationCoordinatorTests` calls
`coordinator.start()`, which calls `refreshSources`. In the test host,
`.standard` is the `net.melisma.Otos` domain — the user's real preferences.

`ImportPreferencesStore.load(defaults:)` / `.save(_:defaults:)`
(`Otos/Models/MediaCompanionModels.swift:156,175`) default to `.standard` as
well, and `buildPlan` calls `load()` with no argument.

### 5. A smoke run permanently registered a scratch directory

`Otos/Support/SmokeLibrarySeed.swift` is production code, not debug-gated. It
reads `OTOS_SMOKE_LIBRARY_ROOT` and calls `viewModel.ensureLibrary(url:)` — the
same intent as a user pressing Add. An earlier smoke run pointed it at a
scratchpad path, so the production catalog now holds:

```
id=11 | library | /tmp/claude-501/…/scratchpad/smoke-library | 2 assets
```

The directory no longer exists. The row is visible in the product sidebar as a
library named `smoke-library`.

### 6. A smoke run killed a real import mid-flight

`script/smoke-run.sh` sets `QUIT_ON_EXIT=1` and its `cleanup` trap calls
`quit_app` unconditionally — `osascript … quit`, then `kill` on the PID it
launched. It has no notion of the app being busy.

On 2026-08-05 this terminated a user-initiated import of 344 files / 9.1 GB after
62 had settled, leaving 7 `active_file_operation` rows in `copying` and 7
`.otos-import-staging` files in the destination.

The durable journal did its job. On relaunch, recovery logged all seven as
`phase=copying stagingExists=true finalExists=false`, deleted the staging files,
and cleared the rows; the replan then saw the 62 as preexisting
(`copyCount=282 skipCount=1436`) and the rerun completed
`expectedPublished=282 storedBatchCount=282 failed=0 blocked=0`. 62 + 282 = 344,
with nothing lost, duplicated, or half-published.

**That recovery is not a reason to leave the script as it is.** It is the reason
the incident cost nothing this time. The script reached for `kill` on an
application that was actively writing the user's files; correctness came from
ARC-048's journal, not from the tool behaving reasonably.

### Not this repo's leak — do not "fix" these

`~/Library/Preferences` also holds 621 `OtosStudioPreferencesInfrastructureTests-*`
(dated 2026-04-30 → 05-21) and 163 `TestDefaults-*` (newest 2026-04-02, oldest
2025-07-21). Neither string appears anywhere in this repository's sources. They
are stale artifacts of other projects on the same machine. Stage 7 lists them for
one-time cleanup; no code change here prevents or causes them.

## Root cause

**Every production data location is an ambient default, so "production" is what
you get when you say nothing.**

Three of them:

| Location | Default | Resolves to, in the test host |
| --- | --- | --- |
| `CatalogStore.Location` (`CatalogStore.swift:233`) | `.application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos")` | the production catalog + thumbnails |
| `ImportPreferencesStore.load/save` (`MediaCompanionModels.swift:156,175`) | `.standard` | the production preferences domain |
| `CatalogWindowViewModel.gridColumnCountDefaults` (`CatalogWindowViewModel.swift`) | `.standard` | the production preferences domain |

plus one hardcoded reach: `MediaOperationCoordinator.swift:809,823` uses
`UserDefaults.standard` directly, with no seam at all.

`Bundle.main` is the app for a hosted test bundle, so none of these defaults can
tell "app" from "test". Deleting leftover files after the fact would leave the
mechanism intact; the fix is to remove the defaults.

Evidence 5 and 6 share a second, smaller root cause: **the smoke tooling assumes
it owns the app.** It adds roots as if it were the user, and it kills the process
as if nothing else could be happening. Both assumptions are false the moment the
smoke target is the production library — which is exactly the case the tooling
exists to serve.

## Design

**Production data locations are constructed once, by name, at the app entry
point. Nothing else may default to them.**

- A type that needs a data location takes it as a parameter with **no default
  value**. Omitting it becomes a compile error, so a test physically cannot
  reach production data by forgetting something.
- `OtosApp` is the only place that names the production catalog location and
  `UserDefaults.standard`.
- The hosted test app does not start the product stack at all (Stage 1). Tests
  build their own stores; there is no reason for a second, production-pointed
  one to exist in the process.
- Test support vends temporary `UserDefaults` through a holder that removes the
  domain in `deinit`, so cleanup does not depend on anyone remembering `defer`.
- `script/verify.sh` fails if a test run changed production data. That is what
  keeps this fixed after the implementer moves on.

For smoke runs, the same rule applied to the user's *configuration* rather than
their bytes: a smoke run may **select** an existing root and let the app do its
own work against it, but may not **add**, remove, or re-map anything.

### Why not just delete the stray files in a teardown hook

That is the band-aid this plan exists to avoid. It leaves `CatalogStore()` still
resolving to the production catalog, so the next test someone writes without an
explicit location silently scans a 16,159-file cloud library again. Removing the
defaults makes the mistake unrepresentable; deleting files makes it invisible.

### Why not a runtime "am I under XCTest?" check instead

Detecting `XCTestConfigurationFilePath` and swapping locations is one line, but
it puts the safety property in a runtime branch that only holds if every future
data location remembers to consult it. The compile-time version needs no such
discipline. Stage 5 does add one such check, deliberately narrow: a single
assertion in the one production factory, as a tripwire for a future ambient
default that someone adds without reading this plan. It is a backstop, not the
mechanism.

## Stage 1 — Stop the hosted test app from starting the product stack

The test host launches the app. The app should come up inert under test.

**Files:** `Otos/OtosApp.swift`.

**Work:**

1. Add one nonisolated helper that answers whether this process is a test run,
   from `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`.
   Put it beside `RunContext` (`Otos/Support/`), with a comment saying why it
   exists and that it must never be used to change product behavior — only to
   decline starting it.
2. In the `Window` scene's `.task`, return immediately when that is true, before
   `catalogViewModel.start()`. Do not construct the view model lazily or
   restructure the scene; the `@State` initializer must also stop reaching for
   production data, which Stage 2 handles.

**Done when:**

- `script/test.sh` produces no `op=catalog.scan phase=start` line naming any root
  under `~/Library/CloudStorage` or `/Volumes`.
- The production catalog's mtime is unchanged across a test run (measure exactly
  as in Evidence 2).
- `script/smoke-run.sh` and a normal `open -a Otos` still start normally.

## Stage 2 — Remove the production defaults

**Files:** `Otos/Stores/CatalogStore.swift`, `Otos/Models/MediaCompanionModels.swift`,
`Otos/ViewModels/CatalogWindowViewModel.swift`,
`Otos/Services/MediaOperationCoordinator.swift`, `Otos/OtosApp.swift`, plus every
call site the compiler flags.

**Work:**

1. Delete the default value from `CatalogStore.init(location:)`. Callers must
   state a location.
2. Delete the `= .standard` defaults from `ImportPreferencesStore.load(defaults:)`
   and `save(_:defaults:)`.
3. Delete the `= .standard` default from `CatalogWindowViewModel`'s
   `gridColumnCountDefaults`, and rename it `preferences` — it no longer holds
   only the grid column count once step 4 lands.
4. Give `MediaOperationCoordinator` a `preferences: UserDefaults` init parameter
   with no default, and replace both `UserDefaults.standard` uses
   (`:809`, `:823`) with it. Thread the same instance into the
   `ImportPreferencesStore.load(defaults:)` call in `buildPlan`. The ViewModel
   passes its own `preferences` down when it constructs the coordinator.
5. In `OtosApp`, construct the view model with the production catalog location
   and `UserDefaults.standard`, named explicitly, in one place.

Do **not** introduce an `AppDataEnvironment`/`Dependencies` container type. There
are two values and one construction site; a container would add a layer without
removing complexity, and CLAUDE.md rules it out until a verified requirement
needs it.

**Done when:**

- `grep -rn "UserDefaults.standard" Otos/` returns exactly one hit, in `OtosApp.swift`.
- `grep -rn "Bundle.main.bundleIdentifier" Otos/` returns at most one hit, in
  `OtosApp.swift`.
- The build fails if you delete the arguments at any call site. Verify by trying
  it once, then restoring.
- Every existing test still passes **unmodified except for the new required
  arguments**. If a test's behavior changes, you have changed product behavior;
  stop and work out why.

## Stage 3 — Temporary defaults that clean themselves up

**Files:** new `OtosTests/TemporaryDefaults.swift`;
`OtosTests/CatalogWindowViewModelGridZoomTests.swift`,
`CatalogWindowViewModelSelectionTests.swift`,
`CatalogWindowViewModelViewModeTests.swift`,
`MediaCompanionInventoryTests.swift`, and any test the compiler now forces to
pass `preferences`.

**Work:**

1. Add a `final class TemporaryDefaults` holding a UUID-suffixed suite name and
   its `UserDefaults`, which calls `removePersistentDomain(forName:)` in `deinit`.
   `deinit` runs even when a test throws or a `#require` fails, which is why this
   is a class and not a `defer` convention.
2. Replace `isolatedDefaults()` and the three inline
   `UserDefaults(suiteName: "…\(UUID())")!` constructions with it.
3. Give `MediaOperationCoordinatorTests` a `TemporaryDefaults` and pass it as the
   coordinator's `preferences`.
4. Use a suite prefix that a script can match exactly, e.g.
   `net.melisma.OtosTests.<test-name>.<uuid>`. Stage 4 greps for it.

**Done when:**

- `ls ~/Library/Preferences | grep -c "net.melisma.Otos"` returns the same number
  before and after a full `script/test.sh` run.
- No test constructs `UserDefaults(suiteName:)` directly.

## Stage 4 — Make `verify.sh` enforce it

Without this the invariant decays the first time someone adds a test.

**Files:** new `script/check-production-data-untouched.sh`; `script/verify.sh`;
`script/lib/` if a helper fits there.

**Work:**

1. The new script takes a `--before` / `--after` mode. `--before` records, to a
   file under the repo's ignored scratch area: the production catalog's mtime and
   size if it exists, and the sorted list of `~/Library/Preferences` entries
   matching `net.melisma.Otos*`.
2. `--after` re-reads both and exits non-zero, with a diff in the message, if
   either changed. Name the offending files; "something changed" is not
   actionable at 2 a.m.
3. Wire it into `script/verify.sh` around the test step. A missing production
   catalog (a fresh machine, or CI) is a pass, not a failure — record "absent"
   and require it to still be absent.
4. Add it to the script inventory that CI checks.

**Done when:**

- `script/verify.sh` is green on a clean tree.
- Reverting Stage 1 makes it fail, and the failure message names the catalog.
- Reverting Stage 3 makes it fail, and the failure message names the leaked
  preference domains.

Verify both of those by actually reverting, running, and restoring. A guard that
has never failed has not been tested.

## Stage 5 — The tripwire

**Files:** `Otos/OtosApp.swift` (or wherever Stage 2 step 5 put the production
construction).

**Work:** at the single production construction site, `assert` that the test
environment variable from Stage 1 is absent. Comment it as a backstop for a
future ambient default, and note that Stage 4 is the real guard. Use `assert`,
not `precondition` — a release build must not carry it.

**Done when:** deliberately calling the production factory from a scratch test
trips the assertion. Delete the scratch test afterwards.

## Stage 6 — Smoke runs stop mutating configuration

**Files:** `Otos/Support/SmokeLibrarySeed.swift` (renamed),
`Otos/OtosApp.swift`, `script/smoke-run.sh`, `script/build_and_run.sh`.

**Work:**

1. Rename the type to `SmokeLibrarySelection` and change its behavior: resolve
   the configured path against the roots the store already has, and **select**
   it. If the path is not an already-saved root, log an error naming the
   registered roots and select nothing. It must never call `ensureLibrary`.
2. Rename the environment variable to `OTOS_SMOKE_SELECT_ROOT` so an old exported
   value cannot silently keep the old meaning, and update both scripts.
3. Wrap the whole seam in `#if DEBUG`. A release build should not contain a way
   for an environment variable to steer the catalog at all.
4. Update `script/smoke-run.sh`'s usage text: it already insists on an explicit
   root, and should now also say the root must already be registered, and that a
   smoke run never adds one.

This keeps exactly what the user wants — smoke runs against the real 16,159-file
library, exercising scan, enrichment, materialization, and import planning —
while making it structurally impossible for a smoke run to change what libraries
exist.

**Done when:**

- `script/smoke-run.sh --verify "<an existing root>"` still passes.
- Pointing it at a path that is not a registered root fails with a message
  listing the registered roots, and `SELECT COUNT(*) FROM library_root` is
  unchanged.
- `grep -rn "ensureLibrary" Otos/Support/` returns nothing.

## Stage 6b — Smoke runs stop destroying in-progress work

A smoke run that may not change the user's configuration must equally not
terminate work the user started. See Evidence 6: the cleanup trap killed a live
9.1 GB import.

**Files:** `Otos/Services/MediaOperationCoordinator.swift` (read-only query),
`Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift`,
`Otos/OtosApp.swift`, `script/smoke-run.sh`.

**Design.** The script cannot answer "is the app busy?" by inspecting a process.
The app already owns that fact — `MediaOperationCoordinator.executing` is exactly
the set of sources with an executor in flight — so the app must publish it and the
script must read it. Do not approximate this in bash by grepping logs or counting
journal rows: the journal is a durability record, not a liveness signal, and a
script that guesses will eventually guess wrong while 9 GB is in flight.

**Work:**

1. Emit a heartbeat the script can read without any IPC machinery: extend the
   existing session logging so the coordinator logs
   `op=import.activity phase=started|finished rootPath=…` around the window in
   which `executing` is non-empty. One line each way; do not add a per-file
   heartbeat.
2. In `script/smoke-run.sh`, replace the unconditional `quit_app` in `cleanup`
   with: ask the app to quit; if an import is in flight, do not, and instead print
   the source path and leave the app running with a non-zero exit and a message
   saying the smoke run is incomplete because an import was active. Never `kill`
   a process that reported an active import — the fallback `kill` is what turned a
   graceful-quit request into a mid-copy termination.
3. Refuse to *start* a `--jank` smoke run when an import is already active, for
   the same reason. Fail with the same message.

**Done when:**

- Starting an import and then running `script/smoke-run.sh --jank <root>` exits
  non-zero without launching, and names the active source.
- Starting an import *during* a smoke run leaves the app alive at script exit, and
  the import completes normally. Verify against the real card, and check
  `SELECT COUNT(*) FROM active_file_operation` is 0 afterwards with no
  `.otos-import-staging` files left in the destination.
- With no import running, cleanup still quits the app exactly as it does today.

**What this stage does not do.** It does not make the app resilient to being
killed — it already is, and Evidence 6 documents the recovery ladder working end
to end on 344 real files. This stage stops our own tooling from exercising that
ladder on the user's data by accident.

## Stage 7 — One-time cleanup of what already leaked

Code changes do not remove what is already on disk. These are the user's files;
**do not run these as part of the implementation.** Put them in the PR
description for the user to run when they choose.

1. Remove the dead `smoke-library` root through the product UI: Settings →
   Libraries → select `smoke-library` → remove. Use the UI, not SQL — removing a
   root has an overlay-purge lifecycle that the app owns.
2. Delete this repo's leaked preference domains:

   ```bash
   find ~/Library/Preferences -maxdepth 1 -name 'net.melisma.Otos.tests.*.plist' -delete
   ```

   Note the `.tests.` in the pattern. `net.melisma.Otos.plist` is the real app's
   preferences and must not be touched.
3. Optionally, the stale non-Otos domains from other projects (621
   `OtosStudioPreferencesInfrastructureTests-*`, 163 `TestDefaults-*`). Unrelated
   to this repository; listed only because they were found during the same
   investigation.

## Requirements, ADRs, and docs

- `docs/requirements.md`: no new rows. This is test and tooling isolation, and
  CLAUDE.md keeps process/tooling rows out of the registry. Stage 6 does change
  implemented behavior of a shipped seam — if `SmokeLibrarySelection` survives as
  product-visible behavior at all, it belongs in an ADR, not a requirement row;
  see below.
- `docs/adr/`: add one ADR for the ownership decision — "production data
  locations are named once at the entry point and never defaulted" — including
  the rejected alternatives (teardown hooks, runtime XCTest detection as the
  mechanism, a dependency-container type). The smoke seam's read-only,
  DEBUG-only, never-interrupt contract belongs in the same ADR: it is one
  decision about what developer tooling may do to a production install.
- `docs/architecture.md`: update the ownership table if Stage 2 changes who
  constructs `CatalogStore`.
- Delete this plan file when all stages have landed.

## Sequencing

Stages 1 → 2 → 3 → 4 in order; 4 depends on 1 and 3 to be provable. Stage 5 after
2. Stages 6 and 6b are independent of the rest and of each other, and may land
first if that is more convenient. Stage 7 is the user's, after everything else has
merged.

Land them as separate PRs. Stage 2 will touch many call sites and should not be
reviewed in the same diff as Stage 1's one-line guard.

**Do Stage 6b early if any smoke run is planned against a production library
before this plan finishes.** It is the only stage that protects data the user
cannot get back by re-running something.

## What "done" means for the whole plan

Run this, and get identical output on both sides:

```bash
ls ~/Library/Preferences | grep -c 'net.melisma.Otos'
stat -f '%Sm %z' -t '%F %T' "$HOME/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite"
sqlite3 -readonly "$HOME/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite" 'SELECT COUNT(*) FROM library_root;'
./script/verify.sh
# …repeat the three reads…
```

and `script/verify.sh` itself fails if that is ever not true again.
