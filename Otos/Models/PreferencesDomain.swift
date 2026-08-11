import Foundation

/// The single explicit choice of which `UserDefaults` domain a construction site uses.
///
/// Production is `.standard`; tests use `.suite(<unique>)`. There is no default
/// parameter that can silently select production — every initializer that needs
/// preferences requires a `PreferencesDomain` value, and each isolation owner
/// creates its own `UserDefaults` instance from it (ARC-042, ADR 0020).
///
/// The domain itself is `Sendable` and `Equatable`; the `UserDefaults` instance
/// it creates is not — it is owned by the isolation that created it.
nonisolated enum PreferencesDomain: Equatable, Sendable {
    case standard
    case suite(String)

    /// Creates the `UserDefaults` instance for this domain. The caller owns the
    /// returned instance and must not share it across isolation boundaries as a
    /// shared reference; each actor/MainActor owner calls this once at init.
    func makeDefaults() -> UserDefaults {
        switch self {
        case .standard:
            UserDefaults.standard
        case let .suite(name):
            // A UUID-suffixed suite name is never a reserved domain, so this
            // force-unwrap is safe — suite creation cannot fail for the names
            // this codebase generates.
            UserDefaults(suiteName: name)!
        }
    }
}
