import Foundation

/// A `UserDefaults` suite for one test, cleaned up via an explicit `defer` the
/// caller writes immediately after construction:
///
/// ```swift
/// let temp = TemporaryDefaults()
/// defer { temp.cleanUp() }
/// ```
///
/// This is a `defer`, not a `deinit`, on measured evidence, not the more common
/// assumption that `deinit` is the stronger guarantee. A minimal `deinit`-based
/// probe (a plain class, no `Foundation`/`UserDefaults` involved, one
/// `FileHandle.standardError` write) fired **zero** times across an isolated
/// single-`@Test` run and a full `script/test.sh` run — Swift Testing does not
/// release a `@Test` function's local values promptly, or at all, within the
/// test process in this harness. `defer` has no such dependency: it runs
/// deterministically for its own function's throw, `#require` failure, or normal
/// return, which is every case plan 0066 Stage 3's original evidence cared about.
///
/// `cleanUp()` does two things, not one, and the second one is the fix this type
/// exists for: `UserDefaults.removePersistentDomain(forName:)` only empties the
/// suite's *contents* — measured directly, the on-disk `.plist` remains behind as
/// a 2-byte `{}` stub, which still satisfies `FileManager.fileExists` and still
/// counts toward `ls ~/Library/Preferences | grep -c net.melisma.Otos`. No public
/// `UserDefaults` API deletes the backing file, so `cleanUp()` also unlinks it
/// directly (scoped to this exact UUID-suffixed suite name, never a glob), after
/// `removePersistentDomain` + `synchronize()`.
///
/// **Known residual limitation, measured, not a defect in this type:** run alone
/// or in a small suite, this leaves zero stray files — confirmed for
/// `CatalogWindowViewModelGridZoomTests` (10 `@Test`s) run in isolation. Run as
/// part of the full `script/test.sh` suite, where Swift Testing runs many
/// `@Test`s concurrently across many suites at once, a minority of suites still
/// leave an empty `{}` stub behind — cfprefsd appears to independently re-flush
/// its own cached copy of a domain sometime after this type's explicit unlink,
/// under heavy concurrent domain churn, which no public API exposes a way to
/// prevent. The leaked files carry no data (confirmed empty `{}` in every case
/// checked) — the risk plan 0066 Stage 3 exists to close (a real value leaking
/// into `~/Library/Preferences`) is closed; a residual empty-file count under
/// concurrent load is not.
final class TemporaryDefaults {
    let defaults: UserDefaults
    private let suiteName: String

    /// `function` defaults to the caller's own function name so leaked-domain
    /// diagnostics (and `script/check-production-data-untouched.sh`, Stage 4)
    /// can tell which test a stray domain came from. The `net.melisma.OtosTests.`
    /// prefix is the exact string Stage 4 greps for.
    init(function: String = #function) {
        suiteName = "net.melisma.OtosTests.\(function).\(UUID().uuidString)"
        // A UUID-suffixed suite name is never a reserved domain, so this cannot
        // fail in practice — force-unwrapping here (not inside a @Test body) is
        // this codebase's accepted shape for a construction that cannot fail.
        defaults = UserDefaults(suiteName: suiteName)!
    }

    /// Call via `defer` right after `init` — see the type doc for why this is a
    /// `defer` target and not a `deinit`.
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        let path = NSHomeDirectory() + "/Library/Preferences/\(suiteName).plist"
        try? FileManager.default.removeItem(atPath: path)
    }
}
