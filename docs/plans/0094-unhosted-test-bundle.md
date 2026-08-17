# 0094 — Unhosted Test Bundle On An OtosKit Framework

## Read first

- `docs/research/2026-08-16-unhosted-test-bundle-capability.md` — the measurements
  and the three probes this plan rests on. Read it before starting; every number
  quoted below comes from there.
- `docs/adr/0020-production-data-locations-and-the-developer-smoke-seam.md` — its
  **Defers** section explicitly leaves the hosted-bundle arrangement open. This plan
  closes that deferral. ADR 0020 is not wrong and is not being overturned; it owns
  data locations and keeps owning them.

This plan assumes no prior context. Every increment states its goal, the exact
steps, how to verify, and how to roll back.

## What is wrong today

`OtosTests` is a **hosted** bundle: `TEST_HOST` launches `Otos.app`, so
`@main struct OtosApp` and a live `NSApplication` run loop exist inside every test
process. The comment at `Otos/OtosApp.swift:52` states the reason plainly — the app
is launched "to get a process to attach to."

Three consequences, all measured:

1. **The main actor is the bottleneck.** `@MainActor` suites average **2.80 s per
   test**; `nonisolated` suites average **0.59 s**. Every `nonisolated` suite
   averages 0.00 s. `MediaAssetTilePresentationTests` — 27 pure string-formatting
   assertions — averages **3.05 s**, while the equivalent
   `nonisolated enum ImportBarPresentation` runs 36 tests in **0.00 s**.
2. **Concurrency collapses intermittently.** Summed test duration is constant
   (620–860 s) across all 11 archived runs, but elapsed time swings from 18 s to
   **1534 s**. That collapse, not steady-state cost, is the "15 minute" `verify.sh`.
3. **The hosting hazard needs policing.** Because the app runs in-process, it could
   reach production data, so `RunContext.isTestRun`, `TemporaryDefaults`, 68
   hand-written `defer`s, a formally-accepted plist leak, and two shell scripts
   exist to prevent it. 1,343 leaked preference domains were present on 2026-08-16;
   they cost ~21 s per `verify.sh` run.

The research proved **no Otos test needs an app host**: 14/14 AppKit capabilities
and 9/9 grid-layout assertions pass in a non-bundled process. The only unavailable
behaviour is `isKeyWindow == true`, which no test asserts.

## Constraints that bound every increment

These are discovered facts, not preferences. Violating one breaks the build or the
docs gates.

| # | Constraint | Why |
| --- | --- | --- |
| C1 | **No source or test file moves on disk.** | 799 doc references point at `Otos/…` paths (360 in `docs/requirements.md`, 439 across `docs/`), and 299 requirement citations name `OtosTests/<file>.swift#<test>`. `script/requirements-authority-check.sh` resolves them. Xcode target membership is independent of directory layout. |
| C2 | **The test directory stays named `OtosTests/`.** | Same 299 citations. |
| C3 | **The C bridging header must become a module before any framework exists.** | `SWIFT_OBJC_BRIDGING_HEADER = Otos/Support/OtosXXH3.h` — framework targets cannot use bridging headers. |
| C4 | **A guard script may only be deleted in the same PR that re-points its requirement row.** | ARC-001, ARC-002, ARC-002A, ARC-011, ARC-014, ARC-015, MED-004 cite `` `script/guard-*.sh#self-test` `` as their only verifying test. |
| C5 | **Increments 1–7 are code increments** and need full `script/verify.sh` plus the normal PR path. Only increment 8's doc updates are doc-only. |
| C6 | **`docs/requirements.md` gets no new rows for this work.** | CLAUDE.md: "Do not add process, workflow, or tooling rows." |

## Target end state

```
Otos.xcodeproj
├── OtosXXH3      (C sources, module map)        ← new, increment 1
├── OtosKit       (framework, 125 Swift files)   ← new, increment 2
│                 depends on OtosXXH3, GRDB, MediaMetadata
├── Otos.app      (main.swift + Assets.xcassets) ← shrinks to ~3 lines of Swift
│                 links + embeds OtosKit
└── OtosTests     (unhosted, links OtosKit)      ← TEST_HOST removed, increment 3
```

