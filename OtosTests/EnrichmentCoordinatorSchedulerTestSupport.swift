import Foundation
@testable import OtosKit

struct TestEnrichmentReadinessChecker: EnrichmentReadinessChecking, Sendable {
    let result: FileMaterializationStatus

    func status(of _: URL) -> FileMaterializationStatus {
        result
    }
}

/// A schedule whose ledger paces each row, as it paces a row whose source sends the original
/// only for the user's work (`EnrichmentSchedule.pace`). The rows hold no claim in it, so a
/// coordinator started from it owes the Store nothing for them.
func pacedSchedule(
    _ rows: [(id: MediaAssetID, sourceSize: Int64?)],
    now: ContinuousClock.Instant = .now
) -> EnrichmentSchedule {
    var schedule = EnrichmentSchedule(retrySchedule: .production)
    for row in rows {
        schedule.pace(row.id, sourceSize: row.sourceSize, now: now)
    }
    return schedule
}
