import AppKit
import Foundation
import os
@testable import OtosKit
import Testing

/// Controller-level tests for grid zoom arbitration through `MediaGridMutationGate`
/// (APP-006, ARC-023): a zoom requested while a diffable structural apply is in flight must
/// never run concurrently with that apply, and must install exactly once after it
/// completes. The controller is driven off-window (`makeController` forces `loadView`
/// but never adds the view to a window), so `receiveColumnCount` takes the gate's
/// pre-window path — installing the layout directly and completing synchronously — which
/// keeps these tests free of AppKit animation timing.
@MainActor
struct MediaGridZoomTests {
    @Test func presentationUpdateDoesNotPreemptAnimatedGridZoomPath() {
        let controller = makeController(itemCount: 4)
        let originalLayout = controller.collectionView.collectionViewLayout

        controller.applyPresentation(.grid(columnCount: 3))

        #expect(controller.collectionView.collectionViewLayout === originalLayout)
        #expect(controller.mutationGate.installedColumnCount == GridColumnCount.defaultValue)

        controller.receiveColumnCount(3)

        #expect(controller.collectionView.collectionViewLayout !== originalLayout)
        #expect(controller.mutationGate.installedColumnCount == 3)
    }

    @Test func zoomRequestedWhileApplyIsInFlightDefersAndInstallsExactlyOnceAfterCompletion() {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        let newGrid = CatalogMediaGridState(
            scope: .allMedia,
            orderedAssetIDs: ids + [makeAssetID(path: "extra.jpg")]
        )
        // Mark a structural apply in flight on the gate (differing identities).
        guard controller.mutationGate.receive(newGrid) == [.apply(newGrid, change: .unchanged)]
        else {
            Issue.record("Expected the differing grid to start a structural apply")
            return
        }
        #expect(controller.mutationGate.inFlight == .structuralApply)

        controller.receiveColumnCount(3)

        #expect(
            controller.mutationGate.installedColumnCount == GridColumnCount.defaultValue,
            "swap must not run while an apply is in flight"
        )
        #expect(controller.mutationGate.requestedColumnCount == 3)

        let context = MediaGridViewController.StructuralApplyCompletionContext(
            grid: newGrid,
            change: .unchanged,
            applyStart: .now,
            applyCallStart: .now,
            commit: .init(start: .now),
            diffPolicyMs: 0,
            structureBuildMs: 0,
            batchUpdatesMs: 0,
            insertedCount: 1,
            removedCount: 0,
            reorderOnly: false,
            largeApply: false,
            animatingDifferences: true,
            animationSuppressed: false,
            usesReloadDataFallback: false,
            appliedBy: .batchUpdates,
            sectionCount: 1,
            heldDuringScroll: false,
            signpost: .beginState(id: .exclusive)
        )
        controller.completeStructuralApply(context, operation: nil, stallMonitor: nil)

        #expect(controller.mutationGate.installedColumnCount == 3)
        #expect(controller.mutationGate.inFlight == .none)
    }
}

@MainActor
private func makeController(itemCount: Int) -> MediaGridViewController {
    let controller = MediaGridViewController()
    _ = controller.view // forces loadView(), which installs the collection view and data source

    let assetIDs = (0 ..< itemCount).map { makeAssetID(path: "asset-\($0).jpg") }
    controller.show(MediaGridStructure(orderedIDs: assetIDs))

    let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: assetIDs)
    _ = controller.mutationGate.receive(grid)
    _ = controller.mutationGate.completeStructuralApply(applied: grid)

    return controller
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}