Files stay exactly where they are on disk (C1). Only target membership changes.

---

## Increment 1 — Give the vendored C its own module

**Goal.** Remove `SWIFT_OBJC_BRIDGING_HEADER` from the equation so a framework
target becomes possible (C3).

**Files involved (none move):** `Otos/Support/OtosXXH3.h`,
`Otos/Support/OtosXXH3.c`, `Otos/Vendor/xxHash-0.8.3/xxhash.c`,
`Otos/Vendor/xxHash-0.8.3/xxhash.h`.

**Steps.**

1. In Xcode: **File ▸ New ▸ Target ▸ macOS ▸ Library**. Name it `OtosXXH3`, type
   **Static Library**, language **C**. Xcode creates a stub `OtosXXH3.c`/`.h` in a
   new folder — **delete those stub files from disk and from the target**.
2. Select the four real C files above in the Project navigator. In the File
   Inspector, set **Target Membership** to `OtosXXH3` only (uncheck `Otos`).
3. Create `Otos/Support/module.modulemap`:

   ```
   module OtosXXH3 {
       header "OtosXXH3.h"
       export *
   }
   ```

4. On the `OtosXXH3` target, set:
   - `MODULEMAP_FILE = Otos/Support/module.modulemap`
   - `HEADER_SEARCH_PATHS = $(SRCROOT)/Otos/Vendor/xxHash-0.8.3`
   - `DEFINES_MODULE = YES`
5. On the `Otos` app target: **delete** the `SWIFT_OBJC_BRIDGING_HEADER` setting
   (Debug and Release), and add `OtosXXH3` under **Frameworks and Libraries**.
6. Add `import OtosXXH3` to the one Swift file that calls the C symbols:
   `Otos/Services/ContentHasher.swift`.

**Verify.**

```bash
script/verify.sh
```

`OtosTests/ContentHasherTests.swift` is the behavioural oracle — it must pass
unmodified. Confirm the setting is gone:

```bash
grep -c SWIFT_OBJC_BRIDGING_HEADER Otos.xcodeproj/project.pbxproj
```

Expect `0`.

**Rollback.** Revert the commit; nothing outside the project file and one `import`
line changed.

**Done when** `verify.sh` is green and no bridging header remains.

---

## Increment 2 — Create the OtosKit framework

**Goal.** Move all Swift source into a framework the app links, so a test bundle can
link it without an app host. No files move on disk (C1).

**Steps.**

1. **File ▸ New ▸ Target ▸ macOS ▸ Framework**, name `OtosKit`. Delete the stub
   `OtosKit.swift`/`.h` Xcode generates.
2. Select **all** `.swift` files under `Otos/` in the Project navigator. Set Target
   Membership to `OtosKit` only (uncheck `Otos`). This includes `OtosApp.swift` and
   `ContentView.swift`. `Assets.xcassets` stays on the `Otos` app target.
3. On `OtosKit`, set:
   - `SWIFT_APPROACHABLE_CONCURRENCY = YES`
   - `SWIFT_STRICT_CONCURRENCY = complete`
   - `SWIFT_VERSION = 6.0`
   - `MACOSX_DEPLOYMENT_TARGET = 27.0`
   - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (unchanged for now; increment 4
     revisits it)
   - `DEFINES_MODULE = YES`
   - `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`
4. Add `OtosXXH3`, `GRDB`, and `MediaMetadata` to `OtosKit`'s **Frameworks and
   Libraries**; remove GRDB and MediaMetadata from the `Otos` app target.
