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
/// **Known residual, measured:** under the full concurrent suite a minority of suites leave
/// an empty `{}` stub behind — cfprefsd re-flushes its cached copy after this type's unlink,
/// which no public API prevents. An empty stub is accepted. A domain with *keys* in it is
/// never cfprefsd: it means a writer ran after `cleanUp()`. As of plan 0072 the only way
/// that happened was unawaited async teardown (`defer { Task { … } }`); that shape is now
/// banned and `script/check-production-data-untouched.sh` fails on any data-carrying domain.
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
