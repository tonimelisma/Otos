import Foundation

/// Localized import-batch sidebar labels. Identity remains `ImportBatchID`;
/// formatting is presentation-only and may disambiguate identical clock labels.
nonisolated enum ImportBatchFormatting {
    private static let primary: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let disambiguated: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.timeZone = .current
        return formatter
    }()

    static func sidebarTitle(for batchID: ImportBatchID) -> String {
        primary.string(from: batchID.date)
    }

    /// When two batches render the same primary label, include seconds/zone.
    static func sidebarTitle(
        for batchID: ImportBatchID,
        among batches: [ImportBatchSummary]
    ) -> String {
        let primaryLabel = sidebarTitle(for: batchID)
        let collisions = batches.filter { sidebarTitle(for: $0.batchID) == primaryLabel }
        guard collisions.count > 1 else {
            return primaryLabel
        }
        return disambiguated.string(from: batchID.date)
    }
}
