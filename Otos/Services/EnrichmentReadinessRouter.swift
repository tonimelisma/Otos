import Foundation

/// The detector the enricher re-checks immediately before it reads an original's bytes
/// (ADR 0008), so a provider that evicted the file since it was routed never makes a read
/// download it. It never decides where an original is: that question has one owner,
/// `MaterializationRequesting.locality(of:)` (ADR 0046 §4), which the coordinator's
/// readiness routing asks. It never reads bytes and never persists the transient status.
nonisolated protocol EnrichmentReadinessChecking: Sendable {
    func status(of url: URL) -> FileMaterializationStatus
}

nonisolated struct LiveEnrichmentReadinessChecker: EnrichmentReadinessChecking {
    func status(of url: URL) -> FileMaterializationStatus {
        FileMaterialization.status(of: url)
    }
}
