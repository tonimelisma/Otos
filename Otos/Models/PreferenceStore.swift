import Foundation
import Synchronization

/// The narrow key-value surface the app actually uses. Production wraps
/// `UserDefaults`; `.suite` domains (previews and tests) back onto an
/// in-memory, name-keyed store instead, so no test touches cfprefsd, writes a
/// plist, or needs cleanup. The surface is exactly what
/// `grep -rhoE '\(preferences|defaults\)\.[a-zA-Z]+\(' Otos` shows in use —
/// widened past the plan's original four-method sketch, which missed
/// `integer`/`bool`/`dictionary` reached through the `preferences`-named
/// call sites rather than `defaults`-named ones.
nonisolated protocol PreferenceStore: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int
    func bool(forKey key: String) -> Bool
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// Dictionary-backed `PreferenceStore` for one `PreferencesDomain.suite` name.
/// Never touches cfprefsd or the filesystem; discarded with the process, so it
/// needs no cleanup call.
///
/// One `Mutex`-protected slot per concrete type this codebase actually stores
/// (confirmed exhaustively via `grep -rhoE '\(preferences|defaults\)\.set\('
/// Otos`: Bool, Int, Double, String, `[String: String]`) rather than a single
/// `Mutex<[String: Any]>`. `Sendable` is a marker protocol with no runtime
/// witness table, so an already-erased `Any` can never be cast to `any
/// Sendable` to prove it safe to cross `Mutex.withLock`'s `sending` closure
/// boundary — there is no dynamic way to satisfy that contract for `Any`.
/// Storing each concrete, statically-known-Sendable type in its own slot
/// sidesteps the question entirely. `set`/`object` dispatch on the payload's
/// runtime type to pick the slot; an unrecognized type is a programmer error
/// (this store only ever sees what this codebase itself writes).
final class InMemorySuitePreferenceStore: PreferenceStore {
    private let bools = Mutex<[String: Bool]>([:])
    private let ints = Mutex<[String: Int]>([:])
    private let doubles = Mutex<[String: Double]>([:])
    private let strings = Mutex<[String: String]>([:])
    private let stringDictionaries = Mutex<[String: [String: String]]>([:])

    func object(forKey key: String) -> Any? {
        if let value = bools.withLock({ $0[key] }) {
            return value
        }
        if let value = ints.withLock({ $0[key] }) {
            return value
        }
        if let value = doubles.withLock({ $0[key] }) {
            return value
        }
        if let value = strings.withLock({ $0[key] }) {
            return value
        }
        if let value = stringDictionaries.withLock({ $0[key] }) {
            return value
        }
        return nil
    }

    func string(forKey key: String) -> String? {
        strings.withLock { $0[key] }
    }

    func integer(forKey key: String) -> Int {
        ints.withLock { $0[key] } ?? 0
    }

    func bool(forKey key: String) -> Bool {
        bools.withLock { $0[key] } ?? false
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        stringDictionaries.withLock { $0[key] }
    }

    func set(_ value: Any?, forKey key: String) {
        removeObject(forKey: key)
        switch value {
        case let value as Bool:
            bools.withLock { $0[key] = value }
        case let value as Int:
            ints.withLock { $0[key] = value }
        case let value as Double:
            doubles.withLock { $0[key] = value }
        case let value as String:
            strings.withLock { $0[key] = value }
        case let value as [String: String]:
            stringDictionaries.withLock { $0[key] = value }
        case nil:
            break
        default:
            preconditionFailure("InMemorySuitePreferenceStore.set: unsupported value type \(type(of: value!))")
        }
    }

    func removeObject(forKey key: String) {
        bools.withLock { _ = $0.removeValue(forKey: key) }
        ints.withLock { _ = $0.removeValue(forKey: key) }
        doubles.withLock { _ = $0.removeValue(forKey: key) }
        strings.withLock { _ = $0.removeValue(forKey: key) }
        stringDictionaries.withLock { _ = $0.removeValue(forKey: key) }
    }
}

/// Backs every `PreferencesDomain.suite` name with the same
/// `InMemorySuitePreferenceStore` instance across independent `makeDefaults()`
/// calls, matching the sharing semantics a real `UserDefaults` suite gave
/// callers that reconstruct from the same domain name (`PreferencesDomainTests`
/// depends on this: two independently-constructed actors given the same
/// domain must observe each other's writes). Scoped to this file and reachable
/// only through `PreferencesDomain.makeDefaults()` — the in-process analogue of
/// what cfprefsd already was, minus the disk writes and the leak.
private nonisolated let suiteRegistry = Mutex<[String: InMemorySuitePreferenceStore]>([:])

extension PreferencesDomain {
    /// Creates the `PreferenceStore` for this domain. `.standard` is the real,
    /// process-wide `UserDefaults.standard` singleton. `.suite` never touches
    /// disk: repeated calls with the same name return the same in-memory store.
    nonisolated func makeDefaults() -> any PreferenceStore {
        switch self {
        case .standard:
            UserDefaults.standard
        case let .suite(name):
            suiteRegistry.withLock {
                if let existing = $0[name] {
                    return existing
                }
                let created = InMemorySuitePreferenceStore()
                $0[name] = created
                return created
            }
        }
    }
}