5. **Turn `OtosApp` into a library type with a shim entry point.** This keeps the
   public API surface to exactly one type instead of twelve. In
   `Otos/OtosApp.swift`:
   - delete the `@main` attribute
   - change `struct OtosApp: App` to `public struct OtosApp: App`
   - add `public init() {}`

   Then create a new file `Otos/main.swift`, target membership `Otos` **only**:

   ```swift
   import OtosKit

   OtosApp.main()
   ```

   > Why the shim: `OtosApp.swift` references `CatalogWindowViewModel`,
   > `CatalogStore`, `PreferencesDomain`, `ContentView`, `SettingsView`,
   > `RunContext`, `OtosSignpost`, `OtosLog`, `SmokeLibrarySelection`,
   > `MediaChoice`, `GridColumnCount`, and `CatalogSortMenuContent`, plus ~35
   > members of the ViewModel. Leaving it in the app target would force all of
   > those `public`. The codebase currently has **zero** `public` declarations;
   > this keeps it at one.

6. On the `Otos` app target, add `OtosKit` to **Frameworks and Libraries** with
   **Embed & Sign**.
7. Confirm the app target's Compile Sources phase now contains only `main.swift`.

**Verify.**

```bash
script/build.sh
script/verify.sh
```

Then launch the app and confirm the window, menus, and Settings still work:

```bash
script/smoke-run.sh
```

**Rollback.** Revert the commit. The only source edits are three lines in
`OtosApp.swift` and one new `main.swift`.

**Done when** `verify.sh` is green, the app launches, and
`Otos.app/Contents/Frameworks/OtosKit.framework` exists in the build product.

> **Note.** `OtosTests` is still hosted at this point and still says
> `@testable import Otos`. It keeps working because `BUNDLE_LOADER` still resolves
> against the app, which now links OtosKit. Increment 3 cuts that cord.

---

## Increment 3 — Unhost the test bundle

**Goal.** Remove the app process — and its run loop — from every test process.

**Steps.**

1. On the `OtosTests` target, **delete** these settings in **both** Debug and
   Release:
   - `TEST_HOST`
   - `BUNDLE_LOADER`
2. Add `OtosKit` to `OtosTests` ▸ **Frameworks and Libraries** (Do Not Embed).
3. Rewrite the import in every test file (files do not move — C1/C2):

   ```bash
   grep -rl '@testable import Otos$' OtosTests | \
     xargs sed -i '' 's/@testable import Otos$/@testable import OtosKit/'
   ```

   Then confirm none were missed:

   ```bash
   grep -rn '@testable import Otos$' OtosTests | wc -l   # expect 0
   ```

4. In `Otos.xcscheme`, the Test action no longer needs the app as a host. Leave
   `parallelizable = "YES"` as it is; the research showed
   `-parallel-testing-enabled` changes nothing here (3.6 s vs 3.3 s on a 54-test
   subset), so do **not** add it.
5. Delete `RunContext.isTestRun` from `Otos/Support/RunContext.swift` and both
   branches that use it in `Otos/OtosApp.swift` (lines 24 and 55). The app can no
   longer be launched by a test, so the guard is dead code. `runKind` collapses to
   `"prod"`; no script depends on `kind=test` (verified).

**Verify.**

```bash
script/verify.sh
```

All 707 tests must pass. Then confirm the host is gone and measure the payoff:

```bash
grep -c TEST_HOST Otos.xcodeproj/project.pbxproj   # expect 0
grep -oE "on 'My Mac[^']*'" logs/test-*-test.log | tail -1
```

The test-host line should no longer name `Otos`. Record elapsed time from
`IDETestOperationsObserverDebug: <n> elapsed`; compare against the 18–56 s healthy
baseline.

**Expected failures and what they mean.**

- *"cannot find type X in scope"* — a file was left on the `Otos` target in
  increment 2. Fix its Target Membership.
- *A test that asserted on `NSApp` state* — none exist today; if one appears, it was
  added after this plan was written and needs its own decision.
- *`Bundle.main.bundleIdentifier` is now `nil` in tests* — expected. Only
  `Otos/Support/Instrumentation.swift:5` reads it, and it already falls back to
  `"net.melisma.Otos"`.

