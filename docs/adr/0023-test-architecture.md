# ADR 0023 — Test architecture: an OtosKit framework, an unhosted bundle, and an in-memory preference store

## Status

Accepted.

## Context

`OtosTests` was a **hosted** bundle: `TEST_HOST` launched `Otos.app`, so `@main
struct OtosApp` and a live `NSApplication` run loop existed inside every test
process. ADR 0020 named the reason plainly — the app was launched "to get a
process to attach to" — and explicitly deferred this arrangement to a future
ADR. Research (`docs/research/2026-08-16-unhosted-test-bundle-capability.md`,
11 archived runs plus three feasibility probes) measured three consequences,
all traceable to hosting:

1. **The main actor was the bottleneck, not the work.** `@MainActor` suites
   averaged 2.80 s/test; `nonisolated` suites averaged 0.59 s, and every
   `nonisolated` suite specifically averaged 0.00 s. `MediaAssetTilePresentation`
   (27 pure string-formatting tests) averaged 3.05 s/test purely from inheriting
   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the equivalent already-`nonisolated`
   `ImportBarPresentation` (36 tests) averaged 0.00 s. Summed test duration was
   constant (620–860 s) across every archived run; only achieved concurrency
   varied, from 0.5x to 39x, which is where "`verify.sh` takes 15 minutes"
   actually came from — two of eleven runs collapsed to 703 s and 1534 s while
   steady state was ~96 s.
2. **The hosting hazard needed policing.** Because the app ran in-process, it
   could reach production data, so `RunContext.isTestRun`, `TemporaryDefaults`,
   68 hand-written `defer`s, a formally-accepted plist leak, and two shell
   scripts (`script/check-production-data-untouched.sh`,
   `script/purge-test-preference-domains.sh`) existed to prevent it. 1,343
   leaked preference domains were present on 2026-08-16, costing ~21 s per
   `verify.sh` run before even reaching the leak's actual cause.
3. **The leak's cause was `PreferencesDomain.suite` minting a real
   `UserDefaults(suiteName:)`.** Every `.suite(<unique>)` domain — one per test
   — wrote a real cfprefsd-backed plist, regardless of hosting.

## Decision

**Otos.app links an OtosKit framework instead of containing the application
directly, and OtosTests links OtosKit instead of hosting Otos.app.**

- `OtosXXH3` (new static-library target) owns the vendored C hashing —
  `Otos/Support/OtosXXH3.{h,c}` and `Otos/Vendor/xxHash-0.8.3/xxhash.{h,c}`.
  It exists first because a framework target cannot use a bridging header,
  and `Otos`'s bridging header named exactly these files.
- `OtosKit` (new framework target) owns essentially all application Swift
  source — everything the dataflow map in `docs/architecture.md` describes.
  It links `OtosXXH3`, GRDB, and MediaMetadata. `OtosApp` is its sole public
  type (`public struct OtosApp: App`); the codebase had zero `public`
  declarations before this and has exactly one now.
- `Otos` (the app target) shrinks to `main.swift` (`import OtosKit; import
  SwiftUI; OtosApp.main()`) plus `Assets.xcassets`. It links and embeds
  OtosKit.
