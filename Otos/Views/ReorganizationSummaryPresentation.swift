import Foundation

/// Pure display mapper for `LibraryReorganizationRunner.ReorganizationPlanSummary`,
/// beside `ContentView`'s confirmation dialog the same way `ImportBarPresentation`
/// sits beside `ImportPlanFooter`: the runner reports typed counts, this is the one
/// place that turns them into a sentence (DES-034 one clause, DES-035 user
/// vocabulary — never the planner's own "relocate"/"no-op"/"components" words).
/// `noOpCount` and `componentCount` are not decision-relevant to the user
/// confirming a reorganization and are intentionally left out.
enum ReorganizationSummaryPresentation {
    static func string(for summary: LibraryReorganizationRunner.ReorganizationPlanSummary) -> String {
        guard summary.blockedCount > 0 else {
            return "\(summary.relocateCount) items will be renamed or moved."
        }
        return "\(summary.relocateCount) items will be renamed or moved · \(summary.blockedCount) can't be processed."
    }
}