**Rollback.** Revert; re-add `TEST_HOST`/`BUNDLE_LOADER` and re-run the `sed` in
reverse.

**Done when** `verify.sh` is green with `TEST_HOST` absent.

---

## Increment 4 — Take pure logic off the main actor

**Goal.** Stop pure value-in/value-out code inheriting `MainActor` from a build
setting. This is CLAUDE.md's "MainActor gravity" smell.

**Steps.**

1. List candidate types — pure functions over value types, no UI state:

   ```bash
   grep -rln "^enum \|^struct " Otos/Models Otos/Views | \
     xargs grep -ln "static func" | sort
   ```

2. For each, mark the type `nonisolated` (the shape
   `Otos/Views/ImportBarPresentation.swift:84` already uses). Start with
   `MediaAssetTilePresentation`, which the research measured at 3.05 s/test.
3. Remove `@MainActor` from the corresponding test suites in `OtosTests/`.
4. If a type cannot be made `nonisolated` without touching UI state, **leave it
   alone and note why in the PR**. Do not force it.

**Verify.**

```bash
script/verify.sh
```

Then confirm the per-test cost moved, using the same extraction the research used:

```bash
awk '/^Test case .* seconds\)$/ {
  split($0,q,"\x27"); n=split($0,f,"("); d=f[n]; sub(/ seconds\)$/,"",d);
  print d "\t" q[2] }' logs/test-<newest>-test.log | sort -rn | head -20
```

`MediaAssetTilePresentationTests` should drop from ~3.05 s to near 0.00 s.

**Rollback.** Revert per-type; each is independent.

**Done when** `verify.sh` is green and no pure presentation type is main-isolated
without a written reason.

---

## Increment 5 — Replace `UserDefaults` with a storage protocol

**Goal.** Stop tests writing to cfprefsd. This is what actually ends the leak;
everything else was cleanup after the fact.

**Steps.**

1. Add `Otos/Models/PreferenceStore.swift`:

   ```swift
   /// The narrow key-value surface the app actually uses. Production wraps
   /// `UserDefaults`; tests use an in-memory dictionary, so no test touches
   /// cfprefsd, writes a plist, or needs cleanup.
   nonisolated protocol PreferenceStore: AnyObject, Sendable {
       func object(forKey key: String) -> Any?
       func string(forKey key: String) -> String?
       func set(_ value: Any?, forKey key: String)
       func removeObject(forKey key: String)
   }
   ```

   Confirm this is the complete surface before writing it:

   ```bash
   grep -rhoE 'defaults\.[a-zA-Z]+\(' Otos --include="*.swift" | sort -u
   ```

   Widen the protocol if that command shows more; do not guess.
2. Conform `UserDefaults` to it in an extension (all four members already exist).
3. Add an in-memory implementation to `OtosTests/` — a final class over a
   dictionary, serialised by whatever isolation its owner has.
4. Change the five concrete injection sites from `UserDefaults` to
   `any PreferenceStore`:
   - `Otos/ViewModels/CatalogWindowViewModel.swift:148`
   - `Otos/Models/MediaCompanionModels.swift:162` and `:181`
   - `Otos/Services/LibraryReorganizationRunner.swift:12`
   - `Otos/Services/MediaOperationCoordinator.swift:24`
5. `PreferencesDomain.makeDefaults()` returns `any PreferenceStore`. Keep
   `PreferencesDomain` — required non-defaulted parameters are the part of ADR 0020
   that stays.
6. **Fix the `@AppStorage` hole.** `Otos/Views/MediaGridView.swift:28` uses
   `@AppStorage("dismissedCameraConnectionBannerIdentities")`, which resolves to
   `UserDefaults.standard` because `defaultAppStorage` is injected nowhere. Replace
   it with the injected `PreferenceStore`, passed in like every other preference.
7. **Delete `OtosTests/TemporaryDefaults.swift`** and all 68 `defer { temp.cleanUp() }`
   call sites:

   ```bash
   grep -rn "TemporaryDefaults()" OtosTests | wc -l   # 68 before, 0 after
   ```

