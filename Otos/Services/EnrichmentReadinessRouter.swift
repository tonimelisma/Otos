import Foundation

/// Readiness routing is deliberately a pure live-fact boundary. It may classify a
/// candidate as ready or materialization work, but it never reads bytes and never
/// persists the transient provider status.
nonisolated protocol EnrichmentReadinessChecking: Sendable {
    func status(of url: URL) -> FileMaterializationStatus
}

nonisolated struct LiveEnrichmentReadinessChecker: EnrichmentReadinessChecking {
    func status(of url: URL) -> FileMaterializationStatus {
        FileMaterialization.status(of: url)
    }
}
