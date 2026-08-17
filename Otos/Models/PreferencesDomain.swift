import Foundation

/// The single explicit choice of which preference domain a construction site uses.
///
/// Production is `.standard`; tests and previews use `.suite(<unique>)`. There is
/// no default parameter that can silently select production — every initializer
/// that needs preferences requires a `PreferencesDomain` value, and each
/// isolation owner creates its own `PreferenceStore` instance from it (ARC-042,
/// ADR 0020). `makeDefaults()` lives in `PreferenceStore.swift`, next to the
/// store implementations it chooses between.
///
/// The domain itself is `Sendable` and `Equatable`; the `PreferenceStore`
/// instance it creates is not — it is owned by the isolation that created it.
nonisolated enum PreferencesDomain: Equatable, Sendable {
    case standard
    case suite(String)
}
