import Foundation

/// The single pure rule for the filesystem mtime stamped on an imported primary.
/// Planner and executor must compare the same integer-second fact; unknown dates
/// stay unknown instead of using a wall-clock fallback that would prevent convergence.
nonisolated enum ImportDestinationDate {
    static func expected(for source: PlanningFileFacts) -> Date? {
        if let compact = source.captureWallCompact,
           let date = CaptureWallClock.date(fromCompact: compact) {
            return date
        }
        return source.contentModifiedAt
    }
}
