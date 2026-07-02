import Foundation

/// A small, testable state machine keeps imperative AppKit update lifecycle out of
/// SwiftUI. It never queues history: while one apply is active, only the newest
/// requested grid survives. Lives beside `MediaAssetCollectionView` (its only owner)
/// but in its own file so the collection bridge stays focused and the gate can be
/// unit-tested directly (`MediaAssetCollectionTests`).
@MainActor
final class MediaAssetCollectionApplyGate {
    enum Action {
        case none
        case pending(replacedExisting: Bool)
        case refreshVisible(CatalogMediaGridState, resetScroll: Bool)
        case apply(CatalogMediaGridState, resetScroll: Bool)

        var diagnosticDescription: String {
            switch self {
            case .none:
                "none"
            case .pending:
                "pending"
            case .refreshVisible:
                "refreshVisible"
            case .apply:
                "apply"
            }
        }
    }

    private(set) var displayedOrderedIDs: [MediaAssetID] = []
    private(set) var displayedScope: SidebarSelection = .allMedia
    private(set) var isApplyInFlight = false
    private var pendingGrid: CatalogMediaGridState?

    func receive(_ grid: CatalogMediaGridState) -> Action {
        if isApplyInFlight {
            let replacedExisting = pendingGrid != nil
            pendingGrid = grid
            return .pending(replacedExisting: replacedExisting)
        }

        let resetScroll = grid.scope != displayedScope
        if grid.orderedAssetIDs == displayedOrderedIDs {
            displayedScope = grid.scope
            return .refreshVisible(grid, resetScroll: resetScroll)
        }

        isApplyInFlight = true
        return .apply(grid, resetScroll: resetScroll)
    }

    func complete(applied grid: CatalogMediaGridState) -> Action {
        displayedOrderedIDs = grid.orderedAssetIDs
        displayedScope = grid.scope
        isApplyInFlight = false

        guard let pendingGrid else {
            return .none
        }
        self.pendingGrid = nil
        return receive(pendingGrid)
    }
}