**Verify.**

```bash
script/verify.sh
ls ~/Library/Preferences/net.melisma.OtosTests.*.plist 2>/dev/null | wc -l
```

The second command must print `0` **after a full test run** — that is the whole
point of this increment. Run it twice to be sure nothing leaks on the second pass.

**Rollback.** Revert. The protocol is additive until step 4.

**Done when** a full test run leaks zero preference domains.

---

## Increment 6 — Delete the leak policing, re-point the requirement rows

**Goal.** Remove machinery whose only job was defending against increments 3 and 5.

**Steps.**

1. Delete `script/purge-test-preference-domains.sh` — nothing leaks now.
2. Delete `script/check-production-data-untouched.sh` and both call sites in
   `script/verify.sh`. Tests cannot reach production data: they do not launch the
   app, and `PreferenceStore` in tests is in-memory.
3. **Before deleting any `guard-*.sh`, re-point its requirement row (C4).** Check
   which rows are affected:

   ```bash
   grep -nE '`script/guard-[a-z-]+\.sh#self-test`' docs/requirements.md
   ```

   For each of ARC-001, ARC-002, ARC-002A, ARC-011, ARC-014, ARC-015, MED-004,
   either keep the guard or replace its verification with a real test in the same
   PR. **`guard-unsandboxed.sh` stays** — it asserts a build-configuration fact, which
   is legitimately a script's job.
4. Consider whether `guard-view-passivity.sh` can become a link-time fact by
   splitting `OtosKit` into `OtosCore` (Models/Services/Stores/Support) and
   `OtosUI` (Views/ViewModels, depending on Core). If `OtosUI` does not link GRDB, a
   view *cannot* call SQLite and the grep is redundant. **This split is optional and
   explicitly out of scope for this plan** — record the finding, do not do it here.

**Verify.**

```bash
script/verify.sh
script/requirements-authority-check.sh
```

The authority check must pass with no orphaned citations.

**Rollback.** Revert; the scripts are self-contained.

**Done when** `verify.sh` is green and every requirement row still names a test that
exists.

---

## Increment 7 — Restructure `verify.sh`

**Goal.** Remove duplicated work now that the leak policing is gone.

**Steps.**

1. Replace `build.sh` + `test.sh` with one `build-for-testing` (measured 9.9 s warm)
   followed by `test-without-building`. Running `xcodebuild build` and then
   `xcodebuild test` duplicates an invocation for no coverage.
2. Run `requirements-authority-check.sh self-test` only when that script itself has
   changed. It costs **15.5 s**, identical to the real run, and `verify.sh` pays it
   every time. The seven `guard-*.sh` self-tests together cost 0.8 s — keep those
   unconditional.
3. Run the static gates (guards, lint, doc-citations, sendable) concurrently with
   the build; they share nothing with `xcodebuild`.

**Verify.** Time it before and after:

```bash
time script/verify.sh
```

Steady state was ~96 s. Target is ~35 s.

**Rollback.** Revert `script/verify.sh`.

**Done when** `verify.sh` is green and materially faster.

---

## Increment 8 — Re-measure, then write the ADRs (doc-only)

**Goal.** Record what was built, and state honestly whether the intermittent stall
is gone.

**Steps.**

1. Run the full suite **at least 10 times** and record elapsed from
   `IDETestOperationsObserverDebug: <n> elapsed`:

   ```bash
   for i in $(seq 1 10); do script/verify.sh > /dev/null 2>&1; done
   for L in $(ls -t logs/test-*.log | head -10); do
     grep -oE "[0-9.]+ elapsed -- Testing started completed" "$L"
   done
   ```

   The pre-change distribution was 18 s, 18 s, 29 s, 28 s, 32 s, 34 s, 41 s, 41 s,
   56 s, **703 s**, **1534 s** — two collapses in eleven runs. If ten runs show no
   outlier, say that; ten clean runs is evidence, not proof, and the report must say
   so.
2. Write **ADR 0023 — Test architecture**, justifying what was built: the framework
   extraction, the unhosted bundle, and the storage protocol. It must name what it
   owns and what it defers (MECE).
3. **Rewrite** `docs/adr/0020-…` — do not append (CLAUDE.md: "never append increment
   history"). Two edits:
   - its **Defers** entry for "Test-suite process isolation mechanics" now points at
     ADR 0023
   - fold the existing `## Addendum 2026-08-06` section into the body. It is the only
     appended-history section in `docs/adr/` and violates the rule.
