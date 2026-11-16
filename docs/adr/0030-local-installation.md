# 0030 — The installed app is a debuggable Debug build with its own identity

Status: accepted.

## Context

Otos is used day to day from `/Applications`, not only launched by scripts. Every
problem met there must stay fully diagnosable by the agent: debugger and
Instruments attach, every `#if DEBUG` diagnostic, and logs readable after the fact.
Dev builds keep running alongside it, from branches whose catalog schema may be
newer than the installed app's. The Store refuses a future schema without erasing
it (ENR-004), so two builds sharing one Application Support folder would let an
unmerged branch lock the installed app out of its own catalog. Two processes on one
catalog would also give one database two `CatalogStore` owners.

## Decision

- **Two identities.** The app target's bundle id is
  `net.melisma.Otos$(OTOS_BUNDLE_ID_SUFFIX)`. Debug sets the suffix to `.dev`;
  `script/install.sh` builds with it empty. Data locations already derive from the
  bundle id (ADR 0020), so the installed app owns
  `~/Library/Application Support/net.melisma.Otos` and its preferences and TCC
  grants, and dev builds own `net.melisma.Otos.dev`. The log subsystem stays the
  constant `net.melisma.Otos` (ADR 0015) for both.
- **Debug, built — not archived.** `script/install.sh` runs a plain Debug
  `xcodebuild build` into `build/InstallDerivedData`. Debug keeps
  `com.apple.security.get-task-allow`, without which hardened runtime blocks lldb
  and `xctrace` attach. `xcodebuild archive` was measured to strip that entitlement
  even when an explicit entitlements file sets it, so an archive cannot produce a
  debuggable app. It compiles with `SWIFT_OPTIMIZATION_LEVEL=-O`. That is still the Debug
  configuration, so `get-task-allow` (checked by the install) and every `#if DEBUG` path
  stay; only the code is optimized. Unoptimized, the window's own Swift work was most of
  a click. On a generated owner-shaped catalog, All Media's order read took about
  1.8 s unoptimized and 0.2 s at `-O`: the rows 0.65–0.76 s against 0.07 s, the stack rule
  0.25–0.39 s against 0.02 s, the collapse 0.2–0.55 s against 0.04 s, the position index
  0.23–0.33 s against 0.02 s (`docs/research/2026-11-16-window-reads-owner-catalog.md`). Dev builds and
  the tests stay unoptimized: the Swift 6 compiler crashed compiling the test target at
  `-O`. The build disables code coverage (Xcode 27 enables it for Debug
  by default; the instrumented binary writes `default.profraw` into its working
  directory) and the preview debug dylib. `CFBundleVersion` is the commit count of
  the installed commit; the install refuses a dirty tree, and refuses a build whose
  tree changed during it. One install runs at a time: a second waits for the first to
  exit, then builds its own HEAD (ADR 0044's build-folder hold).
- **Symbols live with the build.** The installed binary's debug map points at
  object files in `build/InstallDerivedData`, which only the next install
  overwrites — the same step that replaces the binary. No separate symbol store.
- **Logs persist.** `Config/Otos-Info.plist` carries an `OSLogPreferences` profile
  (`man 5 os_log`) enabling and persisting `.debug` and above for the subsystem.
- **Installing never interrupts work.** If the installed app is running and the
  operational journal shows an import or reorganization in flight (ADR 0020's busy
  predicate), the install stops and reports `phase=pending`. Otherwise it sends a
  normal Quit, waits for exit, swaps the bundle by rename, registers it with
  LaunchServices, and relaunches it in the background. It never kills the app.
- **One bundle carries the product identity.** The install moves the built
  bundle into `/Applications` rather than copying it, and unregisters every other
  LaunchServices registration of `net.melisma.Otos`. Otherwise a launch by bundle
  id can start a stale build against the installed app's catalog: on 2026-10-01 a
  Sep 22 Xcode build did, and its import failed with `database is locked` beside
  the running installed app.
- **Every app-changing increment installs.** The Definition of Done runs
  `script/install.sh` from `main` after merge.

## Rejected alternatives

- **Release build.** Optimized, but drops `get-task-allow` and `#if DEBUG`
  diagnostics. A Debug build compiled with `-O` is optimized and keeps both.
- **An unoptimized Debug build.** Kept every diagnostic, but its Swift work was six to ten
  times the optimized build's on the window's hottest path (above).
- **`xcodebuild archive` + dSYM archive.** Cannot keep `get-task-allow` (measured).
- **One shared identity.** Schema lock-out and two catalog owners, above.
- **Developer ID signing and notarization.** Needed only for other Macs; a locally
  built app carries no quarantine flag.

## Consequences

- A dev catalog starts empty unless seeded; it was seeded once from the existing
  data with an APFS clone.
- Dev scripts still refuse to launch while any process named `Otos` runs,
  including the installed app, because their log predicates match by process name.
- A pending install leaves the previous build installed until the next run.

## Defers

- Data locations and the smoke seam — ADR 0020. Logging levels and facade — ADR 0015.
