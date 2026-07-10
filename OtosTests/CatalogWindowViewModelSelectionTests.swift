import AppKit
import Foundation
@testable import Otos
import Testing

/// Intent-level coverage for ViewModel-owned grid selection (plan 0053 Stage A).
/// Gesture rules themselves live in `GridSelectionTests`; these tests prove the
/// ViewModel owns the value, intents update it, and applyState prunes/clears it
/// before any AppKit renderer sees the new order.
@MainActor
struct CatalogWindowViewModelSelectionTests {
    @Test func startsEmpty() {
        let model = makeSelectionViewModel()
        #expect(model.gridSelection == .empty)
        #expect(model.selectionAnchor == nil)
        #expect(model.orderedSelectedAssetIDs.isEmpty)
    }

    @Test func plainClickSelectsAndAnchors() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)

        let updated = model.applyGridClick(
            hit: ids[1],
            modifiers: [],
            orderedIDs: ids
        )

        #expect(updated.selection == [ids[1]])
        #expect(updated.anchor == ids[1])
        #expect(model.gridSelection == updated)
        #expect(model.selectionAnchor == ids[1])
    }

    @Test func shiftClickExtendsFromAnchor() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 6)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        let updated = model.applyGridClick(
            hit: ids[4],
            modifiers: [.shift],
            orderedIDs: ids
        )

        #expect(updated.selection == Set(ids[1 ... 4]))
        #expect(updated.anchor == ids[1])
    }

    @Test func emptySpaceClears() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        let updated = model.applyGridClick(
            hit: nil,
            modifiers: [],
            orderedIDs: ids
        )

        #expect(updated == .empty)
        #expect(model.gridSelection == .empty)
    }

    @Test func shiftEmptySpaceIsNoOp() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        let updated = model.applyGridClick(
            hit: nil,
            modifiers: [.shift],
            orderedIDs: ids
        )

        #expect(updated.selection == [ids[0]])
        #expect(updated.anchor == ids[0])
    }

    @Test func loupeEmptySpaceIsNoOp() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        model.applyState(makeWindowState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        model.openLoupe(id: ids[0])

        let updated = model.applyGridClick(hit: nil, modifiers: [], orderedIDs: ids)

        #expect(updated.selection == [ids[0]])
        #expect(model.focusedAssetID == ids[0])
    }

    @Test func reconcileNativeAdoptsKeyboardSelection() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)

        let updated = model.reconcileNativeSelection(Set(ids[0 ... 2]))

        #expect(updated.selection == Set(ids[0 ... 2]))
        #expect(updated.anchor == ids[0])
        #expect(updated.base == Set(ids[0 ... 2]))
    }

    @Test func reconcileNativeIsIdempotentWhenEqual() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        let before = model.gridSelection

        let updated = model.reconcileNativeSelection([ids[1]])

        #expect(updated == before)
    }

    @Test func reconcileNativeInCompareIsNoOp() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        model.applyState(makeWindowState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()
        let before = model.gridSelection

        let updated = model.reconcileNativeSelection(Set(ids[0 ... 2]))

        #expect(updated == before)
        #expect(model.comparePair.members.count == 2)
    }

    @Test func clearGridSelectionResetsModel() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 2)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)

        model.clearGridSelection(reason: "descriptorChange")

        #expect(model.gridSelection == .empty)
    }

    @Test func handlersFromViewModelRoundTrip() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        let handlers = MediaGridSelectionHandlers.from(model)

        let updated = handlers.applyClick(ids[2], [], ids)
        #expect(updated.selection == [ids[2]])
        #expect(handlers.currentSelection().anchor == ids[2])
        #expect(model.gridSelection.anchor == ids[2])
    }

    @Test func applyStatePrunesRemovedIdentities() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 5)
        model.applyState(makeWindowState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[3], modifiers: [.shift], orderedIDs: ids)
        #expect(model.gridSelection.selection == Set(ids[1 ... 3]))

        let survivors = [ids[0], ids[1], ids[2], ids[4]]
        model.applyState(makeWindowState(orderedIDs: survivors))

        #expect(model.gridSelection.selection == [ids[1], ids[2]])
        #expect(model.gridSelection.anchor == ids[1])
        #expect(model.gridSelection.base == [ids[1]])
    }

    @Test func descriptorChangeClearsAtApplyState() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        model.applyState(makeWindowState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        #expect(model.gridSelection.selection == [ids[0]])

        let libraryScope = CatalogQueryDescriptor(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            filter: .all,
            sort: .defaultOrder
        )
        model.applyState(makeWindowState(orderedIDs: ids, descriptor: libraryScope))

        #expect(model.gridSelection == .empty)
    }

    @Test func focusReconcileRunsOnGridChange() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        model.applyState(makeWindowState(orderedIDs: ids))
        model.openLoupe(id: ids[1])
        #expect(model.focusedAssetID == ids[1])

        let survivors = [ids[0], ids[2], ids[3]]
        model.applyState(makeWindowState(orderedIDs: survivors))

        let expected = BrowserModePolicy.pruneFocus(
            previous: ids[1],
            previousOrderedIDs: ids,
            survivingOrderedIDs: survivors
        )
        #expect(model.focusedAssetID == expected)
    }

    @Test func selectionSurvivesFreshControllerFirstApply() throws {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        model.applyState(makeWindowState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        let expected = Set([ids[0], ids[1]])
        #expect(model.gridSelection.selection == expected)

        let controller = MediaGridViewController()
        _ = controller.view
        controller.selectionHandlers = .from(model)
        let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
        controller.receive(grid)
        // Drive apply to completion: receive starts apply; wait for async completion.
        try awaitApplyCompletion(controller, expectedIDs: ids)

        #expect(model.gridSelection.selection == expected)
        #expect(controller.selectedIdentities() == expected)
    }

    @Test func selectionSurvivesModeRoundTrip() throws {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        model.applyState(makeWindowState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[2], modifiers: [], orderedIDs: ids)
        model.openLoupe(id: ids[2])
        #expect(model.gridSelection.selection == [ids[2]])

        let strip = MediaGridViewController(presentation: .strip(tileEdge: 72))
        _ = strip.view
        strip.selectionHandlers = .from(model)
        let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
        strip.receive(grid)
        try awaitApplyCompletion(strip, expectedIDs: ids)
        #expect(model.gridSelection.selection == [ids[2]])
        #expect(strip.selectedIdentities() == [ids[2]])

        model.exitToGrid()
        let gridController = MediaGridViewController()
        _ = gridController.view
        gridController.selectionHandlers = .from(model)
        gridController.receive(grid)
        try awaitApplyCompletion(gridController, expectedIDs: ids)
        #expect(model.gridSelection.selection == [ids[2]])
        #expect(gridController.selectedIdentities() == [ids[2]])
    }
}

