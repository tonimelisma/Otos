import Foundation
@testable import Otos

/// Actor-internal seams for the plan 0059 scheduler-review-fix tests: they exercise
/// `claimedWork`/`retryLedger` state transitions directly rather than driving a full
/// retry schedule through real time.
extension EnrichmentCoordinator {
    func testSeedClaimedWork(id: MediaAssetID, record: ClaimedWorkRecord) {
        claimedWork[id] = record
    }

    func testClaimedWorkRecord(for id: MediaAssetID) -> ClaimedWorkRecord? {
        claimedWork[id]
    }

    func testSeedRetryLedger(id: MediaAssetID, entry: RetryLedgerEntry) {
        retryLedger[id] = entry
    }

    func testRetryLedgerEntry(for id: MediaAssetID) -> RetryLedgerEntry? {
        retryLedger[id]
    }
}