- `OtosTests` drops `TEST_HOST`/`BUNDLE_LOADER`, links OtosKit directly (not
  embedded), and every test file's `@testable import Otos` becomes `@testable
  import OtosKit` — the app module has nothing left to test.
- No source or test file moved on disk. Every file above compiled in the same
  directory before and after; only Xcode target membership changed, via the
  Xcode 16+ synchronized-group exception-set mechanism (a per-target
  exclusion list layered onto a shared synced folder) rather than classic
  file references.

**Pure value-in/value-out types are marked `nonisolated` instead of
inheriting `MainActor`.** `MediaAssetTilePresentation`, `BrowserViewMode`,
`MediaGridClipboard`, and `MediaGridPresentation` no longer pay main-actor
queueing for work that touches no UI state.
`placeholderIcon`/`placeholderIconCache` (the one genuinely main-actor-confined
member — it caches `NSImage`) stays `@MainActor` as an explicit override on
the otherwise-`nonisolated` type. This is deliberately narrow: the plan's own
instruction was "if a type cannot be made `nonisolated` without touching UI
state, leave it alone and note why" — `LoupeVideoPlayerView`
(`NSViewRepresentable`) and `PaneThumbnailView` (a SwiftUI `View`) are real UI
and stay `@MainActor`.

**`UserDefaults` is reached through a `PreferenceStore` protocol, and
`PreferencesDomain.suite` domains are in-memory.** The protocol surface (7
methods — `object`, `string`, `integer`, `bool`, `dictionary`, `set`,
`removeObject`) was confirmed by grepping every call site actually in use
(`grep -rhoE '\(preferences|defaults\)\.[a-zA-Z]+\(' Otos`), not assumed.
`UserDefaults` conforms with zero extra code. `.standard` still returns the
real `UserDefaults.standard` singleton. `.suite(name)` now returns a
name-keyed, in-memory store (`InMemorySuitePreferenceStore`, backed by five
`Synchronization.Mutex`-protected slots — one per concrete type this codebase
stores: `Bool`, `Int`, `Double`, `String`, `[String: String]`) instead of a
real `UserDefaults(suiteName:)`. `PreferencesDomain.makeDefaults()` lives in
`Otos/Models/PreferenceStore.swift`, next to the store implementations it
chooses between, rather than in the test target: `PreferencesDomainTests`
proves that two independently-constructed actors given "the same domain" (by
name, not by object reference) must observe each other's writes, which only a
registry inside `makeDefaults()` itself — reachable identically from both app
and test construction sites — can preserve without rewiring how every
consumer is wired together. `OtosTests/TemporaryDefaults.swift` and all 68
`defer { cleanUp() }` call sites are gone: an in-memory domain needs no
cleanup.

**`script/verify.sh` no longer polices what it no longer needs to.**
`script/check-production-data-untouched.sh` and
`script/purge-test-preference-domains.sh` are deleted — tests cannot reach
production data (they never launch the app, and preferences are in-memory).
`script/build.sh` runs `build-for-testing` and `script/test.sh` runs
`test-without-building` instead of a plain `build` followed by a
self-contained `test` (which duplicated the compile). The static gates
(the seven `guard-*.sh` scripts and their self-tests, `check-doc-citations.sh`,
`lint.sh`) run in a background job while the build compiles in the
foreground, since none of them touch `build/DerivedData` or Xcode state.
`requirements-authority-check.sh self-test` — identical output every run,
~15.5 s — only runs when that script itself differs from `origin/main`.

## Rejected alternatives

- **Fix the bridging header without unhosting.** Increment 2's own attempt
  proved this insufficient: the full suite crashed broadly and
  non-deterministically inside Swift Testing's own runtime
  (`Runner._applyScopingTraits`) once `OtosKit` existed but the bundle stayed
  hosted — confirmed by bisection (unhosting alone, as a diagnostic probe,
  eliminated the crash: 738 pass / 1 fail / 0 crashes unhosted vs. dozens of
  restart-exhausted crashes hosted). A framework-shaped app and a hosted test
  bundle are incompatible in this toolchain; increments 2 and 3 landed
  together for exactly this reason.
- **Split into `OtosCore` + `OtosUI` now**, so `guard-view-passivity.sh`'s
  grep-based check could become a link-time fact (a view target that never
  links GRDB cannot call SQLite). Explicitly deferred — see Defers below.
- **Real `UserDefaults` suites with better cleanup**, rather than eliminating
  cfprefsd writes at the source. Rejected on the same grounds ADR 0020 already
  rejected "clean up after the fact": a crashed or interrupted run skips its
  own cleanup, and the run that matters most is exactly the one that leaves
  debris.
- **A name-keyed `Mutex<[String: Any]>` for the in-memory store.** `Sendable`
  is a marker protocol with no runtime witness table — an already-erased
  `Any` parameter can never be dynamically cast to `any Sendable` to prove
  itself safe to cross `Mutex.withLock`'s `sending` closure boundary (the
  compiler rejects exactly that cast: "marker protocol 'Sendable' cannot be
  used in a conditional cast"). `ARC-042` (a hard `verify.sh` gate, not a
  style preference) forbids the `@unchecked Sendable`/`nonisolated(unsafe)`
  escapes that would otherwise dodge the question. Five type-specific slots,
  each statically Sendable, sidestep it entirely.

## Consequences

- `Otos.xcodeproj` has four targets instead of two: `OtosXXH3`, `OtosKit`,
  `Otos`, `OtosTests`. `docs/architecture.md` names where each lives.
- The codebase has exactly one `public` declaration (`OtosApp`). Adding a
  second needs its own justification, same bar ADR 0020's "Consequences"
  already set for adding a data location.
- **A durable trap for future work**: any new file added under `Otos/`
  requires refreshing the exception set of *every* target that references
  the shared `Otos` synchronized-group root, not just the new file's own
  target — exceptions only *exclude*, so a file created after a target's
  exception set was last computed silently defaults into that target's
  membership too. This bit increment 5 directly: `Otos/main.swift`
  (created in increment 2) was absent from `OtosXXH3`'s increment-1
  exception list, so it silently compiled inside the C-only static-library
  target until a build error caught it.
- Xcode target creation, membership, and package-dependency wiring for this
  ADR were scripted against `project.pbxproj` with the `xcodeproj` Ruby gem
  rather than done through Xcode's GUI wizard, for a reviewable diff and
  reproducibility. Two Xcode 27 beta build-system bugs were found and routed
  around along the way: linking a sibling static-library product via a
  Frameworks-build-phase file reference corrupts a linker argument during
  the new build system's eager-linking debug-dylib step (worked around with
  explicit `OTHER_LDFLAGS`/`LIBRARY_SEARCH_PATHS`); consumers of a framework's
  transitive package/module dependencies (GRDB's `GRDBSQLite`, `OtosXXH3`)
  need those dependencies re-declared directly even where the consumer's own
  source never imports them, because Swift's explicit-module scanner
  re-resolves each consuming target's full transitive closure independently.
- Measured warm `script/verify.sh`: **36.9 s**, against the ~96 s
  steady-state baseline this ADR's Context cites and the plan's ~35 s target.
  Whether the intermittent multi-minute collapse itself is gone — as opposed
  to the steady-state cost, which unambiguously dropped — is reported
  honestly in `docs/research/`, not asserted here: ten additional runs give
  evidence, not proof, for an event that occurred twice in eleven prior runs.
- A pre-existing, unrelated test-isolation gap in `MediaOperationCoordinatorTests`/
  `MediaOperationCoordinatorAdversarialTests` (neither file touched by this
  work beyond a mechanical import rename) is now visible for the first time:
  individual tests there pass reliably in isolation but intermittently time
  out under full-suite parallel load, which hosted execution structurally
  could never produce (a hosted bundle cannot run test *processes* in true
  parallel; unhosted, `parallelizable="YES"` — already set, unchanged by this
  work — now genuinely can). Not fixed by this ADR; flagged as a follow-up.

## Defers

- **Splitting `OtosKit` into `OtosCore` and `OtosUI`**, so
  `guard-view-passivity.sh`'s grep-based check could become a link-time fact
  (a view target that does not link GRDB cannot call SQLite, and the guard
  becomes redundant). Recorded as a finding, not attempted: `OtosKit` today
  is Models + Services + Stores + Support + Views + ViewModels, undivided.
- **The `MediaOperationCoordinatorTests` parallel-load flakiness** named in
  Consequences. Its likely cause (shared state across tests newly running in
  genuinely separate processes) is diagnosable but out of this ADR's scope.
- **Where overlay lives and when it is purged** — ADR 0008, unchanged by this
  work.
- **Production data locations and the read-only smoke seam** — ADR 0020,
  unchanged in substance; only its Defers entry for test-process isolation
  now points here instead of forward.
