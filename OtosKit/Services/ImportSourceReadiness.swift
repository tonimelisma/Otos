import Foundation

/// Whether an attached source's live inventory can be trusted enough to offer
/// Import (ADR 0024). Pure function of `CatalogLibraryState`'s availability
/// and activity — no coordinator or catalog state beyond what's already on the
/// row, and fully unit-tested without a live device or filesystem.
///
/// Gate, not stream. While a source is still being
/// read there is no partial/growing total — the bar holds state A until
/// readiness proves `.ready`, never showing a count that might still change.
nonisolated enum ImportSourceReadiness: Equatable, Sendable {
    /// A filesystem scan or device enumeration is in progress, or availability
    /// hasn't resolved yet: nothing built from the catalog right now can be
    /// trusted as the live inventory.
    case preparing
    /// Live inventory is stable; safe to offer Import against.
    case ready
    /// Source isn't reachable at all.
    case unreachable

    static func evaluate(_ state: CatalogLibraryState) -> ImportSourceReadiness {
        switch state.availability {
        case .unavailable, .unknown:
            .unreachable
        case .available:
            switch state.activity {
            case .scanning, .enumerating:
                .preparing
            case .idle:
                .ready
            }
        }
    }
}
