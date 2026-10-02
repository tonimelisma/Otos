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
  debuggable app. The build disables code coverage (Xcode 27 enables it for Debug
  by default; the instrumented binary writes `default.profraw` into its working
  directory) and the preview debug dylib. `CFBundleVersion` is the commit count of
  the installed commit; the install refuses a dirty tree.
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
- **Every app-changing increment installs.** The Definition of Done runs
  `script/install.sh` from `main` after merge.

## Rejected alternatives

- **Release build.** Optimized, but drops `get-task-allow` and `#if DEBUG`
  diagnostics; the owner accepted Debug performance.
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