@MainActor
private func makeSelectionViewModel() -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        enrichmentCoordinator: nil,
        startsStallMonitor: false,
        startsEnrichment: false,
        gridColumnCountDefaults: UserDefaults(suiteName: "Otos.SelectionTests.\(UUID().uuidString)")!
    )
}

private func makeIDs(count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "asset-\(index).jpg")
        )
    }
}

private func makeWindowState(
    orderedIDs: [MediaAssetID],
    descriptor: CatalogQueryDescriptor = .default
) -> CatalogWindowState {
    CatalogWindowState(
        title: "Test",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(
            descriptor: descriptor,
            orderedAssetIDs: orderedIDs
        ),
        filterOptions: .empty,
        resolvedSidebarSelection: descriptor.scope,
        mediaEmptyState: orderedIDs.isEmpty ? .noMedia : .noMedia,
        deviceConnectionBanner: nil,
        queryGeneration: 0
    )
}

/// Diffable apply completion is async; poll until the gate has adopted the IDs
/// (and thus `completeStructuralApply` has rendered selection).
@MainActor
private func awaitApplyCompletion(
    _ controller: MediaGridViewController,
    expectedIDs: [MediaAssetID]
) throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if controller.mutationGate.displayedOrderedIDs == expectedIDs,
           controller.mutationGate.inFlight == .none
        {
            // One more run-loop pass so the apply completion block has run.
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    Issue.record("Timed out waiting for structural apply completion")
}
