@testable import OtosKit
import Testing

@MainActor
struct MediaGridBridgeTests {
    // MARK: - Structural apply arbitration (migrated to MediaGridMutationGate)

    @Test func mutationGateKeepsOnlyNewestPendingGrid() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        let intermediate = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let newest = makeGrid(scope: .allMedia, paths: ["c.jpg"])

        #expect(gate.receive(first) == [.apply(first, change: .unchanged)])
        #expect(gate.receive(intermediate) == [.pending(replacedExisting: false)])
        #expect(gate.receive(newest) == [.pending(replacedExisting: true)])
        #expect(
            gate.completeStructuralApply(applied: first)
                == [.apply(newest, change: .unchanged)]
        )
    }

    @Test func identicalIDsRefreshVisibleWithoutStructuralApply() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])

        #expect(gate.receive(first) == [.apply(first, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: first) == [])
        #expect(
            gate.receive(first)
                == [.refreshVisible(first, change: .unchanged)]
        )
    }

    @Test func descriptorChangeResetsScrollAndSelectionAndSameDescriptorStructurePreservesThem() {
        let gate = MediaGridMutationGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(allMedia) == [.apply(allMedia, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: allMedia) == [])

        let sameDescriptor = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        #expect(gate.receive(sameDescriptor) == [.apply(sameDescriptor, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: sameDescriptor) == [])

        let differentScope = makeGrid(scope: .library(LibraryRootPath(rawValue: "/Pictures")), paths: ["a.jpg"])
        #expect(gate.receive(differentScope) == [.apply(differentScope, change: .scope)])
    }

    @Test func descriptorChangeWithSameIDsRefreshClearsSelection() {
        let gate = MediaGridMutationGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(allMedia) == [.apply(allMedia, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: allMedia) == [])

        let sameIDsInLibraryScope = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["a.jpg"]
        )
        #expect(
            gate.receive(sameIDsInLibraryScope)
                == [.refreshVisible(sameIDsInLibraryScope, change: .scope)]
        )
    }

    // MARK: - Scroll hold

    @Test func scrollHoldParksSameDescriptorAndDrainsNewestOnRelease() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(first) == [.apply(first, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: first) == [])

        gate.beginScrollHold()
        let intermediate = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let newest = makeGrid(scope: .allMedia, paths: ["c.jpg"])
        #expect(gate.receive(intermediate) == [.pending(replacedExisting: false)])
        #expect(gate.receive(newest) == [.pending(replacedExisting: true)])
        #expect(gate.scrollHold)
        #expect(gate.endScrollHold() == [.apply(newest, change: .unchanged)])
        #expect(!gate.scrollHold)
        #expect(gate.lastDrainedHeldDuringScroll)
    }

    @Test func scrollHoldBypassesDescriptorChangedAndClearsParkedPending() {
        let gate = MediaGridMutationGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(allMedia) == [.apply(allMedia, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: allMedia) == [])

        gate.beginScrollHold()
        let parked = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        #expect(gate.receive(parked) == [.pending(replacedExisting: false)])

        // Same IDs + new scope is refreshVisible (not apply); still bypasses hold.
        let library = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["a.jpg"]
        )
        #expect(
            gate.receive(library)
                == [.refreshVisible(library, change: .scope)]
        )
        #expect(gate.endScrollHold() == [])
        #expect(!gate.lastDrainedHeldDuringScroll)

        // Different IDs + new scope still bypasses as an immediate apply.
        gate.beginScrollHold()
        let parkedAgain = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["a.jpg", "extra.jpg"]
        )
        #expect(gate.receive(parkedAgain) == [.pending(replacedExisting: false)])
        let otherLibrary = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Other")),
            paths: ["z.jpg"]
        )
        #expect(gate.receive(otherLibrary) == [.apply(otherLibrary, change: .scope)])
        #expect(gate.endScrollHold() == [])
    }

    @Test func scrollHoldDuringInFlightKeepsNewestWinsUntilBothClear() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(first) == [.apply(first, change: .unchanged)])

        gate.beginScrollHold()
        let intermediate = makeGrid(scope: .allMedia, paths: ["b.jpg"])
        let newest = makeGrid(scope: .allMedia, paths: ["c.jpg"])
        #expect(gate.receive(intermediate) == [.pending(replacedExisting: false)])
        #expect(gate.receive(newest) == [.pending(replacedExisting: true)])

        #expect(gate.completeStructuralApply(applied: first) == [])
        #expect(gate.scrollHold)
        #expect(gate.endScrollHold() == [.apply(newest, change: .unchanged)])
        #expect(gate.lastDrainedHeldDuringScroll)
    }

    @Test func descriptorChangeParkedDuringApplyBypassesScrollHoldOnCompletion() {
        let gate = MediaGridMutationGate()
        let initial = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(initial) == [.apply(initial, change: .unchanged)])

        gate.beginScrollHold()
        let library = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["b.jpg"]
        )
        #expect(gate.receive(library) == [.pending(replacedExisting: false)])
        #expect(
            gate.completeStructuralApply(applied: initial)
                == [.apply(library, change: .scope)]
        )
        #expect(gate.scrollHold)
    }

    @Test func descriptorChangeParkedDuringZoomBypassesScrollHoldOnCompletion() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let initial = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        _ = gate.receive(initial)
        _ = gate.completeStructuralApply(applied: initial)

        gate.beginScrollHold()
        #expect(gate.receiveColumnCount(5) == [.zoomSwap(columnCount: 5)])
        let library = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["b.jpg"]
        )
        #expect(gate.receive(library) == [.pending(replacedExisting: false)])
        #expect(
            gate.completeZoomSwap(installed: 5)
                == [.apply(library, change: .scope)]
        )
        #expect(gate.scrollHold)
    }

    @Test func zoomSwapIgnoresScrollHold() {
        let gate = MediaGridMutationGate(columnCount: 6)
        let base = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(base) == [.apply(base, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: base) == [])

        gate.beginScrollHold()
        #expect(gate.receiveColumnCount(4) == [.zoomSwap(columnCount: 4)])
        #expect(gate.completeZoomSwap(installed: 4) == [])
        #expect(gate.installedColumnCount == 4)
        #expect(gate.endScrollHold() == [])
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
                == [.apply(gridPrime, change: .unchanged)]
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
                .refreshVisible(sameIDsNewScope, change: .scope),
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
                == [.apply(secondGrid, change: .unchanged)]
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
        #expect(gate.receive(second) == [.apply(second, change: .unchanged)])

        #expect(gate.receiveColumnCount(4) == []) // parked
        let third = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(gate.receive(third) == [.pending(replacedExisting: false)])

        // The parked grid applies first (content correctness); the zoom stays deferred.
        #expect(
            gate.completeStructuralApply(applied: second)
                == [.apply(third, change: .unchanged)]
        )
        // Only once that apply completes does the parked zoom drain.
        #expect(gate.completeStructuralApply(applied: third) == [.zoomSwap(columnCount: 4)])
        #expect(gate.completeZoomSwap(installed: 4) == [])
    }

    // MARK: - Structural apply policy truth table (ARC-023)

    @Test func structuralApplyPolicyAnimatesSmallInserts() {
        let previous = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"]).orderedAssetIDs
        let smallInsert = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]).orderedAssetIDs
        let policy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            previousOrderedIDSet: Set(previous),
            nextOrderedIDs: smallInsert,
            descriptorChanged: false
        )
        #expect(policy.animatingDifferences)
        #expect(!policy.usesReloadDataFallback)
        #expect(!policy.reorderOnly)
    }

    @Test func structuralApplyPolicyAnimatesSameDescriptorReorderAtAnyScale() {
        let previous = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"]).orderedAssetIDs
        let reordered = [previous[2], previous[1], previous[0]]
        let small = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            previousOrderedIDSet: Set(previous),
            nextOrderedIDs: reordered,
            descriptorChanged: false
        )
        #expect(small.reorderOnly)
        #expect(small.animatingDifferences)
        #expect(!small.usesReloadDataFallback)

        let largePaths = (0 ..< MediaGridStructuralApplyPolicy.reloadDataFallbackItemCountThreshold)
            .map { "asset-\($0).jpg" }
        let largePrevious = makeGrid(scope: .allMedia, paths: largePaths).orderedAssetIDs
        let largeReordered = Array(largePrevious.reversed())
        let large = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: largePrevious,
            previousOrderedIDSet: Set(largePrevious),
            nextOrderedIDs: largeReordered,
            descriptorChanged: false
        )
        #expect(large.reorderOnly)
        #expect(large.largeApply)
        #expect(large.animatingDifferences)
        #expect(!large.usesReloadDataFallback)
    }

    @Test func structuralApplyPolicyFallsBackForDescriptorChangedReorder() {
        let previous = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"]).orderedAssetIDs
        let reordered = [previous[2], previous[1], previous[0]]
        let policy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            previousOrderedIDSet: Set(previous),
            nextOrderedIDs: reordered,
            descriptorChanged: true
        )
        #expect(policy.reorderOnly)
        #expect(!policy.animatingDifferences)
        #expect(policy.usesReloadDataFallback)
    }

    @Test func structuralApplyPolicyFallsBackForLargeMembershipChange() {
        let largeApply = makeGrid(
            scope: .allMedia,
            paths: (0 ..< MediaGridStructuralApplyPolicy.reloadDataFallbackItemCountThreshold).map { "asset-\($0).jpg" }
        ).orderedAssetIDs
        let policy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: [],
            previousOrderedIDSet: [],
            nextOrderedIDs: largeApply,
            descriptorChanged: false
        )
        #expect(policy.largeApply)
        #expect(!policy.animatingDifferences)
        #expect(policy.usesReloadDataFallback)
    }

    @Test func gateApplyCarriesQueryChangeFact() {
        let gate = MediaGridMutationGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        #expect(gate.receive(allMedia) == [.apply(allMedia, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: allMedia) == [])

        let sameDescriptorReorder = makeGrid(scope: .allMedia, paths: ["b.jpg", "a.jpg"])
        #expect(
            gate.receive(sameDescriptorReorder)
                == [.apply(sameDescriptorReorder, change: .unchanged)]
        )
        #expect(gate.completeStructuralApply(applied: sameDescriptorReorder) == [])

        let sortFlip = CatalogMediaGridState(
            descriptor: CatalogQueryDescriptor(
                scope: .allMedia,
                sort: MediaSortOrder(field: .bestDate, direction: .ascending)
            ),
            orderedAssetIDs: ["a.jpg", "b.jpg"].map { makeAssetID(path: $0) }
        )
        #expect(gate.receive(sortFlip) == [.apply(sortFlip, change: .filterOrSort)])
    }

    // MARK: - Retained membership set

    @Test func gateRetainsOrderedIDSetConsistentWithArray() {
        let gate = MediaGridMutationGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(gate.displayedOrderedIDs.isEmpty)
        #expect(gate.displayedOrderedIDSet.isEmpty)

        #expect(gate.receive(first) == [.apply(first, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: first) == [])
        #expect(gate.displayedOrderedIDs == first.orderedAssetIDs)
        #expect(gate.displayedOrderedIDSet == Set(first.orderedAssetIDs))

        let reordered = makeGrid(scope: .allMedia, paths: ["c.jpg", "a.jpg", "b.jpg"])
        #expect(gate.receive(reordered) == [.apply(reordered, change: .unchanged)])
        #expect(gate.completeStructuralApply(applied: reordered) == [])
        #expect(gate.displayedOrderedIDs == reordered.orderedAssetIDs)
        #expect(gate.displayedOrderedIDSet == Set(reordered.orderedAssetIDs))
        #expect(gate.displayedOrderedIDSet.count == gate.displayedOrderedIDs.count)
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
