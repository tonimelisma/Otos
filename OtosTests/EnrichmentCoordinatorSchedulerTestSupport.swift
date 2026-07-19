import Foundation
@testable import Otos

struct TestEnrichmentReadinessChecker: EnrichmentReadinessChecking, Sendable {
    let result: FileMaterializationStatus

    func status(of _: URL) -> FileMaterializationStatus {
        result
    }
}

/// Actor-internal seams for scheduler tests: they exercise process-local state
/// transitions directly rather than driving a full retry schedule through real time.
extension EnrichmentCoordinator {
    func testSeedMaterialization(_ work: DownloadWork, inFlight: Bool = false) {
        materializationDemands[work.id] = work
        materializationClaimIDs.insert(work.id)
        if inFlight {
            materializingIDs.insert(work.id)
        }
    }

    func testMaterializationWork(for id: MediaAssetID) -> DownloadWork? {
        materializationDemands[id]
    }

    func testSeedRetryLedger(id: MediaAssetID, entry: RetryLedgerEntry) {
        retryLedger[id] = entry
    }

    func testRetryLedgerEntry(for id: MediaAssetID) -> RetryLedgerEntry? {
        retryLedger[id]
    }
}
