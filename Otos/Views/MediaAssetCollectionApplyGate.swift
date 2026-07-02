import Foundation

/// A small, testable state machine keeps imperative AppKit update lifecycle out of
/// SwiftUI. It never queues history: while one apply is active, only the newest
/// requested grid survives. A query-descriptor change is a user context change,
/// so it resets scroll and selection even when the same identities survive.
/// Lives beside `MediaAssetCollectionView` (its only owner) but in its own file
/// so the collection bridge stays focused and the gate can be unit-tested
/// directly (`MediaAssetCollectionTests`).
@MainActor
final class MediaAssetCollectionApplyGate {
    enum Action {
        case none
        case pending(replacedExisting: Bool)
        case refreshVisible(CatalogMediaGridState, resetScroll: Bool, resetSelection: Bool)
        case apply(CatalogMediaGridState, resetScroll: Bool, resetSelection: Bool)

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
    private(set) var displayedDescriptor: CatalogQueryDescriptor = .default
    private(set) var isApplyInFlight = false
    private var pendingGrid: CatalogMediaGridState?

    func receive(_ grid: CatalogMediaGridState) -> Action {
        if isApplyInFlight {
            let replacedExisting = pendingGrid != nil
            pendingGrid = grid
            return .pending(replacedExisting: replacedExisting)
        }

        let descriptorChanged = grid.descriptor != displayedDescriptor
        let resetScroll = descriptorChanged
        let resetSelection = descriptorChanged
        if grid.orderedAssetIDs == displayedOrderedIDs {
            displayedDescriptor = grid.descriptor
            return .refreshVisible(
                grid,
                resetScroll: resetScroll,
                resetSelection: resetSelection
            )
        }

        isApplyInFlight = true
        return .apply(
            grid,
            resetScroll: resetScroll,
            resetSelection: resetSelection
        )
    }

    func complete(applied grid: CatalogMediaGridState) -> Action {
        displayedOrderedIDs = grid.orderedAssetIDs
        displayedDescriptor = grid.descriptor
        isApplyInFlight = false

        guard let pendingGrid else {
            return .none
        }
        self.pendingGrid = nil
        return receive(pendingGrid)
    }
}
