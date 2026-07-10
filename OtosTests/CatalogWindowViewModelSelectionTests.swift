import AppKit
import Foundation
@testable import Otos
import Testing

/// Intent-level coverage for ViewModel-owned grid selection (plan 0052 Increment 1).
/// Gesture rules themselves live in `GridSelectionTests`; these tests prove the
/// ViewModel owns the value and that each intent updates it correctly.
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
            orderedIDs: ids,
            liveSelection: []
        )

        #expect(updated.selection == [ids[1]])
        #expect(updated.anchor == ids[1])
        #expect(model.gridSelection == updated)
        #expect(model.selectionAnchor == ids[1])
    }

    @Test func shiftClickExtendsFromAnchor() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 6)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids, liveSelection: [])
        let updated = model.applyGridClick(
            hit: ids[4],
            modifiers: [.shift],
            orderedIDs: ids,
            liveSelection: [ids[1]]
        )

        #expect(updated.selection == Set(ids[1 ... 4]))
        #expect(updated.anchor == ids[1])
    }

    @Test func emptySpaceClears() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids, liveSelection: [])
        let updated = model.applyGridClick(
            hit: nil,
            modifiers: [],
            orderedIDs: ids,
            liveSelection: [ids[0]]
        )

        #expect(updated == .empty)
        #expect(model.gridSelection == .empty)
    }

    @Test func shiftEmptySpaceIsNoOp() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids, liveSelection: [])
        let updated = model.applyGridClick(
            hit: nil,
            modifiers: [.shift],
            orderedIDs: ids,
            liveSelection: [ids[0]]
        )

        #expect(updated.selection == [ids[0]])
        #expect(updated.anchor == ids[0])
    }

    @Test func reconcileNativeAdoptsKeyboardSelection() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids, liveSelection: [])

        let updated = model.reconcileNativeSelection(Set(ids[0 ... 2]))

        #expect(updated.selection == Set(ids[0 ... 2]))
        #expect(updated.anchor == ids[0])
        #expect(updated.base == Set(ids[0 ... 2]))
    }

    @Test func reconcileNativeIsIdempotentWhenEqual() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids, liveSelection: [])
        let before = model.gridSelection

        let updated = model.reconcileNativeSelection([ids[1]])

        #expect(updated == before)
    }

    @Test func pruneSelectionDropsMissingIdentities() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 5)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids, liveSelection: [])
        _ = model.applyGridClick(
            hit: ids[3],
            modifiers: [.shift],
            orderedIDs: ids,
            liveSelection: [ids[1]]
        )

        let survivors = [ids[0], ids[1], ids[2], ids[4]]
        let updated = model.pruneSelection(
            preserved: Set(ids[1 ... 3]),
            to: survivors
        )

        #expect(updated.selection == [ids[1], ids[2]])
        #expect(updated.anchor == ids[1])
        #expect(updated.base == [ids[1]])
    }

    @Test func pruneSelectionClearsAnchorWhenAnchorLeaves() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 4)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids, liveSelection: [])
        _ = model.applyGridClick(
            hit: ids[2],
            modifiers: [.shift],
            orderedIDs: ids,
            liveSelection: [ids[1]]
        )

        let survivors = [ids[0], ids[2], ids[3]]
        let updated = model.pruneSelection(
            preserved: Set(ids[1 ... 2]),
            to: survivors
        )

        #expect(updated.selection == [ids[2]])
        #expect(updated.anchor == nil)
        #expect(updated.base.isEmpty)
    }

    @Test func clearGridSelectionResetsModel() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 2)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids, liveSelection: [])

        model.clearGridSelection(reason: "descriptorChange")

        #expect(model.gridSelection == .empty)
    }

    @Test func handlersFromViewModelRoundTrip() {
        let model = makeSelectionViewModel()
        let ids = makeIDs(count: 3)
        let handlers = MediaGridSelectionHandlers.from(model)

        let updated = handlers.applyClick(ids[2], [], ids, [])
        #expect(updated.selection == [ids[2]])
        #expect(handlers.currentSelection().anchor == ids[2])
        #expect(model.gridSelection.anchor == ids[2])

        handlers.clear("test")
        #expect(handlers.currentSelection() == .empty)
        #expect(model.gridSelection == .empty)
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
