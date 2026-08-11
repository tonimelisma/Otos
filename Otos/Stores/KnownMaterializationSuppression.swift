import Foundation

/// Known-materialization event suppression policy
/// (docs/research/2026-07-11-onedrive-materialization-fsevents.md).
///
/// Provider hydration runs outside the Otos process, so `IgnoreSelf` cannot
/// identify those FSEvents. When measurement shows fact-neutral hydration with a
/// stable regular-file flag shape, Store may suppress only that allowlisted shape
/// for normalized paths Otos has explicitly asked the provider to materialize.
/// Membership/coverage shapes never suppress. Launch and periodic integrity scans
/// repair any residual miss inside the grace window.
nonisolated enum KnownMaterializationSuppressionPolicy {
    /// Materialization may wait up to 120s; measured OneDrive event lag peaked
    /// near 9s after the SF_DATALESS transition. Keep the entry active through
    /// operation completion with this safety ceiling, then apply endGrace.
    static let activeCeiling: Duration = .seconds(135)
    static let endGrace: Duration = .seconds(5)

    static func isSuppressible(
        flags: FilesystemEventFlags,
        id: MediaAssetID,
        active: [MediaAssetID: Date],
        now: Date
    ) -> Bool {
        guard flags.isKnownMaterializationSuppressibleShape else {
            return false
        }
        guard let expiry = active[id], expiry > now else {
            return false
        }
        return true
    }
}

/// Process-local known-materialization suppression map owned by `CatalogStore`.
nonisolated struct KnownMaterializationSuppressionState {
    private var expiryByID: [MediaAssetID: Date] = [:]

    var count: Int {
        expiryByID.count
    }

    mutating func begin(id: MediaAssetID, now: Date = Date()) {
        pruneExpired(now: now)
        let ceiling = DiagnosticsTiming.seconds(KnownMaterializationSuppressionPolicy.activeCeiling)
        let candidate = now.addingTimeInterval(ceiling)
        // A newer begin must not shorten an overlapping newer ceiling.
        if let existing = expiryByID[id] {
            expiryByID[id] = max(existing, candidate)
        } else {
            expiryByID[id] = candidate
        }
    }

    mutating func endSuccess(id: MediaAssetID, now: Date = Date()) {
        pruneExpired(now: now)
        // Replace the active ceiling with the measured post-completion grace so
        // late duplicate provider events still suppress briefly.
        let grace = DiagnosticsTiming.seconds(KnownMaterializationSuppressionPolicy.endGrace)
        expiryByID[id] = now.addingTimeInterval(grace)
    }

    mutating func endFailure(id: MediaAssetID, now: Date = Date()) {
        pruneExpired(now: now)
        expiryByID.removeValue(forKey: id)
    }

    mutating func pruneExpired(now: Date = Date()) {
        expiryByID = expiryByID.filter { $0.value > now }
    }

    mutating func clear() {
        expiryByID.removeAll(keepingCapacity: false)
    }

    mutating func removeAll(under root: LibraryRootPath) {
        expiryByID = expiryByID.filter { $0.key.libraryRootPath != root }
    }

    func activeExpiries(now: Date = Date()) -> [MediaAssetID: Date] {
        expiryByID.filter { $0.value > now }
    }
}
