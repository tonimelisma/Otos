import Foundation

/// Known-materialization event suppression policy (plan 0056).
///
/// Provider hydration runs outside the Otos process, so `IgnoreSelf` cannot
/// identify those FSEvents. When measurement shows fact-neutral hydration with a
/// stable regular-file flag shape, Store may suppress only that allowlisted shape
/// for normalized paths Otos has explicitly asked the provider to materialize.
/// Membership/coverage shapes never suppress. Launch and periodic integrity scans
/// repair any residual miss inside the grace window.
nonisolated enum KnownMaterializationSuppressionPolicy {
    /// Measured OneDrive delivery lag peaked near 9s from request; keep a 15s
    /// active window from begin, then 5s after successful materialization ends.
    static let beginGrace: Duration = .seconds(15)
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
        let candidate = now.addingTimeInterval(Self.seconds(KnownMaterializationSuppressionPolicy.beginGrace))
        if let existing = expiryByID[id] {
            expiryByID[id] = max(existing, candidate)
        } else {
            expiryByID[id] = candidate
        }
    }

    mutating func endSuccess(id: MediaAssetID, now: Date = Date()) {
        pruneExpired(now: now)
        let candidate = now.addingTimeInterval(Self.seconds(KnownMaterializationSuppressionPolicy.endGrace))
        if let existing = expiryByID[id] {
            expiryByID[id] = max(existing, candidate)
        } else {
            expiryByID[id] = candidate
        }
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

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
