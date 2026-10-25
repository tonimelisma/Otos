import Foundation
@testable import OtosKit

struct TestEnrichmentReadinessChecker: EnrichmentReadinessChecking, Sendable {
    let result: FileMaterializationStatus

    func status(of _: URL) -> FileMaterializationStatus {
        result
    }
}

/// A schedule whose ledger paces each row, built through the transitions a background
/// materialization takes when its last in-window retry fails. The rows hold no claim in
/// it, so a coordinator started from it owes the Store nothing for them.
func pacedSchedule(
    _ rows: [(id: MediaAssetID, sourceSize: Int64?)],
    now: ContinuousClock.Instant = .now
) -> EnrichmentSchedule {
    var schedule = EnrichmentSchedule(retrySchedule: .production)
    let lastAttempt = EnrichmentRetrySchedule.production.backgroundDownloadDelays.count
    for row in rows {
        let work = EnrichmentCoordinator.DownloadWork(
            id: row.id, url: row.id.fileURL, sourceSize: row.sourceSize, captureDate: nil,
            isVideo: false, attemptCount: lastAttempt
        )
        schedule.demand(work, ownsStoreClaim: false)
        _ = schedule.takeSubmissions(globalLimit: .max, backgroundPerRoot: .max, viewport: [], now: now)
        _ = schedule.finish(work, outcome: .requestFailed, now: now)
    }
    return schedule
}
