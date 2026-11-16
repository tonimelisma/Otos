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
/// `.sessionOnly(base)` reads `base` and keeps every write in this process's memory, so the
/// session sees its own changes and `base` is left exactly as it was, however the session
/// ends. A read-only tour runs on `.sessionOnly(.standard)` (`PreferencesDomain.configured`):
/// its filter, sort, scope and zoom live for the visible session only, and a tour cut short
/// before its restore step leaves the owner's saved place untouched (ADR 0020).
///
/// The domain itself is `Sendable` and `Hashable`; the `PreferenceStore`
/// instance it creates is not — it is owned by the isolation that created it.
indirect nonisolated enum PreferencesDomain: Hashable, Sendable {
    case standard
    case suite(String)
    case sessionOnly(PreferencesDomain)
}
