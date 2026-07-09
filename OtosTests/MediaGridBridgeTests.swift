@testable import Otos
import Testing

@MainActor
struct MediaGridBridgeTests {
    // MARK: - Structural apply arbitration (migrated to MediaGridMutationGate)

    @Test func mutationGateKeepsOnlyNewestPendingGrid() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        let intermediate = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let newest = makeGrid(scope: .allMedia, paths: ["c.jpg"])

        #expect(gate.receive(first) == [.apply(first, resetScroll: false, resetSelection: false)])
        #expect(gate.receive(intermediate) == [.pending(replacedExisting: false)])
        #expect(gate.receive(newest) == [.pending(replacedExisting: true)])
        #expect(
            gate.completeStructuralApply(applied: first)
                == [.apply(newest, resetScroll: false, resetSelection: false)]
        )
    }

    @Test func identicalIDsRefreshVisibleWithoutStructuralApply() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])

        #expect(gate.receive(first) == [.apply(first, resetScroll: false, resetSelection: false)])
        #expect(gate.completeStructuralApply(applied: first) == [])
        #expect(
            gate.receive(first)
                == [.refreshVisible(first, resetScroll: false, resetSelection: false)]
        )
    }

    @Test func descriptorChangeResetsScrollAndSelectionAndSameDescriptorStructurePreservesThem() {
        let gate = MediaGridMutationGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(allMedia) == [.apply(allMedia, resetScroll: false, resetSelection: false)])
        #expect(gate.completeStructuralApply(applied: allMedia) == [])

        let sameDescriptor = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        #expect(gate.receive(sameDescriptor) == [.apply(sameDescriptor, resetScroll: false, resetSelection: false)])
        #expect(gate.completeStructuralApply(applied: sameDescriptor) == [])

        let differentScope = makeGrid(scope: .library(LibraryRootPath(rawValue: "/Pictures")), paths: ["a.jpg"])
        #expect(gate.receive(differentScope) == [.apply(differentScope, resetScroll: true, resetSelection: true)])
    }

    @Test func descriptorChangeWithSameIDsRefreshClearsSelection() {
        let gate = MediaGridMutationGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(allMedia) == [.apply(allMedia, resetScroll: false, resetSelection: false)])
        #expect(gate.completeStructuralApply(applied: allMedia) == [])

        let sameIDsInLibraryScope = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["a.jpg"]
        )
        #expect(
            gate.receive(sameIDsInLibraryScope)
                == [.refreshVisible(sameIDsInLibraryScope, resetScroll: true, resetSelection: true)]
        )
    }

    // MARK: - Zoom / apply cross-arbitration (F1 and F2 regressions)

    /// F1: a zoom that is superseded back to the currently installed count while an apply
    /// is in flight must produce no swap — the grid must not silently change columns.
    @Test func zoomSupersededToInstalledCountDuringApplyProducesNoSwap() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let grid = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = gate.receive(grid) // apply in flight

        #expect(gate.receiveColumnCount(5) == []) // parked while in flight
        #expect(gate.receiveColumnCount(6) == []) // superseded back to the installed count

        #expect(gate.completeStructuralApply(applied: grid) == [])
        #expect(gate.installedColumnCount == 6)
        #expect(gate.requestedColumnCount == 6)
    }

    @Test func zoomRequestedDuringApplyConvergesExactlyOnce() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let grid = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = gate.receive(grid) // apply in flight

        #expect(gate.receiveColumnCount(4) == [])
        #expect(gate.completeStructuralApply(applied: grid) == [.zoomSwap(columnCount: 4)])
        #expect(gate.completeZoomSwap(installed: 4) == [])
        #expect(gate.installedColumnCount == 4)
    }

    /// F2: a grid state arriving while a zoom swap animates must park as pending — it must
    /// never start a diffable apply concurrently with the swap — and drain as `.apply`
    /// only when the swap completes.
    @Test func gridArrivingDuringZoomSwapParksThenAppliesOnCompletion() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let base = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = gate.receive(base)
        _ = gate.completeStructuralApply(applied: base)

        #expect(gate.receiveColumnCount(4) == [.zoomSwap(columnCount: 4)]) // swap starts

        let gridPrime = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        #expect(gate.receive(gridPrime) == [.pending(replacedExisting: false)])

        #expect(
            gate.completeZoomSwap(installed: 4)
                == [.apply(gridPrime, resetScroll: false, resetSelection: false)]
        )
    }

    /// A completion drain can legitimately emit a non-exclusive `.refreshVisible` (a
    /// same-identity, new-descriptor grid parked mid-swap) followed by a trailing
    /// `.zoomSwap` for a column count that changed again mid-swap.
    @Test func completionDrainsRefreshVisibleThenTrailingZoomSwap() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let base = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = gate.receive(base)
        _ = gate.completeStructuralApply(applied: base)

        #expect(gate.receiveColumnCount(4) == [.zoomSwap(columnCount: 4)]) // installed still 6

        let sameIDsNewScope = makeGrid(scope: .library(LibraryRootPath(rawValue: "/Pictures")), paths: ["a.jpg"])
        #expect(gate.receive(sameIDsNewScope) == [.pending(replacedExisting: false)])
        #expect(gate.receiveColumnCount(5) == []) // requested changes again mid-swap

        #expect(
            gate.completeZoomSwap(installed: 4) == [
                .refreshVisible(sameIDsNewScope, resetScroll: true, resetSelection: true),
                .zoomSwap(columnCount: 5),
            ]
        )
    }

    @Test func newestValueWinsForBothMutationKinds() {
        let swapGate = MediaGridMutationGate(columnCount: 6)
        let base = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = swapGate.receive(base)
        _ = swapGate.completeStructuralApply(applied: base)

        _ = swapGate.receiveColumnCount(4) // swap in flight
        let firstGrid = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let secondGrid = makeGrid(scope: .allMedia, paths: ["c.jpg"])
        #expect(swapGate.receive(firstGrid) == [.pending(replacedExisting: false)])
        #expect(swapGate.receive(secondGrid) == [.pending(replacedExisting: true)])
        #expect(
            swapGate.completeZoomSwap(installed: 4)
                == [.apply(secondGrid, resetScroll: false, resetSelection: false)]
        )

        let applyInFlightGate = MediaGridMutationGate(columnCount: 6)
        let grid = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = applyInFlightGate.receive(grid) // apply in flight
        #expect(applyInFlightGate.receiveColumnCount(4) == [])
        #expect(applyInFlightGate.receiveColumnCount(5) == [])
        #expect(applyInFlightGate.completeStructuralApply(applied: grid) == [.zoomSwap(columnCount: 5)])
    }

    /// Chained: an apply that starts from a parked grid runs before the parked zoom; only
    /// after that apply completes does the zoom finally drain.
    @Test func chainedApplyDrainsBeforeParkedZoom() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let base = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = gate.receive(base)
        _ = gate.completeStructuralApply(applied: base)

        let second = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        #expect(gate.receive(second) == [.apply(second, resetScroll: false, resetSelection: false)])

        #expect(gate.receiveColumnCount(4) == []) // parked
        let third = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(gate.receive(third) == [.pending(replacedExisting: false)])

        // The parked grid applies first (content correctness); the zoom stays deferred.
        #expect(
            gate.completeStructuralApply(applied: second)
                == [.apply(third, resetScroll: false, resetSelection: false)]
        )
        // Only once that apply completes does the parked zoom drain.
        #expect(gate.completeStructuralApply(applied: third) == [.zoomSwap(columnCount: 4)])
        #expect(gate.completeZoomSwap(installed: 4) == [])
    }

    // MARK: - Structural apply policy and tile detail cache (unchanged)

    @Test func structuralApplyPolicyUsesReloadDataFallbackOnlyForLargeOrReorderApplies() {
        let previous = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"]).orderedAssetIDs
        let smallInsert = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]).orderedAssetIDs
        let smallInsertPolicy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            nextOrderedIDs: smallInsert
        )
        #expect(smallInsertPolicy.animatingDifferences)
        #expect(!smallInsertPolicy.usesReloadDataFallback)

        let reordered = [previous[2], previous[1], previous[0]]
        let reorderPolicy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            nextOrderedIDs: reordered
        )
        #expect(reorderPolicy.reorderOnly)
        #expect(!reorderPolicy.animatingDifferences)
        #expect(reorderPolicy.usesReloadDataFallback)

        let largeApply = makeGrid(
            scope: .allMedia,
            paths: (0 ..< MediaGridStructuralApplyPolicy.reloadDataFallbackItemCountThreshold).map { "asset-\($0).jpg" }
        ).orderedAssetIDs
        let largePolicy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: [],
            nextOrderedIDs: largeApply
        )
        #expect(largePolicy.largeApply)
        #expect(!largePolicy.animatingDifferences)
        #expect(largePolicy.usesReloadDataFallback)
    }

    @Test func tileDetailCacheMergesAndEvictsLeastRecentlyUsedAssets() {
        let firstDetail = makeDetail(path: "a.jpg")
        let secondDetail = makeDetail(path: "b.jpg")
        let thirdDetail = makeDetail(path: "c.jpg")
        var cache = MediaTileDetailCache(limit: 2)

        cache.merge([firstDetail.id: firstDetail, secondDetail.id: secondDetail])
        #expect(cache.count == 2)
        #expect(cache.detail(for: firstDetail.id) == firstDetail)

        cache.merge([thirdDetail.id: thirdDetail])
        #expect(cache.count == 2)
        #expect(cache.detail(for: firstDetail.id) == firstDetail)
        #expect(cache.detail(for: secondDetail.id) == nil)
        #expect(cache.detail(for: thirdDetail.id) == thirdDetail)
    }
}

@MainActor
private func makeGrid(scope: SidebarSelection, paths: [String]) -> CatalogMediaGridState {
    let assets = paths.map { makeAssetID(path: $0) }
    return CatalogMediaGridState(
        scope: scope,
        orderedAssetIDs: assets
    )
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

@MainActor
private func makeDetail(path: String) -> MediaTileDetail {
    MediaTileDetail(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}