4. Update `docs/architecture.md` — the target split changes the code map.
5. Update `docs/requirements.md` **only** where a row's cited source files or tests
   moved target or were re-pointed. **No new rows** (C6).
6. Delete this plan file when increment 8 lands (CLAUDE.md: "Delete a plan when its
   work is fully done") and update `docs/plans/README.md`.

**Done when** the ADRs describe what exists and this file is gone.

---

## Requirements and ADRs

- **`docs/requirements.md`** — no new rows (C6). Rows change only where cited files
  changed target or a guard's verification was re-pointed (increment 6).
- **ADR 0023 (new, increment 8)** — claims the territory ADR 0020 deferred.
- **ADR 0020 (rewritten, increment 8)** — cedes test-process isolation to 0023,
  keeps required non-defaulted parameters and the read-only smoke seam, and loses
  its appended addendum.
- **`docs/architecture.md`** — updated for the target split.

## Risks

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Unhosting does not fix the intermittent collapse | Medium | It removes the *measured* main-thread competitor, which is the leading hypothesis, not a proven cause. Increment 8 re-measures over 10 runs and reports honestly either way. Increments 5–7 stand on their own regardless. |
| A test depends on `isKeyWindow` | Very low | None does today (verified across all 103 files). If one is added before this lands, it needs its own decision. |
| Public API sprawl from the framework boundary | Low | The `main.swift` shim keeps the public surface at exactly one type (`OtosApp`). The codebase has zero `public` declarations today; a PR adding more than one needs justification. |
| pbxproj merge conflicts with in-flight work | **High** | Plan 0093 (grid day headers) is the next active plan and will touch `Otos/Views`. Increments 1–3 rewrite `Otos.xcodeproj/project.pbxproj` heavily, and a project-file conflict is not resolvable by hand in any pleasant way. **Land 0093 first, or rebase this work onto it** — do not run the two in parallel. |
| Deleting a guard orphans a requirement row | Medium | C4 forbids it. `requirements-authority-check.sh` fails loudly if it happens. |
| Flaky tests confuse the before/after measurement | **High** | Seven tests have failed across recent runs with the failing set changing run to run: `CatalogStoreFilesystemEventTests.diskChangeReconcilesAfterRescan`, `…subtreeDirectoryEventReconcilesWithoutSiblingMutation`, `CatalogWindowViewModelViewModeTests.downloadingRetryDoesNotDisturbSiblingPane`, `MediaOperationCoordinatorAdversarialTests.batchPresentationSurvivesDetachAfterCleanSettle`, `MediaOperationCoordinatorTests.catalogChangeWakesWaitingForMetadataSource`, `…explicitDestinationResumesTrackingDefaultAfterItBecomesUnavailable`, `OriginalsReadOnlyTests.materializationCoordinatorLeavesOriginalTreeUnchanged`. **A red baseline blocks merge** (CLAUDE.md). Green `main` first, in its own PR. The flakes may share a root cause with the stall. |

## Sequencing

Increment 0 is not this plan — it is **greening `main`**. Seven flaky tests are a red
baseline, and CLAUDE.md blocks merging anything except the fix that greens it. Do
that first, in its own PR, and it doubles as a second data point on whether the
flakes and the stall share a cause.

Then: 1 → 2 → 3 are a single mechanical chain and must land in order. 4, 5, 6, 7 are
independent of each other and can be reordered or parallelised. 8 is last.
